"""Read-only TESTNET preflight / status / message lookup for Base Sepolia <-> Robinhood Chain testnet.

Fail-closed: any configuration problem, RPC error, chain mismatch or unexpected on-chain value yields a
non-READY status. Chains outside the two-entry testnet allowlist are rejected even if a config names them.
Nothing here signs, sends or holds keys; it only issues read-only JSON-RPC calls (see rpc.py) and, for
`message`, one HTTPS GET to the LayerZero Scan testnet API.
"""
import datetime
import json
import re
import urllib.parse
import urllib.request

from . import rpc
from .strict import is_int, is_nonzero_address

TESTNET_ALLOWLIST = {84532: "base-sepolia", 46630: "robinhood-testnet"}
# Explicitly refused even if a config file is edited to include them.
MAINNET_DENYLIST = {1, 10, 56, 137, 8453, 42161, 4663, 43114, 130, 7777777}
CHAIN_KEYS = ("baseSepolia", "robinhoodTestnet")
HEAD_LAG_BLOCKS = 5  # read slightly behind head: some public RPCs briefly refuse the newest block
TX_HASH_RE = re.compile(r"0x[0-9a-f]{64}")
READY, BLOCKED, INVALID, UNKNOWN, NOT_DEPLOYED = "READY", "BLOCKED", "INVALID", "UNKNOWN", "NOT_DEPLOYED"
# testnet-status exit codes (fail closed: no status ever exits 0, because no status proves backing).
STATUS_EXIT_CODES = {UNKNOWN: 4, BLOCKED: 1, NOT_DEPLOYED: 6, INVALID: 5}
ADDRESS_FIELDS = ("endpoint", "sendUln302", "receiveUln302", "executor", "dvnLayerZeroLabs", "deadDvn")


class ConfigError(ValueError):
    pass


def validate_config(cfg):
    """Structural, offline validation of the route expectations. Returns the chains dict."""
    if not isinstance(cfg, dict) or cfg.get("environment") != "testnet" or cfg.get("schemaVersion") != 1:
        raise ConfigError("expected a schemaVersion 1 testnet config")
    chains = cfg.get("chains")
    if not isinstance(chains, dict) or set(chains) != set(CHAIN_KEYS):
        raise ConfigError(f"chains must be exactly {CHAIN_KEYS}")
    for key in CHAIN_KEYS:
        c = chains[key]
        cid = c.get("chainId")
        if not is_int(cid) or cid in MAINNET_DENYLIST or cid not in TESTNET_ALLOWLIST:
            raise ConfigError(f"{key}: chainId {cid!r} is not an allowlisted testnet")
        if TESTNET_ALLOWLIST[cid] != c.get("chainKey"):
            raise ConfigError(f"{key}: chainKey does not match chainId {cid}")
        rpc.validate_public_url(c.get("rpc", ""))
        for field in ADDRESS_FIELDS:
            if not is_nonzero_address(c.get(field)):
                raise ConfigError(f"{key}.{field}: expected lowercase non-zero address")
        if c["dvnLayerZeroLabs"] == c["deadDvn"]:
            raise ConfigError(f"{key}: DVN must not be the dead DVN")
        for field in ("eid", "sendConfirmations", "receiveConfirmations", "maxMessageSize"):
            if not is_int(c.get(field)) or c[field] <= 0:
                raise ConfigError(f"{key}.{field}: expected positive integer")
        if c.get("remote") not in CHAIN_KEYS or c["remote"] == key:
            raise ConfigError(f"{key}.remote invalid")
    b, r = chains["baseSepolia"], chains["robinhoodTestnet"]
    if b["chainId"] == r["chainId"] or b["eid"] == r["eid"]:
        raise ConfigError("chains must be distinct")
    if b["sendConfirmations"] != r["receiveConfirmations"] or r["sendConfirmations"] != b["receiveConfirmations"]:
        raise ConfigError("send/receive confirmations must mirror across the route")
    if not is_int(cfg.get("oftMessageBytes")) or not is_int(cfg.get("lzReceiveGas")):
        raise ConfigError("oftMessageBytes and lzReceiveGas required")
    return chains


class _Checks:
    def __init__(self):
        self.items = []

    def add(self, chain, name, ok, observed, expected=None):
        entry = {"chain": chain, "check": name, "ok": bool(ok), "observed": observed}
        if expected is not None:
            entry["expected"] = expected
        self.items.append(entry)
        return ok

    @property
    def ok(self):
        return bool(self.items) and all(i["ok"] for i in self.items)


def _executor_options(gas):
    # Type-3 options: 0x0003 | worker 1 (executor) | size 17 | option 1 (lzReceive) | uint128 gas
    return bytes.fromhex("0003") + b"\x01" + (17).to_bytes(2, "big") + b"\x01" + gas.to_bytes(16, "big")


def _probe_chain(key, c, remote, client, checks, cfg):
    """Runs every read-only check for one chain. Returns the evidence dict."""
    evidence = {"chainKey": c["chainKey"], "rpc": c["rpc"]}
    chain_id = client.chain_id()
    evidence["chainId"] = chain_id
    if not checks.add(key, "chainId", chain_id == c["chainId"] and chain_id in TESTNET_ALLOWLIST, chain_id,
                      c["chainId"]):
        return evidence  # never read state from an unexpected chain
    block = client.block_number() - HEAD_LAG_BLOCKS
    evidence["blockNumber"] = block
    evidence["blockHash"] = client.block_hash(block)
    evidence["finalityVerified"] = False

    def call(to, sig, *words):
        return client.eth_call(to, rpc.calldata(sig, *words), block)

    contracts = {}
    for field in ADDRESS_FIELDS:
        code = client.code(c[field], block)
        contracts[field] = {"address": c[field], "runtimeBytes": len(code),
                            "runtimeCodeHash": rpc.code_hash(code) if code else None}
        checks.add(key, f"code:{field}", len(code) > 0, len(code))
    evidence["contracts"] = contracts

    eid = rpc.dec_uint(call(c["endpoint"], "eid()"))
    checks.add(key, "endpoint.eid", eid == c["eid"], eid, c["eid"])
    rem = remote["eid"]
    supported = rpc.dec_bool(call(c["endpoint"], "isSupportedEid(uint32)", rpc.enc_uint(rem)))
    checks.add(key, "endpoint.isSupportedEid(remote)", supported, supported, True)
    send_lib = rpc.dec_address(call(c["endpoint"], "defaultSendLibrary(uint32)", rpc.enc_uint(rem)))
    checks.add(key, "endpoint.defaultSendLibrary(remote)", send_lib == c["sendUln302"], send_lib, c["sendUln302"])
    recv_lib = rpc.dec_address(call(c["endpoint"], "defaultReceiveLibrary(uint32)", rpc.enc_uint(rem)))
    checks.add(key, "endpoint.defaultReceiveLibrary(remote)", recv_lib == c["receiveUln302"], recv_lib,
               c["receiveUln302"])

    zero = rpc.enc_address("0x" + "00" * 20)
    for lib_field, conf_field, label in (("sendUln302", "sendConfirmations", "send"),
                                         ("receiveUln302", "receiveConfirmations", "receive")):
        uln = rpc.dec_uln_config(call(c[lib_field], "getUlnConfig(address,uint32)", zero, rpc.enc_uint(rem)))
        evidence[f"default{label.title()}UlnConfig"] = uln
        expected = {"confirmations": c[conf_field], "requiredDVNs": [c["dvnLayerZeroLabs"]], "optionalDVNs": []}
        observed = {k: uln[k] for k in expected}
        checks.add(key, f"{label}Uln.defaultConfig", observed == expected, observed, expected)
        checks.add(key, f"{label}Uln.noDeadDvn", c["deadDvn"] not in uln["requiredDVNs"] + uln["optionalDVNs"],
                   uln["requiredDVNs"] + uln["optionalDVNs"])

    exec_raw = call(c["sendUln302"], "getExecutorConfig(address,uint32)", zero, rpc.enc_uint(rem))
    executor = {"maxMessageSize": rpc.dec_uint(exec_raw, 0), "executor": rpc.dec_address(exec_raw, 1)}
    evidence["defaultExecutorConfig"] = executor
    checks.add(key, "sendUln.defaultExecutor", executor["executor"] == c["executor"]
               and executor["maxMessageSize"] >= c["maxMessageSize"], executor,
               {"executor": c["executor"], "maxMessageSize": c["maxMessageSize"]})

    probe = b"\0" * 31 + b"\x01"
    message = b"\0" * (cfg["oftMessageBytes"] - 8) + (1).to_bytes(8, "big")
    try:
        fee_raw = client.eth_call(c["endpoint"], rpc.quote_calldata(
            rem, probe, message, _executor_options(cfg["lzReceiveGas"]), "0x" + "00" * 19 + "01"), block)
        native_fee = rpc.dec_uint(fee_raw, 0)
        evidence["quoteNativeFeeWei"] = str(native_fee)
        checks.add(key, "endpoint.quote(oft-sized message)", native_fee > 0, str(native_fee))
    except rpc.RpcError as err:
        checks.add(key, "endpoint.quote(oft-sized message)", False, str(err))

    uni = c.get("uniswapV4", {})
    address = uni.get("poolManager") or uni.get("undocumentedCodeObservedAt")
    if address:
        code = client.code(address, block)
        evidence["uniswapV4"] = {"documented": bool(uni.get("documented")), "address": address,
                                 "runtimeBytes": len(code), "runtimeCodeHash": rpc.code_hash(code) if code else None,
                                 "requiredForBridge": False}
    return evidence


def preflight(cfg, clients, now=None):
    """`clients` maps chain key -> RpcClient. Returns a JSON-serializable report."""
    report = {"kind": "TESTNET_READ_ONLY_PREFLIGHT", "status": INVALID, "mainnetProhibited": True,
              "retrievedAt": (now or datetime.datetime.now(datetime.UTC)).isoformat(timespec="seconds"),
              "chains": {}, "checks": [], "blockers": []}
    try:
        chains = validate_config(cfg)
    except (ConfigError, ValueError) as err:
        report["blockers"].append(f"config: {err}")
        return report
    checks = _Checks()
    for key in CHAIN_KEYS:
        try:
            report["chains"][key] = _probe_chain(key, chains[key], chains[chains[key]["remote"]], clients[key],
                                                 checks, cfg)
        except (rpc.RpcError, ValueError, KeyError) as err:
            checks.add(key, "rpc", False, str(err))
    report["checks"] = checks.items
    report["blockers"] += [f"{i['chain']}: {i['check']} -> {i['observed']}" for i in checks.items if not i["ok"]]
    report["status"] = READY if checks.ok else BLOCKED
    report["note"] = ("Unfinalized, unsynchronized reads at a recent block per chain. READY means the pinned "
                      "LayerZero route is present as expected; it is not a deployment or delivery proof.")
    return report


# ---------------------------------------------------------------------- status of a deployment

def validate_deployments(dep):
    if not isinstance(dep, dict) or dep.get("kind") != "TESTNET_DEPLOYMENT_RECORD":
        raise ConfigError("expected a TESTNET_DEPLOYMENT_RECORD")
    fields = {"operator": dep.get("operator"),
              "baseSepolia.token": (dep.get("baseSepolia") or {}).get("token"),
              "baseSepolia.adapter": (dep.get("baseSepolia") or {}).get("adapter"),
              "robinhoodTestnet.backed": (dep.get("robinhoodTestnet") or {}).get("backed")}
    missing = [k for k, v in fields.items() if v is None]
    bad = [k for k, v in fields.items() if v is not None and not is_nonzero_address(v)]
    if bad:
        raise ConfigError(f"invalid addresses: {bad}")
    return fields, missing


def status(cfg, dep, clients):
    """Structural checks plus raw observations of a recorded deployment. Never an accounting verdict."""
    out = {"kind": "TESTNET_DEPLOYMENT_STATUS", "status": INVALID, "checks": [], "blockers": [],
           **STATUS_EVIDENCE_FLAGS}
    try:
        chains = validate_config(cfg)
        fields, missing = validate_deployments(dep)
    except (ConfigError, ValueError) as err:
        out["blockers"].append(str(err))
        return out
    if missing:
        out["status"] = NOT_DEPLOYED
        out["blockers"].append(f"deployment record incomplete: {missing}")
        return out
    checks = _Checks()
    obs = {}
    try:
        b, r = chains["baseSepolia"], chains["robinhoodTestnet"]
        bc, rc = clients["baseSepolia"], clients["robinhoodTestnet"]
        for key, c, client in (("baseSepolia", b, bc), ("robinhoodTestnet", r, rc)):
            cid = client.chain_id()
            if not checks.add(key, "chainId", cid == c["chainId"], cid, c["chainId"]):
                raise rpc.RpcError(f"{key}: wrong chain")
        bblock, rblock = bc.block_number() - HEAD_LAG_BLOCKS, rc.block_number() - HEAD_LAG_BLOCKS
        adapter, token, backed, operator = (fields["baseSepolia.adapter"], fields["baseSepolia.token"],
                                            fields["robinhoodTestnet.backed"], fields["operator"])

        def bcall(to, sig, *w):
            return bc.eth_call(to, rpc.calldata(sig, *w), bblock)

        def rcall(to, sig, *w):
            return rc.eth_call(to, rpc.calldata(sig, *w), rblock)

        checks.add("baseSepolia", "adapter.token", rpc.dec_address(bcall(adapter, "token()")) == token,
                   rpc.dec_address(bcall(adapter, "token()")), token)
        for key, call, app, peer, c in (("baseSepolia", bcall, adapter, backed, b),
                                        ("robinhoodTestnet", rcall, backed, adapter, r)):
            checks.add(key, "endpoint", rpc.dec_address(call(app, "endpoint()")) == c["endpoint"],
                       rpc.dec_address(call(app, "endpoint()")), c["endpoint"])
            observed_peer = "0x" + call(app, "peers(uint32)", rpc.enc_uint(chains[c["remote"]]["eid"])).hex()
            checks.add(key, "peer", observed_peer == "0x" + rpc.enc_address(peer).hex(), observed_peer)
            checks.add(key, "owner", rpc.dec_address(call(app, "owner()")) == operator,
                       rpc.dec_address(call(app, "owner()")), operator)
            obs[f"{key}.paused"] = rpc.dec_bool(call(app, "paused()"))
        locked = rpc.dec_uint(bcall(adapter, "totalLocked()"))
        observed_l = rpc.dec_uint(bcall(token, "balanceOf(address)", rpc.enc_address(adapter)))
        supply = rpc.dec_uint(rcall(backed, "totalSupply()"))
        obs.update({"baseBlock": bblock, "robinhoodBlock": rblock, "totalLocked": str(locked),
                    "observedAdapterBalance": str(observed_l), "representationSupply": str(supply),
                    "operatorStandInBalance": str(rpc.dec_uint(bcall(token, "balanceOf(address)",
                                                                     rpc.enc_address(operator)))),
                    "operatorBackedBalance": str(rpc.dec_uint(rcall(backed, "balanceOf(address)",
                                                                    rpc.enc_address(operator))))})
        # Purely descriptive relations between raw numbers. They are NOT accounting conclusions: the two reads
        # are unfinalized, taken at unrelated blocks, and in-flight P/Q are not measured.
        obs["balanceRelations"] = {
            "trackedLockedVsObservedAdapterBalance": _relation(
                "TRACKED_L", locked, "OBSERVED_ADAPTER_BALANCE", observed_l),
            "trackedLockedVsObservedRepresentationSupply": _relation(
                "TRACKED_L", locked, "OBSERVED_R", supply),
            "observedAdapterBalanceVsObservedRepresentationSupply": _relation(
                "OBSERVED_ADAPTER_BALANCE", observed_l, "OBSERVED_R", supply),
        }
    except (rpc.RpcError, ValueError) as err:
        checks.add("route", "rpc", False, str(err))
    out["observations"] = obs
    out["checks"] = checks.items
    out["blockers"] = [f"{i['chain']}: {i['check']} -> {i['observed']}" for i in checks.items if not i["ok"]]
    out.update(STATUS_EVIDENCE_FLAGS)
    # Structural problems (wrong chain, endpoint/peer/owner/token mismatch, RPC failure) block. Otherwise the
    # backing state is UNKNOWN whatever the numbers say: settlement, in-flight obligations and insolvency
    # cannot be established from unsynchronized, unfinalized snapshots with unmeasured P/Q.
    out["status"] = UNKNOWN if checks.ok else BLOCKED
    out["note"] = ("Structural wiring checks plus raw, unsynchronized, unfinalized observations. balanceRelations "
                   "are descriptive comparisons only; they do not show settlement, pending messages, solvency "
                   "or a completed roundtrip. Neither do equal balances or an indexer DELIVERED status.")
    return out


STATUS_EVIDENCE_FLAGS = {"finalityVerified": False, "snapshotSynchronized": False,
                         "inFlightLiabilitiesVerified": False, "accountingConclusion": None}


def _relation(left_name, left, right_name, right):
    word = "EQUALS" if left == right else ("GREATER_THAN" if left > right else "LESS_THAN")
    return f"{left_name}_{word}_{right_name}"


# ---------------------------------------------------------------------- LayerZero Scan lookup

def message_url(cfg, tx_hash):
    if not TX_HASH_RE.fullmatch(tx_hash or ""):
        raise ConfigError("tx hash must be lowercase 0x + 64 hex")
    base = cfg["sources"]["layerzeroScanApi"]
    rpc.validate_public_url(base)
    if urllib.parse.urlsplit(base).hostname != "scan-testnet.layerzero-api.com":
        raise ConfigError("only the LayerZero Scan TESTNET API is allowed")
    return f"{base}/messages/tx/{tx_hash}"


def summarize_messages(payload, cfg):
    """Reduces a Scan API response to the fields relevant to the pinned route."""
    chains = validate_config(cfg)
    eids = {chains[k]["eid"] for k in CHAIN_KEYS}
    out = []
    for m in payload.get("data", []) if isinstance(payload, dict) else []:
        path = m.get("pathway", {})
        out.append({
            "guid": m.get("guid"),
            "status": (m.get("status") or {}).get("name"),
            "srcEid": path.get("srcEid"), "dstEid": path.get("dstEid"), "nonce": path.get("nonce"),
            "sender": (path.get("sender") or {}).get("address"),
            "receiver": (path.get("receiver") or {}).get("address"),
            "sourceTx": ((m.get("source") or {}).get("tx") or {}).get("txHash"),
            "destinationTx": ((m.get("destination") or {}).get("tx") or {}).get("txHash"),
            "onPinnedRoute": {path.get("srcEid"), path.get("dstEid")} == eids,
        })
    return out


def fetch_message(cfg, tx_hash, opener=None):
    url = message_url(cfg, tx_hash)
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "sairi-tools"})
    try:
        with (opener or urllib.request.urlopen)(request, timeout=30) as response:  # noqa: S310 - fixed https host
            payload = json.loads(response.read())
    except (OSError, ValueError) as err:  # network errors are OSError; malformed JSON is ValueError
        return {"kind": "LAYERZERO_SCAN_LOOKUP", "url": url, "status": BLOCKED, "error": str(err), "messages": []}
    messages = summarize_messages(payload, cfg)
    delivered = bool(messages) and all(m["status"] == "DELIVERED" and m["onPinnedRoute"] for m in messages)
    return {"kind": "LAYERZERO_SCAN_LOOKUP", "url": url,
            "status": INDEXER_DELIVERED if delivered else INDEXER_NOT_DELIVERED,
            "proof": False, "messages": messages,
            "note": ("Third-party indexer view only, not proof of delivery or of a completed roundtrip. Record "
                     "the destination execution transaction and its on-chain receipt as evidence.")}


INDEXER_DELIVERED, INDEXER_NOT_DELIVERED = "INDEXER_REPORTS_DELIVERED", "INDEXER_DOES_NOT_REPORT_DELIVERED"
