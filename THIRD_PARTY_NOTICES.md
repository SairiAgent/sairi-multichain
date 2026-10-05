# Third-party notices and dependency policy

Original project source is MIT. This prototype deliberately imports no external Solidity or Python source libraries; minimal token/test interfaces are original. No third-party code has been relabeled MIT.

Toolchain dependencies (not bundled source):

- Python 3.12.8 — Python Software Foundation license; standard-library tooling, no PyPI packages.
- Foundry v1.5.1 — upstream MIT/Apache-2.0 licensing; used as build/test tooling.
- Solidity 0.8.30 compiler — upstream GPL-3.0; tool only, not copied into project source.
- Pinned GitHub Actions keep their upstream licenses; see immutable commits in the workflow and source evidence ledger.

Research candidates, **not imported**:

- LayerZero OFTAdapter file declares MIT; package observed 4.0.1. Inspect exact pinned transitive files/licenses before adoption.
- Uniswap v4 PoolManager source declares BUSL-1.1, not MIT at retrieval time. Nonproduction testing does not imply permission to deploy a production integration. Preserve BUSL and per-file licenses; review its change-date and applicable additional grants before production use.
- OpenZeppelin dependencies, if introduced later, must be pinned and retain their notices.

See docs/SOURCES.md and docs/adr/0001-interoperability.md. No license compatibility claim for an integration that has not been imported or reviewed.
