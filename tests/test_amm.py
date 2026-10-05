import copy
import dataclasses
import re
import unittest
from fractions import Fraction

import _support
from sairi_tools import UINT256_MAX, amm
from sairi_tools.amm import Pool, PoolError, quote_exact_input


def seeded(r0, r1):
    pool = Pool()
    pool.add_liquidity(r0, r1, 0, "LP")
    return pool


class SolidityParityTest(unittest.TestCase):
    def test_constants_match_solidity_source(self):
        src = (_support.ROOT / "src" / "pool" / "LocalConstantProductPool.sol").read_text()

        def const(name):
            return int(re.search(rf"{name}\s*=\s*([\d_]+);", src).group(1).replace("_", ""))

        self.assertEqual(const("FEE_DENOMINATOR"), amm.FEE_DENOMINATOR)
        self.assertEqual(const("CREATOR_FEE_BPS"), amm.CREATOR_FEE_BPS)
        self.assertEqual(const("LP_FEE_BPS"), amm.LP_FEE_BPS)
        self.assertEqual(const("MINIMUM_LIQUIDITY"), amm.MINIMUM_LIQUIDITY)


class FeeMathTest(unittest.TestCase):
    """Expected values below were computed by hand, independently of the implementation."""

    def test_rounding_matches_solidity_test_vectors(self):
        q = quote_exact_input(12_345, 100 * 10**18, 10**24)
        self.assertEqual((q.creator_fee, q.lp_fee), (123, 36))  # floor(12345/100), floor(12222*30/10000)
        q = quote_exact_input(99, 100 * 10**18, 10**24)
        self.assertEqual((q.creator_fee, q.lp_fee, q.net), (0, 0, 99))

    def test_known_outputs_small_pool(self):
        # gross 10_000: creator 100, lp floor(9900*0.003)=29, net 9871, out floor(9871e6/1009871)=9774
        q = quote_exact_input(10_000, 1_000_000, 1_000_000)
        self.assertEqual((q.creator_fee, q.lp_fee, q.net, q.output), (100, 29, 9_871, 9_774))
        # gross 1_000: creator 10, lp floor(2.97)=2, net 988, out floor(988e6/1000988)=987
        q = quote_exact_input(1_000, 1_000_000, 1_000_000)
        self.assertEqual((q.creator_fee, q.lp_fee, q.net, q.output), (10, 2, 988, 987))

    def test_integration_test_fee_amounts(self):
        # LocalHarnessFlow: 2e18 WETH-like in, 3_000e12 bSAIRI in -> 1% creator fees asserted there.
        self.assertEqual(quote_exact_input(2 * 10**18, 50 * 10**18, 500_000 * 10**12).creator_fee, 2 * 10**16)
        self.assertEqual(quote_exact_input(3_000 * 10**12, 500_000 * 10**12, 50 * 10**18).creator_fee, 3 * 10**13)

    def test_buy_fee_math_vector(self):
        # PoolAndFees.test_buy_feeMath: 10e18 in, reserves 100e18 / 1_000_000e18.
        q = quote_exact_input(10 * 10**18, 100 * 10**18, 10**24)
        self.assertEqual(q.creator_fee, 10**17)
        self.assertEqual(q.lp_fee, 297 * 10**14)  # floor(9.9e18 * 30 / 10000)
        self.assertEqual(q.net, 98_703 * 10**14)
        self.assertEqual(q.output, 10**24 * 98_703 // 1_098_703)

    def test_effective_fee_rate_rounding_caveat(self):
        q = quote_exact_input(10_000, 10**9, 10**9)
        self.assertEqual(Fraction(q.creator_fee + q.lp_fee, 10_000), Fraction(129, 10_000))  # 1.29%, floored
        q = quote_exact_input(1_000_000, 10**12, 10**12)
        self.assertEqual(Fraction(q.creator_fee + q.lp_fee, 1_000_000), Fraction(1_297, 100_000))  # 1.297%

    def test_creator_fee_is_one_percent_floor_for_range(self):
        for gross in list(range(0, 2_000)) + [10**18 + 7, 3_333 * 10**18 + 5]:
            q = quote_exact_input(gross, 10**30, 10**30)
            self.assertEqual(q.creator_fee, gross // 100)
            self.assertEqual(q.lp_fee, (gross - gross // 100) * 3 // 1000)
            self.assertEqual(q.creator_fee + q.lp_fee + q.net, gross)


class SwapStateTest(unittest.TestCase):
    def test_creator_outside_pool_lp_fee_stays(self):
        pool = seeded(10**24, 100 * 10**18)
        k0 = pool.reserve0 * pool.reserve1
        r = pool.swap_exact_input(False, 10 * 10**18, 10 * 10**18, 1)  # WETH in (buy)
        self.assertEqual(pool.reserve1, 100 * 10**18 + 10 * 10**18 - r.creator_fee)
        self.assertEqual(pool.reserve0, 10**24 - r.output)
        self.assertEqual(pool.accrued, [0, r.creator_fee])
        self.assertGreaterEqual(pool.reserve0 * pool.reserve1, k0)

    def test_partial_maximum_untouched(self):
        pool = seeded(10**12, 10**12)
        r = pool.swap_exact_input(True, 600_000, 1_000_000, 0)
        self.assertEqual((r.consumed, r.untouched, r.creator_fee), (600_000, 400_000, 6_000))
        with self.assertRaises(PoolError) as ctx:
            pool.swap_exact_input(True, 1_000_001, 1_000_000, 0)
        self.assertEqual(ctx.exception.code, "MaxInputExceeded")

    def test_reverts(self):
        pool = seeded(1_000_000, 1_000_000)
        cases = [
            ((True, 0, 0, 0), "ZeroInput"),
            ((True, 1, 1, 0), "ZeroOutput"),  # creator 0, lp 0, net 1, floor(1e6/1000001) = 0
            ((True, 1_000, 1_000, 988), "Slippage"),  # output is 987
        ]
        for args, code in cases:
            with self.assertRaises(PoolError) as ctx:
                pool.swap_exact_input(*args)
            self.assertEqual(ctx.exception.code, code)
        self.assertEqual((pool.reserve0, pool.reserve1), (1_000_000, 1_000_000))
        with self.assertRaises(PoolError) as ctx:
            Pool.swap_exact_output()
        self.assertEqual(ctx.exception.code, "ExactOutputUnsupported")
        with self.assertRaises(PoolError) as ctx:
            Pool().swap_exact_input(True, 1, 1, 0)
        self.assertEqual(ctx.exception.code, "NoLiquidity")

    def test_uint256_bounds(self):
        for bad in (-1, True, UINT256_MAX + 1, "1"):
            with self.assertRaises(PoolError) as ctx:
                quote_exact_input(bad, 1, 1)
            self.assertEqual(ctx.exception.code, "NotUint256")
        with self.assertRaises(PoolError) as ctx:
            quote_exact_input(UINT256_MAX, 1, 1)  # gross * 100 overflows
        self.assertEqual(ctx.exception.code, "Panic(0x11)")
        with self.assertRaises(PoolError) as ctx:
            quote_exact_input(10**30, 1, UINT256_MAX)  # reserveOut * net overflows
        self.assertEqual(ctx.exception.code, "Panic(0x11)")

    def test_claims_exact_and_fixed(self):
        pool = seeded(10**12, 10**12)
        pool.swap_exact_input(True, 12_345, 12_345, 0)
        pool.swap_exact_input(True, 99, 99, 0)  # sub-unit creator fee: nothing accrues
        self.assertEqual(pool.claimable(0), 123)
        self.assertEqual(pool.claim(0), 123)
        self.assertEqual(pool.delivered[0], 123)
        with self.assertRaises(PoolError) as ctx:
            pool.claim(0)
        self.assertEqual(ctx.exception.code, "NothingToClaim")


def state(pool):
    return copy.deepcopy(dataclasses.asdict(pool))


class AtomicityAndValidationTest(unittest.TestCase):
    """A raised PoolError must leave the model untouched, like a Solidity revert."""

    def assert_reverts_unchanged(self, pool, code, fn, *args):
        before = state(pool)
        with self.assertRaises(PoolError) as ctx:
            fn(*args)
        self.assertEqual(ctx.exception.code, code)
        self.assertEqual(state(pool), before)

    def test_fee_accrual_overflow_rolls_back_reserves(self):
        pool = Pool(reserve0=10**6, reserve1=10**6, accrued=[UINT256_MAX, 0])
        self.assert_reverts_unchanged(pool, "Panic(0x11)", pool.swap_exact_input, True, 10_000, 10_000, 0)
        # The other direction accrues to a different slot and still works.
        pool.swap_exact_input(False, 10_000, 10_000, 0)
        self.assertEqual(pool.accrued, [UINT256_MAX, 100])

    def test_lp_reserve_overflow_rolls_back_shares(self):
        pool = Pool(reserve0=UINT256_MAX - 5, reserve1=10, total_shares=10, shares={"LP": 10})
        # shares = 1, amount0 = ceil((2^256 - 6) / 10): reserve0 + amount0 overflows after shares are known.
        self.assert_reverts_unchanged(pool, "Panic(0x11)", pool.add_liquidity, UINT256_MAX // 10, 1, 0, "BOB")
        self.assertNotIn("BOB", pool.shares)

    def test_failed_checks_leave_state_unchanged(self):
        pool = seeded(10**18, 10**18)
        self.assert_reverts_unchanged(pool, "MinSharesNotMet", pool.add_liquidity, 10**18, 10**18, 10**18 + 1, "B")
        self.assert_reverts_unchanged(pool, "Slippage", pool.swap_exact_input, True, 10**15, 10**15, 10**18)
        self.assert_reverts_unchanged(pool, "MinAmountsNotMet", pool.remove_liquidity, "LP", 10**6, 10**18, 0)
        self.assert_reverts_unchanged(pool, "NothingToClaim", pool.claim, 0)

    def test_minimums_must_be_uint(self):
        pool = seeded(10**18, 10**18)
        for bad in (-1, True, 1.0, "0", None, UINT256_MAX + 1):
            self.assert_reverts_unchanged(pool, "NotUint256", pool.add_liquidity, 10**18, 10**18, bad, "B")
            self.assert_reverts_unchanged(pool, "NotUint256", pool.remove_liquidity, "LP", 10**6, bad, 0)
            self.assert_reverts_unchanged(pool, "NotUint256", pool.remove_liquidity, "LP", 10**6, 0, bad)
            self.assert_reverts_unchanged(pool, "NotUint256", pool.swap_exact_input, True, 10**6, 10**6, bad)

    def test_direction_must_be_bool(self):
        pool = seeded(10**18, 10**18)
        for bad in (1, 0, "buy", None):
            self.assert_reverts_unchanged(pool, "InvalidDirection", pool.swap_exact_input, bad, 10**6, 10**6, 0)
            with self.assertRaises(PoolError):
                pool.reserves(bad)

    def test_claim_asset_index_strict(self):
        pool = seeded(10**12, 10**12)
        pool.swap_exact_input(True, 12_345, 12_345, 0)
        for bad in (True, False, -1, 2, "0", None, 0.0):
            self.assert_reverts_unchanged(pool, "InvalidAsset", pool.claim, bad)
            with self.assertRaises(PoolError):
                pool.claimable(bad)
        self.assertEqual(pool.claim(0), 123)

    def test_holder_labels_validated(self):
        pool = seeded(10**18, 10**18)
        for bad in ("", None, 1):
            self.assert_reverts_unchanged(pool, "InvalidHolder", pool.add_liquidity, 10**18, 10**18, 0, bad)
            self.assert_reverts_unchanged(pool, "InvalidHolder", pool.remove_liquidity, bad, 1, 0, 0)

    def test_constructor_validation_allows_virtual_quote_pool(self):
        pool = Pool(reserve0=10**6, reserve1=10**6)  # zero supply, as used by the CLI quote
        self.assertEqual(pool.swap_exact_input(True, 10_000, 20_000, 0).output, 9_774)
        for kwargs in (dict(reserve0=-1), dict(reserve1=True), dict(total_shares=UINT256_MAX + 1),
                       dict(shares={"A": 5}), dict(shares={"": 0}), dict(accrued=[0]),
                       dict(accrued=[1, 0], delivered=[2, 0]), dict(delivered=[0, -1])):
            with self.assertRaises(PoolError, msg=kwargs):
                Pool(**kwargs)

    def test_add_liquidity_with_supply_but_no_reserves_panics_cleanly(self):
        pool = Pool(total_shares=10, shares={"LP": 10})
        self.assert_reverts_unchanged(pool, "Panic(0x12)", pool.add_liquidity, 1, 1, 0, "B")


class LiquidityTest(unittest.TestCase):
    def test_first_deposit(self):
        pool = Pool()
        r = pool.add_liquidity(500_000 * 10**12, 50 * 10**18, 5 * 10**18 - 1_000, "ALICE")
        self.assertEqual((r.amount0, r.amount1, r.shares), (500_000 * 10**12, 50 * 10**18, 5 * 10**18 - 1_000))
        self.assertEqual(pool.total_shares, 5 * 10**18)
        with self.assertRaises(PoolError) as ctx:
            Pool().add_liquidity(1_000, 1_000, 0, "x")  # sqrt = 1000 <= MINIMUM_LIQUIDITY
        self.assertEqual(ctx.exception.code, "InsufficientLiquidityMinted")

    def test_off_ratio_excess_untouched(self):
        pool = seeded(10**18, 10**18)
        r = pool.add_liquidity(2 * 10**18, 10**18, 0, "BOB")
        self.assertEqual((r.amount0, r.amount1, r.shares, r.unused0, r.unused1), (10**18, 10**18, 10**18, 10**18, 0))

    def test_rounding_up_never_dilutes(self):
        pool = seeded(1_000_003, 7_000_019)
        pool.swap_exact_input(True, 12_345, 12_345, 0)
        for max0, max1 in ((10_001, 70_000), (3, 50), (999_999, 1), (123_457, 864_199)):
            try:
                q = pool.quote_add_liquidity(max0, max1)
            except PoolError as err:
                self.assertEqual(err.code, "InsufficientLiquidityMinted")
                continue
            s, r0, r1 = pool.total_shares, pool.reserve0, pool.reserve1
            self.assertLessEqual(q.amount0, max0)
            self.assertLessEqual(q.amount1, max1)
            self.assertGreaterEqual(q.amount0 * s, q.shares * r0)  # paid at least pro-rata
            self.assertGreaterEqual(q.amount1 * s, q.shares * r1)
            self.assertLess(q.amount0 * s - q.shares * r0, s)  # by less than one raw unit
            self.assertLess(q.amount1 * s - q.shares * r1, s)

    def test_min_shares_and_remove_minima(self):
        pool = seeded(10**18, 10**18)
        with self.assertRaises(PoolError) as ctx:
            pool.add_liquidity(10**18, 10**18, 10**18 + 1, "BOB")
        self.assertEqual(ctx.exception.code, "MinSharesNotMet")
        shares = pool.shares["LP"]
        a0, a1 = pool.quote_remove_liquidity(shares)
        with self.assertRaises(PoolError) as ctx:
            pool.remove_liquidity("LP", shares, a0 + 1, 0)
        self.assertEqual(ctx.exception.code, "MinAmountsNotMet")
        self.assertEqual(pool.remove_liquidity("LP", shares, a0, a1), (a0, a1))
        self.assertEqual(pool.total_shares, amm.MINIMUM_LIQUIDITY)
        with self.assertRaises(PoolError) as ctx:
            pool.remove_liquidity("LP", 1, 0, 0)
        self.assertEqual(ctx.exception.code, "InsufficientShares")


if __name__ == "__main__":
    unittest.main()
