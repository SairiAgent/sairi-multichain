"""Deterministic SYNTHETIC liquidity simulator on the local constant-product harness.

Not real balances, not a price forecast and not concentrated-liquidity (Uniswap v3/v4) math. All
arithmetic is integer; ratios use `fractions.Fraction` and are rendered as decimal strings (never
floats). Every buy (WETH in -> SAIRI out) and sell (SAIRI in -> WETH out) case starts from the same
fresh pool, so cases are independent.

USD prices and amounts are fixed-point integers scaled by 10**USD_DECIMALS.
"""
from fractions import Fraction

from . import UINT256_MAX
from .amm import CREATOR_FEE_BPS, FEE_DENOMINATOR, LP_FEE_BPS, Pool, PoolError
from .strict import format_fraction, format_units

USD_DECIMALS = 18
USD = 10**USD_DECIMALS
PCT_PLACES = 6
USD_PLACES = 6

DEFAULT_TOTAL_LIQUIDITY_USD = 120_000 * USD
DEFAULT_SAIRI_USD = USD // 100  # 0.01, synthetic placeholder - NOT a market price
DEFAULT_WETH_USD = 3_000 * USD  # synthetic placeholder - NOT a market price
DEFAULT_TRADES_USD = (500 * USD, 1_000 * USD, 5_000 * USD, 10_000 * USD)
DIRECTIONS = ("buy", "sell")

NOMINAL_FEE_RATE = Fraction(CREATOR_FEE_BPS, FEE_DENOMINATOR) + Fraction(LP_FEE_BPS, FEE_DENOMINATOR) * (
    1 - Fraction(CREATOR_FEE_BPS, FEE_DENOMINATOR)
)  # 0.01297 before integer flooring


def _pct(fr):
    return format_fraction(fr * 100, PCT_PLACES)


def _usd(fr):
    return format_fraction(fr, USD_PLACES)


def raw_to_usd(raw, decimals, price_usd):
    return Fraction(raw * price_usd, 10**decimals * USD)


def usd_to_raw(usd, decimals, price_usd):
    """floor(usd / price) in raw token units."""
    return usd * 10**decimals // price_usd


def initial_reserves(total_usd, sairi_usd, weth_usd, sairi_decimals, weth_decimals):
    """Half of the synthetic total USD liquidity on each side, floored to raw units."""
    half = total_usd // 2
    return usd_to_raw(half, sairi_decimals, sairi_usd), usd_to_raw(half, weth_decimals, weth_usd)


def _check_params(p):
    for key in ("total_usd", "sairi_usd", "weth_usd"):
        if isinstance(p[key], bool) or not isinstance(p[key], int) or p[key] <= 0:
            raise ValueError(f"{key} must be a positive integer (fixed-point, {USD_DECIMALS} decimals)")
    for key in ("sairi_decimals", "weth_decimals"):
        if isinstance(p[key], bool) or not isinstance(p[key], int) or not 0 <= p[key] <= 18:
            raise ValueError(f"{key} must be an integer in [0, 18]")
    for trade in p["trades_usd"]:
        if isinstance(trade, bool) or not isinstance(trade, int) or trade <= 0:
            raise ValueError("trade sizes must be positive fixed-point integers")


def simulate_case(reserve_sairi, reserve_weth, direction, trade_usd, prices, decimals):
    """One independent exact-input swap from a fresh pool seeded with the given raw reserves."""
    if not isinstance(direction, str) or direction not in DIRECTIONS:
        raise ValueError(f"direction must be one of {DIRECTIONS}, got {direction!r}")
    sairi_usd, weth_usd = prices
    sairi_dec, weth_dec = decimals
    buy = direction == "buy"
    in_asset, out_asset = ("WETH", "SAIRI") if buy else ("SAIRI", "WETH")
    in_dec, out_dec = (weth_dec, sairi_dec) if buy else (sairi_dec, weth_dec)
    in_price, out_price = (weth_usd, sairi_usd) if buy else (sairi_usd, weth_usd)
    case = {"direction": direction, "inputAsset": in_asset, "outputAsset": out_asset,
            "tradeUsd": _usd(Fraction(trade_usd, USD))}

    pool = Pool()
    try:
        pool.add_liquidity(reserve_sairi, reserve_weth, 0, "synthetic-lp")
    except PoolError as err:
        case["error"] = f"seed:{err.code}"
        return case
    zero_for_one = not buy  # token0 = SAIRI, token1 = WETH (Solidity constructor order)
    r_in, r_out = pool.reserves(zero_for_one)
    k_before = pool.reserve0 * pool.reserve1
    gross = usd_to_raw(trade_usd, in_dec, in_price)
    try:
        result = pool.swap_exact_input(zero_for_one, gross, gross, 0)
    except PoolError as err:
        case.update({"grossInputRaw": str(gross), "error": err.code})
        return case

    net = gross - result.creator_fee - result.lp_fee
    spot = Fraction(r_out, r_in)
    input_usd = raw_to_usd(gross, in_dec, in_price)
    output_usd = raw_to_usd(result.output, out_dec, out_price)
    case.update({
        "grossInputRaw": str(gross),
        "grossInput": format_units(gross, in_dec),
        "consumedRaw": str(result.consumed),
        "untouchedRaw": str(result.untouched),
        "creatorFeeAsset": in_asset,
        "creatorFeeRaw": str(result.creator_fee),
        "creatorFee": format_units(result.creator_fee, in_dec),
        "creatorFeeUsd": _usd(raw_to_usd(result.creator_fee, in_dec, in_price)),
        "lpFeeAsset": in_asset,
        "lpFeeRaw": str(result.lp_fee),
        "lpFee": format_units(result.lp_fee, in_dec),
        "lpFeeUsd": _usd(raw_to_usd(result.lp_fee, in_dec, in_price)),
        "protocolFeeRaw": "0",
        "routerFeeRaw": "0",
        "gas": "EXCLUDED",
        "netToCurveRaw": str(net),
        "outputRaw": str(result.output),
        "output": format_units(result.output, out_dec),
        "spotPriceBefore": format_fraction(spot * Fraction(10**in_dec, 10**out_dec), 18),
        "executionPrice": format_fraction(Fraction(result.output * 10**in_dec, gross * 10**out_dec), 18),
        "realizedFeePct": _pct(Fraction(result.creator_fee + result.lp_fee, gross)),
        "priceImpactPct": _pct(1 - Fraction(result.output, 1) / (net * spot)),
        "totalCostPct": _pct(1 - Fraction(result.output, 1) / (gross * spot)),
        "inputUsd": _usd(input_usd),
        "outputUsdAtReference": _usd(output_usd),
        "totalCostUsd": _usd(input_usd - output_usd),
        "reservesAfterRaw": {"SAIRI": str(pool.reserve0), "WETH": str(pool.reserve1)},
        "kNonDecreasing": pool.reserve0 * pool.reserve1 >= k_before,
    })
    return case


def simulate(total_usd=DEFAULT_TOTAL_LIQUIDITY_USD, sairi_usd=DEFAULT_SAIRI_USD, weth_usd=DEFAULT_WETH_USD,
             sairi_decimals=18, weth_decimals=18, trades_usd=DEFAULT_TRADES_USD, reserve_sairi=None,
             reserve_weth=None):
    params = dict(total_usd=total_usd, sairi_usd=sairi_usd, weth_usd=weth_usd, sairi_decimals=sairi_decimals,
                  weth_decimals=weth_decimals, trades_usd=tuple(trades_usd))
    _check_params(params)
    derived = initial_reserves(total_usd, sairi_usd, weth_usd, sairi_decimals, weth_decimals)
    if (reserve_sairi is None) != (reserve_weth is None):
        raise ValueError("explicit reserves need both SAIRI and WETH values")
    explicit = reserve_sairi is not None
    if explicit:
        for name, value in (("reserve_sairi", reserve_sairi), ("reserve_weth", reserve_weth)):
            if type(value) is not int or not 0 < value <= UINT256_MAX:
                raise ValueError(f"{name} must be a positive uint256 raw amount")
    rs, rw = (reserve_sairi, reserve_weth) if explicit else derived
    prices, decimals = (sairi_usd, weth_usd), (sairi_decimals, weth_decimals)
    cases = [simulate_case(rs, rw, d, t, prices, decimals) for d in DIRECTIONS for t in params["trades_usd"]]
    value_sairi = raw_to_usd(rs, sairi_decimals, sairi_usd)
    value_weth = raw_to_usd(rw, weth_decimals, weth_usd)
    return {
        "kind": "SYNTHETIC_SIMULATION_NOT_REAL_BALANCES",
        "model": "local constant-product x*y=k harness; not Uniswap v4, not concentrated liquidity",
        "feeModel": {
            "creatorFeeBps": CREATOR_FEE_BPS,
            "lpFeeBps": LP_FEE_BPS,
            "feeDenominator": FEE_DENOMINATOR,
            "creatorFee": "floor(gross*100/10000), input asset, sent outside the pool",
            "lpFee": "floor((gross-creatorFee)*30/10000), input asset, stays in reserves",
            "output": "floor(reserveOut*net/(reserveIn+net))",
            "nominalTotalFeePct": _pct(NOMINAL_FEE_RATE),
            "protocolFee": "0", "routerFee": "0", "gas": "EXCLUDED", "exactOutput": "UNSUPPORTED",
        },
        "assumptions": {
            "totalLiquidityUsdInput": _usd(Fraction(total_usd, USD)),
            "totalLiquidityUsdInputUsed": not explicit,
            "sairiUsd": format_fraction(Fraction(sairi_usd, USD), USD_DECIMALS),
            "wethUsd": format_fraction(Fraction(weth_usd, USD), USD_DECIMALS),
            "pricesAreSynthetic": True,
            "sairiDecimals": sairi_decimals,
            "wethDecimals": weth_decimals,
            "reserveSource": "explicit" if explicit else "half of total USD liquidity on each side",
            "independentCases": True,
        },
        "initialReservesRaw": {"SAIRI": str(rs), "WETH": str(rw)},
        # Actual synthetic starting valuation of the reserves used, at the configured reference prices.
        "initialValuationUsd": {"SAIRI": _usd(value_sairi), "WETH": _usd(value_weth),
                                "total": _usd(value_sairi + value_weth)},
        "cases": cases,
    }
