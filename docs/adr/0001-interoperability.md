# ADR 0001 — conditional OFTAdapter direction; local harness only

Date: 2026-10-05 (updated 2026-10-06). Status: **PROPOSED; testnet implementation exists; production BLOCKED**.

## Decision

Evaluate LayerZero V2 OFTAdapter locking existing Base SAIRI and a single destination OFT representation. Do not deploy another adapter until canonical token identity, existing adapter and mint-domain searches, token compatibility, beneficiary, and actual verifier deployments are independently established. The local prototype is an original accounting/authentication harness, NOT an implementation of LayerZero's verifier network.

Official metadata documents Base EID 30184 and Robinhood EID 30416 with EndpointV2 candidates. Documentation is not bytecode verification. Initial RPC calls returned HTTP403. Subsequent pinned unfinalized code/getter observations succeeded (see SOURCES.md); finalized historical state, full endpoint implementation identity and actual configured DVNs remain UNVERIFIED. See SOURCES.md.

## Options and tradeoffs

- **LayerZero OFTAdapter / OFT:** natural existing-ERC20 lock/mint architecture and mature libraries. Trust includes endpoint code, selected send/receive libraries, configured required/optional DVNs and thresholds, destination finality, executor liveness, peer configuration and owner/delegate keys. Fees are source/destination gas plus executor/DVN quotes, not a fixed number established here. Integration complexity moderate; existing adapters and shared-decimal dust need investigation. OFTAdapter file declares MIT; every transitive dependency must be pinned and license-reviewed before import.
- **Chainlink CCIP:** mature router/token-pool framework, subject to bilateral lane and token-pool support. Trust includes configured CCIP verification and risk-management infrastructure, router/pool administrators and finality. Current Robinhood lane/address support is UNVERIFIED. No invented router or unsupported lane assumption. Costs require official per-lane fee quotes.
- **Custom verification:** rejected for production. A test-only endpoint can exercise failure/replay/in-flight transitions but is not an independent message-verification network.

## Administrative / compromise risks

Peer changes, verifier weakening, proxy upgrades, or administrator compromise can authorize unbacked credits despite local invariants. Production design needs governed changes, delay, emergency policies, monitoring and audited deployment parameters. No administrator should withdraw required collateral. Pausing must not confiscate or expire redemption rights. Library compatibility tests and fork/code verification are still required; local harness tests do not establish production integration.

## Licensing evidence

Read 2026-10-05: https://github.com/LayerZero-Labs/devtools/blob/main/packages/oft-evm/contracts/OFTAdapter.sol (Git blob 733e332113167f1b01ba591d5ec0fe2dd388f097, SPDX MIT), package metadata version 4.0.1.

## Update 2026-10-06 — testnet implementation

The OFTAdapter direction is now implemented for **testnet only** (`src/layerzero/`), on vendored, pinned LayerZero packages (`oft-evm` 4.0.1, `oapp-evm` 0.4.1, protocol/messagelib 3.0.168) and OpenZeppelin 4.9.6. Protocol and messagelib packages are LZBL-1.2; `PacketV1Codec` (LZBL-1.2) is compiled into the OFT bytecode through upstream `OFTCore`, so production use needs a license review. The Base Sepolia ↔ Robinhood testnet route was verified read-only (EIDs 40245/40451, ULN302 libraries, LayerZero Labs DVN, executors, fee quotes). Production status is unchanged: **BLOCKED** on canonical SAIRI identity, existing adapters, DVN selection, licensing, audit and mainnet evidence. CCIP was not re-evaluated.
