# Existing SAIRI — verification gate

The project expands existing SAIRI on Base rather than migrating it or issuing an unrelated supply. Approximately USD 120,000 liquidity is **user-reported, UNVERIFIED**, not necessarily treasury-owned or withdrawable. No Base liquidity has been changed.

Canonical contract identity is **BLOCKED** pending a provenance-backed address, not a ticker search. Until verified, all production address fields remain unset and live validation must fail.

Required on-chain evidence, at pinned finalized blocks:

- Canonical address, decimals, total supply and mint/burn authorities.
- Runtime code, implementation code and proxy/admin/upgrade controls.
- Transfer fees, restrictions, rebasing and ERC-20 return behavior.
- Existing bridge adapters, endpoints/peers and outstanding representation domains.
- Actual launch protocol/version, pools, LP ownership, liquidity rights and fee beneficiaries.

No pool ownership, fee rights or beneficiary is inferred from the token address. No token selected by ticker alone. No fork tests have run; no verified production integration is claimed.
