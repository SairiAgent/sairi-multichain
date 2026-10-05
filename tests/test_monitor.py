import copy
import unittest

import _support
from sairi_tools import monitor
from sairi_tools.strict import StrictJSONError, load_path, loads

NOW = _support.MONITOR_NOW


def reason_codes(result):
    return {r["code"] for r in result["reasons"]}


class MonitorFixtureTest(unittest.TestCase):
    def test_committed_fixtures(self):
        expected = {
            "monitor-safe.json": monitor.SAFE,
            "monitor-unsafe.json": monitor.UNSAFE,
            "monitor-stale.json": monitor.STALE,
            "monitor-incoherent.json": monitor.UNKNOWN,
        }
        for name, status in expected.items():
            result = monitor.evaluate(load_path(_support.fixture(name)), NOW)
            self.assertEqual(result["status"], status, (name, result["reasons"]))
            self.assertTrue(result["synthetic"])
            self.assertIn("SYNTHETIC_FIXTURE", reason_codes(result))

    def test_unsafe_fixture_is_balance_loss_with_unchanged_tracked_total(self):
        result = monitor.evaluate(load_path(_support.fixture("monitor-unsafe.json")), NOW)
        self.assertEqual(result["status"], monitor.UNSAFE)
        self.assertEqual(result["trackedLocked"], result["requiredBacking"])  # bookkeeping still "balanced"
        self.assertIn("OBSERVED_BELOW_TRACKED", reason_codes(result))
        self.assertIn("BACKING_DEFICIT", reason_codes(result))

    def test_nonsynthetic_fixture_fails_closed(self):
        result = monitor.evaluate(load_path(_support.fixture("monitor-nonsynthetic.json")), NOW)
        self.assertEqual(result["status"], monitor.UNKNOWN)
        self.assertIs(result["synthetic"], False)
        self.assertIn("LIVE_EVIDENCE_UNVERIFIED", reason_codes(result))
        self.assertNotIn("SYNTHETIC_FIXTURE", reason_codes(result))
        self.assertEqual(result["liveEvidenceCollector"], "ABSENT")


class MonitorTest(unittest.TestCase):
    def setUp(self):
        self.snap = load_path(_support.fixture("monitor-safe.json"))

    def evaluate(self, snap=None, now=NOW):
        return monitor.evaluate(snap if snap is not None else self.snap, now)

    def set_all(self, key, value):
        for obs in self.snap["observations"].values():
            obs[key] = value

    def test_coherent_safe_reports_values(self):
        result = self.evaluate()
        self.assertEqual(result["status"], monitor.SAFE)
        self.assertEqual(result["values"], {"L": 505_000_000_000, "R": 500_000_000_000, "P": 5_000_000_000, "Q": 0})
        self.assertEqual(result["requiredBacking"], 505_000_000_000)
        self.assertEqual(result["surplus"], 0)
        self.assertEqual(result["checkpoint"], {"epoch": 42, "ledgerCheckpoint": "local-ledger-42"})

    def test_surplus_is_safe(self):
        self.snap["observations"]["L"]["value"] += 7
        result = self.evaluate()
        self.assertEqual(result["status"], monitor.SAFE)
        self.assertEqual(result["surplus"], 7)

    def test_deficit_unsafe_including_pending(self):
        for name in ("R", "P", "Q"):
            snap = copy.deepcopy(self.snap)
            snap["observations"][name]["value"] += 1
            result = self.evaluate(snap)
            self.assertEqual(result["status"], monitor.UNSAFE, name)
            self.assertEqual(result["surplus"], -1)
            self.assertIn("BACKING_DEFICIT", reason_codes(result))

    def test_incoherent_epoch_or_checkpoint_is_unknown(self):
        snap = copy.deepcopy(self.snap)
        snap["observations"]["R"]["epoch"] = 43
        result = self.evaluate(snap)
        self.assertEqual(result["status"], monitor.UNKNOWN)
        self.assertIn("INCOHERENT_CHECKPOINT", reason_codes(result))
        self.assertIsNone(result["checkpoint"])
        snap = copy.deepcopy(self.snap)
        snap["observations"]["Q"]["ledgerCheckpoint"] = "local-ledger-41"
        self.assertEqual(self.evaluate(snap)["status"], monitor.UNKNOWN)

    def test_not_finalized_is_unknown(self):
        self.snap["observations"]["P"]["finalized"] = False
        result = self.evaluate()
        self.assertEqual(result["status"], monitor.UNKNOWN)
        self.assertIn("NOT_FINALIZED", reason_codes(result))

    def test_absent_evidence_is_unknown(self):
        self.snap["observations"]["L"]["evidence"] = None
        result = self.evaluate()
        self.assertEqual(result["status"], monitor.UNKNOWN)
        self.assertIn("EVIDENCE_ABSENT", reason_codes(result))

    def test_unknown_units_or_decimals_is_unknown(self):
        snap = copy.deepcopy(self.snap)
        snap["observations"]["R"]["units"] = "local-decimal"
        self.assertEqual(self.evaluate(snap)["status"], monitor.UNKNOWN)
        snap = copy.deepcopy(self.snap)
        snap["observations"]["R"]["decimals"] = 12
        result = self.evaluate(snap)
        self.assertEqual(result["status"], monitor.UNKNOWN)
        self.assertIn("UNKNOWN_UNITS", reason_codes(result))

    def test_null_value_or_missing_observation_is_unknown(self):
        snap = copy.deepcopy(self.snap)
        snap["observations"]["Q"]["value"] = None
        result = self.evaluate(snap)
        self.assertEqual(result["status"], monitor.UNKNOWN)
        self.assertIsNone(result["requiredBacking"])
        snap = copy.deepcopy(self.snap)
        del snap["observations"]["P"]
        result = self.evaluate(snap)
        self.assertEqual(result["status"], monitor.UNKNOWN)
        self.assertIn("MISSING_OBSERVATION", reason_codes(result))
        self.assertIsNone(result["checkpoint"])

    def test_stale(self):
        self.snap["observations"]["L"]["observedAt"] = NOW - 301
        result = self.evaluate()
        self.assertEqual(result["status"], monitor.STALE)

    def test_age_equal_to_max_is_fresh(self):
        self.set_all("observedAt", NOW - 300)
        self.assertEqual(self.evaluate()["status"], monitor.SAFE)

    def test_stale_deficit_reported_but_stale_takes_precedence(self):
        self.snap["observations"]["R"]["value"] += 1
        self.snap["observations"]["R"]["observedAt"] = NOW - 1_000
        result = self.evaluate()
        self.assertEqual(result["status"], monitor.STALE)
        self.assertIn("BACKING_DEFICIT", reason_codes(result))

    def test_future_timestamp_invalid(self):
        self.snap["observations"]["L"]["observedAt"] = NOW + 1
        result = self.evaluate()
        self.assertEqual(result["status"], monitor.INVALID)
        self.assertIn("FUTURE_TIMESTAMP", reason_codes(result))

    def test_malformed_amounts_invalid(self):
        for bad in (True, False, "505000000000", -1, 1.5, [1], {"v": 1}):
            snap = copy.deepcopy(self.snap)
            snap["observations"]["L"]["value"] = bad
            result = self.evaluate(snap)
            self.assertEqual(result["status"], monitor.INVALID, bad)
            self.assertIsNone(result["values"]["L"], bad)

    def test_malformed_fields_invalid(self):
        mutations = [
            ("finalized", 1), ("finalized", "true"), ("observedAt", True), ("observedAt", -5),
            ("observedAt", "1700000500"), ("epoch", True), ("epoch", -1), ("ledgerCheckpoint", ""),
            ("evidence", {"source": "x"}), ("evidence", {"source": "x", "chainId": True, "blockNumber": 1}),
        ]
        for key, value in mutations:
            snap = copy.deepcopy(self.snap)
            snap["observations"]["L"][key] = value
            self.assertEqual(self.evaluate(snap)["status"], monitor.INVALID, (key, value))

    def test_malformed_snapshot_shape(self):
        snap = copy.deepcopy(self.snap)
        snap["observations"]["L"]["extra"] = 1
        self.assertEqual(self.evaluate(snap)["status"], monitor.INVALID)
        snap = copy.deepcopy(self.snap)
        snap["observations"]["X"] = snap["observations"]["L"]
        self.assertEqual(self.evaluate(snap)["status"], monitor.INVALID)
        snap = copy.deepcopy(self.snap)
        del snap["maxAgeSeconds"]
        self.assertEqual(self.evaluate(snap)["status"], monitor.INVALID)
        snap = copy.deepcopy(self.snap)
        snap["sharedDecimals"] = True
        self.assertEqual(self.evaluate(snap)["status"], monitor.INVALID)
        self.assertEqual(self.evaluate([])["status"], monitor.INVALID)

    def test_invalid_beats_unknown(self):
        self.snap["observations"]["L"]["value"] = -1
        self.snap["observations"]["R"]["finalized"] = False
        self.assertEqual(self.evaluate()["status"], monitor.INVALID)

    def test_float_amount_rejected_by_strict_loader(self):
        with self.assertRaises(StrictJSONError):
            loads('{"value": 1.0}')

    def test_invalid_now(self):
        with self.assertRaises(ValueError):
            self.evaluate(now=True)

    # ------------------------------------------------------------ observed L vs tracked totalLocked

    def test_lower_observed_balance_is_unsafe_even_if_tracked_total_unchanged(self):
        # Negative rebase / loss: balanceOf(lockbox) drops by 1 shared unit, totalLocked does not.
        self.snap["observations"]["L"]["value"] -= 1
        result = self.evaluate()
        self.assertEqual(result["status"], monitor.UNSAFE)
        self.assertEqual(result["trackedLocked"], result["requiredBacking"])
        self.assertEqual((result["surplus"], result["untrackedSurplus"]), (-1, -1))
        self.assertIn("OBSERVED_BELOW_TRACKED", reason_codes(result))
        self.assertIn("BACKING_DEFICIT", reason_codes(result))

    def test_donation_is_untracked_surplus_and_safe(self):
        self.snap["observations"]["L"]["value"] += 9
        result = self.evaluate()
        self.assertEqual(result["status"], monitor.SAFE)
        self.assertEqual((result["surplus"], result["untrackedSurplus"]), (9, 9))
        self.assertIn("UNTRACKED_SURPLUS", reason_codes(result))

    def test_tracked_total_never_substitutes_for_missing_observed_balance(self):
        del self.snap["observations"]["L"]
        result = self.evaluate()
        self.assertEqual(result["status"], monitor.UNKNOWN)
        self.assertIsNone(result["values"]["L"])
        self.assertIsNone(result["surplus"])
        self.assertEqual(result["trackedLocked"], 505_000_000_000)

    def test_tracked_ledger_mismatch(self):
        snap = copy.deepcopy(self.snap)
        snap["observations"][monitor.TRACKED]["value"] -= 1  # ledger records less than liabilities
        result = self.evaluate(snap)
        self.assertEqual(result["status"], monitor.UNSAFE)
        self.assertIn("TRACKED_LEDGER_MISMATCH", reason_codes(result))
        snap = copy.deepcopy(self.snap)
        snap["observations"]["L"]["value"] += 1
        snap["observations"][monitor.TRACKED]["value"] += 1  # tracked above liabilities: warning only
        result = self.evaluate(snap)
        self.assertEqual(result["status"], monitor.SAFE)
        self.assertIn("TRACKED_LEDGER_MISMATCH", reason_codes(result))

    def test_tracked_observation_held_to_same_rules(self):
        snap = copy.deepcopy(self.snap)
        snap["observations"][monitor.TRACKED]["epoch"] = 41
        self.assertEqual(self.evaluate(snap)["status"], monitor.UNKNOWN)
        snap = copy.deepcopy(self.snap)
        snap["observations"][monitor.TRACKED]["value"] = True
        self.assertEqual(self.evaluate(snap)["status"], monitor.INVALID)

    def test_tracked_is_optional(self):
        del self.snap["observations"][monitor.TRACKED]
        result = self.evaluate()
        self.assertEqual(result["status"], monitor.SAFE)
        self.assertIsNone(result["trackedLocked"])

    # ------------------------------------------------------------ non-synthetic fail-closed

    def test_nonsynthetic_never_safe(self):
        self.snap["synthetic"] = False
        result = self.evaluate()
        self.assertEqual(result["status"], monitor.UNKNOWN)
        self.assertIn("LIVE_EVIDENCE_UNVERIFIED", reason_codes(result))
        self.assertEqual(result["coherenceBasis"], "DECLARED_LABELS_ONLY_NOT_PROOF")

    def test_nonsynthetic_still_reports_deficit_reasons(self):
        self.snap["synthetic"] = False
        self.snap["observations"]["L"]["value"] -= 1
        result = self.evaluate()
        self.assertEqual(result["status"], monitor.UNKNOWN)
        self.assertIn("BACKING_DEFICIT", reason_codes(result))
        self.assertIn("OBSERVED_BELOW_TRACKED", reason_codes(result))
        self.assertEqual(result["surplus"], -1)

    def test_synthetic_flag_must_be_bool(self):
        for value in (1, 0, "true", None):
            snap = copy.deepcopy(self.snap)
            snap["synthetic"] = value
            self.assertEqual(self.evaluate(snap)["status"], monitor.INVALID, value)

    def test_malformed_units_types_do_not_raise(self):
        for value in ([], {}, ["shared-decimal"]):
            snap = copy.deepcopy(self.snap)
            snap["observations"]["R"]["units"] = value
            self.assertEqual(self.evaluate(snap)["status"], monitor.UNKNOWN, value)


if __name__ == "__main__":
    unittest.main()
