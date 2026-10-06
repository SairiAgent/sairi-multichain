# Third-party notices and dependency policy

Original project source is MIT. Third-party code keeps its own license; no third-party file has been relabeled MIT.

## Vendored Solidity sources (`dependencies/`)

Vendored verbatim from npm registry tarballs pinned by exact version and sha512 integrity in `dependencies/lock.json`; every vendored file is pinned by sha256 and checked offline by `make deps-verify` (part of `make check`). Only the import closure of the declared entrypoints, each package's `package.json`, and the full license texts listed below are included. No git submodules, symlinks or package-manager installs.

| Package | Version | Licenses (per-file SPDX) | Full license text shipped in the package directory | Use |
|---|---|---|---|---|
| `@layerzerolabs/oft-evm` | 4.0.1 | MIT | `LayerZero-v2-LICENSE-MIT` | `OFTAdapter` / `OFT` base for `src/layerzero/` |
| `@layerzerolabs/oapp-evm` | 0.4.1 | MIT | `LayerZero-v2-LICENSE-MIT` | OApp, enforced options, `OptionsBuilder` |
| `@layerzerolabs/lz-evm-protocol-v2` | 3.0.168 | **LZBL-1.2** and MIT (interfaces) | `LayerZero-v2-LICENSE-LZBL-1.2`, `LayerZero-v2-LICENSE-MIT` | EndpointV2 for local integration tests; interfaces; `PacketV1Codec` |
| `@layerzerolabs/lz-evm-messagelib-v2` | 3.0.168 | **LZBL-1.2** and MIT (interfaces) | `LayerZero-v2-LICENSE-LZBL-1.2`, `LayerZero-v2-LICENSE-MIT` | SendUln302 / ReceiveUln302 for local integration tests |
| `@openzeppelin/contracts` | 4.9.6 | MIT | `OpenZeppelin-contracts-4.9.6-LICENSE` | Ownable, ERC20, SafeERC20, ERC165 (the LayerZero endpoint sources require the 4.x `Ownable`; both LayerZero OApp packages declare `^4.8.1 \|\| ^5.0.0`) |
| `solidity-bytes-utils` | 0.8.4 | Unlicense (`BytesLib.sol`); `package.json` says MIT | upstream `LICENSE` from the npm tarball (Unlicense text) | `OptionsBuilder` dependency |

Per-file SPDX counts at this pin: MIT 46, LZBL-1.2 25, Unlicense 1 (`make deps-verify` prints them).

## Full license texts and provenance (`licenses/`)

The npm tarballs for the LayerZero and OpenZeppelin packages contain no license file, but that does not remove the obligation to redistribute the license terms. The full texts were therefore copied verbatim from official upstream repositories at pinned commits (retrieved 2026-10-06):

| File | Upstream (commit) | git blob | sha256 |
|---|---|---|---|
| `licenses/LayerZero-v2-LICENSE-LZBL-1.2` | LayerZero-Labs/LayerZero-v2 `LICENSE-LZBL-1.2` (`9c741e7f9790639537b1710a203bcdfd73b0b9ac`) | `52be5c9fe938d115b30069a14b99d088b9928e19` | `3d4db850…fcd7a78d9` |
| `licenses/LayerZero-v2-LICENSE-MIT` | LayerZero-Labs/LayerZero-v2 `LICENSE-MIT` (same commit) | `0029fa9f47e32a77a2475b109327f492a7a9b0d7` | `1bdefbc2…dd8a684244` |
| `licenses/OpenZeppelin-contracts-4.9.6-LICENSE` | OpenZeppelin/openzeppelin-contracts `LICENSE` at tag `v4.9.6` (`dc44c9f1a4c3b10af99492eed84f83ed244203f6`) | `817249a0cd2ec1bb1c3d15ed0166f97903e94557` | `0e05b4f4…255e0187ea3` |

`licenses/lock.json` records the exact URLs and full hashes. `make deps-verify` recomputes both the sha256 and the git blob id offline. It also requires every vendored package to carry identical copies of its texts, and every vendored Solidity file's SPDX license to have a full text in its package directory. OFT/OApp caveat: the LayerZero-Labs/devtools repository (source of `oft-evm`/`oapp-evm`) had no LICENSE file at the checked commit. Those files are MIT by SPDX header and `package.json`, and LayerZero's published MIT text is shipped with them; a devtools-specific copyright line is unverified.

**LZBL-1.2 is the LayerZero Business License 1.2. It is not MIT and not an open-source license.** Its text grants rights to copy, modify, redistribute and make **non-production** use, excludes "Permissioned Applications", converts to a GPL-2.0-or-later-compatible license on a Change Date four years from 2023-12-14 for permissionless applications, and requires that the license be conspicuously displayed on every copy (hence the copies in each LZBL package directory). Most LZBL files (EndpointV2, ULN302 and their bases) are compiled only into local tests, never into contracts this repository deploys. However the upstream `OFTCore` imports `OAppPreCrimeSimulator`, which pulls the LZBL-1.2 library `PacketV1Codec` into the deployable `SairiOFTAdapter` / `SairiBackedOFT` bytecode. Testnet use is non-production; any production use requires a license review of LZBL-1.2 terms for that code. This summary is not legal advice, and no compatibility or permission claim is made here.

## Toolchain (not bundled)

- Python 3.12.8 — PSF license; standard-library tooling only, no PyPI packages.
- Foundry v1.5.1 — MIT/Apache-2.0; build/test/script tooling.
- Solidity 0.8.30 compiler — GPL-3.0; tool only.
- Pinned GitHub Actions keep their upstream licenses (immutable commits in the workflow).

## Research references, not imported

- Uniswap v4 PoolManager source declares BUSL-1.1 (change date per upstream license). Now imported for non-production local/testnet integration; see the updated notice below.

See [docs/SOURCES.md](docs/SOURCES.md) and [ADR 0001](docs/adr/0001-interoperability.md).

## Uniswap v4 local integration (added 2026-10-06)

`@uniswap/v4-core@1.0.2` is vendored verbatim, npm integrity and per-file hashes pinned in
`dependencies/lock.json`. Core PoolManager is **BUSL-1.1**, interfaces/libraries include MIT;
vendored Solmate `Owned.sol` is **AGPL-3.0-only**. Full pinned texts/provenance are in `licenses/`
and copied into the package directory. The current BUSL text specifies a 2027-06-15 change date
(or earlier specified date); no production-fork license is assumed. Self-deployed managers here
are non-production testing only. Canonical manager integration does not imply cloning production
core under the project's MIT license. Original project source alone is MIT.
