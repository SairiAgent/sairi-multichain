import copy
import datetime
import unittest

import _support  # noqa: F401  (path setup)
from sairi_tools import config
from sairi_tools.strict import StrictJSONError, load_path, loads

TODAY = datetime.date(2026, 10, 5)


def codes(report):
    return {issue.code for issue in report.issues}


def issue_paths(report):
    return {issue.path for issue in report.issues}


def synthetic_live():
    """SYNTHETIC TEST DATA ONLY: a live-shaped config whose addresses are local mock placeholders and whose
    "VERIFIED" evidence records are FAKE. It exercises validator logic; it is never written to
    config/networks/ and proves nothing about any deployment."""
    cfg = load_path(_support.LOCAL_CONFIG)
    cfg["environment"], cfg["mock"] = "live", False
    for side in config.SIDES:
        cfg["networks"][side]["chainId"] = config.LIVE_CHAIN_IDS[side]
        cfg["networks"][side]["name"] = config.LIVE_NETWORK_NAMES[side]
        cfg["networks"][side]["eid"] = config.LIVE_EIDS[side]
    for path in config.leaf_paths():
        side = path.split(".")[1] if path.startswith("networks.") else "representation"
        cfg["evidence"][path] = {
            "status": "VERIFIED",
            "source": "https://example.invalid/SYNTHETIC-TEST-ONLY-not-evidence",
            "retrievedAt": "2026-10-01",
            "chainId": config.LIVE_CHAIN_IDS[side],
            "pinnedBlock": 123456,
            "codeVerified": True,
            "codeHash": "0x" + "ab" * 32,
            "configuredValue": config.leaf_value(cfg, path),
        }
    return cfg


class LocalConfigTest(unittest.TestCase):
    def setUp(self):
        self.cfg = load_path(_support.LOCAL_CONFIG)

    def check(self, cfg=None):
        return config.validate(cfg if cfg is not None else self.cfg, today=TODAY)

    def test_committed_local_fixture_is_valid_and_typed(self):
        report = self.check()
        self.assertTrue(report.ok, report.to_dict())
        self.assertEqual(report.config.environment, "local-mock")
        self.assertEqual(report.config.fees.creator_fee_bps, 100)
        self.assertEqual(report.config.representation.token_decimals, 12)
        self.assertEqual(report.to_dict()["status"], "VALID")

    def test_missing_key(self):
        del self.cfg["networks"]["canonical"]["eid"]
        report = self.check()
        self.assertFalse(report.ok)
        self.assertIn("networks.canonical.eid", issue_paths(report))
        self.assertIn("MISSING_KEY", codes(report))

    def test_unknown_key(self):
        self.cfg["networks"]["canonical"]["rpc"] = "https://example.invalid"
        self.assertIn("UNKNOWN_KEY", codes(self.check()))

    def test_null_local_value_is_missing(self):
        self.cfg["networks"]["representation"]["weth"] = None
        self.assertIn("MISSING", codes(self.check()))

    def test_bool_never_passes_integer_validation(self):
        for path in (("sharedDecimals",), ("networks", "canonical", "eid"), ("networks", "canonical", "tokenDecimals"),
                     ("limits", "rateWindowSeconds"), ("fees", "creatorFeeBps")):
            cfg = copy.deepcopy(self.cfg)
            target = cfg
            for key in path[:-1]:
                target = target[key]
            target[path[-1]] = True
            report = self.check(cfg)
            self.assertFalse(report.ok, path)
            self.assertIn("TYPE", codes(report), path)

    def test_string_number_rejected(self):
        self.cfg["networks"]["canonical"]["chainId"] = "31337"
        self.assertIn("TYPE", codes(self.check()))

    def test_invalid_ids(self):
        for value, code in ((0, "RANGE"), (2**32, "RANGE"), (-1, "RANGE")):
            cfg = copy.deepcopy(self.cfg)
            cfg["networks"]["canonical"]["eid"] = value
            self.assertIn(code, codes(self.check(cfg)), value)
        cfg = copy.deepcopy(self.cfg)
        cfg["networks"]["representation"]["eid"] = cfg["networks"]["canonical"]["eid"]
        self.assertIn("DUPLICATE_EID", codes(self.check(cfg)))
        cfg = copy.deepcopy(self.cfg)
        cfg["networks"]["representation"]["chainId"] = cfg["networks"]["canonical"]["chainId"]
        self.assertIn("DUPLICATE_CHAIN", codes(self.check(cfg)))

    def test_local_fixture_cannot_use_live_chain_ids(self):
        self.cfg["networks"]["canonical"]["chainId"] = 8453
        self.assertIn("LOCAL_USES_LIVE_ID", codes(self.check()))

    def test_decimals_bounds(self):
        for value in (19, -1):
            cfg = copy.deepcopy(self.cfg)
            cfg["networks"]["canonical"]["tokenDecimals"] = value
            self.assertIn("RANGE", codes(self.check(cfg)))
        self.cfg["sharedDecimals"] = 13  # representation token has 12
        report = self.check()
        self.assertIn("DECIMALS", codes(report))
        self.cfg["sharedDecimals"] = 12
        self.assertTrue(self.check().ok)
        self.cfg["networks"]["canonical"]["tokenDecimals"] = 0
        self.cfg["networks"]["representation"]["tokenDecimals"] = 0
        self.cfg["sharedDecimals"] = 0
        self.assertTrue(self.check().ok)

    def test_addresses(self):
        bad = ("0x" + "0" * 40, "0x" + "a1" * 19, "a1" * 21, "0x" + "A1" * 20, "0x" + "g1" * 20, 1)
        for value in bad:
            cfg = copy.deepcopy(self.cfg)
            cfg["networks"]["representation"]["dex"] = value
            self.assertIn("ADDRESS", codes(self.check(cfg)), value)

    def test_recipients_treasury_must_not_alias_tokens(self):
        for key in ("token", "bridgeApp", "weth", "endpoint", "dex"):
            cfg = copy.deepcopy(self.cfg)
            cfg["creatorBeneficiary"] = cfg["networks"]["canonical"][key]
            self.assertIn("TREASURY_ALIAS", codes(self.check(cfg)), key)
        self.cfg["creatorBeneficiary"] = self.cfg["networks"]["representation"]["token"]
        self.assertIn("TREASURY_ALIAS", codes(self.check()))

    def test_peers_and_tokens_cross_checked(self):
        cfg = copy.deepcopy(self.cfg)
        cfg["networks"]["canonical"]["peer"] = "0x" + "e1" * 20
        self.assertIn("PEER", codes(self.check(cfg)))
        cfg = copy.deepcopy(self.cfg)
        cfg["networks"]["representation"]["token"] = "0x" + "e2" * 20
        self.assertIn("TOKEN", codes(self.check(cfg)))
        cfg = copy.deepcopy(self.cfg)
        cfg["networks"]["canonical"]["weth"] = cfg["networks"]["canonical"]["token"]
        self.assertIn("DUPLICATE_ADDRESS", codes(self.check(cfg)))

    def test_fees_must_match_solidity(self):
        self.cfg["fees"]["lpFeeBps"] = 25
        self.assertIn("FEE_MISMATCH", codes(self.check()))

    def test_environment_markers_strict(self):
        cfg = copy.deepcopy(self.cfg)
        cfg["environment"] = "production"
        self.assertIn("ENVIRONMENT", codes(self.check(cfg)))
        cfg = copy.deepcopy(self.cfg)
        cfg["mock"] = False
        self.assertIn("ENVIRONMENT", codes(self.check(cfg)))
        cfg = copy.deepcopy(self.cfg)
        cfg["mock"] = 1
        self.assertIn("ENVIRONMENT", codes(self.check(cfg)))
        cfg = copy.deepcopy(self.cfg)
        cfg["schemaVersion"] = True
        self.assertIn("SCHEMA", codes(self.check(cfg)))

    def test_local_fixture_cannot_claim_evidence(self):
        self.cfg["evidence"] = synthetic_live()["evidence"]
        self.assertIn("LOCAL_EVIDENCE", codes(self.check()))

    def test_documentary_reference_cannot_be_verified(self):
        self.cfg["documentaryReferences"] = [{"id": "x", "network": "base", "field": "eid", "value": 1,
                                              "source": "doc", "status": "VERIFIED"}]
        self.assertIn("DOC_REF_STATUS", codes(self.check()))

    def test_non_object_rejected(self):
        self.assertFalse(config.validate([], today=TODAY).ok)
        self.assertFalse(config.validate(None, today=TODAY).ok)

    def test_documentary_reference_malformed_status_rejected_cleanly(self):
        for status in (["UNVERIFIED"], {"UNVERIFIED": 1}, None, 1, True):
            cfg = copy.deepcopy(self.cfg)
            cfg["documentaryReferences"] = [{"id": "x", "network": "base", "field": "eid", "value": 1,
                                             "source": "doc", "status": status}]
            report = self.check(cfg)  # must not raise TypeError on unhashable values
            self.assertFalse(report.ok, status)
            self.assertIn("DOC_REF_STATUS", codes(report), status)
            self.assertEqual(report.to_dict()["status"], "REJECTED")
        cfg = copy.deepcopy(self.cfg)
        cfg["documentaryReferences"] = [["not", "an", "object"], "x"]
        self.assertIn("TYPE", codes(self.check(cfg)))

    def test_local_fixture_cannot_use_live_eids(self):
        self.cfg["networks"]["representation"]["eid"] = config.LIVE_EIDS["representation"]
        self.assertIn("LOCAL_USES_LIVE_ID", codes(self.check()))

    def test_malformed_types_never_raise(self):
        junk = ([], {}, [1, 2], {"a": []}, None, True, -1, 2**300)
        targets = [("environment",), ("mock",), ("schemaVersion",), ("documentaryReferences",), ("evidence",),
                   ("fees",), ("limits",), ("networks",), ("networks", "canonical"), ("networks", "canonical", "name"),
                   ("networks", "canonical", "eid"), ("networks", "representation", "token"), ("creatorBeneficiary",)]
        for path in targets:
            for value in junk:
                cfg = copy.deepcopy(self.cfg)
                node = cfg
                for key in path[:-1]:
                    node = node[key]
                if config.same_json_value(node[path[-1]], value):
                    continue  # e.g. mock=True or documentaryReferences=[] are the valid fixture values
                node[path[-1]] = value
                report = self.check(cfg)
                self.assertFalse(report.ok, (path, value))
                self.assertEqual(report.to_dict()["status"], "REJECTED")


class LiveConfigTest(unittest.TestCase):
    def test_committed_live_config_fails_closed(self):
        cfg = load_path(_support.LIVE_CONFIG)
        report = config.validate(cfg, today=TODAY)
        self.assertFalse(report.ok)
        self.assertIsNone(report.config)
        self.assertIn("BLOCKED_UNKNOWN", codes(report))
        self.assertIn("EVIDENCE_MISSING", codes(report))
        blocked = {i.path for i in report.issues if i.code == "BLOCKED_UNKNOWN"}
        for side in config.SIDES:
            for key in ("endpoint", "bridgeApp", "peer", "token", "weth", "dex", "eid", "tokenDecimals"):
                self.assertIn(f"networks.{side}.{key}", blocked)
        self.assertIn("creatorBeneficiary", blocked)

    def test_documentary_ids_recorded_separately_not_promoted(self):
        cfg = load_path(_support.LIVE_CONFIG)
        documented = {(r["network"], r["field"]): r["value"] for r in cfg["documentaryReferences"]}
        self.assertEqual(documented[("base", "eid")], 30184)
        self.assertEqual(documented[("robinhood-mainnet", "eid")], 30416)
        self.assertTrue(all(r["status"] == "UNVERIFIED" for r in cfg["documentaryReferences"]))
        for side in config.SIDES:
            for key in ("eid", "endpoint", "weth", "token", "peer", "dex", "bridgeApp"):
                self.assertIsNone(cfg["networks"][side][key])
        self.assertIsNone(cfg["creatorBeneficiary"])

    def test_fully_evidenced_synthetic_live_shape_validates(self):
        report = config.validate(synthetic_live(), today=TODAY)
        self.assertTrue(report.ok, report.to_dict())
        self.assertEqual(report.config.canonical.chain_id, 8453)
        self.assertEqual(report.config.representation.chain_id, 4663)
        self.assertEqual((report.config.canonical.eid, report.config.representation.eid), (30184, 30416))
        # Even a VALID record check is offline only and never claims a verified deployment.
        self.assertIs(report.to_dict()["deploymentVerified"], False)
        self.assertEqual(report.to_dict()["verificationScope"], config.VERIFICATION_SCOPE)

    def test_committed_live_config_has_no_evidence_or_values_to_promote(self):
        cfg = load_path(_support.LIVE_CONFIG)
        self.assertEqual(cfg["evidence"], {})
        report = config.validate(cfg, today=TODAY).to_dict()
        self.assertEqual(report["status"], "REJECTED")
        self.assertIs(report["deploymentVerified"], False)

    def test_live_eids_must_match_documented_layerzero_ids(self):
        for side, wrong in (("canonical", 30416), ("canonical", 30185), ("representation", 30184),
                            ("representation", 101)):
            def f(c, side=side, wrong=wrong):
                c["networks"][side]["eid"] = wrong
                c["evidence"][f"networks.{side}.eid"]["configuredValue"] = wrong  # evidence "agrees"
            self.assertIn("LIVE_EID", self.mutate(f), (side, wrong))

    def test_evidence_bound_to_exact_configured_value(self):
        def changed_address(c):
            c["networks"]["representation"]["dex"] = "0x" + "e5" * 20  # old evidence retained
        self.assertIn("EVIDENCE_VALUE_MISMATCH", self.mutate(changed_address))

        def changed_decimals(c):
            c["networks"]["representation"]["tokenDecimals"] = 6
        self.assertIn("EVIDENCE_VALUE_MISMATCH", self.mutate(changed_decimals))

        def changed_rate(c):
            c["limits"]["rateLimitPerWindow"] = 1
        self.assertIn("EVIDENCE_VALUE_MISMATCH", self.mutate(changed_rate))

        def wrong_type(c):
            c["evidence"]["networks.canonical.tokenDecimals"]["configuredValue"] = "18"
        self.assertIn("EVIDENCE_VALUE_MISMATCH", self.mutate(wrong_type))

        def bool_for_int(c):
            c["sharedDecimals"] = 1
            c["networks"]["canonical"]["tokenDecimals"] = 1
            c["networks"]["representation"]["tokenDecimals"] = 1
            for path in ("sharedDecimals", "networks.canonical.tokenDecimals"):
                c["evidence"][path]["configuredValue"] = 1
            c["evidence"]["networks.representation.tokenDecimals"]["configuredValue"] = True
        self.assertIn("EVIDENCE_VALUE_MISMATCH", self.mutate(bool_for_int))

        def missing_value(c):
            del c["evidence"]["owner"]["configuredValue"]
        self.assertIn("MISSING_KEY", self.mutate(missing_value))

    def test_zero_code_hash_rejected(self):
        def f(c):
            c["evidence"]["networks.canonical.token"]["codeHash"] = "0x" + "0" * 64
        self.assertIn("EVIDENCE_CODE", self.mutate(f))

    def test_source_url_userinfo_and_shape(self):
        # Placeholder-only strings, assembled so no credential-shaped literal exists in the repository.
        host = "example.invalid"
        bad = [
            "https://" + "token" + "@" + host + "/x",
            "https://" + "user:" + "placeholder" + "@" + host + "/x",
            "https://" + ":" + "placeholder" + "@" + host + "/x",
            "https://" + "@" + host + "/x",
            "https:///x",
            "https://",
            "https:" + host + "/x",
            "https://" + host + ":notaport/x",
            "https://[" + host,
            "https://" + host + "/x?" + "access_token" + "=" + "placeholder",
            "https://" + host + "/x?a=1&" + "API_KEY" + "=" + "placeholder",
            "https://" + host + "/x " + "y",
            "ftp://" + host + "/x",
            "HTTP://" + host + "/x",
        ]
        for url in bad:
            self.assertFalse(config.is_safe_https_url(url), url)

            def f(c, url=url):
                c["evidence"]["owner"]["source"] = url
            self.assertIn("EVIDENCE_SOURCE", self.mutate(f), url)
        for url in ("https://" + host + "/record?block=1&chain=8453", "HTTPS://" + host + "/a#frag"):
            self.assertTrue(config.is_safe_https_url(url), url)
        for value in (None, 1, ["https://" + host], {"url": "https://" + host}):
            self.assertFalse(config.is_safe_https_url(value))

    def mutate(self, fn):
        cfg = synthetic_live()
        fn(cfg)
        report = config.validate(cfg, today=TODAY)
        self.assertFalse(report.ok)
        return codes(report)

    def test_live_null_value_blocked(self):
        def f(c):
            c["networks"]["representation"]["weth"] = None
        self.assertIn("BLOCKED_UNKNOWN", self.mutate(f))

    def test_live_chain_ids_enforced(self):
        def f(c):
            c["networks"]["canonical"]["chainId"] = 1
        self.assertIn("LIVE_CHAIN", self.mutate(f))

        def g(c):
            c["networks"]["canonical"]["chainId"], c["networks"]["representation"]["chainId"] = 4663, 8453
        self.assertIn("LIVE_CHAIN", self.mutate(g))

    def test_every_field_needs_evidence(self):
        for path in config.leaf_paths():
            cfg = synthetic_live()
            del cfg["evidence"][path]
            report = config.validate(cfg, today=TODAY)
            self.assertIn("EVIDENCE_MISSING", codes(report), path)

    def test_evidence_fields(self):
        cases = {
            "status": ("UNVERIFIED", "EVIDENCE_UNVERIFIED"),
            "source": ("http://example.invalid/x", "EVIDENCE_SOURCE"),
            "retrievedAt": ("2099-01-01", "EVIDENCE_DATE"),
            "chainId": (31337, "EVIDENCE_NETWORK"),
            "pinnedBlock": (True, "EVIDENCE_BLOCK"),
            "codeVerified": (1, "EVIDENCE_CODE"),
            "codeHash": ("0x1234", "EVIDENCE_CODE"),
        }
        for key, (value, code) in cases.items():
            def f(c, key=key, value=value):
                c["evidence"]["networks.canonical.token"][key] = value
            self.assertIn(code, self.mutate(f), key)

        def bad_date(c):
            c["evidence"]["owner"]["retrievedAt"] = "2026-02-30"
        self.assertIn("EVIDENCE_DATE", self.mutate(bad_date))

        def credential_url(c):
            c["evidence"]["owner"]["source"] = "https://user:" + "placeholder" + "@example.invalid/x"
        self.assertIn("EVIDENCE_SOURCE", self.mutate(credential_url))

        def wrong_network(c):
            c["evidence"]["networks.representation.weth"]["chainId"] = 8453
        self.assertIn("EVIDENCE_NETWORK", self.mutate(wrong_network))

        def unknown_path(c):
            c["evidence"]["networks.canonical.rpc"] = c["evidence"]["owner"]
        self.assertIn("UNKNOWN_KEY", self.mutate(unknown_path))


class StrictJSONTest(unittest.TestCase):
    def test_rejects_floats_constants_and_duplicates(self):
        for text in ('{"a": 1.0}', '{"a": 1e3}', '{"a": NaN}', '{"a": Infinity}', '{"a": 1, "a": 2}'):
            with self.assertRaises(StrictJSONError, msg=text):
                loads(text)

    def test_accepts_big_integers_exactly(self):
        self.assertEqual(loads('{"a": 340282366920938463463374607431768211455}')["a"], 2**128 - 1)


if __name__ == "__main__":
    unittest.main()
