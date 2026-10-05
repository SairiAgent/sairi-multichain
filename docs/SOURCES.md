# Sources and evidence ledger

Retrieved **2026-10-05 UTC**. Status vocabulary: VERIFIED (specify scope), UNVERIFIED, UNSUPPORTED, BLOCKED. Documentary facts do not equal verified code or working integrations. **No live/fork integration tests ran. Initial documentary records have no pinned blocks; later read-only RPC observations are recorded separately below.**

## Robinhood Chain

- https://docs.robinhood.com/chain/ and https://docs.robinhood.com/chain/connecting — VERIFIED documentary statement: mainnet live, chain 4663; testnet 46630; ETH gas. Mainnet RPC `https://rpc.mainnet.chain.robinhood.com`, testnet RPC `https://rpc.testnet.chain.robinhood.com`; explorers `https://robinhoodchain.blockscout.com`, `https://explorer.testnet.chain.robinhood.com`.
- https://docs.robinhood.com/chain/contracts and https://docs.robinhood.com/chain/protocol-contracts — documented WETH mainnet candidate `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`, testnet candidate `0x7943e237c7F95DA44E0301572D358911207852Fa`. **UNVERIFIED** runtime bytecode, implementation, decimals and pinned block. These are research candidates, NOT validated deployment parameters.
- https://docs.robinhood.com/chain/cross-chain-messaging — documents Ethereum/Robinhood native Arbitrum messaging and seven-day L2-to-L1 challenge period; does not establish a direct Base token route.

Read-only `eth_chainId` / `eth_blockNumber` requests to both official Robinhood RPCs and `https://mainnet.base.org` returned HTTP 403 in this environment. Robinhood WETH Blockscout `/api/v2/smart-contracts/<address>` read also returned HTTP 403. These initial failures were not evidence of absent deployments. Subsequent read-only calls succeeded with explicit JSON headers and a documented public Base provider; see the later pinned observations below. Full integration verification remains blocked.

## LayerZero

Sources: https://metadata.layerzero-api.com/v1/metadata ; https://docs.layerzero.network/v2/deployments/chains/robinhood ; https://docs.layerzero.network/v2/deployments/chains/base ; https://docs.layerzero.network/v2/developers/evm/oft/quickstart . Metadata independently read by orchestrator.

- Base: native chain 8453, EID 30184; EndpointV2 candidate `0x1a44076050125825900e736c501f859c50fe728c`; SendUln302 `0xb5320b0b3a13cc860893e2bd79fcd7e13484dda2`; ReceiveUln302 `0xc70ab6f32772f59fbfc23889caf4ba3376c84baf`.
- Robinhood: native chain 4663, EID 30416; EndpointV2 candidate `0x6f475642a6e85809b1c36fa62763669b1b48dd5b`; SendUln302 `0xc39161c743d0307eb9bcc9fef03eeb9dc4802de7`; ReceiveUln302 `0xe1844c5d63a9543023008d332bd3d2e6f1fe1043`; Executor `0x4208d6e27538189bb48e603d6123a94b8abe0a0b`.
- Metadata lists Robinhood LayerZero Labs DVN `0xd01ae6905d48315f7be10c7330aecf8360ef5b12` and Nethermind DVN `0x0ffe02df012299a370d5dd69298a5826eacafdf8`. Selected DVNs, thresholds, confirmations, route configuration, libraries and peer wiring remain **UNVERIFIED**.
- Initial documentary candidates have `blockNumber: null`, `bytecodeVerified: false`; later pinned observations are separate evidence, not an approved deployment configuration. No imported LayerZero dependency or tested official endpoint integration yet.
- OFTAdapter source SPDX MIT, Git blob `733e332113167f1b01ba591d5ec0fe2dd388f097`: https://github.com/LayerZero-Labs/devtools/blob/main/packages/oft-evm/contracts/OFTAdapter.sol . Upstream explicitly warns only one default adapter in a mesh and assumes lossless transfers. Package metadata observed 4.0.1, not an imported dependency pin.

## DEX economics and licenses

- https://docs.bankr.bot/token-launching/overview/ — current documented Doppler schedule: creator cash 95% of 0.7% = **0.665%**, locked LP 0.285%, Bankr 0.475%, BNKR buyback 0.2375%, Doppler approximately 0.0875%, all-in 1.75%. Creator-side 0.95% includes locked LP, not 1% delivered cash. Standard launch creates a new supply; Robinhood launch support does not prove acceptance of existing backed tokens. Historical launches may have different schedules. **UNSUPPORTED for this project's exact 100-bps objective without a separately verified integration.**
- https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting and https://docs.uniswap.org/contracts/v4/deployments returned HTTP 403 here. Official GitHub files readable: https://github.com/Uniswap/v4-core/blob/main/src/PoolManager.sol , https://github.com/Uniswap/v4-core/blob/main/licenses/BUSL_LICENSE . PoolManager Git blob `e282995135c2aac1a09638df7e0ca16be22561e5`, compiler 0.8.26, BUSL-1.1. Nonproduction use permitted; change date earlier of 2027-06-15 or ENS-defined date, then MIT. No core files imported. Production license/deployment compatibility **UNVERIFIED**.
- CCIP official directory access returned HTTP 403; Robinhood bilateral lane support **UNVERIFIED**, not classified unsupported.

## Canonical SAIRI

Token identity, decimals, supply, authority, proxy, restrictions, launch version, adapters, pools, LP ownership, beneficiary and fee rights are **UNVERIFIED**. Canonical address and treasury remain null. No ticker inference. User-reported approximately USD120,000 liquidity is not an observed or treasury-owned balance.

## Tooling pin provenance

GitHub API tag refs retrieved 2026-10-05: actions/checkout v4 `11d5960a326750d5838078e36cf38b85af677262`; actions/setup-python v5 `a26af69be951a213d495a4c3e4e4022e16d87065`; foundry-rs/foundry-toolchain v1 `908c540300062bd5a7e473851cdb4282204cee09`. Foundry runtime pinned v1.5.1; Python 3.12.8; Solidity compiler pinned in foundry.toml. No credentials required for local suites.

## Later read-only RPC evidence (2026-10-05 02:22 UTC)

RPC reads now succeeded through `https://base-rpc.publicnode.com` (listed in official LayerZero metadata) and `https://rpc.mainnet.chain.robinhood.com`. Chain ID responses were 8453 and 4663. These facts supersede any inference that RPC access is universally unavailable. No transaction was signed or sent.

Pinned **unfinalized** observations (not a synchronized cross-chain snapshot):

- Base block **52188794**, hash `0xbf04239f39ff734d873a9248deefb5e09143b324cf99fefbc82f4bdb718c97ba`: Endpoint candidate runtime 24,005 bytes; Keccak `0x086c2e9e37f5bdaf45013882cf40f7a43b35c879302ff1ad4a4010d09b4d7237`; `eid()` = 30184. EIP1967 implementation slot zero (not proof of absence of every proxy design).
- Robinhood block **80430444**, hash `0xd519abd68a69fc2f451b9d72524a927e30475046584c3cadfb87740dd261bf55`: Endpoint candidate runtime 24,005 bytes; Keccak `0xcfbbc5787620fd3bc7117ecad89067b17fa445b3e6b7afd724e3a347a9d67763`; `eid()` = 30416. Full endpoint source identity / verification configuration remains UNVERIFIED.
- At that Robinhood block, WETH candidate runtime 2,202 bytes; Keccak `0x5706be52f64875fee65a2cec0d80e47a23d8793cbe85d214b48445e2d05f5353`; `decimals()` = 18. EIP1967 implementation **0xc6b81b429797e0f555440b70cd99e032d7ae947e**, runtime 6,961 bytes; Keccak `0xbe1295f37be34ffe03ad779bda0ef278907e1856b51a3be2f35ee541d75d4650`.

Sourcify proxy source record: https://sourcify.dev/server/v2/contract/4663/0x0bd7d308f8e1639fab988df18a8011f41eacad73?fields=all — `TransparentUpgradeableProxy`, compiler 0.8.16, runtime `exact_match`; on-chain and recompiled hashes match the pinned RPC code. Implementation record: https://sourcify.dev/server/v2/contract/4663/0xc6b81b429797e0f555440b70cd99e032d7ae947e?fields=all — **aeWETH**, runtime `match` with CBOR metadata replacement (not `exact_match`), observed source on-chain hash matches the pinned implementation. Source files include Apache-2.0 and MIT; none were imported.

WETH proxy admin slot was **0xa3acd31afb851b4eb9dad00f5204c01d924267df**; its `owner()` returned **0x2a153c6a1b66dbc930a8d7017230ab0253005c09**. These are read-only observations, NOT changes to authorities. Owner/governance provenance, current safe upgrade controls and integration suitability remain UNVERIFIED. A WETH label does not imply an immutable WETH9 implementation.

Requests for finalized historical state failed (HTTP403 or `historical state ... is not available`); later pinned reads used recent unfinalized blocks. No fork integration tests ran. Complete typed research record: `config/research/rpc-observations.json`. Production addresses remain null until full provenance/finality/deployment gates are satisfied.
