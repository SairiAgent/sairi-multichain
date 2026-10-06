# V4 paired-fee public testnet result

**EXPERIMENTAL — UNAUDITED — NO MAINNET DEPLOYMENT.**

On 2026-10-06 the maintainer deployed an isolated copy of pinned Uniswap v4 core
on Robinhood testnet (46630), attached the existing faucet-backed OFT, and ran
four swaps: exact input and exact output in both directions. This is **not a
canonical DEX deployment, integration, listing, production pool or dollar revenue**.
The paired asset is fixed-supply faucet LABQ, not WETH or a stablecoin.

## Observed result

- Static LP fee: 1%; separate paired-asset hook fee: 0.2%, with mode-specific
  rounding described in [LP rewards](V4_LP_REWARDS.md).
- Hook recipient: `0x26250e47500943464290A77ae3508a3001d9B69d`.
- Hook fees accrued and delivered: **0.007996225405741906 LABQ**.
- Position LP rewards: **0.020131424524456081 TEST** and
  **0.020070878255155671 LABQ**, distinct from hook proceeds and principal.
- Both lab LP recipients equal the operator strictly for faucet recovery;
  distinct-recipient 60/40 allocation is tested locally, not demonstrated by
  two distinct live beneficiaries. Production 40% recipient remains undecided.
- All liquidity removed; driver balances and funding/vault approvals zero.
- Three raw units of each 18-decimal asset remain as core rounding dust.
- This vault is operator-withdrawable, **not permanently locked liquidity**.

Proof transaction:
`0x99bbc91bacadf2fd48eb32f1155ce29091f9e8b445c840896104bc886e78d467`.
Manager: `0x22d6518ee6f80d9d772f56d52b0ea9e08a9aad90`.
Hook: `0x5f2cc0c8b939394dd47df8129712812cb37ce0cc`.
Vault: `0xe48EB27283B38748f9d556081b2604d6A3D24d41`.

Successful receipts, four `SwapProven` events, cumulative LP claim events,
`ProofCompleted`, live bytecode hashes, fixed beneficiary, zero liquidity,
zero allowances and exact hook delivery were independently read back.
Local independent `make check`: 166 Solidity and 158 Python tests passed;
`make demo` and whitespace checks passed. Model review is not an audit.

Full sanitized evidence: [testnet fee proof](evidence/v4-fees-testnet-2026-10-06.json).

## Return and rounding reconciliation

Of the original 100 TEST, **99.999999 TEST returned to Base Sepolia** with
matching successful OFTSent/OFTReceived and endpoint delivery receipts. The
bridge rounds to 1e12 raw units: 999,999,999,997 raw units remain in the
Robinhood operator wallet and 3 raw units remain in core. Together these
are exactly 0.000001 TEST; no replacement tokens were minted to hide dust.

Return source transaction:
`0x77c8a88ceaa9b63e45c79d8b09f175bfab8263a6462936cc67cfe9daf683768d`.
Base destination transaction:
`0x2cb742a47afb9aebda53c4f24abf486d4e17744d4c304d443d60fba75422815a`.
These are mined receipt observations, not a separate economic-solvency or
finality proof. No production SAIRI or mainnet funds moved.
