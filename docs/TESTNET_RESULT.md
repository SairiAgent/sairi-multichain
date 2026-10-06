# Live testnet roundtrip — 2026-10-06

**EXPERIMENTAL, UNAUDITED, TESTNET ONLY. No real SAIRI or mainnet assets moved.**

Using the owner-authorized habitual operator and faucet funds, the maintainer deployed the existing reviewed contracts, pinned both routes, and completed an actual 10-token roundtrip. This supersedes the earlier isolated-signer funding blocker. The test token is a valueless stand-in, not SAIRI.

## Evidence

### Base Sepolia → Robinhood testnet

- Source: [0x13e4a23de418267119d8217c10f3378c3bd85d341936c565dd391521a697aca4](https://sepolia.basescan.org/tx/0x13e4a23de418267119d8217c10f3378c3bd85d341936c565dd391521a697aca4)
- Destination execution: [0x75ac20296ea58abce54a252211285594a9d1bd63b2e109100d0add67012ddf57](https://explorer.testnet.chain.robinhood.com/tx/0x75ac20296ea58abce54a252211285594a9d1bd63b2e109100d0add67012ddf57)
- GUID: `0xc070e8fddaf0e5b3d6f0643704d906b5536d0966081607ec97923b4b764d5212`; nonce 1; amount 10 × 10^18 units.

### Robinhood testnet → Base Sepolia

- Source: [0x466871ffc06cbb64d1e04f56068681b7d699d496bdc2f60540cc4ee9ee49c4bd](https://explorer.testnet.chain.robinhood.com/tx/0x466871ffc06cbb64d1e04f56068681b7d699d496bdc2f60540cc4ee9ee49c4bd)
- Destination execution: [0xc1fc3ad7fb357f07b9598c4633c6a444f043060bb2d6cb47c675efef7e5458dc](https://sepolia.basescan.org/tx/0xc1fc3ad7fb357f07b9598c4633c6a444f043060bb2d6cb47c675efef7e5458dc)
- GUID: `0x325509a96d9b90567c1cc297e4bb569198b7933df4f0d3800f563f35b7c28b6c`; nonce 1; amount 10 × 10^18 units.

Both source receipts succeeded and contain OFTSent from the expected app and PacketSent from its endpoint. Both destination receipts succeeded and contain matching OFTReceived and PacketDelivered from the expected app/endpoint. Checks matched GUID, amount, recipient, source/destination EIDs, source peer and packet nonce. This was not DVN impersonation or an indexer-only conclusion.

Deployment and six wiring receipts per chain also succeeded. The machine-readable [evidence](evidence/testnet-roundtrip-2026-10-06.json) contains deployment addresses, transaction hashes, source/destination delivery receipts and observations.

## Observations and limits

After the return, the reader observed zero tracked locked tokens, zero adapter token balance, zero representation supply, zero operator representation balance, and the original 1,000,000 stand-in tokens back with the operator. Those are unrelated, unfinalized per-chain snapshots; the tool correctly continues reporting UNKNOWN. The roundtrip claim rests on delivery receipts/events, not balance equality. No general solvency or economic-finality conclusion is claimed.

`make setup`, `make check`, route preflight and effective per-app send checks passed. The existing offline suite passed; no production safety claim follows. The Robinhood RPC intermittently rejected its newest block during simulation, before broadcast. A prior supported fork block was used for Robinhood wiring/send simulation; no duplicate broadcast was performed. Base's public RPC also limits eth_getLogs to 500-block ranges; receipt lookup used a bounded range.

Remaining: canonical Uniswap deployment on Robinhood testnet is still unverified, no pool integration is claimed, production DVN/security/governance selection and independent audit remain necessary. Preserve the reversible Base-canonical design; this run does not authorize migration or mainnet.
