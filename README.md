# SAIRI Multichain

**EXPERIMENTAL — UNAUDITED — NO MAINNET DEPLOYMENT**

Independent open-source research and prototyping for expanding existing SAIRI from Base to Robinhood Chain as a single backed economic asset. This is not a migration, exchange-listing request, independent token launch, or promise of liquidity, returns, or risk-free bridging.

## Status
- **Local harness** (unchanged): authenticated mock-endpoint lock/credit/burn/release, backed representation, constant-product swap pool, separate fixed-beneficiary creator fee collector and conservation tests.
- **LayerZero integration (new, testnet-only):** `SairiOFTAdapter` (canonical-side lockbox on the official `OFTAdapter`) and `SairiBackedOFT` (representation on the official `OFT`), built on pinned, hash-verified LayerZero and OpenZeppelin sources. Local integration tests run the **genuine** LayerZero `EndpointV2`, `SendUln302` and `ReceiveUln302` code (only the DVN/executor are labelled test workers), plus a bounded fuzz conservation test.
- **Testnet route verified read-only:** Base Sepolia (84532, EID 40245) ↔ Robinhood Chain testnet (46630, EID 40451) has LayerZero endpoints, default ULN302 libraries, a live LayerZero Labs DVN (not the dead DVN) and executors in both directions, and quotes fees. Deploy / wire / roundtrip scripts with a two-chain allowlist and on-chain preflight are ready; an opt-in fork simulation runs them end-to-end through the live LayerZero contracts.
- **Live testnet milestone:** completed a 10-token Base Sepolia → Robinhood testnet → Base Sepolia roundtrip, verified from successful source/destination receipts and matching LayerZero/OFT events. See [evidence and limits](docs/TESTNET_RESULT.md). No real SAIRI/mainnet assets moved. Uniswap testnet integration remains unverified; the unsynchronized backing monitor still reports UNKNOWN.

Offline Python tooling: fail-closed configuration validator, L/R/P/Q backing monitor, integer liquidity simulator, synthetic accounting demo, and read-only testnet preflight/status tools. Production token, beneficiary, addresses and mainnet deployments remain unverified and `null`. No mainnet operations are authorized by this repository.

## Development
Pinned prerequisites: Foundry v1.5.1, Python 3.12.8 and Solidity 0.8.30. Third-party Solidity is vendored under `dependencies/` and pinned in `dependencies/lock.json`; no Python packages. `make check` is fully offline after the compiler is fetched.

```sh
make setup        # verify pinned Python 3.12.8 and Forge 1.5.1 (installs nothing)
make build        # forge build
make test         # Solidity suite (excluding opt-in fork tests) + Python unittest
make invariants   # invariant/fuzz conservation tests (local harness and LayerZero stack)
make demo         # Solidity integration test + synthetic Python roundtrip and simulator
make deps-verify  # vendored dependencies match the lock exactly (offline)
make check        # fmt, deps-verify, build, tests, invariants, config + expected-reject live gate, monitor fixtures, publication guard

make testnet-preflight   # NETWORK, read-only: verify the Base Sepolia <-> Robinhood testnet route
make testnet-fork-check  # NETWORK, read-only: fork simulation of deploy/wire/roundtrip (not live proof)
```

Tool CLI: `python3.12 tools/sairi.py {validate-config,monitor,simulate,quote,demo,testnet-preflight,testnet-status,testnet-message} --help`. See the [runbook](docs/RUNBOOK.md) and [testnet runbook](docs/TESTNET_RUNBOOK.md).

## Documentation
[Requirements](docs/REQUIREMENTS.md) · [Architecture](docs/ARCHITECTURE.md) · [Status](docs/STATUS.md) · [Fees](docs/FEES.md) · [Accounting](docs/ACCOUNTING.md) · [Admin](docs/ADMIN.md) · [Threat model](docs/THREAT_MODEL.md) · [Runbook](docs/RUNBOOK.md) · [Testnet runbook](docs/TESTNET_RUNBOOK.md) · [Airdrop considerations](docs/AIRDROP.md) · [Review](docs/REVIEW.md) · [Sources](docs/SOURCES.md) · [Existing SAIRI](docs/EXISTING_SAIRI.md) · [ADR 0001](docs/adr/0001-interoperability.md). Integration gates: issues [1](https://github.com/SairiAgent/sairi-multichain/issues/1)–[4](https://github.com/SairiAgent/sairi-multichain/issues/4).

## Notes
The mock endpoints run both sides in one local EVM; the tests reconcile in-flight liabilities from one coherent message ledger. The LayerZero local tests also run both "chains" in one EVM with test-only DVN/executor workers. Neither is proof of a live bridge. The pool uses constant-product math, not concentrated liquidity; 1% creator fees are charged in the consumed input asset, plus a separate 0.3% LP fee on the remainder (1.297% nominal before integer flooring, plus price impact and gas). Exact-output swaps are explicitly unsupported. No production fee schedule has been approved.

Original code is MIT-licensed. Third-party dependencies retain their own licenses, with full texts in `licenses/` and in each vendored package. Some LayerZero protocol files are under LZBL-1.2, the LayerZero Business License, which is **not** an open-source license — see [notices](THIRD_PARTY_NOTICES.md).
