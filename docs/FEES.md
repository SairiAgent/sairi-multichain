# Fees (LOCAL HARNESS)

**EXPERIMENTAL — UNAUDITED — NO MAINNET DEPLOYMENT.** This describes `src/pool/LocalConstantProductPool.sol` and `src/fees/CreatorFeeCollector.sol` as implemented today. It is not an approved production fee schedule, a Uniswap v4 hook, or a statement about any live pool.

## Formula (exact-input swaps only)

All integer arithmetic, Solidity floor division:

```
creatorFee = floor(gross * 100 / 10000)                  # 100 bps of the ACTUAL consumed gross input
lpFee      = floor((gross - creatorFee) * 30 / 10000)     # 30 bps of the remainder
net        = gross - creatorFee - lpFee
output     = floor(reserveOut * net / (reserveIn + net))  # x*y=k on the net amount
reserveIn' = reserveIn + gross - creatorFee               # LP fee stays in the pool
reserveOut'= reserveOut - output
```

- Both fees are charged in the **input asset**: buys (WETH-like in, backed SAIRI out) pay the creator fee in WETH-like; sells (backed SAIRI in, WETH-like out) pay it in backed SAIRI. No fee is taken from the output asset.
- The creator fee leaves the pool for the separate collector; it never becomes LP liquidity. The LP fee stays in reserves, so it accrues to all share holders pro rata.
- Protocol fee: 0. Router fee: 0 (there is no router). Gas is **excluded** from every figure here and in the simulator.

## Delta table for one swap of `gross` input

| Party | Input asset | Output asset |
|---|---|---|
| Trader | `−gross` exactly; any `maxInput − gross` is never pulled (stays with the trader) | `+output` |
| Pool reserves | `+(gross − creatorFee)` (includes `lpFee`) | `−output` |
| Fee collector | `+creatorFee` (`accrued` increases) | 0 |
| Fixed beneficiary | 0 until a claim; then `+(accrued − delivered)` | 0 |
| Protocol / router | 0 | 0 |

Independent worked example (hand-computed, also a unit test): reserves 1,000,000 / 1,000,000 raw, `gross = 10,000`: creatorFee 100, lpFee `floor(9,900 × 0.003) = 29`, net 9,871, output `floor(9,871,000,000 / 1,009,871) = 9,774`; reserves become 1,009,900 / 990,226.

## Total cost

Nominal fee: `1% + 0.3% × 99% = 1.297%` of gross input. **Rounding caveat:** both fees floor, so the realized fee is at most 1.297% and can be lower on small inputs (e.g. 10,000 raw → 129 raw = 1.29%; inputs below 100 raw pay no creator fee; inputs up to 336 raw pay no LP fee).

Exact cost relations used by the simulator, with `spot = reserveOut / reserveIn` before the trade and `realizedFee = (creatorFee + lpFee) / gross = 1 − net/gross`:

```
totalCost   = 1 − output / (gross × spot)
priceImpact = 1 − output / (net × spot)            # curve impact on the net amount, incl. output flooring
totalCost   = 1 − (net / gross) × (1 − priceImpact)
            = 1 − (1 − realizedFee) × (1 − priceImpact)
```

Fee and impact compound multiplicatively; they are **not** an unscaled sum of percentages (the sum overstates cost by `realizedFee × priceImpact`). Larger trades relative to reserves cost more. **All estimates exclude gas**, MEV and any off-pool costs.

## Assets

This is an ERC-20-only harness. There is **no native ETH support and no wrapping/unwrapping**: "WETH-like" is an ERC-20 mock in tests, and users would need to hold the wrapped ERC-20 themselves. No live WETH address is configured (it is `null` in `config/networks/live.json`).

## Partial use, refunds and unsupported modes

- Exact input only. `swapExactInput` pulls exactly `grossInput`; there is no partial fill and no refund transfer, because nothing beyond `grossInput` is ever pulled. Fees are computed on what is consumed, never on `maxInput`.
- `addLiquidity` consumes only the proportional amounts (rounded up < 1 raw unit per asset); the off-ratio excess is never pulled. `minShares` / remove minima protect against reserve changes.
- `swapExactOutput` always reverts `ExactOutputUnsupported`.

## Creator fee custody and claims

- The collector is deployed by the pool constructor; `pool` and `beneficiary` are **immutable**. There is no setter, no owner and no rebinding.
- The beneficiary exists only as a local mock (`config/local/local-mock.json`, test constants). The live beneficiary/treasury is **unknown and `null`**; the validator rejects the live configuration until a value with bound, verified provenance exists.
- `claim(token)` is permissionless, but always pays the fixed beneficiary exactly `accrued − delivered`; the caller receives nothing. Exact-transfer checks revert the whole claim on any token tax.
- The collector holds no LP shares and has no call path into the pool, lockbox or representation: it has **no bridge-collateral authority**. Creator fees in backed SAIRI are ordinary backed tokens already counted in `R`; they do not change observed backing `L`.

## Simulator

`make simulate` (or `python3.12 tools/sairi.py simulate --help`) runs independent buy and sell cases of $500 / $1,000 / $5,000 / $10,000 against a fresh synthetic pool (default $120,000 total liquidity, split half per side at configurable SAIRI/USD and WETH/USD fixed-point prices). With `--reserve-sairi/--reserve-weth` the configured total is reported as unused input, and `initialValuationUsd` gives the actual starting valuation of the supplied reserves at the reference prices. Directions other than buy/sell and non-positive reserves are rejected. The pool code underneath is an arithmetic mirror only (no token, EVM or authorization emulation). It reports the creator fee in the input asset, LP fee, protocol/router fee (0), gas (excluded), output, price impact and total cost as decimal strings computed with integers and exact fractions. The default prices are placeholders, **not market data**, and the model is constant-product, **not concentrated liquidity**. `python3.12 tools/sairi.py quote --reserve-in R --reserve-out R --gross G [--max-input M]` gives the exact integer quote.

Production fees require a separate approval; nothing here implies one.
