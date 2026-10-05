"""Evidence-aware backing monitor:  L >= R + P + Q  in integer shared-decimal units.

  L  OBSERVED canonical backing: floor(canonical.balanceOf(lockbox) / conversionRate). This is the
     actual token balance, not the lockbox's `totalLocked` bookkeeping variable, so a balance loss
     (negative rebase, drain, broken token) lowers L even when `totalLocked` is unchanged.
  R  TOTAL outstanding backed-representation supply (all representation chains)
  P  pending lock messages not yet credited on the representation side
  Q  pending burn messages not yet released on the canonical side

Optional `trackedLocked` = floor(lockbox.totalLocked / conversionRate) is a SEPARATE reconciliation
record. It never substitutes for L. Expected: trackedLocked == R + P + Q and L >= trackedLocked
(L > trackedLocked = donations / untracked surplus).

All observations must declare the same observation epoch and delivery-ledger checkpoint, be finalized,
fresh and evidenced. Matching labels are DECLARED, not proven: no verified live evidence collector
exists, so any non-synthetic snapshot is reported UNKNOWN (LIVE_EVIDENCE_UNVERIFIED). Only snapshots
explicitly marked `synthetic: true` (local fixtures) can be SAFE. Deficit reasons are still reported.

Status precedence (most severe first): INVALID > UNKNOWN > STALE > UNSAFE > SAFE.
The monitor detects accounting failure; it cannot prevent it.
"""
from .strict import is_int

SCHEMA_VERSION = 1
UNITS = "shared-decimal"
NAMES = ("L", "R", "P", "Q")
TRACKED = "trackedLocked"
TOP_KEYS = {"schemaVersion", "synthetic", "sharedDecimals", "maxAgeSeconds", "observations"}
OBS_KEYS = {"value", "units", "decimals", "epoch", "ledgerCheckpoint", "finalized", "observedAt", "evidence"}
EVIDENCE_KEYS = {"source", "chainId", "blockNumber"}

INVALID, UNKNOWN, STALE, UNSAFE, SAFE = "INVALID", "UNKNOWN", "STALE", "UNSAFE", "SAFE"
PRECEDENCE = (INVALID, UNKNOWN, STALE, UNSAFE, SAFE)
EXIT_CODES = {SAFE: 0, UNSAFE: 2, STALE: 3, UNKNOWN: 4, INVALID: 5}
L_DEFINITION = "floor(canonical.balanceOf(lockbox) / conversionRate) - observed balance, not totalLocked"


class _Result:
    def __init__(self):
        self.reasons = []
        self.levels = set()

    def flag(self, level, code, message, observation=None):
        if level in PRECEDENCE:
            self.levels.add(level)
        reason = {"code": code, "severity": level, "message": message}
        if observation is not None:
            reason["observation"] = observation
        self.reasons.append(reason)


def _check_observation(res, name, obs, shared_decimals, max_age, now):
    """Returns the integer value if it is type-valid, else None."""
    if obs is None:
        res.flag(UNKNOWN, "MISSING_OBSERVATION", "observation absent", name)
        return None
    if not isinstance(obs, dict):
        res.flag(INVALID, "MALFORMED", "observation must be an object", name)
        return None
    extra, missing = set(obs) - OBS_KEYS, OBS_KEYS - set(obs)
    if extra:
        res.flag(INVALID, "MALFORMED", f"unexpected keys {sorted(extra)}", name)
    if missing:
        res.flag(INVALID, "MALFORMED", f"missing keys {sorted(missing)}", name)
        return None

    value = obs["value"]
    good_value = None
    if value is None:
        res.flag(UNKNOWN, "VALUE_UNKNOWN", "value is null", name)
    elif not is_int(value):
        res.flag(INVALID, "AMOUNT_TYPE", f"amount must be an integer, got {type(value).__name__}", name)
    elif value < 0:
        res.flag(INVALID, "NEGATIVE_AMOUNT", "amount must be non-negative", name)
    else:
        good_value = value

    if not isinstance(obs["units"], str) or obs["units"] != UNITS or not is_int(obs["decimals"]) \
            or obs["decimals"] != shared_decimals:
        res.flag(UNKNOWN, "UNKNOWN_UNITS", f"units must be {UNITS!r} with decimals={shared_decimals}", name)

    ev = obs["evidence"]
    if ev is None:
        res.flag(UNKNOWN, "EVIDENCE_ABSENT", "no evidence for observation", name)
    elif (not isinstance(ev, dict) or set(ev) != EVIDENCE_KEYS or not isinstance(ev["source"], str)
          or not ev["source"] or not is_int(ev["chainId"]) or ev["chainId"] <= 0
          or not is_int(ev["blockNumber"]) or ev["blockNumber"] < 0):
        res.flag(INVALID, "MALFORMED_EVIDENCE", "evidence needs source, chainId>0, blockNumber>=0", name)

    if not isinstance(obs["finalized"], bool):
        res.flag(INVALID, "MALFORMED", "finalized must be a boolean", name)
    elif not obs["finalized"]:
        res.flag(UNKNOWN, "NOT_FINALIZED", "observation is not finalized", name)

    ts = obs["observedAt"]
    if not is_int(ts) or ts < 0:
        res.flag(INVALID, "TIMESTAMP_TYPE", "observedAt must be a non-negative integer (unix seconds)", name)
    elif ts > now:
        res.flag(INVALID, "FUTURE_TIMESTAMP", "observedAt is in the future", name)
    elif now - ts > max_age:
        res.flag(STALE, "STALE", f"observation age {now - ts}s exceeds {max_age}s", name)

    if not is_int(obs["epoch"]) or obs["epoch"] < 0:
        res.flag(INVALID, "MALFORMED", "epoch must be a non-negative integer", name)
    if not isinstance(obs["ledgerCheckpoint"], str) or not obs["ledgerCheckpoint"]:
        res.flag(INVALID, "MALFORMED", "ledgerCheckpoint must be a non-empty string", name)
    return good_value


def evaluate(snapshot, now):
    """Evaluate a parsed snapshot at unix time `now`. Returns a machine-readable dict."""
    if not is_int(now) or now < 0:
        raise ValueError("now must be a non-negative integer")
    res = _Result()
    values = {n: None for n in NAMES}
    out = {
        "status": None, "reasons": res.reasons, "values": values, "requiredBacking": None,
        "surplus": None, "trackedLocked": None, "untrackedSurplus": None, "checkpoint": None,
        "synthetic": None, "units": UNITS, "sharedDecimals": None, "evaluatedAt": now,
        "lDefinition": L_DEFINITION, "coherenceBasis": "DECLARED_LABELS_ONLY_NOT_PROOF",
        "liveEvidenceCollector": "ABSENT",
    }
    if not isinstance(snapshot, dict) or set(snapshot) != TOP_KEYS:
        res.flag(INVALID, "MALFORMED", f"snapshot must have exactly keys {sorted(TOP_KEYS)}")
        out["status"] = INVALID
        return out
    if not is_int(snapshot["schemaVersion"]) or snapshot["schemaVersion"] != SCHEMA_VERSION:
        res.flag(INVALID, "SCHEMA", f"schemaVersion must be {SCHEMA_VERSION}")
    if not isinstance(snapshot["synthetic"], bool):
        res.flag(INVALID, "MALFORMED", "synthetic must be a boolean")
    else:
        out["synthetic"] = snapshot["synthetic"]
        if not snapshot["synthetic"]:
            res.flag(UNKNOWN, "LIVE_EVIDENCE_UNVERIFIED",
                     "no verified live evidence collector exists; non-synthetic snapshots cannot be SAFE (BLOCKED)")
    shared, max_age = snapshot["sharedDecimals"], snapshot["maxAgeSeconds"]
    if not is_int(shared) or not 0 <= shared <= 18:
        res.flag(INVALID, "MALFORMED", "sharedDecimals must be an integer in [0, 18]")
        shared = None
    out["sharedDecimals"] = shared
    if not is_int(max_age) or max_age <= 0:
        res.flag(INVALID, "MALFORMED", "maxAgeSeconds must be a positive integer")
        max_age = 0
    observations = snapshot["observations"]
    if not isinstance(observations, dict) or set(observations) - set(NAMES) - {TRACKED}:
        res.flag(INVALID, "MALFORMED", f"observations must be an object keyed by L, R, P, Q (+ optional {TRACKED})")
        observations = {}

    for name in NAMES:
        values[name] = _check_observation(res, name, observations.get(name), shared, max_age, now)
    tracked = None
    if TRACKED in observations:
        tracked = _check_observation(res, TRACKED, observations[TRACKED], shared, max_age, now)
        out["trackedLocked"] = tracked

    names = NAMES + ((TRACKED,) if TRACKED in observations else ())
    present = [observations[n] for n in names if isinstance(observations.get(n), dict)]
    keys = [(o.get("epoch"), o.get("ledgerCheckpoint")) for o in present]
    coherent = all(k == keys[0] for k in keys)
    if len(present) == len(names) and coherent:
        epoch, checkpoint = keys[0]
        out["checkpoint"] = {"epoch": epoch, "ledgerCheckpoint": checkpoint}
    elif not coherent:
        res.flag(UNKNOWN, "INCOHERENT_CHECKPOINT",
                 "observations declare different epochs/ledger checkpoints; not a synchronized snapshot")

    required = None
    if all(values[n] is not None for n in ("R", "P", "Q")):
        required = values["R"] + values["P"] + values["Q"]
        out["requiredBacking"] = required
    if required is not None and values["L"] is not None:
        out["surplus"] = values["L"] - required
        if values["L"] < required:
            res.flag(UNSAFE, "BACKING_DEFICIT", f"observed L={values['L']} < R+P+Q={required}")
    if tracked is not None and values["L"] is not None:
        out["untrackedSurplus"] = values["L"] - tracked
        if values["L"] < tracked:
            res.flag(UNSAFE, "OBSERVED_BELOW_TRACKED",
                     f"observed balance L={values['L']} < tracked totalLocked={tracked} (loss, rebase or drain)")
        elif values["L"] > tracked:
            res.flag("INFO", "UNTRACKED_SURPLUS",
                     f"observed balance exceeds tracked totalLocked by {values['L'] - tracked} (donations); "
                     "not releasable, not counted as tracked backing")
    if tracked is not None and required is not None and tracked != required:
        level = UNSAFE if tracked < required else "WARNING"
        res.flag(level, "TRACKED_LEDGER_MISMATCH",
                 f"tracked totalLocked={tracked} != R+P+Q={required}; ledger does not reconcile")

    if out["synthetic"]:
        res.flag("INFO", "SYNTHETIC_FIXTURE", "local synthetic data; not an observation of any live chain")
    out["status"] = next(level for level in PRECEDENCE if level in res.levels or level == SAFE)
    return out
