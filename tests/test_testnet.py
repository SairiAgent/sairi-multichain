"""Offline tests for the read-only testnet tooling. All chain data here is FAKE, served by an in-process
transport; nothing touches the network."""
import copy
import datetime
import json
import re
import unittest

import _support  # noqa: F401  (path setup)
from sairi_tools import rpc, testnet
from sairi_tools.keccak import keccak256, selector, to_checksum_address
from sairi_tools.strict import load_path

ROOT = _support.ROOT
CONFIG = ROOT / "config" / "testnet" / "base-sepolia-robinhood-testnet.json"
DEPLOYMENTS = ROOT / "tests" / "fixtures" / "testnet-not-deployed.json"
NOW = datetime.datetime(2026, 10, 6, tzinfo=datetime.UTC)


def word(value):
    return value.to_bytes(32, "big")


def addr_word(address):
    return rpc.enc_address(address)


def enc_uln(confirmations, required, optional=(), threshold=0):
    def arr(items):
        return word(len(items)) + b"".join(addr_word(a) for a in items)

    req, opt = arr(list(required)), arr(list(optional))
    head = (word(confirmations) + word(len(required)) + word(len(optional)) + word(threshold)
            + word(6 * 32) + word(6 * 32 + len(req)))
    return word(32) + head + req + opt


class FakeChain:
    """Answers the read-only JSON-RPC calls the tooling makes, from a dict of fake state."""

    def __init__(self, chain_cfg, remote_cfg, **overrides):
        c = chain_cfg
        self.chain_id = overrides.get("chain_id", c["chainId"])
        self.calls = []
        dvn = overrides.get("dvn", c["dvnLayerZeroLabs"])
        self.code = {a: b"\x60\x00" for a in (c[f] for f in testnet.ADDRESS_FIELDS)}
        uni = c.get("uniswapV4", {})
        for key in ("poolManager", "undocumentedCodeObservedAt"):
            if uni.get(key):
                self.code[uni[key]] = b"\x60\x01"
        self.code.update(overrides.get("code", {}))
        rem = remote_cfg["eid"]
        self.answers = {
            (c["endpoint"], "eid()"): word(overrides.get("eid", c["eid"])),
            (c["endpoint"], "isSupportedEid(uint32)"): word(1),
            (c["endpoint"], "defaultSendLibrary(uint32)"): addr_word(c["sendUln302"]),
            (c["endpoint"], "defaultReceiveLibrary(uint32)"): addr_word(c["receiveUln302"]),
            (c["sendUln302"], "getUlnConfig(address,uint32)"): enc_uln(c["sendConfirmations"], [dvn]),
            (c["receiveUln302"], "getUlnConfig(address,uint32)"): enc_uln(c["receiveConfirmations"], [dvn]),
            (c["sendUln302"], "getExecutorConfig(address,uint32)"): word(10000) + addr_word(c["executor"]),
            (c["endpoint"], "quote((uint32,bytes32,bytes,bytes,bool),address)"): word(10**14) + word(0),
        }
        self.answers.update(overrides.get("answers", {}))
        self.remote_eid = rem
        self.fail = overrides.get("fail")

    def __call__(self, payload):
        method, params = payload["method"], payload["params"]
        self.calls.append(method)
        if self.fail == method:
            return {"jsonrpc": "2.0", "id": payload["id"], "error": {"code": -32000, "message": "boom"}}
        if method == "eth_chainId":
            result = hex(self.chain_id)
        elif method == "eth_blockNumber":
            result = hex(1000)
        elif method == "eth_getBlockByNumber":
            result = {"hash": "0x" + "11" * 32}
        elif method == "eth_getCode":
            result = "0x" + self.code.get(params[0], b"").hex()
        elif method == "eth_call":
            data = bytes.fromhex(params[0]["data"][2:])
            key = next((k for k in self.answers if k[0] == params[0]["to"] and selector(k[1]) == data[:4]), None)
            if key is None:
                return {"jsonrpc": "2.0", "id": payload["id"], "error": {"code": 3, "message": "execution reverted"}}
            result = "0x" + self.answers[key].hex()
        else:
            raise AssertionError(f"unexpected method {method}")
        return {"jsonrpc": "2.0", "id": payload["id"], "result": result}


def clients(cfg, base_over=None, rh_over=None):
    b, r = cfg["chains"]["baseSepolia"], cfg["chains"]["robinhoodTestnet"]
    fb, fr = FakeChain(b, r, **(base_over or {})), FakeChain(r, b, **(rh_over or {}))
    return ({"baseSepolia": rpc.RpcClient(b["rpc"], transport=fb),
             "robinhoodTestnet": rpc.RpcClient(r["rpc"], transport=fr)}, fb, fr)


class KeccakTest(unittest.TestCase):
    def test_known_vectors(self):
        self.assertEqual(keccak256(b"").hex(), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        self.assertEqual(keccak256(b"abc").hex(),
                         "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        long = " ".join(["The quick brown fox jumps over the lazy dog."] * 5).encode()
        self.assertGreater(len(long), 136)  # multi-block absorb (vector from `cast keccak`)
        self.assertEqual(keccak256(long).hex(), "82b3938cecdd6cdef37a3a29a9b7324598071cf43ec343755696d05c3ac548e9")
        self.assertEqual(selector("transfer(address,uint256)").hex(), "a9059cbb")
        self.assertEqual(selector("eid()").hex(), "416ecebf")

    def test_eip55_vectors(self):
        for expected in ("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
                         "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB", "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb"):
            self.assertEqual(to_checksum_address(expected.lower()), expected)
        with self.assertRaises(ValueError):
            to_checksum_address("0x1234")
        with self.assertRaises(TypeError):
            keccak256("text")


class RpcSafetyTest(unittest.TestCase):
    def test_url_validation(self):
        rpc.validate_public_url("https://sepolia.base.org")
        userinfo_url = "https://user" + ":" + "pw" + "@host.example"  # assembled so the publication guard stays strict
        for bad in ("http://sepolia.base.org", userinfo_url, "https://host.example/?apikey=x",
                    "https://host.example/#frag", "ftp://host.example", "https://"):
            with self.assertRaises(ValueError, msg=bad):
                rpc.validate_public_url(bad)

    def test_only_read_only_methods(self):
        client = rpc.RpcClient("https://example.invalid", transport=lambda p: {"result": "0x1"})
        for method in ("eth_sendRawTransaction", "eth_sendTransaction", "eth_sign", "personal_sign"):
            with self.assertRaises(rpc.RpcError):
                client.call(method, [])

    def test_abi_decoders_reject_malformed(self):
        with self.assertRaises(rpc.RpcError):
            rpc.dec_address(b"\x01" * 32)
        with self.assertRaises(rpc.RpcError):
            rpc.dec_bool(word(2))
        with self.assertRaises(rpc.RpcError):
            rpc.dec_uint(b"\x00" * 31)
        uln = rpc.dec_uln_config(enc_uln(2, ["0x" + "ab" * 20], ["0x" + "cd" * 20], 1))
        self.assertEqual(uln["requiredDVNs"], ["0x" + "ab" * 20])
        self.assertEqual(uln["optionalDVNs"], ["0x" + "cd" * 20])
        self.assertEqual(uln["confirmations"], 2)

    def test_quote_calldata_layout(self):
        data = rpc.quote_calldata(40451, b"\0" * 32, b"\x01" * 40, b"\x02" * 22, "0x" + "00" * 19 + "01")
        self.assertEqual(data[:4], selector("quote((uint32,bytes32,bytes,bytes,bool),address)"))
        body = data[4:]
        self.assertEqual(rpc.dec_uint(body, 0), 64)  # tuple offset
        tup = body[64:]
        self.assertEqual(rpc.dec_uint(tup, 0), 40451)
        self.assertEqual(rpc.dec_uint(tup, rpc.dec_uint(tup, 2) // 32), 40)  # message length
        self.assertEqual(rpc.dec_uint(tup, rpc.dec_uint(tup, 3) // 32), 22)  # options length
        self.assertEqual(rpc.dec_uint(tup, 4), 0)  # payInLzToken = false


class ConfigTest(unittest.TestCase):
    def setUp(self):
        self.cfg = load_path(CONFIG)

    def test_repository_config_valid(self):
        chains = testnet.validate_config(self.cfg)
        self.assertEqual({c["chainId"] for c in chains.values()}, {84532, 46630})

    def _rejects(self, mutate):
        cfg = copy.deepcopy(self.cfg)
        mutate(cfg)
        with self.assertRaises(ValueError):
            testnet.validate_config(cfg)

    def test_mainnet_and_unknown_chains_rejected(self):
        for cid in (1, 8453, 4663, 11155111):
            self._rejects(lambda c, cid=cid: c["chains"]["baseSepolia"].__setitem__("chainId", cid))
        self._rejects(lambda c: c["chains"]["robinhoodTestnet"].__setitem__("chainId", 4663))
        self._rejects(lambda c: c.__setitem__("environment", "live"))

    def test_structural_rejections(self):
        self._rejects(lambda c: c["chains"]["baseSepolia"].__setitem__("rpc", "http://sepolia.base.org"))
        self._rejects(lambda c: c["chains"]["baseSepolia"].__setitem__("rpc", "https://k@sepolia.base.org"))
        self._rejects(lambda c: c["chains"]["baseSepolia"].__setitem__(
            "endpoint", "0x6EDCE65403992e310A62460808c4b910D972f10f"))
        self._rejects(lambda c: c["chains"]["baseSepolia"].__setitem__("sendConfirmations", 5))
        self._rejects(lambda c: c["chains"]["robinhoodTestnet"].__setitem__(
            "dvnLayerZeroLabs", c["chains"]["robinhoodTestnet"]["deadDvn"]))
        self._rejects(lambda c: c["chains"]["robinhoodTestnet"].__setitem__("chainKey", "base-sepolia"))
        self._rejects(lambda c: c["chains"].pop("robinhoodTestnet"))

    def test_mirrors_solidity_routes_and_makefile(self):
        sol = (ROOT / "script" / "testnet" / "TestnetRoutes.sol").read_text()
        make = (ROOT / "Makefile").read_text()
        literals = {a.lower() for a in re.findall(r"0x[0-9a-fA-F]{40}", sol)}
        for key, fn in (("baseSepolia", "baseSepolia"), ("robinhoodTestnet", "robinhoodTestnet")):
            c = self.cfg["chains"][key]
            block = sol[sol.index(f"function {fn}()"):]
            block = block[:block.index("}")]
            for field, sol_field in (("endpoint", "endpoint"), ("sendUln302", "sendLib"),
                                     ("receiveUln302", "receiveLib"), ("executor", "executor"),
                                     ("dvnLayerZeroLabs", "dvn")):
                m = re.search(rf"{sol_field}: (0x[0-9a-fA-F]{{40}})", block)
                self.assertIsNotNone(m, f"{key}.{field}")
                self.assertEqual(m.group(1).lower(), c[field], f"{key}.{field}")
                self.assertEqual(to_checksum_address(c[field]), m.group(1), f"{key}.{field} checksum")
                self.assertIn(c[field], literals)
            self.assertIn(f"sendConfirmations: {c['sendConfirmations']},", block)
            self.assertIn(f"receiveConfirmations: {c['receiveConfirmations']},", block)
        self.assertIn(f"BASE_SEPOLIA_RPC := {self.cfg['chains']['baseSepolia']['rpc']}", make)
        self.assertIn(f"ROBINHOOD_TESTNET_RPC := {self.cfg['chains']['robinhoodTestnet']['rpc']}", make)
        script = (ROOT / "script" / "testnet" / "SairiTestnet.s.sol").read_text()
        self.assertIn(f"LZ_RECEIVE_GAS = {self.cfg['lzReceiveGas']:_};", script)


class PreflightTest(unittest.TestCase):
    def setUp(self):
        self.cfg = load_path(CONFIG)

    def test_ready_with_expected_state(self):
        cl, fb, fr = clients(self.cfg)
        report = testnet.preflight(self.cfg, cl, now=NOW)
        self.assertEqual(report["status"], testnet.READY, report["blockers"])
        self.assertEqual(report["blockers"], [])
        self.assertTrue(report["mainnetProhibited"])
        self.assertEqual(report["chains"]["baseSepolia"]["blockNumber"], 1000 - testnet.HEAD_LAG_BLOCKS)
        self.assertFalse(report["chains"]["robinhoodTestnet"]["uniswapV4"]["documented"])
        self.assertNotIn("eth_sendRawTransaction", fb.calls + fr.calls)

    def test_wrong_chain_blocks_without_reading_state(self):
        cl, fb, _ = clients(self.cfg, base_over={"chain_id": 8453})
        report = testnet.preflight(self.cfg, cl, now=NOW)
        self.assertEqual(report["status"], testnet.BLOCKED)
        self.assertEqual(fb.calls, ["eth_chainId"])

    def test_dead_dvn_default_blocks(self):
        dead = self.cfg["chains"]["robinhoodTestnet"]["deadDvn"]
        cl, _, _ = clients(self.cfg, rh_over={"dvn": dead})
        report = testnet.preflight(self.cfg, cl, now=NOW)
        self.assertEqual(report["status"], testnet.BLOCKED)
        self.assertTrue(any("noDeadDvn" in b for b in report["blockers"]))

    def test_missing_code_eid_mismatch_and_rpc_errors_block(self):
        endpoint = self.cfg["chains"]["baseSepolia"]["endpoint"]
        for over in ({"code": {endpoint: b""}}, {"eid": 30184}, {"fail": "eth_getCode"},
                     {"answers": {(endpoint, "quote((uint32,bytes32,bytes,bytes,bool),address)"): word(0) + word(0)}}):
            cl, _, _ = clients(self.cfg, base_over=over)
            self.assertEqual(testnet.preflight(self.cfg, cl, now=NOW)["status"], testnet.BLOCKED, over)

    def test_unsupported_route_blocks(self):
        endpoint = self.cfg["chains"]["robinhoodTestnet"]["endpoint"]
        cl, _, _ = clients(self.cfg, rh_over={"answers": {(endpoint, "isSupportedEid(uint32)"): word(0)}})
        self.assertEqual(testnet.preflight(self.cfg, cl, now=NOW)["status"], testnet.BLOCKED)

    def test_invalid_config_is_invalid(self):
        cfg = copy.deepcopy(self.cfg)
        cfg["chains"]["baseSepolia"]["chainId"] = 8453
        cl, _, _ = clients(self.cfg)
        self.assertEqual(testnet.preflight(cfg, cl, now=NOW)["status"], testnet.INVALID)


class StatusTest(unittest.TestCase):
    OPERATOR, TOKEN, ADAPTER, BACKED = ("0x" + "0a" * 20, "0x" + "0b" * 20, "0x" + "0c" * 20, "0x" + "0d" * 20)

    def setUp(self):
        self.cfg = load_path(CONFIG)
        self.dep = load_path(DEPLOYMENTS)

    def test_empty_fixture_is_not_deployed(self):
        cl, _, _ = clients(self.cfg)
        out = testnet.status(self.cfg, self.dep, cl)
        self.assertEqual(out["status"], "NOT_DEPLOYED")

    def _deployed(self, locked, observed, supply, owner=None):
        dep = copy.deepcopy(self.dep)
        dep["operator"] = self.OPERATOR
        dep["baseSepolia"] = {"token": self.TOKEN, "adapter": self.ADAPTER}
        dep["robinhoodTestnet"] = {"backed": self.BACKED}
        b, r = self.cfg["chains"]["baseSepolia"], self.cfg["chains"]["robinhoodTestnet"]
        base_answers = {
            (self.ADAPTER, "token()"): addr_word(self.TOKEN),
            (self.ADAPTER, "endpoint()"): addr_word(b["endpoint"]),
            (self.ADAPTER, "peers(uint32)"): addr_word(self.BACKED),
            (self.ADAPTER, "owner()"): addr_word(owner or self.OPERATOR),
            (self.ADAPTER, "paused()"): word(0),
            (self.ADAPTER, "totalLocked()"): word(locked),
            (self.TOKEN, "balanceOf(address)"): word(observed),
        }
        rh_answers = {
            (self.BACKED, "endpoint()"): addr_word(r["endpoint"]),
            (self.BACKED, "peers(uint32)"): addr_word(self.ADAPTER),
            (self.BACKED, "owner()"): addr_word(self.OPERATOR),
            (self.BACKED, "paused()"): word(0),
            (self.BACKED, "totalSupply()"): word(supply),
            (self.BACKED, "balanceOf(address)"): word(supply),
        }
        cl, _, _ = clients(self.cfg, base_over={"answers": base_answers}, rh_over={"answers": rh_answers})
        return testnet.status(self.cfg, dep, cl)

    def test_every_balance_relation_is_unknown(self):
        """Unsynchronized, unfinalized two-chain reads with unmeasured P/Q never yield an accounting verdict."""
        cases = {
            (10, 10, 10): ("TRACKED_L_EQUALS_OBSERVED_R", "TRACKED_L_EQUALS_OBSERVED_ADAPTER_BALANCE"),
            (10, 10, 4): ("TRACKED_L_GREATER_THAN_OBSERVED_R", "TRACKED_L_EQUALS_OBSERVED_ADAPTER_BALANCE"),
            (10, 10, 11): ("TRACKED_L_LESS_THAN_OBSERVED_R", "TRACKED_L_EQUALS_OBSERVED_ADAPTER_BALANCE"),
            (10, 9, 10): ("TRACKED_L_EQUALS_OBSERVED_R", "TRACKED_L_GREATER_THAN_OBSERVED_ADAPTER_BALANCE"),
            (10, 12, 10): ("TRACKED_L_EQUALS_OBSERVED_R", "TRACKED_L_LESS_THAN_OBSERVED_ADAPTER_BALANCE"),
            (0, 0, 0): ("TRACKED_L_EQUALS_OBSERVED_R", "TRACKED_L_EQUALS_OBSERVED_ADAPTER_BALANCE"),
        }
        for (locked, observed, supply), (vs_r, vs_balance) in cases.items():
            out = self._deployed(locked, observed, supply)
            self.assertEqual(out["status"], testnet.UNKNOWN, (locked, observed, supply))
            rel = out["observations"]["balanceRelations"]
            self.assertEqual(rel["trackedLockedVsObservedRepresentationSupply"], vs_r)
            self.assertEqual(rel["trackedLockedVsObservedAdapterBalance"], vs_balance)
            self.assertFalse(out["finalityVerified"])
            self.assertFalse(out["inFlightLiabilitiesVerified"])
            self.assertFalse(out["snapshotSynchronized"])
            self.assertIsNone(out["accountingConclusion"])
            self.assertEqual(out["observations"]["totalLocked"], str(locked))
            self.assertEqual(out["observations"]["representationSupply"], str(supply))
            flat = json.dumps(out)
            for verdict in ("SETTLED", "PENDING_IN_FLIGHT", "UNSAFE", "SAFE\"", "SOLVENT", "INSOLVENT"):
                self.assertNotIn(verdict, flat)

    def test_structural_failures_block(self):
        self.assertEqual(self._deployed(10, 10, 10, owner="0x" + "ee" * 20)["status"], testnet.BLOCKED)
        cl, _, _ = clients(self.cfg, base_over={"chain_id": 8453})
        dep = copy.deepcopy(self.dep)
        dep["operator"] = self.OPERATOR
        dep["baseSepolia"] = {"token": self.TOKEN, "adapter": self.ADAPTER}
        dep["robinhoodTestnet"] = {"backed": self.BACKED}
        self.assertEqual(testnet.status(self.cfg, dep, cl)["status"], testnet.BLOCKED)

    def test_no_status_exits_zero(self):
        self.assertNotIn(0, testnet.STATUS_EXIT_CODES.values())
        self.assertEqual(testnet.STATUS_EXIT_CODES[testnet.UNKNOWN], 4)

    def test_bad_record_invalid(self):
        dep = copy.deepcopy(self.dep)
        dep["operator"] = "0xNOTANADDRESS"
        cl, _, _ = clients(self.cfg)
        self.assertEqual(testnet.status(self.cfg, dep, cl)["status"], testnet.INVALID)


class MessageLookupTest(unittest.TestCase):
    def setUp(self):
        self.cfg = load_path(CONFIG)

    def test_url_restrictions(self):
        tx = "0x" + "ab" * 32
        self.assertEqual(testnet.message_url(self.cfg, tx),
                         f"https://scan-testnet.layerzero-api.com/v1/messages/tx/{tx}")
        for bad in ("0x1234", "0x" + "AB" * 32, tx + "00"):
            with self.assertRaises(ValueError):
                testnet.message_url(self.cfg, bad)
        cfg = copy.deepcopy(self.cfg)
        cfg["sources"]["layerzeroScanApi"] = "https://scan.layerzero-api.com/v1"  # mainnet scan refused
        with self.assertRaises(ValueError):
            testnet.message_url(cfg, tx)

    def test_summary_and_delivery_status(self):
        payload = {"data": [{"guid": "0x01", "status": {"name": "DELIVERED"},
                             "pathway": {"srcEid": 40245, "dstEid": 40451, "nonce": 1,
                                         "sender": {"address": "0xa"}, "receiver": {"address": "0xb"}},
                             "source": {"tx": {"txHash": "0xs"}}, "destination": {"tx": {"txHash": "0xd"}}}]}

        class Resp:
            def __init__(self, body):
                self.body = body

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                import json
                return json.dumps(self.body).encode()

        out = testnet.fetch_message(self.cfg, "0x" + "ab" * 32, opener=lambda req, timeout: Resp(payload))
        self.assertEqual(out["status"], testnet.INDEXER_DELIVERED)
        self.assertIs(out["proof"], False)
        self.assertTrue(out["messages"][0]["onPinnedRoute"])
        payload["data"][0]["pathway"]["dstEid"] = 40161
        out = testnet.fetch_message(self.cfg, "0x" + "ab" * 32, opener=lambda req, timeout: Resp(payload))
        self.assertEqual(out["status"], testnet.INDEXER_NOT_DELIVERED)
        out = testnet.fetch_message(self.cfg, "0x" + "ab" * 32, opener=lambda req, timeout: Resp({"data": []}))
        self.assertEqual(out["status"], testnet.INDEXER_NOT_DELIVERED)


class CliTest(unittest.TestCase):
    def test_preflight_rejects_live_config_offline(self):
        code, out = _support.run_cli("testnet-preflight", _support.LIVE_CONFIG)
        self.assertEqual(code, 1)
        self.assertEqual(out["status"], testnet.INVALID)

    def test_status_and_message_reject_bad_inputs_offline(self):
        code, out = _support.run_cli("testnet-status", CONFIG, _support.LIVE_CONFIG)
        self.assertEqual(code, 5)
        self.assertEqual(out["status"], testnet.INVALID)
        self.assertFalse(out["inFlightLiabilitiesVerified"])
        # The dedicated fixture is all-null: NOT_DEPLOYED, with no network read.
        code, out = _support.run_cli("testnet-status", CONFIG, DEPLOYMENTS)
        self.assertEqual((code, out["status"]), (6, testnet.NOT_DEPLOYED))
        code, _ = _support.run_cli("testnet-status", CONFIG, DEPLOYMENTS, "--expect", "NOT_DEPLOYED")
        self.assertEqual(code, 0)
        code, _ = _support.run_cli("testnet-status", CONFIG, DEPLOYMENTS, "--expect", "UNKNOWN")
        self.assertEqual(code, 1)
        code, out = _support.run_cli("testnet-message", CONFIG, "0x1234")
        self.assertEqual(code, 1)
        self.assertEqual(out["status"], testnet.INVALID)


if __name__ == "__main__":
    unittest.main()
