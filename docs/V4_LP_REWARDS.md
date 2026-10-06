# Base-like LP incentives — accepted direction

**EXPERIMENTAL, UNAUDITED, TESTNET ONLY.** The default engineering direction is a
**1% static pool LP fee plus a separate 0.2% paired-asset hook fee** paid to
`0x26250e47500943464290A77ae3508a3001d9B69d`, following the latest user override.
The ERC20 remains clean, with no transfer tax. This is not a literal clone of Base. No production deployment, recipient allocation or liquidity-lock policy
is established here.

## Verified Base reference and deliberate differences

Base's observed Clanker pool has a 1% LP rate plus a separate 0.2% protocol hook
charge on the paired asset. Combined cost is approximately 1.2%, with direction,
mode, impact and rounding affecting the exact result. The recorded LP position's
rewards split 60% to `0x26250e47500943464290A77ae3508a3001d9B69d` and 40% to
`0xF60633D02690e2A15A54AB919925F3d038Df163e`; the latter's identity is unknown.
The habitual wallet receives both assets, while the 40% recipient's preference
converts its SAIRI rewards to the paired asset. This is not a split of all pool
volume or protocol revenue. Other active liquidity earns its own fees.

The inspected Base locker exposes no principal-removal or NFT-withdrawal method.
In contrast **this experimental vault explicitly permits its operator to withdraw
principal**. It is not a liquidity lock. No lock duration, vesting, or promise of
permanent liquidity is implied. A production custody/lock decision remains open.

## Vault accounting and authority

`src/v4/SairiV4LpVault.sol` owns one fixed-range position with immutable pool,
operator and recipients. It accepts only an ordered ERC20 pair, static fee 10000
(parts per million), and an explicitly supplied immutable pool hook (or none).
The selected default hook is `SairiPairedFeeHook`; callers must verify the selected
hook code and manager independently, as the generic vault is not a hook whitelist. It never changes token transfers or bridge
backing. Native currency, taxed/rebasing tokens and arbitrary rescue operations
are unsupported. Accidentally transferred tokens have no rescue path.

- Only the operator may add/remove principal, with deadline and principal-only
  spend/minimum-receipt limits. Price movement and impermanent loss still apply.
- Permissionless `harvest()` and `claim(asset)` distribute only that position's
  earned rewards, not principal or direct token donations to the vault.
- Real core `modifyLiquidity` returns fees separately from the aggregate delta;
  principal is their difference. Rewards become manager ERC6909 claims.
- Cumulative paid totals allocate floor(earned * 60 / 100) to the first recipient
  and the remainder to the second, avoiding repeated-claim rounding exploits.
- Both recipients receive both assets in kind. There is no conversion service.
  The 60/40 implementation is a testable candidate, **not a selected production
  allocation**; the unidentified Base 40% address is not silently copied.
- The vault cannot stop other LPs, pools, routers or DEXs from operating. Its
  reward entitlement is only its active liquidity's share of fee growth.
- Core donations intentionally increase fee growth and are LP rewards; direct
  ERC20 donations to the vault do not. Neither is bridge collateral issuance.
- The general vault does not control a manager's protocol-fee authority. A real
  deployment must check manager governance/fee settings separately. The isolated
  lab manager below has zero owner and zero controller, so protocol fees cannot
  be enabled there. No guarantee about canonical Uniswap governance is implied.

## Separate paired-asset fee

`SairiPairedFeeHook` charges only pools selecting this hook and containing the
representation. It enforces static LP fee 10000 (1%). The paired asset is always
the other currency; SAIRI representations are never the creator-fee asset.
Wallet transfers, liquidity changes and bridge transfers are not taxed.

The immutable hook beneficiary is the habitual wallet above. Anyone can claim;
claims cannot be redirected. Credits are minted as manager ERC6909 balances,
separate from LP-position rewards and bridge backing. Claim settlement checks
exact transfers; taxed/rebasing assets are unsupported. There is no fee setter,
recipient setter, upgrade or rescue authority. Unhooked pools bypass this fee.
The old 1%-creator-fee hook is not this default.

All arithmetic uses raw token units and floors:

- Paired input, exact input: reserve `floor(grossInput * 2 / 1002)` before core
  execution; the remaining input includes the ordinary 1% LP fee.
- Paired output, exact output: reserve `floor(netOutput * 2 / 998)` and request
  `netOutput + reservedFee` from core, preserving the requested trader output.
- Paired output, exact input: take `floor(actualCoreOutput * 2 / 1000)`.
- Paired input, exact output: add `floor(actualCoreInput * 2 / 1000)`.

For the first two modes **partial fills revert atomically**, including all fee
credits: an upfront specified-asset fee is never retained on an unfilled amount.
For the other two modes partial fills are supported and fees use only actual core
deltas. Routers must account for these constraints, max-input/min-output limits
and integer rounding. Tiny amounts can pay zero hook fees. This is a documented
Base-like schedule, not a claim of identical Clanker implementation or rounding.
The nominal combined rate is approximately 1.2%, not universally exactly 1.2%.
Price impact and gas are additional. Only the 0.2% hook proceeds are dedicated to
the habitual wallet; its separate LP entitlement depends on the chosen position
allocation and active liquidity. Manager protocol governance must be checked too.

## Bounded real-core public testnet proof

This is **self-deployed vendored Uniswap v4 core**, not the official Robinhood DEX,
not an integration claim, and not production liquidity. The existing test-backed
OFT representation is attached; no new bridge or representation is deployed.
The quote is a fixed-supply faucet-only LABQ token, not WETH or a stablecoin.

After independent review, a designated maintainer may simulate then broadcast:

```sh
export SAIRI_TESTNET_CONFIRM=testnet-only
export SAIRI_TESTNET_OPERATOR=<faucet-operator-address>
forge script script/testnet/SairiV4LpProof.s.sol:SairiV4LpProof \
  --sig 'deployLab(address)' <existing-testnet-representation> \
  --rpc-url https://rpc.testnet.chain.robinhood.com
forge script script/testnet/SairiV4LpProof.s.sol:SairiV4LpProof \
  --sig 'prove(address,address,address)' <lab-manager-from-receipt> <existing-testnet-representation> <hook-from-receipt> \
  --rpc-url https://rpc.testnet.chain.robinhood.com
```

These commands are simulations. Authorized broadcast adds `--broadcast --slow`
and encrypted-keystore or hardware signer flags, never raw keys. Every entrypoint
requires chain 46630, explicit acknowledgement and nonzero operator. The proof
driver additionally requires the habitual beneficiary as operator so hook claims
can be reconciled into faucet recovery. `deployLab` also deploys a paired-hook
factory and mines its CREATE2 salt locally, never in a signed transaction. Verify actual
transaction receipts, emitted events, balances and bytecode before calling it a
public proof. Script logs alone do not establish settlement.

The driver funds exactly 40 tokens per asset, creates 1000e18 liquidity in ticks
[-600,600], executes exact-in and exact-out in both directions (1e18 specified),
harvests/claims both LP rewards and the separate paired-hook fees, removes all
liquidity, claims LP rewards again and refunds its balances.
Both lab recipient addresses equal the operator solely for faucet recovery. This
does **not** demonstrate a selected live 60/40 allocation; distinct-recipient unit
tests verify that distribution separately. Vault approvals are revoked and
funding approvals consumed. Supply cannot change during the proof.

`ProofCompleted` reports exact raw-unit loss per asset, bounded at 20 raw units;
core add/remove/feeGrowth rounding can retain dust even after complete liquidity
withdrawal. Never report a 100-token return unless observed balances support it.
The OFT bridge's 1e12 raw-unit granularity is coarser: bridge only the floor-rounded
available balance, and report both residual wallet dust and manager dust. Do not
mint substitutes or conceal a shortfall. A failed atomic proof is retryable; a
completed proof cannot be rerun. Script-level deployments and approvals are
separate transactions and must also be reconciled if a later transaction fails.

## Verification

`forge test --match-path 'test/v4/*'` exercises actual vendored core. Vault tests
cover principal/fee separation, permissions, deadlines, minimums, multi-LP accrual,
all swap modes, partial fills, donation distinction, cumulative rounding,
reentrancy, taxed-token claim rollback/retry and settlement rollback. Lab tests
cover four modes, exact dust reconciliation, supply, cleanup, authorization,
chain gate and retry after funding failure. Run `make check` and `make demo` too.

The prior [creator hook](V4_CREATOR_FEES.md) and local [constant-product
harness](FEES.md) remain experimental alternatives, **superseded as defaults**.
They must not be described as the accepted fee configuration.
