# Status

**EXPERIMENTAL — UNAUDITED — NO MAINNET DEPLOYMENT**

## LIVE TESTNET RESULT — 2026-10-06

Completed the 10-token Base Sepolia → Robinhood testnet → Base Sepolia roundtrip with successful on-chain receipts and matching delivery events. See [result](TESTNET_RESULT.md) and [machine-readable evidence](evidence/testnet-roundtrip-2026-10-06.json). Historical funding blocker below is superseded; no mainnet or real SAIRI was used.

## IMPLEMENTED

- Authenticated local lockbox / backed representation with replay protection, pauses, rate limits, exposure caps, shared-decimal dust rejection and no administrative collateral withdrawal.
- Local constant-product pool and separate immutable-beneficiary fee collector: 100-bps creator fee on consumed gross input, correct input asset, separate sequential LP fee, exact-output rejection. LP entry consumes only proportional amounts with explicit `minShares`; removal enforces both asset minima (local harness design, not an LP-donation approximation).
- Exact transfer checks on both sender and recipient, including taxes enabled after deposits; claims are atomic and nonreentrant.
- Pinned compiler/tooling, public CI, publication guard, official-source research and integration issue backlog.
- Standard-library Python 3.12.8 tooling (`tools/sairi.py`, `tools/sairi_tools/`) :
  - fail-closed configuration validator with typed dataclasses, an explicit local mock fixture (`config/local/local-mock.json`) and a live file (`config/networks/live.json`) whose production values are `null` and which is expected to be rejected; live evidence must be bound to the exact configured value, use credential-free https sources and a nonzero code hash, and the live candidate shape requires LayerZero EIDs 30184 (Base) / 30416 (Robinhood Chain). Offline record check only — no on-chain verification, `deploymentVerified: false`;
  - L/R/P/Q monitor (SAFE / UNSAFE / STALE / UNKNOWN / INVALID) where L is the **observed** lockbox balance and `totalLocked` is a separate `trackedLocked` reconciliation value; non-synthetic snapshots always report UNKNOWN; five synthetic/placeholder fixtures;
  - integer pool arithmetic mirror (atomic: checks before commit, strict argument types) and synthetic buy/sell simulator matching the Solidity fee math;
  - synthetic accounting roundtrip demo (observed L and tracked total, donation step) with swap and claim reconciliation;
  - Python unit tests under `tests/`; Make targets wire them into `test`, `demo` and `check`.
- Docs: [FEES](FEES.md), [ACCOUNTING](ACCOUNTING.md), [ADMIN](ADMIN.md), [THREAT_MODEL](THREAT_MODEL.md), [RUNBOOK](RUNBOOK.md), [AIRDROP](AIRDROP.md) (considerations only).

### LayerZero OFT milestone (testnet-only, 2026-10-06)

- Pinned, hash-verified vendored dependencies (`dependencies/lock.json`, `tools/vendor_deps.py`, `make deps-verify`): LayerZero `oft-evm` 4.0.1, `oapp-evm` 0.4.1, `lz-evm-protocol-v2` / `lz-evm-messagelib-v2` 3.0.168, OpenZeppelin 4.9.6, `solidity-bytes-utils` 0.8.4. Full license texts (LZBL-1.2, LayerZero MIT, OpenZeppelin MIT; BytesLib Unlicense) come from official upstream repositories at pinned commits, are pinned by sha256 and git blob id in `licenses/lock.json`, and are copied into each vendored package directory. `make deps-verify` checks them offline. See [notices](../THIRD_PARTY_NOTICES.md); LZBL-1.2 is not an open-source license.
- `src/layerzero/SairiOFTAdapter.sol` (canonical lockbox on `OFTAdapter`) and `SairiBackedOFT.sol` (representation on `OFT`, no admin mint), sharing `SairiOFTGuards`: single remote EID, once-only peer, pause (inbound stays retryable), outbound rate limit, exposure caps, dust/compose/invalid-recipient rejection. The adapter adds exact-transfer checks on both ends and a `totalLocked` bound on every release. The existing lockbox/backed-representation architecture is unchanged; `SairiTestnetToken` is a valueless stand-in, **not SAIRI**.
- Local integration tests (`test/layerzero/`, `test/invariant/LzOFTConservationFuzz.t.sol`) over the **genuine** pinned EndpointV2 + SendUln302 + ReceiveUln302 with test-only DVN/executor workers: roundtrip, quotes, underpayment, unverified/insufficient-confirmation/tampered/replayed packets, non-peer senders, peer immutability, pause/cap/rate limits, fee-on-transfer rejection, compromised-verifier residual risk, and 128-run bounded conservation fuzzing. Adapter-specific token risks (`OFTAdapterTokenRisks.t.sol`): token-callback reentrancy during lock and release, including re-entering the endpoint to execute a second release, reverts atomically and the message stays retryable; a sender tax or recipient fee switched on **after** deposit makes redemption revert without touching backing, and the same verified message succeeds on retry once the tax is removed. No guard change was needed.
- Testnet tooling: `script/testnet/` (`TestnetRoutes.sol`, `SairiTestnet.s.sol`: preflight, deploy, wire with pinned libraries/DVN/confirmations/executor, send). `send` re-verifies the app's effective per-app route and the exact enforced-options bytes before broadcasting; `TestnetWiringTamper.t.sol` covers per-app DVN, confirmation, optional-DVN, executor, message-size, send/receive-library and option overrides with unchanged defaults. Also: Make targets with a two-chain allowlist and explicit broadcast gate; read-only Python `testnet-preflight`, `testnet-status` (structural checks plus raw observations; backing status always `UNKNOWN`) and `testnet-message` (indexer view, `proof: false`); an opt-in fork simulation (`make testnet-fork-check`); and the [testnet runbook](TESTNET_RUNBOOK.md).

## TESTED

Contract checkpoint `94f2168` (main): orchestrator independently ran `make setup`, `make check` and `make demo` on 2026-10-05 — **70 Solidity tests passed, 0 failed, 0 skipped**, including bounded multi-step conservation fuzz tests and an LP rounding fuzz test (128 runs each), within-backing forged release / unbacked credit demonstrations from a compromised verifier, token-callback reentrancy and owner-induced redemption stalls. Model review is not an audit.

Final local tooling verification on 2026-10-05: **117 Python tests passed, 0 failed**, plus **70 Solidity tests passed, 0 failed, 0 skipped**. Orchestrator independently ran `make setup`, `make check`, `make demo`, and `make simulate`; the documented build/test/invariants/config-check/monitor-check targets ran through check. Three Solidity fuzz tests run 128 cases each. Negative configuration and UNKNOWN/STALE checks behaved as intended. Hosted CI is separate: contract checkpoint passed [run 37253788617](https://github.com/SairiAgent/sairi-multichain/actions/runs/37253788617); final tooling PR/main checks are visible in [Actions](https://github.com/SairiAgent/sairi-multichain/actions), not inferred from local results.

LayerZero milestone independently re-run by the orchestrator after review fixes on 2026-10-06: `make check` passed end to end, including the unchanged publication guard: **110 Solidity tests passed, 0 failed, 0 skipped** (70 existing + 40 new; the opt-in fork test is excluded) and **158 Python tests passed** (117 existing + 41 new); the publication guard checked 193 working files and reachable Git blobs. `make demo` passed. `make testnet-fork-check` passed (1 test: scripted deploy/wire/two legs through the live LayerZero contracts with an impersonated DVN, then `send()` refusing a per-app DVN override). The orchestrator also independently ran `make setup`, `make demo`, `make testnet-preflight` and `make testnet-fork-check`; all exited 0. `make testnet-preflight` returned **READY** on both chains and both script preflights passed; evidence is in `config/research/testnet-preflight-2026-10-06.json`. Earlier fork attempts failed on a transient Robinhood RPC `unsupported block number` error; the test now forks 32 blocks behind head.

Additional independent orchestrator checks (read-only): 10 runtime code hashes matched `cast keccak`; read-only creation-gas estimation for the test token and the backed OFT against the real Robinhood testnet endpoint succeeded. Gas estimation is not deployment proof. A separate working-tree Gitleaks scan found no leaks. Hosted CI for this change is not inferred from these local checks; see [Actions](https://github.com/SairiAgent/sairi-multichain/actions).

## MOCKED

Both chains run in one local EVM with test-only endpoints and freely mintable canonical/WETH-like fixtures. In the LayerZero tests the endpoint and message libraries are genuine pinned code, but the DVN and executor are test workers (`test/layerzero/LzTestWorkers.sol`), and the fork simulation impersonates the live DVN rather than obtaining a real attestation. Pool math is constant product, not Uniswap v4/concentrated liquidity. Fixed local beneficiaries are not production authorities. All tooling fixtures, prices and liquidity figures are synthetic.

## UNVERIFIED

Canonical SAIRI, treasury/beneficiary, existing adapters, supply/administrative controls, real liquidity rights, mainnet bilateral verifier configuration, target WETH/DEX code identities. Live addresses and the real token remain **unknown**. Documentary candidate identifiers are segregated in `config/research/` and in `documentaryReferences` of the live config; they are never read as parameters.

Testnet scope: the LayerZero testnet route is verified only as **unfinalized read-only observations** (code present, getters and default configs as expected). Source-level identity of the deployed testnet endpoint/ULN/DVN/executor bytecode against the vendored sources is **not** verified. A canonical Uniswap deployment on Robinhood testnet is **UNVERIFIED**: the official v4 deployments page lists none, but that absence is not proof that none exists. The undocumented contract at the Robinhood-mainnet PoolManager address on Robinhood testnet is unverified and unused. Testnet balances, settlement and in-flight liabilities are never verified by the tooling (`testnet-status` reports `UNKNOWN`).

## BLOCKED

- **Uniswap on Robinhood testnet:** a canonical deployment is UNVERIFIED, so no testnet pool integration is attempted.
- Production LayerZero use (mainnet adapter/OFT, DVN selection beyond a 1-of-1 testnet DVN, LZBL-1.2 license review, audit) and Uniswap v4 integration; a verified live evidence collector for the monitor (until it exists, real snapshots are UNKNOWN by design); any production use pending provenance, pinned-block code verification, mature-library/DEX integration tests, fee-schedule approval and independent audit. Initial RPC attempts returned HTTP 403; later pinned, unfinalized read-only calls verified chain IDs, endpoint EIDs/code hashes and Robinhood WETH proxy/implementation observations. Sourcify proxy exact-match and implementation metadata-excluded match are recorded in SOURCES. Finalized historical state remains unavailable; these observations do not verify a production integration. Only the explicitly documented testnet deployments and stand-in-token roundtrip have occurred; no mainnet or real-asset operation has occurred.

## Known tooling limits

- The config validator still accepts only lowercase addresses. A standard-library Keccak-256 (`tools/sairi_tools/keccak.py`, tested against known vectors and a live `cast codehash`) now exists for the testnet tooling and EIP-55 checks; the validator has not been changed to use it.
- `testnet-status` reads the two chains at unsynchronized, unfinalized recent blocks and does not measure in-flight P/Q. It therefore reports backing as `UNKNOWN` (exit 4), with raw values and descriptive `balanceRelations` only. It never reports settled, pending, safe or unsafe, and no status exits 0 without `--expect`. The pre-existing monitor semantics are unchanged.
- The monitor evaluates supplied snapshots; it has no chain reader, matching epochs/checkpoints are declarations rather than proof, and therefore only synthetic fixtures can be SAFE.
- The config validator checks evidence records offline; it cannot confirm that a code hash, block or source is genuine.
- The demo and pool model are Python arithmetic mirrors, not EVM/token/authorization emulation; `make demo` runs the Solidity integration test as the executable reference.
- Simulator output is constant-product only; it ignores gas, MEV, concentrated liquidity and real market prices.

## NEXT

- Live roundtrip evidence is recorded in [TESTNET_RESULT](TESTNET_RESULT.md). Next: independently review the deployed configuration and close the remaining DEX/production gates.
- Verify hosted CI for each subsequent change and complete the live integration gates.
- Integration gates: issues [1](https://github.com/SairiAgent/sairi-multichain/issues/1), [2](https://github.com/SairiAgent/sairi-multichain/issues/2), [3](https://github.com/SairiAgent/sairi-multichain/issues/3), [4](https://github.com/SairiAgent/sairi-multichain/issues/4).
