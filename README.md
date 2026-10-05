# SAIRI Multichain

**EXPERIMENTAL — UNAUDITED — NO MAINNET DEPLOYMENT**

Independent open-source research and local prototyping for expanding existing SAIRI from Base to Robinhood Chain as a single backed economic asset. This is not a migration, exchange-listing request, independent token launch, or promise of liquidity, returns, or risk-free bridging.

## Status
Local Solidity harness: authenticated mock-endpoint lock/credit/burn/release, backed representation, constant-product swap pool, separate fixed-beneficiary creator fee collector and conservation tests. Offline Python tooling: fail-closed configuration validator (offline record checks only, no on-chain verification), L/R/P/Q backing monitor (L = observed lockbox balance; only synthetic fixtures can be SAFE, real snapshots are UNKNOWN until a verified evidence collector exists), integer liquidity simulator and a synthetic accounting demo.

**Not** an official LayerZero or Uniswap integration: actual LayerZero OApp/OFT and Uniswap v4 integrations are **blocked** pending provenance, pinned-block code verification, mature-library integration tests, fee approval and audit. Production token, beneficiary, addresses and target-network deployments remain unverified and are `null` in configuration. No mainnet operations are authorized by this repository.

## Development
Pinned prerequisites: Foundry v1.5.1, Python 3.12.8 and Solidity 0.8.30 (fetched by Foundry on first build). No third-party Solidity or Python packages. After compiler setup, everything runs offline with no wallet, key or RPC.

```sh
make setup        # verify pinned Python 3.12.8 and Forge 1.5.1 (installs nothing)
make build        # forge build
make test         # full Solidity suite + Python unittest
make invariants   # invariant/fuzz conservation tests
make demo         # Solidity integration test + synthetic Python roundtrip and simulator
make check        # fmt, build, tests, invariants, config + expected-reject live gate, monitor fixtures, publication guard
```

Tool CLI: `python3.12 tools/sairi.py {validate-config,monitor,simulate,quote,demo} --help`. See the [runbook](docs/RUNBOOK.md).

## Documentation
[Requirements](docs/REQUIREMENTS.md) · [Architecture](docs/ARCHITECTURE.md) · [Status](docs/STATUS.md) · [Fees](docs/FEES.md) · [Accounting](docs/ACCOUNTING.md) · [Admin](docs/ADMIN.md) · [Threat model](docs/THREAT_MODEL.md) · [Runbook](docs/RUNBOOK.md) · [Airdrop considerations](docs/AIRDROP.md) · [Review](docs/REVIEW.md) · [Sources](docs/SOURCES.md) · [Existing SAIRI](docs/EXISTING_SAIRI.md) · [ADR 0001](docs/adr/0001-interoperability.md). Integration gates: issues [1](https://github.com/SairiAgent/sairi-multichain/issues/1)–[4](https://github.com/SairiAgent/sairi-multichain/issues/4).

## Notes
The mock endpoints run both sides in one local EVM; the tests reconcile in-flight liabilities from one coherent message ledger. This is not proof of a mainnet bridge. The pool uses constant-product math, not concentrated liquidity; 1% creator fees are charged in the consumed input asset, plus a separate 0.3% LP fee on the remainder (1.297% nominal before integer flooring, plus price impact and gas). Exact-output swaps are explicitly unsupported. No production fee schedule has been approved.

Original code is MIT-licensed; third-party dependencies retain their own licenses.
