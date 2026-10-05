# SAIRI Multichain

**EXPERIMENTAL — UNAUDITED — NO MAINNET DEPLOYMENT**

Independent open-source research and local prototyping for expanding existing SAIRI from Base to Robinhood Chain as a single backed economic asset. This is not a migration, exchange-listing request, independent token launch, or promise of liquidity, returns, or risk-free bridging.

## Status
Local Solidity harness: authenticated mock-endpoint lock/credit/burn/release, backed representation, constant-product swap pool, separate fixed-beneficiary creator fee collector and conservation tests. **Not** an official LayerZero or Uniswap integration. Production token, beneficiary and target-network deployments remain unverified. Configuration/monitoring/liquidity command-line tools are the next milestone. No mainnet operations are authorized by this repository.

## Development
Pinned prerequisites: Foundry v1.5.1, Python 3.12.8 and Solidity 0.8.30 (fetched by Foundry on first build). No third-party Solidity or Python packages. After compiler setup, local tests require no network, wallet or RPC credentials.

```sh
make setup
make build
make test
make invariants
make demo
make check
```

See [requirements](docs/REQUIREMENTS.md), [architecture](docs/ARCHITECTURE.md), and [status](docs/STATUS.md). Original code is MIT-licensed; third-party dependencies retain their own licenses.

The mock endpoints run both sides in one local EVM; the tests reconcile in-flight liabilities from one coherent message ledger. This is not proof of a mainnet bridge. The pool uses constant-product math, not concentrated liquidity; 1% creator fees are charged in the consumed input asset, plus a separate 0.3% LP fee on the remainder. Exact-output swaps are explicitly unsupported. No production fee schedule has been approved.
