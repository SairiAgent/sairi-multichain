> **SUPERSEDED AS DEFAULT:** The accepted direction is [1% LP fees plus a separate 0.2% paired-asset charge](V4_LP_REWARDS.md). This hook and its old lab scripts are retained experimental alternatives, not the launch configuration.

# Robinhood representation: 1% creator swap fee

**EXPERIMENTAL / UNAUDITED / no production deployment.** User-authorized beneficiary:
`0x26250e47500943464290A77ae3508a3001d9B69d`. `SairiCreatorFeeHook` hard-codes this address and 100 bps;
there are no setters, admin functions, upgrade mechanisms, or bridge permissions.

## Scope and the unavoidable limit

A clean ERC20 cannot impose fees on *all swaps* while leaving ordinary transfers, deposits, LP operations,
OTC trades and bridges untaxed. Its transfer callback has no reliable universal way to identify an economic
swap. Arbitrary `token0()` responders are not authenticated pools. Transfer taxes also break exact settlement
assumptions of mainstream concentrated-liquidity venues. This implementation therefore **does not tax transfers**.

The hook charges every swap executed in a v4 pool whose PoolKey contains this hook and the configured backed
representation, regardless of which compliant router submitted it. Other pools remain permissionless and
can bypass the creator fee. A fee-free competing pool cannot be prohibited without changing the token's
transfer/composability guarantees. Fee revenue depends on routing and liquidity, not just minting a token.

| Venue / path | Creator fee coverage | Evidence / limitation |
|---|---|---|
| Uniswap v4 pool carrying this hook | YES, both directions and exact modes | Genuine pinned PoolManager integration locally tested |
| Alternative/aggregator router through that same pool | YES | Different test driver and settlement enforcement tested; named production router not certified |
| Uniswap v4 pool without this hook | NO | Explicit bypass test |
| Uniswap v2/v3 | NO automatic creator fee | Their LP fees do not invoke a v4 hook; no real-core v3 integration claim here |
| UniswapX / 1inch / other aggregator | CONDITIONAL | Only fills touching this hooked pool; internal inventory/OTC fills do not pay this hook |
| Pleiades proprietary AMM | UNVERIFIED / NO asserted support | No audited integration or documented equivalent hook proven |
| Wallet transfers, bridge, liquidity modifications, LP fee collection, donation | NO | Intended; genuine core LP/donation and OFT roundtrip tests |

Uniswap's official [Robinhood announcement](https://blog.uniswap.org/robinhood-chain-is-live) describes
v2/v3/v4/UniswapX support on mainnet. This does not establish a canonical v4 testnet deployment or validate
a particular frontend/aggregator route. **No canonical Robinhood manager address is invented here.**

## Exact fee semantics (different from the old local harness)

Only `afterSwap` is used for accounting. The fee uses actual execution deltas, not requested input or output.
The unspecified asset is the asset that v4 permits an after-swap return delta to change:

* Exact input: output asset, `creatorFee = floor(actualGrossOutput / 100)`;
  trader gets `actualGrossOutput - creatorFee`.
* Exact output: input asset, `creatorFee = floor(actualPoolInput / 99)`;
  trader pays `actualPoolInput + creatorFee`. This satisfies
  `creatorFee == floor(traderGrossInput / 100)`.
* Fees include no extra markup on unspent input/unfilled output, even when a price limit causes partial fill.
* Pool LP fee is separate and already reflected in the underlying manager's delta. Test pools use 3000
  hundredths-of-a-bip = 0.3% LP fee, **not** a new production LP fee decision.
* Exact-input buy charges backed SAIRI; exact-input sell charges quote. Exact-output buy charges quote;
  exact-output sell charges backed SAIRI. Thus not all revenue is ETH. Native ETH pairs are supported and tested.
* Floor rounding deliberately gives zero below 100 output raw units or 99 pre-fee input raw units. Splitting
  into tiny trades can reduce raw-unit rounding fees; no cross-trade debt or hidden minimum tax is introduced.
* Multi-hop routes pay this fee on each traversed hooked pool, not once per whole route. Routes that revisit
  pools can pay repeatedly. Actual named multi-hop aggregator integration remains unverified.

Example: exact-input execution yielding 10,000 output raw charges 100 and returns 9,900.
Exact-output execution costing 9,900 input raw charges an additional 100, total 10,000.
The old `LocalConstantProductPool` charges 1% gross **input** for exact input only; that is a different local
harness and remains unchanged. No assertion that these two fee bases are identical is made.

## Claims and accounting

During swap callbacks, fees become internal ERC6909 claims against the manager. There is no external token
transfer and no arbitrary-router callback from the hook during swaps. This avoids adding a token callback to
the hot swap path. Anyone may call `claim(asset)`; it always pays the hard-coded beneficiary. The hook burns
its manager claim and takes the underlying asset. Recipient credit **and manager debit** must both exactly
match; taxed tokens revert atomically. Failed claims preserve balances and can be retried. Reentrant claims
are rejected. Direct unsolicited token transfers to the hook are not claim balances and have no rescue path.

Configured representation and manager must contain code; callbacks only accept that manager. PoolKey must
identify this hook and include that representation. Hook CREATE2 address flags are validated in constructor
(beforeInitialize, afterSwap, afterSwapReturnsDelta only). No probing or trusting arbitrary token0 metadata.
A genuine/authenticated manager must be selected by the deployer; code-length checks alone do NOT authenticate
an arbitrary address as Uniswap. Likewise selecting the correct representation is an operator responsibility.

`L = R + P + Q` remains unchanged: creator fees in representation tokens are part of ordinary outstanding R,
including those held by the manager or beneficiary. Fees never grant collateral withdrawal authority. Existing
OFT contracts, one-peer route and deployments are untouched. The local integration proves source lock →
delivery → actual v4 swap → fee claim → fee token return burn → unlock, with in-flight checks at each end.

## Evidence and remaining risks

Tests use unmodified npm-pinned `@uniswap/v4-core@1.0.2` PoolManager bytecode (solc **0.8.26**), not a mock
AMM arithmetic mirror. Original contracts compile with exact solc **0.8.30**. `forge build` must run before
filtered tests because the upstream manager artifact is a separate compiler graph. Read access is restricted
to that one build artifact. Dependency tarballs, file hashes and full licenses are pinned.

Tests cover both buy/sell exact modes, partial exact input/output, fee basis fuzzing, native claims, alternate
router, unsettled malicious-router rollback, unrelated pools, spoofed callbacks, unhooked bypass, dust,
double-claim rejection, transfer-tax settlement rejection, late-enabled recipient/sender-tax claim rejection,
reentrant quote-token claim attempts, LP add/remove/fee collection/donation exemption, and genuine OFT fee
redemption conservation. No live mainnet evidence; a self-deployed testnet lab is not canonical DEX adoption.

Remaining work before production: independent security audit, authenticate canonical manager/bytecode and
representation, routing/UI support and slippage limits, liquidity ownership/budget, named aggregator end-to-end
proofs, supported quote-token review, chain operational risks. A malicious/rebasing paired token is not made
safe by this hook. Recipient/manager balance checks cannot validate dishonest `balanceOf`. Standard exact-transfer
assets only. No generic v3 transfer-tax support has been engineered or claimed.

## Testnet-only lab deployment (maintainer only)

`script/testnet/SairiV4Lab.s.sol` deploys a fresh real-core lab manager + CREATE2 factory + hook on chain **46630
only**, with explicit `SAIRI_TESTNET_CONFIRM=testnet-only` and `SAIRI_TESTNET_OPERATOR`. It accepts an existing
faucet-funded stand-in representation address and does not change/create any bridge. It initializes no pools,
mints no tokens, and sends no cross-chain messages. It is an unaudited lab, not a public swap product.

1. `make check && make demo` and independent diff review.
2. `forge script script/testnet/SairiV4Lab.s.sol:SairiV4Lab --sig 'deployLab(address)' <EXISTING_TESTNET_OFT> --rpc-url https://rpc.testnet.chain.robinhood.com`
3. Verify printed/returned manager, factory, hook, beneficiary, address permission bits and chain ID. The script
   mines a CREATE2 salt using a read-only factory call (not an on-chain mining transaction).
4. Only the authorized maintainer may add `--broadcast --slow` and existing encrypted-keystore/hardware-wallet
   signing flags after reviewing the simulation. Never raw private-key flags. No worker handled keys.
5. For subsequent lab swap proof, use a separately reviewed test-only driver and faucet-only quote token;
   initialize a labelled lab pool; seed bounded liquidity; execute both directions/modes; claim and capture receipts.
   `test/v4/V4FeeIntegration.t.sol:V4Driver` is a deliberately bare **test driver**, not a production router:
   it has no user slippage/deadline checks and native prefunding is lab-only. Do not expose it to real users.

Never substitute a lab manager for canonical Uniswap in marketing or monitoring. No new adapter or OFT is
required for this hook; do not repurpose one-peered original routes or duplicate canonical adapters.

### Local check result (2026-10-06)

On the isolated feature worktree based on `a63e2368af09b4389e55ea2b4965617459b71e45`:
`make check` passed **133 Solidity tests** (including **23 new v4/bridge/guard tests**), **158 Python tests**,
three repeated invariant/fuzz suites, configuration/monitor checks, exact dependency verification and the
publication guard. `make demo` and `git diff --check` passed. Dependency tree:135 files/7 npm packages.
These counts are local execution evidence only. No keys, broadcasts, deploys, commits or pushes were performed
by the implementation worker. No claim that the v4 lab is deployed on a public testnet follows from these checks.
