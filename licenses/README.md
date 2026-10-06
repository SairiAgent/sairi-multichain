# Third-party license texts

Full license texts for the third-party code vendored in `dependencies/`. They are copied verbatim from official upstream repositories at pinned commits, and each file is pinned by sha256 (and by git blob SHA where GitHub reports one) in `licenses/lock.json`. `make deps-verify` checks these hashes offline. This directory is separate from `dependencies/`, so re-vendoring never overwrites it.

| File | Applies to | Upstream source (pinned) |
|---|---|---|
| `LayerZero-v2-LICENSE-LZBL-1.2` | Files whose SPDX header says `LZBL-1.2` in `dependencies/@layerzerolabs/lz-evm-protocol-v2/` and `dependencies/@layerzerolabs/lz-evm-messagelib-v2/` | LayerZero-Labs/LayerZero-v2 `LICENSE-LZBL-1.2` |
| `LayerZero-v2-LICENSE-MIT` | Files whose SPDX header says `MIT` in those LayerZero protocol/messagelib packages | LayerZero-Labs/LayerZero-v2 `LICENSE-MIT` |
| `OpenZeppelin-contracts-4.9.6-LICENSE` | `dependencies/@openzeppelin/contracts/` (OpenZeppelin Contracts 4.9.6, MIT) | OpenZeppelin/openzeppelin-contracts tag `v4.9.6` `LICENSE` |
| `dependencies/solidity-bytes-utils/LICENSE` (vendored in place) | `solidity-bytes-utils` 0.8.4 (`BytesLib.sol` declares `Unlicense`) | npm tarball, pinned in `dependencies/lock.json` |

**LZBL-1.2 is not MIT and not an open-source license.** It is the LayerZero Business License 1.2. Its text is reproduced here in full, as its terms require, for every copy of the LZBL-licensed files in this repository. See THIRD_PARTY_NOTICES.md for how those files are used and for the production license-review caveat.

**`@layerzerolabs/oft-evm` and `@layerzerolabs/oapp-evm`:** each source file declares `SPDX-License-Identifier: MIT` and each `package.json` declares `"license": "MIT"`. However, the upstream LayerZero-Labs/devtools repository had no LICENSE file at the pinned commit (GitHub's license API returned none), and the npm tarballs ship none. The MIT text that LayerZero Labs publishes in LayerZero-v2 (`LayerZero-v2-LICENSE-MIT`) is included here as the applicable MIT notice. Whether devtools has its own copyright line has not been verified.
