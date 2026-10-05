import unittest
from fractions import Fraction

import _support
from sairi_tools import simulator
from sairi_tools.strict import format_fraction, format_units, parse_decimal

USD = simulator.USD


class DisplayTest(unittest.TestCase):
    def test_parse_decimal_exact(self):
        self.assertEqual(parse_decimal("0.01", 18), 10**16)
        self.assertEqual(parse_decimal("120000", 18), 120_000 * 10**18)
        for bad in ("1e3", "-1", "1.", ".5", "0x10", "1.0000000000000000001", "nan", 1.5):
            with self.assertRaises(ValueError, msg=bad):
                parse_decimal(bad, 18)

    def test_format(self):
        self.assertEqual(format_fraction(Fraction(1297, 100_000) * 100, 6), "1.297000")
        self.assertEqual(format_fraction(Fraction(1, 3), 4), "0.3333")
        self.assertEqual(format_fraction(Fraction(2, 3), 4), "0.6667")
        self.assertEqual(format_fraction(Fraction(-1, 10**9), 4), "0.0000")
        self.assertEqual(format_fraction(Fraction(-1, 2), 0), "-1")
        self.assertEqual(format_units(166666666666666666, 18), "0.166666666666666666")
        self.assertEqual(format_units(5, 0), "5")


class SimulatorTest(unittest.TestCase):
    def setUp(self):
        self.report = simulator.simulate()
        self.cases = self.report["cases"]

    def by(self, direction):
        return [c for c in self.cases if c["direction"] == direction]

    def test_shape_and_labels(self):
        self.assertEqual(self.report["kind"], "SYNTHETIC_SIMULATION_NOT_REAL_BALANCES")
        self.assertIn("not concentrated liquidity", self.report["model"])
        self.assertTrue(self.report["assumptions"]["pricesAreSynthetic"])
        self.assertEqual(len(self.cases), 8)
        self.assertEqual([c["tradeUsd"] for c in self.by("buy")], ["500.000000", "1000.000000", "5000.000000",
                                                                   "10000.000000"])
        self.assertEqual(self.report["feeModel"]["nominalTotalFeePct"], "1.297000")
        _support.assert_no_floats(self, self.report)

    def test_initial_split_half_usd_each_side(self):
        # $60k / $0.01 = 6,000,000 SAIRI ; $60k / $3000 = 20 WETH (18 decimals each)
        self.assertEqual(self.report["initialReservesRaw"], {"SAIRI": str(6 * 10**24), "WETH": str(20 * 10**18)})

    def test_buy_uses_weth_input_and_creator_fee_in_weth(self):
        buy500 = self.by("buy")[0]
        self.assertEqual((buy500["inputAsset"], buy500["outputAsset"], buy500["creatorFeeAsset"]), ("WETH", "SAIRI", "WETH"))
        self.assertEqual(buy500["grossInputRaw"], "166666666666666666")
        self.assertEqual(buy500["creatorFeeRaw"], "1666666666666666")
        self.assertEqual(buy500["lpFeeRaw"], str((166666666666666666 - 1666666666666666) * 30 // 10_000))
        self.assertEqual(buy500["untouchedRaw"], "0")

    def test_sell_uses_sairi_input(self):
        sell500 = self.by("sell")[0]
        self.assertEqual((sell500["inputAsset"], sell500["creatorFeeAsset"]), ("SAIRI", "SAIRI"))
        self.assertEqual(sell500["grossInputRaw"], str(50_000 * 10**18))
        self.assertEqual(sell500["creatorFeeRaw"], str(500 * 10**18))

    def test_cases_are_independent_and_costs_ordered(self):
        for direction in ("buy", "sell"):
            impacts = [Fraction(c["priceImpactPct"]) for c in self.by(direction)]
            self.assertEqual(impacts, sorted(impacts))
            self.assertEqual(len(set(impacts)), 4)
            for c in self.by(direction):
                self.assertEqual(c["gas"], "EXCLUDED")
                self.assertEqual((c["protocolFeeRaw"], c["routerFeeRaw"]), ("0", "0"))
                self.assertTrue(c["kNonDecreasing"])
                self.assertGreater(Fraction(c["totalCostPct"]), Fraction(c["realizedFeePct"]))
                self.assertLessEqual(Fraction(c["realizedFeePct"]), Fraction("1.297"))
                gross, cf, lp = int(c["grossInputRaw"]), int(c["creatorFeeRaw"]), int(c["lpFeeRaw"])
                self.assertEqual(cf, gross // 100)
                self.assertEqual(int(c["netToCurveRaw"]), gross - cf - lp)

    def test_configurable_prices_and_liquidity(self):
        report = simulator.simulate(total_usd=240_000 * USD, sairi_usd=2 * USD // 100, weth_usd=2_500 * USD,
                                    trades_usd=[100 * USD])
        self.assertEqual(report["initialReservesRaw"], {"SAIRI": str(6 * 10**24), "WETH": str(48 * 10**18)})
        self.assertEqual(len(report["cases"]), 2)

    def test_explicit_reserves_and_decimals(self):
        report = simulator.simulate(sairi_decimals=6, weth_decimals=18, reserve_sairi=10**12, reserve_weth=10**19,
                                    trades_usd=[500 * USD])
        self.assertEqual(report["assumptions"]["reserveSource"], "explicit")
        self.assertEqual(report["cases"][1]["grossInputRaw"], str(50_000 * 10**6))

    def test_bounds(self):
        bad = [dict(total_usd=0), dict(sairi_usd=-1), dict(weth_usd=True), dict(sairi_decimals=19),
               dict(weth_decimals=True), dict(trades_usd=[0]), dict(trades_usd=[True]), dict(reserve_sairi=10**20)]
        for kwargs in bad:
            with self.assertRaises(ValueError, msg=kwargs):
                simulator.simulate(**kwargs)

    def test_total_cost_compounds_fee_and_impact(self):
        rs = int(self.report["initialReservesRaw"]["SAIRI"])
        rw = int(self.report["initialReservesRaw"]["WETH"])
        for c in self.cases:
            r_in, r_out = (rw, rs) if c["direction"] == "buy" else (rs, rw)
            spot = Fraction(r_out, r_in)
            gross, net, out = int(c["grossInputRaw"]), int(c["netToCurveRaw"]), int(c["outputRaw"])
            total = 1 - Fraction(out) / (gross * spot)
            impact = 1 - Fraction(out) / (net * spot)
            fee = Fraction(gross - net, gross)
            self.assertEqual(total, 1 - (1 - fee) * (1 - impact))
            self.assertLess(total, fee + impact)  # not an unscaled sum
            self.assertEqual(c["totalCostPct"], format_fraction(total * 100, simulator.PCT_PLACES))
            self.assertEqual(c["priceImpactPct"], format_fraction(impact * 100, simulator.PCT_PLACES))

    def test_invalid_direction_rejected(self):
        for bad in ("BUY", "swap", "", None, True, 0):
            with self.assertRaises(ValueError, msg=bad):
                simulator.simulate_case(10**24, 10**19, bad, 500 * USD, (USD // 100, 3_000 * USD), (18, 18))

    def test_explicit_reserves_validated_at_boundary(self):
        for bad in (0, -1, True, 1.5, "1000", 2**256):
            with self.assertRaises(ValueError, msg=bad):
                simulator.simulate(reserve_sairi=bad, reserve_weth=10**19)
            with self.assertRaises(ValueError, msg=bad):
                simulator.simulate(reserve_sairi=10**24, reserve_weth=bad)

    def test_valuation_reported_from_actual_reserves(self):
        default = self.report
        self.assertTrue(default["assumptions"]["totalLiquidityUsdInputUsed"])
        self.assertEqual(default["initialValuationUsd"],
                         {"SAIRI": "60000.000000", "WETH": "60000.000000", "total": "120000.000000"})
        # Explicit reserves: the configured $120k total is NOT the starting valuation.
        report = simulator.simulate(reserve_sairi=10**24, reserve_weth=10**18)  # 1M SAIRI @ $0.01, 1 WETH @ $3000
        self.assertFalse(report["assumptions"]["totalLiquidityUsdInputUsed"])
        self.assertEqual(report["assumptions"]["totalLiquidityUsdInput"], "120000.000000")
        self.assertEqual(report["initialValuationUsd"],
                         {"SAIRI": "10000.000000", "WETH": "3000.000000", "total": "13000.000000"})

    def test_degenerate_pools_report_errors(self):
        report = simulator.simulate(reserve_sairi=1_000, reserve_weth=1_000)
        self.assertTrue(all(c["error"] == "seed:InsufficientLiquidityMinted" for c in report["cases"]))
        report = simulator.simulate(reserve_sairi=10**12, reserve_weth=10**4, trades_usd=[USD // 10**15])
        self.assertEqual([c["error"] for c in report["cases"]], ["ZeroInput", "ZeroOutput"])
        report = simulator.simulate(reserve_sairi=2**200, reserve_weth=2**200)
        self.assertTrue(all(c["error"].endswith("Panic(0x11)") for c in report["cases"]))


if __name__ == "__main__":
    unittest.main()
