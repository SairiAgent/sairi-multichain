# Accounting and monitoring

**EXPERIMENTAL — UNAUDITED — NO MAINNET DEPLOYMENT.** All fixtures referenced here are local and synthetic. No verified live evidence collector exists, so the monitor cannot report any real deployment as SAFE.

## Invariant

All terms are integers in **shared-decimal units** (`sharedDecimals`, 6 in the local harness; `conversionRate = 10^(localDecimals − sharedDecimals)`):

```
L >= R + P + Q
L  OBSERVED backing: floor(canonical.balanceOf(lockbox) / conversionRate) - the actual tokens held
R  TOTAL outstanding backed representation (sum of totalSupply on every representation chain)
P  pending lock messages not yet credited  (sent by the lockbox, not delivered)
Q  pending burn messages not yet released  (sent by the representation, not delivered)
```

`L` is the actual canonical balance held by the lockbox, **not** the lockbox's `totalLocked` variable. `totalLocked` is a separate *tracked* ledger record (`trackedLocked = floor(totalLocked / conversionRate)`). It can stay unchanged after a negative rebase, a token-level loss or a drain, so it must never be substituted for observed backing; doing so would report a false SAFE.

Two separate relations therefore hold in a healthy system:

```
trackedLocked == R + P + Q      (bookkeeping reconciles)
L             >= trackedLocked  (actual tokens cover the bookkeeping; L − trackedLocked = donations / untracked surplus)
```

`test/utils/BridgeFixture.sol` proves the first relation after every test step (and cross-checks P and Q against each app's `totalOutboundSD − peer.totalInboundSD`) and separately asserts `canonical.balanceOf(lockbox) ≥ totalLocked`. Those Solidity assertions are fixture proofs about the harness; they do not redefine `L`.

## Transition deltas (shared-decimal units, amount `a`)

| Transition | ΔL (observed) | ΔR | ΔP | ΔQ | ΔtrackedLocked |
|---|---|---|---|---|---|
| `lockAndSend` (lock) | `+a` | 0 | `+a` | 0 | `+a` |
| credit delivered on representation | 0 | `+a` | `−a` | 0 | 0 |
| `burnAndSend` (burn) | 0 | `−a` | 0 | `+a` | 0 |
| release delivered on canonical side | `−a` | 0 | 0 | `−a` | `−a` |
| any reverted call (pause, cap, rate limit, dust, replay, failed exact transfer) | 0 | 0 | 0 | 0 | 0 |
| unsolicited donation of `d` raw to a lockbox holding balance `b` | `floor((b+d)/c) − floor(b/c)` ≥ 0 | 0 | 0 | 0 | 0 |
| swaps, LP add/remove, fee claims | 0 | 0 | 0 | 0 | 0 |

Every legitimate transition preserves `L − (R + P + Q)`. Donations only increase it (surplus); sub-`conversionRate` donation remainders are dust that changes no shared-unit term until enough accumulates. Pool and fee operations move existing backed tokens between holders and do not change any term.

## Snapshot requirements

A snapshot can be evaluated only if all observations:

1. declare the **same observation epoch and delivery-ledger checkpoint** (the message-ledger position used to compute P and Q);
2. are **finalized**, **fresh** (`now − observedAt ≤ maxAgeSeconds`) and **not in the future**;
3. carry evidence (`source`, `chainId`, `blockNumber`) and declare units `shared-decimal` with the expected decimals;
4. are non-negative JSON integers (booleans, strings, floats, NaN and duplicate keys are rejected).

**Matching labels are a declaration, not proof** that the values form a finalized, comparable cross-chain cut. Reading "latest block" on Base and Robinhood Chain independently is not a synchronized snapshot: messages can be in flight between reads. Because no verified live evidence collector or configuration integration exists, every snapshot with `synthetic: false` is reported `UNKNOWN` (`LIVE_EVIDENCE_UNVERIFIED`) — this is an explicit **BLOCKED** residual, not a missing flag to toggle. Only explicitly `synthetic: true` local fixtures can be `SAFE`.

## Monitor output

`python3.12 tools/sairi.py monitor SNAPSHOT.json [--now UNIX] [--expect STATUS]` prints JSON with `status`, `reasons[]` (code, severity, observation, message), `values` (L/R/P/Q or null), `requiredBacking`, `surplus` (`L − (R+P+Q)`), optional `trackedLocked` and `untrackedSurplus` (`L − trackedLocked`), `checkpoint`, `synthetic`, `lDefinition`, `coherenceBasis` (`DECLARED_LABELS_ONLY_NOT_PROOF`) and `liveEvidenceCollector` (`ABSENT`).

| Status | Exit | Meaning |
|---|---|---|
| `INVALID` | 5 | malformed input: wrong types, negative/bool/string amounts, future timestamps, bad evidence shape |
| `UNKNOWN` | 4 | non-synthetic snapshot (no verified collector), missing/null value, absent evidence, unknown units, not finalized, differing epoch/checkpoint |
| `STALE` | 3 | an observation is older than `maxAgeSeconds` |
| `UNSAFE` | 2 | `L < R + P + Q` (`BACKING_DEFICIT`), `L < trackedLocked` (`OBSERVED_BELOW_TRACKED`) or `trackedLocked < R + P + Q` |
| `SAFE` | 0 | synthetic, coherent-by-declaration, finalized, fresh, evidenced and `L ≥ R + P + Q` |

Precedence is most-severe-first as listed. Deficit reasons are always reported, even when the status is `UNKNOWN` or `STALE`. Informational reasons: `UNTRACKED_SURPLUS` (donations), `TRACKED_LEDGER_MISMATCH` as a WARNING when `trackedLocked > R + P + Q`, `SYNTHETIC_FIXTURE`.

Committed fixtures (`config/local/`, all checked by `make monitor-check` at fixed `--now 1700000600`):

| Fixture | Status | Shows |
|---|---|---|
| `monitor-safe.json` | SAFE | coherent synthetic snapshot, `L == trackedLocked == R+P+Q` with a lock in flight |
| `monitor-unsafe.json` | UNSAFE | observed balance lost 5,000,000,000 shared units (5,000 tokens) while `totalLocked` still equals `R+P+Q` |
| `monitor-stale.json` | STALE | otherwise healthy, but older than `maxAgeSeconds` |
| `monitor-incoherent.json` | UNKNOWN | R taken at a different epoch/checkpoint |
| `monitor-nonsynthetic.json` | UNKNOWN | placeholder non-synthetic data can never be SAFE |

**The monitor detects; it does not prevent.** A compromised verifier can forge an authenticated credit (R rises without L) or an authenticated release within `totalLocked` (L falls while R is unchanged). `test/security/ResidualRisks.t.sol` demonstrates both.

## Dust and donations

- Bridge amounts must be exact multiples of `conversionRate`; sub-shared-decimal dust is rejected (`Dust()`), never truncated. Holders keep dust they cannot bridge (the demo rounds creator fees down before burning).
- Donations raise the observed balance (and therefore `L`, after flooring) but never `totalLocked`. They are never released and are reported as `UNTRACKED_SURPLUS`, not as tracked backing.

## Synthetic demo

`make demo` runs the Solidity integration test (`test/integration/LocalHarnessFlow.t.sol`) and then `tools/sairi.py demo`, a Python arithmetic model of the same flow plus a final donation step. After every step it prints observed `L`, `R`, `P`, `Q`, `trackedLocked` and a monitor verdict, then reconciles swaps, claims and the donation (7 shared units of surplus plus 3 raw units of dust). Output is labelled `SYNTHETIC_LOCAL_DEMO_NOT_A_CHAIN_OBSERVATION`.
