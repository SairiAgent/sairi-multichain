# Administrative powers (LOCAL HARNESS)

**EXPERIMENTAL — UNAUDITED — NO MAINNET DEPLOYMENT.** No production owner, multisig, key or recovery process exists or is proposed here. The committed live configuration leaves `owner` and every other production value `null`, and the validator rejects it.

## What the bridge owner can do (`BridgeAppBase`)

| Power | Effect |
|---|---|
| `setPaused(bool)` | Blocks outbound lock/burn **and** inbound credit/release. Pending messages stay in flight (counted in P/Q) and remain retryable. |
| `setRateLimit(uint256)` | Outbound per-window limit. `0` blocks all new locks/burns on that side. Does **not** bound inbound deliveries. |
| `setExposureCap(uint256)` | Bounds `totalLocked` (lockbox) or `totalSupply` (representation). A low cap makes credits revert and stay in flight. |
| `transferOwnership(address)` | Single-step; a wrong non-zero address loses admin control permanently. |

## What the owner cannot do

- Mint representation or release canonical tokens directly: only the configured endpoint can call `receiveMessage` (`test_ownerCannotDirectlyMintOrRelease`).
- Withdraw lockbox collateral: there is no withdrawal function.
- Change the endpoint, peer, EIDs, shared decimals or rate window: they are immutable.
- Redirect creator fees: the collector's `pool` and `beneficiary` are immutable and claims always pay the beneficiary.

## Acknowledged liveness / governance risk

**The owner can stall redemption indefinitely.** `test_residualGovernanceRisk_pauseStallsRedemptionIndefinitely` pauses the lockbox for three simulated years while a burn is in flight; the holder is never paid until the owner unpauses. `test_residualGovernanceRisk_zeroBurnRateBlocksRedemption` sets the representation burn rate limit to zero so holders cannot start an exit at all. No collateral is withdrawn in either case and accounting stays balanced (`L == R + P + Q`), but holders' redemption is held hostage by governance. There is no timelock, no expiry of pauses, no guardian separation and no user escape hatch in the harness. A production design would need these, and the redemption entitlement must never expire.

## Key and recovery risk

- Owner key loss: no recovery; pauses/limits become permanent at their last value.
- Owner key compromise: attacker can pause, zero the rate limits or lower caps (denial of service), but not directly take collateral.
- Verifier / endpoint compromise is **more severe** than owner compromise and is outside owner control: see [THREAT_MODEL](THREAT_MODEL.md).
- Creator beneficiary key loss/compromise: accrued and future creator fees are lost or stolen; there is no rotation because the beneficiary is immutable by design. Bridge collateral is unaffected.

## Tooling

The Python tools hold no keys, sign nothing and contact no network. `validate-config` rejects any live configuration whose owner, treasury/beneficiary or other values lack a VERIFIED evidence record bound to the exact configured value (source, date, network, pinned block, code-verification fields). It is an offline record check only: it performs no on-chain verification and never reports a deployment as verified. The live owner and beneficiary are unknown and remain `null`; only the local mock fixture has values.
