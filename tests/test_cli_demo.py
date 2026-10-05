import contextlib
import io
import unittest

import _support
from sairi_tools import demo, monitor

NOW = _support.MONITOR_NOW


class DemoTest(unittest.TestCase):
    def setUp(self):
        self.report = demo.run()
        self.steps = self.report["steps"]

    def test_roundtrip_conserves_and_is_safe_every_step(self):
        self.assertTrue(self.report["ok"])
        self.assertEqual(len(self.steps), 10)
        for step in self.steps:
            self.assertEqual(step["monitorStatus"], monitor.SAFE, step)
            # Tracked ledger record reconciles exactly; observed backing (actual balance) covers it.
            self.assertEqual(step["trackedLocked"], step["R"] + step["P"] + step["Q"], step)
            self.assertGreaterEqual(step["L"], step["trackedLocked"], step)
        for step in self.steps[:-1]:
            self.assertEqual(step["L"], step["trackedLocked"], step)  # no donation yet
        _support.assert_no_floats(self, self.report)
        self.assertIn("balanceOf", self.report["lDefinition"])

    def test_donation_raises_observed_l_only(self):
        last = self.steps[-1]
        self.assertTrue(last["action"].startswith("donation"))
        self.assertEqual(last["L"] - last["trackedLocked"], demo.DONATION_LD // demo.CANON_RATE)
        self.assertEqual(last["trackedLocked"], self.steps[-2]["trackedLocked"])
        donation = self.report["reconciliation"]["donation"]
        self.assertEqual((donation["surplusSharedUnits"], donation["subSharedDecimalDustRaw"]), ("7", "3"))

    def test_ledger_balance_loss_would_be_flagged(self):
        ledger = demo.Ledger()
        ledger.relay(ledger.lock(10 * demo.CANON_RATE, "X"))
        ledger.lockbox_balance -= demo.CANON_RATE  # model a loss the tracked total does not see
        values = ledger.lrpq()
        snap = demo._snapshot(values, 1, ledger.checkpoint(), demo.DEMO_EPOCH_TIME)
        result = monitor.evaluate(snap, demo.DEMO_EPOCH_TIME)
        self.assertEqual(result["status"], monitor.UNSAFE)
        self.assertEqual(values["trackedLocked"], values["R"])

    def test_in_flight_liabilities_are_counted(self):
        in_flight_lock = self.steps[1]
        self.assertEqual(in_flight_lock["P"], 5_000 * 10**6)
        self.assertEqual(in_flight_lock["L"], 505_000 * 10**6)
        self.assertEqual(in_flight_lock["R"], 500_000 * 10**6)
        in_flight_burn = self.steps[6]
        self.assertTrue(in_flight_burn["action"].startswith("burn"))
        self.assertGreater(in_flight_burn["Q"], 0)
        self.assertEqual(in_flight_burn["P"], 0)
        final = self.steps[-1]
        self.assertEqual((final["P"], final["Q"]), (0, 0))

    def test_swaps_and_claims_reconcile(self):
        self.assertEqual(self.report["claims"]["WETH"]["claimedRaw"], str(2 * 10**16))
        self.assertEqual(self.report["claims"]["SAIRI"]["claimedRaw"], str(3 * 10**13))
        self.assertEqual([s["creatorFeeAsset"] for s in self.report["swaps"]], ["WETH", "SAIRI"])
        for group in self.report["reconciliation"].values():
            self.assertTrue(all(group.values()), group)

    def test_ledger_rejects_dust_and_replay(self):
        ledger = demo.Ledger()
        with self.assertRaises(demo.DemoError):
            ledger.lock(demo.CANON_RATE + 1, "X")
        index = ledger.lock(demo.CANON_RATE, "X")
        ledger.relay(index)
        with self.assertRaises(demo.DemoError):
            ledger.relay(index)


class CLITest(unittest.TestCase):
    def test_validate_local_and_expected_reject_live(self):
        code, out = _support.run_cli("validate-config", _support.LOCAL_CONFIG)
        self.assertEqual((code, out["status"]), (0, "VALID"))
        code, out = _support.run_cli("validate-config", _support.LIVE_CONFIG, "--expect-reject")
        self.assertEqual((code, out["status"], out["gate"]), (0, "REJECTED", "EXPECTED_REJECT_PASSED"))
        code, out = _support.run_cli("validate-config", _support.LIVE_CONFIG)
        self.assertEqual(code, 1)
        code, out = _support.run_cli("validate-config", _support.LOCAL_CONFIG, "--expect-reject")
        self.assertEqual((code, out["gate"]), (1, "FAIL_OPEN_DETECTED"))
        code, out = _support.run_cli("validate-config", _support.ROOT / "does-not-exist.json")
        self.assertEqual((code, out["status"]), (1, "REJECTED"))

    def test_monitor_exit_codes(self):
        for name, status in (("monitor-safe.json", "SAFE"), ("monitor-unsafe.json", "UNSAFE"),
                             ("monitor-stale.json", "STALE"), ("monitor-incoherent.json", "UNKNOWN"),
                             ("monitor-nonsynthetic.json", "UNKNOWN")):
            code, out = _support.run_cli("monitor", _support.fixture(name), "--now", NOW)
            self.assertEqual((code, out["status"]), (monitor.EXIT_CODES[status], status))
            code, out = _support.run_cli("monitor", _support.fixture(name), "--now", NOW, "--expect", status)
            self.assertEqual(code, 0)
        code, out = _support.run_cli("monitor", _support.fixture("monitor-safe.json"), "--now", NOW, "--expect", "UNSAFE")
        self.assertEqual(code, 1)

    def test_simulate_arguments(self):
        code, out = _support.run_cli("simulate", "--total-liquidity-usd", "240000", "--sairi-usd", "0.02",
                                     "--weth-usd", "2500", "--trade-usd", "100", "--trade-usd", "250.5")
        self.assertEqual(code, 0)
        self.assertEqual(len(out["cases"]), 4)
        self.assertEqual(out["assumptions"]["wethUsd"], "2500.000000000000000000")
        code, out = _support.run_cli("simulate", "--reserve-sairi", "1000000000000000000000000",
                                     "--reserve-weth", "10000000000000000000")
        self.assertEqual((code, out["initialReservesRaw"]["WETH"]), (0, "10000000000000000000"))
        code, out = _support.run_cli("simulate", "--reserve-sairi", "1")
        self.assertEqual(code, 2)

    def test_rejects_float_style_arguments(self):
        for argv in (("simulate", "--sairi-usd", "1e-2"), ("quote", "--reserve-in", "1.5", "--reserve-out", "1",
                                                          "--gross", "1")):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                _support.run_cli(*argv)

    def test_quote_matches_known_values(self):
        code, out = _support.run_cli("quote", "--reserve-in", "1000000", "--reserve-out", "1000000", "--gross", "10000",
                                     "--max-input", "20000")
        self.assertEqual(code, 0)
        self.assertEqual((out["creatorFeeRaw"], out["lpFeeRaw"], out["outputRaw"], out["untouchedRaw"]),
                         ("100", "29", "9774", "10000"))
        code, out = _support.run_cli("quote", "--reserve-in", "0", "--reserve-out", "1", "--gross", "1")
        self.assertEqual((code, out["error"]), (1, "NoLiquidity"))

    def test_demo_command(self):
        code, out = _support.run_cli("demo")
        self.assertEqual((code, out["ok"]), (0, True))


if __name__ == "__main__":
    unittest.main()
