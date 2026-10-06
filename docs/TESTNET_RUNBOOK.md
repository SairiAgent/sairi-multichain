# Testnet runbook: Base Sepolia → Robinhood Chain testnet → Base Sepolia

**EXPERIMENTAL — UNAUDITED — TESTNET ONLY — NO MAINNET.** This runbook is for the designated maintainer using faucet funds. It moves only a valueless stand-in token (`tSAIRI-TEST`, **not SAIRI**) and testnet ETH for gas and LayerZero fees. Implementation workers do not run broadcast steps; only the designated maintainer/orchestrator may do so under explicit testnet authorization.

## Route (verified read-only on 2026-10-06; see [SOURCES](SOURCES.md))

| | Base Sepolia | Robinhood Chain testnet |
|---|---|---|
| Chain ID | 84532 | 46630 |
| Public RPC | `https://sepolia.base.org` | `https://rpc.testnet.chain.robinhood.com` |
| LayerZero EID | 40245 | 40451 |
| EndpointV2 | `0x6EDCE65403992e310A62460808c4b910D972f10f` | `0x3aCAAf60502791D199a5a5F0B173D78229eBFe32` |
| SendUln302 | `0xC1868e054425D378095A003EcbA3823a5D0135C9` | `0x45841dd1ca50265Da7614fC43A361e526c0e6160` |
| ReceiveUln302 | `0x12523de19dc41c91F7d2093E0CFbB76b17012C8d` | `0xd682ECF100f6F4284138AA925348633B0611Ae21` |
| Executor | `0x8A3D588D9f6AC041476b094f97FF94ec30169d3D` | `0x701f3927871EfcEa1235dB722f9E608aE120d243` |
| Required DVN (LayerZero Labs, 1-of-1) | `0xe1a12515F9AB2764b887bF60B923Ca494EBbB2d6` | `0xa78A78a13074eD93aD447a26Ec57121f29E8feC2` |
| Confirmations (send / receive) | 2 / 1 | 1 / 2 |
| SAIRI app | stand-in token + `SairiOFTAdapter` (lockbox) | `SairiBackedOFT` (backed representation) |

Single source of truth: `config/testnet/base-sepolia-robinhood-testnet.json`, mirrored by `script/testnet/TestnetRoutes.sol` and the Makefile RPC variables (consistency enforced by `tests/test_testnet.py`). A 1-of-1 testnet DVN is acceptable for a testnet exercise only; it is **not** a production security configuration.

## Safety rails

- Scripts and tooling reject every chain except 84532 and 46630 (mainnet IDs are explicitly denied) and re-verify the endpoint, EID, default libraries, DVN, confirmations and executor on-chain before any broadcast. A mismatch stops the run; there is no fallback to another chain, RPC or mock.
- Broadcast targets require `SAIRI_TESTNET_CONFIRM=testnet-only`, `SAIRI_TESTNET_OPERATOR=<address>` and `SIGNER="<Foundry signer flags>"` (an encrypted keystore account or hardware wallet chosen by the maintainer). The repository never stores or reads key material; do not put keys in files, environment files or command history. `SIGNER` values containing `private-key` or `mnemonic` are refused, and broadcast commands are printed with the signer flags redacted.
- `wire()` pins the send/receive libraries, DVN, confirmations and executor explicitly so later LayerZero default changes cannot silently alter the route. Peers can be set once only.
- Before broadcasting, `send` re-checks the app's **effective per-app** route, not just the endpoint defaults. Peer, pinned send/receive libraries, DVN, confirmations, executor, max message size and the **exact** enforced-options bytes (120,000 lzReceive gas, zero value) must all match. Any per-app override by the owner/delegate stops the send, even if the defaults are unchanged (`test/layerzero/TestnetWiringTamper.t.sol`, and the fork test).
- `send` refuses if the LayerZero quote exceeds `MAX_FEE` (wei).
- Enforced `lzReceive` gas is 120,000. Measured locally against genuine EndpointV2 code: about 82,700 (mint to a fresh recipient) and 62,600 (release to a fresh recipient); `test_lzReceiveGas_fitsEnforcedOptionWithMargin` keeps both under 90,000.
- Owners cannot renounce ownership (renouncing while paused would strand redemptions).
- Caps: stand-in supply 1,000,000; exposure cap 1,000,000; outbound rate limit 100,000 per 24 h (18-decimal units). Use small amounts.

## Steps

```sh
make setup && make check                  # offline, must pass first
make testnet-preflight                    # read-only: Python JSON-RPC checks + script preflight on both chains
make testnet-fork-check                   # read-only fork SIMULATION of the whole flow (DVN impersonated)

export SAIRI_TESTNET_CONFIRM=testnet-only SAIRI_TESTNET_OPERATOR=0x...   # faucet-funded testnet address
make testnet-deploy-canonical      SIGNER="..."   # Base Sepolia: token + adapter -> record addresses
make testnet-deploy-representation SIGNER="..."   # Robinhood testnet: backed OFT -> record address
export SAIRI_TESTNET_ADAPTER=0x... SAIRI_TESTNET_BACKED=0x...
make testnet-wire-robinhood SIGNER="..."
make testnet-wire-base      SIGNER="..."
# Leg 1: lock on Base Sepolia, mint on Robinhood testnet (AMOUNT multiple of 1e12)
make testnet-send-base AMOUNT=10000000000000000000 MAX_FEE=1000000000000000 SIGNER="..."
make testnet-message TX=0x<leg-1 source tx hash>   # indexer view only; repeat manually (no background polling)
# Leg 2: burn on Robinhood testnet, release on Base Sepolia
make testnet-send-robinhood AMOUNT=10000000000000000000 MAX_FEE=1000000000000000 SIGNER="..."
make testnet-message TX=0x<leg-2 source tx hash>
# Record addresses in config/testnet/deployments.json, then:
make testnet-status EXPECT=UNKNOWN          # structural wiring checks pass; backing status is always UNKNOWN
```

Broadcast receipts are written under `broadcast/` (git-ignored). Copy only public transaction hashes and contract addresses into the evidence record; never copy local paths, RPC keys or signer details.

## What the read-only tools can and cannot show

- `testnet-status` checks structure: chain IDs, the adapter's token, endpoints, peers and owners. Failures there give `BLOCKED` (exit 1); an all-null record gives `NOT_DEPLOYED` (exit 6). Otherwise it reports `UNKNOWN` (exit 4) together with the raw numbers: `totalLocked`, the observed adapter balance, the representation supply, operator balances, and the block read on each chain. It also reports purely descriptive `balanceRelations` such as `TRACKED_L_EQUALS_OBSERVED_R`. The two reads are unfinalized and taken at unrelated blocks, and in-flight P/Q are not measured (`finalityVerified`, `snapshotSynchronized` and `inFlightLiabilitiesVerified` are all `false`). So no relation, equal or otherwise, means settled, pending, solvent or insolvent. No status exits 0 unless `EXPECT=` names it.
- `testnet-message` reports what the third-party LayerZero Scan indexer says (`INDEXER_REPORTS_DELIVERED`, `proof: false`). It is a pointer to the destination transaction, not evidence by itself.

## Evidence required before claiming a live roundtrip

A live roundtrip is claimed **only** from on-chain transaction evidence:

- both deployment transaction hashes and both wiring transaction sets;
- leg-1 and leg-2 source transaction hashes with their `OFTSent` / `PacketSent` logs;
- for each leg, the **destination execution transaction hash** whose receipt succeeded and contains `PacketDelivered` from the destination EndpointV2 and `OFTReceived` from the SAIRI app for the same GUID and amount;
- the raw `testnet-status` observations, recorded as observations.

Equal balances and an indexer `DELIVERED` status are each insufficient on their own. Record evidence in `docs/STATUS.md` and `docs/SOURCES.md`. Fork simulation, local tests and preflight are **not** live proof.

## Failure handling

- **Ambiguous broadcast or timeout**: inspect the saved Foundry broadcast record, transaction hash, chain receipt and sender nonce before doing anything else. Do not rerun a deploy or send command as a blind retry: it can create another contract or another transfer. Resume only after reconciling what was actually mined.
- **Preflight BLOCKED**: stop. Read `blockers`; LayerZero may have changed defaults or the RPC may be lagging. Do not edit expectations to make it pass without new official evidence.
- **Robinhood RPC "unsupported block number"**: the public RPC occasionally refuses its newest block. Tools read 5 blocks behind head; re-run later. This is not evidence about LayerZero.
- **Message not delivered**: check LayerZero Scan; a paused app, exposure cap or insufficient gas makes the destination `lzReceive` revert and the message stays verified and retryable through `EndpointV2.lzReceive` (permissionless) once fixed. Never redeploy a second adapter for the same token.
- **Status UNKNOWN with `TRACKED_L_LESS_THAN_OBSERVED_R`**: not a proof of insolvency (the reads are unsynchronized), but treat it as a reason to pause both apps and investigate the transaction history before continuing.
- **Release reverts after a token change** (for example a tax enabled after deposit): backing is untouched and the verified message stays retryable; retry once the token behaves exactly again (`test/layerzero/OFTAdapterTokenRisks.t.sol`).

## Live result (2026-10-06)

The earlier isolated-signer funding blocker is superseded. The owner authorized the habitual operator, funded Robinhood testnet, and the maintainer completed the live roundtrip with valueless stand-in tokens. See [TESTNET_RESULT](TESTNET_RESULT.md) for both source/destination execution hashes and evidence. Do not redeploy or replay the completed sends. A new experiment must reconcile existing state first.

## Uniswap

Official Uniswap v4 deployment documentation lists Base Sepolia (PoolManager `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`) and Robinhood Chain **mainnet**, with no Robinhood Chain testnet section. That absence does not prove there is no Uniswap on Robinhood testnet: a canonical Robinhood testnet deployment is **UNVERIFIED**. Contract code exists on Robinhood testnet at the mainnet PoolManager address, but it is undocumented and unverified. This milestone does not create or use any Robinhood testnet pool, and pool integration remains BLOCKED.
