# Optional airdrop considerations (NOT PLANNED, NOT IMPLEMENTED)

**EXPERIMENTAL — UNAUDITED — NO MAINNET DEPLOYMENT.** This repository contains no airdrop, no snapshot tooling for live chains, no independent token launch. This note only records constraints any future, separately approved proposal would have to meet.

## Principles

- **Existing funding only.** Any reward budget must come from existing legitimate SAIRI holdings voluntarily authorized for distribution, then be correctly bridged and backed if used on the destination. No new canonical issuance, unbacked mint, treasury movement or liquidity withdrawal is authorized by this note.
- **Backed holdings only.** Eligibility could only be based on legitimately held canonical SAIRI or fully backed representation. A distribution must never mint unbacked representation; any representation must enter supply through an actual lock (`L` increases with `R`).
- **No new token launch.** Distributing existing backed SAIRI is a transfer of already-backed units, not an independent token, migration or promise of value.
- **Redemption never expires.** A claim deadline may end an *unclaimed distribution*; it must not expire, reduce or condition the holder's right to redeem backed representation for canonical SAIRI.

## Snapshot double-count risks

A holder's position can appear in more than one place at once:

| Location | Risk |
|---|---|
| Canonical balance **and** locked in the lockbox | Locked tokens belong to the lockbox; count `R` holders, not the lockbox balance as a holder. |
| In-flight lock (`P`) | Debited on Base, not yet credited on Robinhood Chain: counted on neither side by naive balance reads, or on both if reads span the delivery. |
| In-flight burn (`Q`) | Burned on Robinhood Chain, not yet released on Base: same problem in reverse. |
| Pool reserves / LP shares | Reserves belong to LP share holders pro rata; counting both the pool address and LPs double-counts. |
| Fee collector (`accrued − delivered`) | Belongs to the fixed beneficiary; counting both collector and beneficiary after a claim double-counts. |
| Contracts, exchanges, bridges | Custodial addresses aggregate many owners; policy must be explicit. |

A snapshot would therefore need the same coherence rules as the monitor ([ACCOUNTING](ACCOUNTING.md)): one finalized epoch and delivery-ledger checkpoint across chains, with P and Q attributed exactly once. Unrelated latest-block reads are not a valid snapshot.

## Other risks

Sybil splitting, wash trading into the pool to farm eligibility (creator and LP fees make this costly but not impossible), front-running of a published snapshot block, legal/regulatory review, and the governance risks in [ADMIN](ADMIN.md). None of these has been assessed for production.

## Reproducibility and complex ownership

A future proposal must publish the snapshot algorithm/version, chain IDs, finalized block hashes/numbers, message-ledger cut, normalized units, exclusion rules and hashes of reproducible public inputs. Independent operators should be able to recompute eligibility without private customer records. No production root or distributor is supplied here.

Smart wallets may have owners, modules or account-abstraction rules that differ from an EOA signature; do not assume EOAs are the only legitimate holders. Staking escrows, vesting contracts and LP positions require an explicit look-through policy: attribute beneficial ownership once, while avoiding counting both the escrow/pool balance and the beneficiary/share position. Custodial exchanges need an explicit inclusion/exclusion or verified distribution policy; do not scrape private account information or infer customers from an omnibus address.
