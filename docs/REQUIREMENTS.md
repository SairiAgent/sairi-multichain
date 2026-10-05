# Requirements

- Preserve canonical SAIRI and liquidity on Base. Expansion is backed, not independent issuance.
- Prototype lock/credit/burn/release with L >= R + P + Q in normalized integer units, authenticated peers, replay prevention and bounded exposure.
- Creator objective: 100 bps of executed gross input, WETH on buys and SAIRI on sells, separate from LP/protocol/router fees. Not a transfer tax.
- Authorized beneficiary remains unset pending verification. Fees never access backing.
- Local configuration, accounting evidence monitor and synthetic liquidity simulations must fail closed or report UNKNOWN/STALE.
- Mainnet integration, fee schedule, audit and deployments are separate gates, not implied by local tests.
