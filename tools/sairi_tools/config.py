"""Fail-closed configuration validator.

Two environments exist and are distinguished by two independent markers (`environment` and `mock`):

* ``local-mock`` - an explicit synthetic fixture for the local harness. Chain IDs must NOT be the live
  IDs, and it may not carry evidence (a mock cannot claim verification).
* ``live`` - LayerZero-shaped candidate: Base (chain 8453, EID 30184) canonical side and Robinhood Chain
  (chain 4663, EID 30416) representation side. Every value must be non-null AND backed by a VERIFIED
  evidence record bound to that exact value (`configuredValue`, same JSON type) with source, date,
  network, pinned block and code-verification fields. Unknown production values are null, so the
  committed live file is expected to be REJECTED.

SCOPE: this is OFFLINE structural/provenance-record checking only. It reads no chain and does NOT verify
deployed bytecode, ownership or endpoint deployments; a VALID result only means the record is complete
and self-consistent. Documentary identifiers (e.g. LayerZero EIDs found in public metadata) are recorded
separately under `documentaryReferences` and are never read as live parameters.
"""
import datetime
import re
import urllib.parse
from dataclasses import dataclass, field

from . import UINT256_MAX
from .strict import DATE_RE, is_int, is_nonzero_address

SCHEMA_VERSION = 1
LOCAL = "local-mock"
LIVE = "live"
LIVE_CHAIN_IDS = {"canonical": 8453, "representation": 4663}
# Documented LayerZero V2 endpoint IDs (config/research/documentary-candidates.json). Required values
# for the live candidate shape; matching them proves nothing about any deployment.
LIVE_EIDS = {"canonical": 30184, "representation": 30416}
LIVE_NETWORK_NAMES = {"canonical": "base", "representation": "robinhood-mainnet"}
MAX_TOKEN_DECIMALS = 18
VERIFICATION_SCOPE = "OFFLINE_RECORD_CHECK_ONLY_NO_ONCHAIN_VERIFICATION"

# Must equal the constants in src/pool/LocalConstantProductPool.sol.
SOLIDITY_FEES = {"creatorFeeBps": 100, "lpFeeBps": 30, "feeDenominator": 10_000}

TOP_KEYS = {
    "schemaVersion", "environment", "mock", "documentaryReferences", "sharedDecimals",
    "creatorBeneficiary", "owner", "fees", "limits", "networks", "evidence",
}
NETWORK_KEYS = {"name", "chainId", "eid", "endpoint", "bridgeApp", "peer", "token", "tokenDecimals", "weth", "dex"}
NETWORK_ADDRESS_KEYS = ("endpoint", "bridgeApp", "peer", "token", "weth", "dex")
FEE_KEYS = set(SOLIDITY_FEES)
LIMIT_KEYS = {"exposureCap", "rateWindowSeconds", "rateLimitPerWindow"}
EVIDENCE_KEYS = {
    "status", "source", "retrievedAt", "chainId", "pinnedBlock", "codeVerified", "codeHash", "configuredValue",
}
DOC_REF_KEYS = {"id", "network", "field", "value", "source", "status"}
DOC_REF_STATUSES = ("UNVERIFIED", "DOCUMENTARY")
SIDES = ("canonical", "representation")

HASH_RE = re.compile(r"0x[0-9a-f]{64}")
ZERO_HASH = "0x" + "0" * 64
CREDENTIAL_QUERY_KEYS = {
    "token", "access_token", "id_token", "auth", "authorization", "api_key", "apikey", "key", "secret",
    "client_secret", "password", "passwd", "pwd", "signature", "sig", "session", "x-api-key",
}


def is_safe_https_url(value):
    """https URL with a host, no userinfo of any form and no credential-like query keys."""
    if not isinstance(value, str) or not value or any(c.isspace() for c in value):
        return False
    try:
        parts = urllib.parse.urlsplit(value)
        host = parts.hostname
        parts.port  # noqa: B018 - raises ValueError on a malformed port
        query = urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
    except ValueError:
        return False
    if parts.scheme != "https" or not host or "@" in parts.netloc:
        return False
    if parts.username is not None or parts.password is not None:
        return False
    return not any(key.lower() in CREDENTIAL_QUERY_KEYS for key, _ in query)


def same_json_value(a, b):
    """Strict equality: same JSON type (bool is never int) and same value."""
    return type(a) is type(b) and a == b


def leaf_value(cfg, path):
    node = cfg
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def leaf_paths():
    """Every value that must carry evidence in a live configuration."""
    paths = ["sharedDecimals", "creatorBeneficiary", "owner"]
    paths += [f"fees.{k}" for k in sorted(FEE_KEYS)]
    paths += [f"limits.{k}" for k in sorted(LIMIT_KEYS)]
    for side in SIDES:
        paths += [f"networks.{side}.{k}" for k in sorted(NETWORK_KEYS)]
    return paths


# ---------------------------------------------------------------- typed result


@dataclass(frozen=True)
class Issue:
    path: str
    code: str
    message: str

    def to_dict(self):
        return {"path": self.path, "code": self.code, "message": self.message}


@dataclass(frozen=True)
class Network:
    name: str
    chain_id: int
    eid: int
    endpoint: str
    bridge_app: str
    peer: str
    token: str
    token_decimals: int
    weth: str
    dex: str


@dataclass(frozen=True)
class Fees:
    creator_fee_bps: int
    lp_fee_bps: int
    fee_denominator: int


@dataclass(frozen=True)
class Limits:
    exposure_cap: int
    rate_window_seconds: int
    rate_limit_per_window: int


@dataclass(frozen=True)
class ProtocolConfig:
    environment: str
    shared_decimals: int
    creator_beneficiary: str
    owner: str
    fees: Fees
    limits: Limits
    canonical: Network
    representation: Network


@dataclass
class Report:
    environment: object
    issues: list = field(default_factory=list)
    config: ProtocolConfig | None = None

    @property
    def ok(self):
        return not self.issues and self.config is not None

    def add(self, path, code, message):
        self.issues.append(Issue(path, code, message))

    def to_dict(self):
        return {
            "environment": self.environment if isinstance(self.environment, str) else None,
            "status": "VALID" if self.ok else "REJECTED",
            "issueCount": len(self.issues),
            "issues": [i.to_dict() for i in self.issues],
            "verificationScope": VERIFICATION_SCOPE,
            "deploymentVerified": False,
        }


# ---------------------------------------------------------------- validation


def _check_keys(report, path, obj, expected):
    if not isinstance(obj, dict):
        report.add(path or "$", "TYPE", "expected an object")
        return False
    for key in sorted(set(obj) - expected):
        report.add(f"{path}.{key}" if path else key, "UNKNOWN_KEY", "unexpected key")
    missing = sorted(expected - set(obj))
    for key in missing:
        report.add(f"{path}.{key}" if path else key, "MISSING_KEY", "required key absent")
    return not missing


def _unknown(report, env, path):
    if env == LIVE:
        report.add(path, "BLOCKED_UNKNOWN", "production value unknown (null); fail closed until verified")
    else:
        report.add(path, "MISSING", "local fixture value must be explicit")


def _int_field(report, env, path, value, lo, hi):
    if value is None:
        _unknown(report, env, path)
        return False
    if not is_int(value):
        report.add(path, "TYPE", f"expected integer, got {type(value).__name__}")
        return False
    if not lo <= value <= hi:
        report.add(path, "RANGE", f"must be within [{lo}, {hi}]")
        return False
    return True


def _address_field(report, env, path, value):
    if value is None:
        _unknown(report, env, path)
        return False
    if not is_nonzero_address(value):
        report.add(path, "ADDRESS", "expected nonzero lowercase 0x-prefixed 20-byte hex address")
        return False
    return True


def _str_field(report, env, path, value):
    if value is None:
        _unknown(report, env, path)
        return False
    if not isinstance(value, str) or not value.strip():
        report.add(path, "TYPE", "expected non-empty string")
        return False
    return True


def _validate_network(report, env, side, net):
    base = f"networks.{side}"
    if not _check_keys(report, base, net, NETWORK_KEYS):
        return False
    ok = _str_field(report, env, f"{base}.name", net.get("name"))
    ok &= _int_field(report, env, f"{base}.chainId", net.get("chainId"), 1, 2**64 - 1)
    ok &= _int_field(report, env, f"{base}.eid", net.get("eid"), 1, 2**32 - 1)
    ok &= _int_field(report, env, f"{base}.tokenDecimals", net.get("tokenDecimals"), 0, MAX_TOKEN_DECIMALS)
    for key in NETWORK_ADDRESS_KEYS:
        ok &= _address_field(report, env, f"{base}.{key}", net.get(key))
    if ok and env == LIVE:
        if net["chainId"] != LIVE_CHAIN_IDS[side]:
            report.add(f"{base}.chainId", "LIVE_CHAIN", f"live {side} chain must be {LIVE_CHAIN_IDS[side]}")
            ok = False
        if net["name"] != LIVE_NETWORK_NAMES[side]:
            report.add(f"{base}.name", "LIVE_CHAIN", f"live {side} network must be {LIVE_NETWORK_NAMES[side]}")
            ok = False
        if net["eid"] != LIVE_EIDS[side]:
            report.add(f"{base}.eid", "LIVE_EID", f"live {side} LayerZero EID must be {LIVE_EIDS[side]}")
            ok = False
    if ok and env == LOCAL and net["chainId"] in LIVE_CHAIN_IDS.values():
        report.add(f"{base}.chainId", "LOCAL_USES_LIVE_ID", "local fixtures must not reuse live chain IDs")
        ok = False
    if ok and env == LOCAL and net["eid"] in LIVE_EIDS.values():
        report.add(f"{base}.eid", "LOCAL_USES_LIVE_ID", "local fixtures must not reuse live endpoint IDs")
        ok = False
    if ok and net["token"] == net["weth"]:
        report.add(f"{base}.weth", "DUPLICATE_ADDRESS", "WETH must differ from the bridged token")
        ok = False
    return bool(ok)


def _validate_evidence(report, env, cfg, today):
    evidence = cfg.get("evidence")
    if not isinstance(evidence, dict):
        report.add("evidence", "TYPE", "expected an object")
        return
    if env == LOCAL:
        if evidence:
            report.add("evidence", "LOCAL_EVIDENCE", "local mock fixtures cannot claim verification evidence")
        return
    known = set(leaf_paths())
    for path in sorted(set(evidence) - known):
        report.add(f"evidence.{path}", "UNKNOWN_KEY", "evidence for an unknown field")
    networks = cfg.get("networks") if isinstance(cfg.get("networks"), dict) else {}
    for path in leaf_paths():
        epath = f"evidence.{path}"
        item = evidence.get(path)
        if item is None:
            report.add(epath, "EVIDENCE_MISSING", "live value requires VERIFIED evidence")
            continue
        if not _check_keys(report, epath, item, EVIDENCE_KEYS):
            continue
        if item["status"] != "VERIFIED":
            report.add(f"{epath}.status", "EVIDENCE_UNVERIFIED", "status must be VERIFIED")
        value = leaf_value(cfg, path)
        if value is None or not same_json_value(item["configuredValue"], value):
            report.add(f"{epath}.configuredValue", "EVIDENCE_VALUE_MISMATCH",
                       "evidence must name the exact configured value (same type and value)")
        if not is_safe_https_url(item["source"]):
            report.add(f"{epath}.source", "EVIDENCE_SOURCE",
                       "expected https URL with a host, no userinfo and no credential-like query keys")
        _check_date(report, f"{epath}.retrievedAt", item["retrievedAt"], today)
        chain_id = item["chainId"]
        expected_chain = None
        if path.startswith("networks."):
            side = path.split(".")[1]
            expected_chain = LIVE_CHAIN_IDS[side]
        if not is_int(chain_id) or chain_id not in LIVE_CHAIN_IDS.values():
            report.add(f"{epath}.chainId", "EVIDENCE_NETWORK", "evidence network must be a live chain ID")
        elif expected_chain is not None and chain_id != expected_chain:
            report.add(f"{epath}.chainId", "EVIDENCE_NETWORK", f"evidence must come from chain {expected_chain}")
        elif path.startswith("networks.") and isinstance(networks.get(path.split(".")[1]), dict):
            if networks[path.split(".")[1]].get("chainId") not in (None, chain_id):
                report.add(f"{epath}.chainId", "EVIDENCE_NETWORK", "evidence chain differs from configured chain")
        if not is_int(item["pinnedBlock"]) or item["pinnedBlock"] <= 0:
            report.add(f"{epath}.pinnedBlock", "EVIDENCE_BLOCK", "pinned block must be a positive integer")
        if item["codeVerified"] is not True:
            report.add(f"{epath}.codeVerified", "EVIDENCE_CODE", "code/provenance verification must be true")
        code_hash = item["codeHash"]
        if not isinstance(code_hash, str) or not HASH_RE.fullmatch(code_hash) or code_hash == ZERO_HASH:
            report.add(f"{epath}.codeHash", "EVIDENCE_CODE", "expected nonzero lowercase 32-byte code hash")


def _check_date(report, path, value, today):
    if not isinstance(value, str) or not DATE_RE.fullmatch(value):
        report.add(path, "EVIDENCE_DATE", "expected YYYY-MM-DD")
        return
    try:
        date = datetime.date.fromisoformat(value)
    except ValueError:
        report.add(path, "EVIDENCE_DATE", "invalid calendar date")
        return
    if date > today:
        report.add(path, "EVIDENCE_DATE", "date is in the future")


def _validate_doc_refs(report, refs):
    if not isinstance(refs, list):
        report.add("documentaryReferences", "TYPE", "expected a list")
        return
    for i, ref in enumerate(refs):
        path = f"documentaryReferences[{i}]"
        if not _check_keys(report, path, ref, DOC_REF_KEYS):
            continue
        # Type check first: untrusted lists/dicts must not reach a membership test.
        if not isinstance(ref["status"], str) or ref["status"] not in DOC_REF_STATUSES:
            report.add(f"{path}.status", "DOC_REF_STATUS", "documentary references are never VERIFIED parameters")
        for key in ("id", "network", "field", "source"):
            if not isinstance(ref[key], str) or not ref[key]:
                report.add(f"{path}.{key}", "TYPE", "expected non-empty string")
        if not (ref["value"] is None or is_int(ref["value"]) or isinstance(ref["value"], str)):
            report.add(f"{path}.value", "TYPE", "expected integer, string or null")


def validate(cfg, today=None):
    """Validate a parsed configuration object. Returns a Report; `report.config` is set only if valid."""
    today = today or datetime.date.today()
    env = cfg.get("environment") if isinstance(cfg, dict) else None
    report = Report(environment=env)
    if not _check_keys(report, "", cfg, TOP_KEYS):
        return report
    if cfg["schemaVersion"] != SCHEMA_VERSION or not is_int(cfg["schemaVersion"]):
        report.add("schemaVersion", "SCHEMA", f"expected {SCHEMA_VERSION}")
    if env not in (LOCAL, LIVE):
        report.add("environment", "ENVIRONMENT", f"expected {LOCAL!r} or {LIVE!r}")
        return report
    if cfg["mock"] is not (env == LOCAL):
        report.add("mock", "ENVIRONMENT", "mock marker must be true exactly for local-mock")

    _validate_doc_refs(report, cfg["documentaryReferences"])

    ok = _int_field(report, env, "sharedDecimals", cfg["sharedDecimals"], 0, MAX_TOKEN_DECIMALS)
    ok &= _address_field(report, env, "creatorBeneficiary", cfg["creatorBeneficiary"])
    ok &= _address_field(report, env, "owner", cfg["owner"])

    fees = cfg["fees"]
    if _check_keys(report, "fees", fees, FEE_KEYS):
        for key, expected in SOLIDITY_FEES.items():
            if _int_field(report, env, f"fees.{key}", fees.get(key), 0, UINT256_MAX):
                if fees[key] != expected:
                    report.add(f"fees.{key}", "FEE_MISMATCH", f"must equal Solidity constant {expected}")
                    ok = False
            else:
                ok = False
    else:
        ok = False

    limits = cfg["limits"]
    if _check_keys(report, "limits", limits, LIMIT_KEYS):
        ok &= _int_field(report, env, "limits.exposureCap", limits.get("exposureCap"), 0, UINT256_MAX)
        ok &= _int_field(report, env, "limits.rateWindowSeconds", limits.get("rateWindowSeconds"), 1, UINT256_MAX)
        ok &= _int_field(report, env, "limits.rateLimitPerWindow", limits.get("rateLimitPerWindow"), 0, UINT256_MAX)
    else:
        ok = False

    nets = cfg["networks"]
    if _check_keys(report, "networks", nets, set(SIDES)):
        for side in SIDES:
            if side in nets:
                ok &= _validate_network(report, env, side, nets[side])
            else:
                ok = False
    else:
        ok = False

    _validate_evidence(report, env, cfg, today)

    if ok:
        _cross_checks(report, cfg)
    if not report.issues:
        report.config = _build(cfg)
    return report


def _cross_checks(report, cfg):
    can, rep = cfg["networks"]["canonical"], cfg["networks"]["representation"]
    shared = cfg["sharedDecimals"]
    for side, net in (("canonical", can), ("representation", rep)):
        if shared > net["tokenDecimals"]:
            report.add("sharedDecimals", "DECIMALS", f"shared decimals exceed {side} token decimals")
    if can["chainId"] == rep["chainId"]:
        report.add("networks.representation.chainId", "DUPLICATE_CHAIN", "chains must differ")
    if can["eid"] == rep["eid"]:
        report.add("networks.representation.eid", "DUPLICATE_EID", "endpoint IDs must differ")
    if can["peer"] != rep["bridgeApp"]:
        report.add("networks.canonical.peer", "PEER", "canonical peer must be the representation bridge app")
    if rep["peer"] != can["bridgeApp"]:
        report.add("networks.representation.peer", "PEER", "representation peer must be the lockbox")
    if rep["token"] != rep["bridgeApp"]:
        report.add("networks.representation.token", "TOKEN", "representation token is the bridge app itself")
    if can["token"] == can["bridgeApp"]:
        report.add("networks.canonical.token", "TOKEN", "canonical token must differ from the lockbox")

    treasury = cfg["creatorBeneficiary"]
    for side, net in (("canonical", can), ("representation", rep)):
        for key in NETWORK_ADDRESS_KEYS:
            if key != "peer" and net[key] == treasury:
                report.add("creatorBeneficiary", "TREASURY_ALIAS", f"must differ from networks.{side}.{key}")


def _build(cfg):
    def net(n):
        return Network(n["name"], n["chainId"], n["eid"], n["endpoint"], n["bridgeApp"], n["peer"], n["token"],
                       n["tokenDecimals"], n["weth"], n["dex"])

    f, lim = cfg["fees"], cfg["limits"]
    return ProtocolConfig(
        environment=cfg["environment"],
        shared_decimals=cfg["sharedDecimals"],
        creator_beneficiary=cfg["creatorBeneficiary"],
        owner=cfg["owner"],
        fees=Fees(f["creatorFeeBps"], f["lpFeeBps"], f["feeDenominator"]),
        limits=Limits(lim["exposureCap"], lim["rateWindowSeconds"], lim["rateLimitPerWindow"]),
        canonical=net(cfg["networks"]["canonical"]),
        representation=net(cfg["networks"]["representation"]),
    )
