# Threat model (LOCAL HARNESS)

**EXPERIMENTAL — UNAUDITED — NO MAINNET DEPLOYMENT.** Model-assisted review is not an audit. See also [REVIEW](REVIEW.md), [ADR 0001](adr/0001-interoperability.md) and [ADMIN](ADMIN.md).

## Assets

Canonical SAIRI locked in the lockbox (`L`); backed representation supply (`R`); in-flight messages (`P`, `Q`); pool reserves and LP shares; creator fees held by the collector.

## Trust assumptions

1. **Endpoint / verification network is trusted.** The apps authenticate "the configured endpoint reports the configured peer sent this nonce". Nothing more.
2. Tokens are honest, non-rebasing ERC-20s whose `balanceOf` is truthful. Fee-on-transfer and later-enabled taxes are rejected by both-end exact transfer checks; arbitrary malicious tokens are out of scope.
3. The owner is honest for liveness (see ADMIN).

## Explicitly accepted, demonstrated residual risks

| Threat | Result in the harness | Evidence |
|---|---|---|
| Compromised verifier forges a credit | Unbacked representation minted; `L < R + P + Q`. Only the representation exposure cap bounds it. | `test_residualRisk_compromisedEndpoint_forgesCreditWithoutLock` |
| Compromised verifier forges a release within `totalLocked` | All backing can be sent to the attacker; honest holders' tokens become unbacked. Outbound rate limits are not consulted for inbound deliveries. | `test_residualRisk_compromisedEndpoint_drainsBackingWithinLimit` |
| Owner pauses or zeroes the burn rate | Redemption stalls indefinitely; no collateral leaves. | `test_residualGovernanceRisk_*` |

Local invariants and `tools/sairi.py monitor` **detect** these violations on synthetic data (a coherent synthetic snapshot reports `UNSAFE`); they do **not prevent** them. For real chains the monitor cannot even confirm safety today: with no verified live evidence collector, every non-synthetic snapshot is `UNKNOWN` (deficit reasons are still listed). Prevention depends on the production verifier configuration (e.g. multiple independent DVNs), which is not implemented or validated here.

## Mitigated in the harness (tests exist)

Replay (per-nonce consumption), unauthorized endpoint/peer, recipient self-aliases, shared-decimal dust, exposure caps, outbound rate limits, reentrancy (including token callbacks), exact transfers on both ends, LP over-pull/dilution (proportional consumption, rounding up, `minShares`, removal minima), exact-output rejection, immutable fee beneficiary and permissionless claims that pay only the beneficiary.

## Monitoring threats

- **False SAFE from bookkeeping:** `totalLocked` can be unchanged after a negative rebase, token loss or drain. The monitor's `L` is the observed `balanceOf(lockbox)` normalized to shared units; `totalLocked` is only a separate `trackedLocked` reconciliation value (`L < trackedLocked` → `UNSAFE`).
- **Unsynchronized reads:** independent latest-block reads on two chains can miss or double-count in-flight value. The monitor requires a shared epoch and delivery-ledger checkpoint and returns `UNKNOWN` otherwise. Matching labels are only declared, not proven.
- **Unverified live data:** any `synthetic: false` snapshot → `UNKNOWN` (`LIVE_EVIDENCE_UNVERIFIED`) until a verified collector and configuration integration exist (BLOCKED). There is deliberately no flag to assert proof.
- **Stale, unfinalized or unevidenced data** → `STALE` / `UNKNOWN`, never `SAFE`.
- **Type confusion** (booleans as integers, numeric strings, floats, duplicate JSON keys, negative values, future timestamps) → rejected (`INVALID`).

## Python model limits

`tools/sairi_tools/amm.py` and `demo.py` are integer arithmetic mirrors. Every state change is computed and checked first and committed only on success (rollback regressions cover fee-accrual and reserve overflow), and arguments are strictly typed (uint256 minima, boolean direction, asset index 0/1). They do **not** emulate the EVM, ERC-20 transfers, exact-transfer checks, reentrancy guards, `msg.sender` authorization or recipient validation; the Solidity tests are the reference for those.

## Mock vs mature-library gap

`LocalEndpointMock` and `LocalConstantProductPool` are original minimal code. They do not reproduce LayerZero OApp/OFT semantics or Uniswap v4 PoolManager/hook semantics. The testnet-only `src/layerzero/` contracts close part of the LayerZero gap: they are built on pinned official OFT/OApp code and tested against genuine EndpointV2 + ULN302 code (DVN quoting/attestation thresholds, confirmations, options, fee payment, nonce ordering, payload-hash checks, `lzReceive` origin checks). Still not covered locally: real DVN/executor off-chain behaviour, chain finality, and the deployed testnet bytecode's source identity. Uniswap v4 remains **blocked**.

## LayerZero OFT (testnet) threats

| Threat | Handling | Evidence |
|---|---|---|
| Non-peer OApp sends to the representation | Endpoint refuses commit (`LZ_PathNotInitializable`) | `test_nonPeerSender_rejectedAtDelivery` |
| Unverified, under-confirmed, tampered or replayed packet | ULN302/EndpointV2 reject | `test_unverifiedPacket_cannotExecute`, `test_insufficientConfirmations_reverts`, `test_tamperedMessage_cannotExecute`, `test_replay_rejectedByEndpoint` |
| Owner re-points the route to an unbacked contract | Peer settable once, only for the configured EID | `test_setPeer_onceOnly_singleEid_nonZero` |
| Fee-on-transfer canonical token under-backs | Exact transfer checks revert | `test_feeOnTransferToken_rejected` |
| **Residual:** compromised/weak verifier forges a release | Bounded by `totalLocked`; within it, backing is drained and the representation becomes unbacked | `test_compromisedVerifier_forgedRelease_boundedByTotalLocked` |
| Token callback re-enters the adapter (relock, or executing another release) during lock/release | Outer exact-transfer check fails; the whole transaction reverts and the message stays retryable | `OFTAdapterTokenRisks.t.sol` reentrancy tests |
| Token tax/fee switched on **after** collateral deposit | Release reverts (transfer failure or `NonExactTransfer`), backing untouched; the same message succeeds once the tax is removed. Liveness depends on the token. | `test_senderTaxEnabledAfterDeposit_*`, `test_recipientFeeEnabledAfterDeposit_*` |
| **Residual:** owner/delegate changes libraries, DVNs, executor or options for the app at the endpoint, or pauses forever | Not prevented by these contracts. Wiring pins the config, and the script's `send()` refuses to broadcast unless the effective per-app route and exact options still match (`TestnetWiringTamper.t.sol`). Other users' transactions are not protected by the script. `testnet-status` cannot prove solvency (always `UNKNOWN`). | governance risk, documented |
| **Residual:** 1-of-1 LayerZero Labs DVN on testnet | Accepted for testnet only; production needs multiple independent DVNs | TESTNET_RUNBOOK |
| Paused/capped destination | Delivery reverts; message stays verified and retryable | `test_pause_blocksSend_inboundStaysRetryable`, `test_exposureCap_outboundAndInbound` |

## Configuration threats

Invented or unverified production addresses are the main tooling risk. The validator rejects live values that are null or lack a VERIFIED evidence record **bound to the exact configured value** (`configuredValue`, same JSON type, so changing an address, decimal or limit while keeping old evidence is rejected), with an https source that has a host, no userinfo of any form and no credential-like query keys, a date not in the future, the matching live chain, a positive pinned block, `codeVerified: true` and a nonzero code hash. The live candidate shape is LayerZero-specific: Base must use EID 30184 and Robinhood Chain EID 30416. Local fixtures may not reuse live chain IDs or EIDs or claim evidence. Documentary identifiers stay in a separate `documentaryReferences` list that is never read as configuration; malformed entries are rejected, not crashed on.

**Scope:** this is offline structural/provenance-record checking. The validator reads no chain and performs **no on-chain code verification**; every report carries `verificationScope: OFFLINE_RECORD_CHECK_ONLY_NO_ONCHAIN_VERIFICATION` and `deploymentVerified: false`. Matching the documented EIDs proves nothing about endpoint deployments. Tests that validate a fully evidenced live shape use explicitly fake, test-only records that are never written to `config/networks/`. EIP-55 checksums cannot be verified with the standard library, so only lowercase addresses are accepted.
