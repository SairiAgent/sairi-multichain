# Status

**EXPERIMENTAL — UNAUDITED — NO MAINNET DEPLOYMENT**

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

## TESTED

Contract checkpoint `94f2168` (main): orchestrator independently ran `make setup`, `make check` and `make demo` on 2026-10-05 — **70 Solidity tests passed, 0 failed, 0 skipped**, including bounded multi-step conservation fuzz tests and an LP rounding fuzz test (128 runs each), within-backing forged release / unbacked credit demonstrations from a compromised verifier, token-callback reentrancy and owner-induced redemption stalls. Model review is not an audit.

Final local tooling verification on 2026-10-05: **117 Python tests passed, 0 failed**, plus **70 Solidity tests passed, 0 failed, 0 skipped**. Orchestrator independently ran `make setup`, `make check`, `make demo`, and `make simulate`; the documented build/test/invariants/config-check/monitor-check targets ran through check. Three Solidity fuzz tests run 128 cases each. Negative configuration and UNKNOWN/STALE checks behaved as intended. Hosted CI is separate: contract checkpoint passed [run 37253788617](https://github.com/SairiAgent/sairi-multichain/actions/runs/37253788617); final tooling PR/main checks are visible in [Actions](https://github.com/SairiAgent/sairi-multichain/actions), not inferred from local results.

## MOCKED

Both chains run in one local EVM with test-only endpoints and freely mintable canonical/WETH-like fixtures. Pool math is constant product, not Uniswap v4/concentrated liquidity. Fixed local beneficiaries are not production authorities. All tooling fixtures, prices and liquidity figures are synthetic.

## UNVERIFIED

Canonical SAIRI, treasury/beneficiary, existing adapters, supply/administrative controls, real liquidity rights, bilateral verifier configuration, target WETH/DEX code identities. Live addresses and the real token remain **unknown**. Documentary candidate identifiers are segregated in `config/research/` and in `documentaryReferences` of the live config; they are never read as parameters.

## BLOCKED

Actual LayerZero OApp/OFT and Uniswap v4 integrations; a verified live evidence collector for the monitor (until it exists, real snapshots are UNKNOWN by design); any production use pending provenance, pinned-block code verification, mature-library/DEX integration tests, fee-schedule approval and independent audit. Initial RPC attempts returned HTTP 403; later pinned, unfinalized read-only calls verified chain IDs, endpoint EIDs/code hashes and Robinhood WETH proxy/implementation observations. Sourcify proxy exact-match and implementation metadata-excluded match are recorded in SOURCES. Finalized historical state remains unavailable; these observations do not verify a production integration. No public-chain deployment or financial operation has occurred.

## Known tooling limits

- EIP-55 checksums need keccak-256 (not in the standard library), so the validator accepts only lowercase addresses.
- The monitor evaluates supplied snapshots; it has no chain reader, matching epochs/checkpoints are declarations rather than proof, and therefore only synthetic fixtures can be SAFE.
- The config validator checks evidence records offline; it cannot confirm that a code hash, block or source is genuine.
- The demo and pool model are Python arithmetic mirrors, not EVM/token/authorization emulation; `make demo` runs the Solidity integration test as the executable reference.
- Simulator output is constant-product only; it ignores gas, MEV, concentrated liquidity and real market prices.

## NEXT

- Verify hosted CI for each subsequent change and complete the live integration gates.
- Integration gates: issues [1](https://github.com/SairiAgent/sairi-multichain/issues/1), [2](https://github.com/SairiAgent/sairi-multichain/issues/2), [3](https://github.com/SairiAgent/sairi-multichain/issues/3), [4](https://github.com/SairiAgent/sairi-multichain/issues/4).
