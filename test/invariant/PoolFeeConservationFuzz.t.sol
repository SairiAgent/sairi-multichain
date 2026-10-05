// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestBase} from "../utils/TestBase.sol";
import {MockERC20} from "../mocks/MockTokens.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {LocalConstantProductPool} from "../../src/pool/LocalConstantProductPool.sol";
import {CreatorFeeCollector} from "../../src/fees/CreatorFeeCollector.sol";

/// @notice Bounded stateful fuzz over the LOCAL pool harness: random swaps in both directions and
/// random permissionless claims. Checks fee conservation, reserve/balance agreement and that k never
/// decreases after each step.
contract PoolFeeConservationFuzzTest is TestBase {
    uint256 internal constant STEPS = 24;
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant LP = address(0x1111);
    address internal constant TRADER = address(0x2222);

    MockERC20 internal bsairi;
    MockERC20 internal weth;
    LocalConstantProductPool internal pool;
    CreatorFeeCollector internal collector;

    uint256[2] internal expectedFees;

    function setUp() public {
        bsairi = new MockERC20("Backed SAIRI (TEST MOCK)", "bSAIRI", 18);
        weth = new MockERC20("WETH-like (TEST MOCK)", "WETH", 18);
        pool = new LocalConstantProductPool(bsairi, weth, CREATOR);
        collector = pool.feeCollector();

        bsairi.mint(LP, 1_000_000e18);
        weth.mint(LP, 100e18);
        vm.startPrank(LP);
        bsairi.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        pool.addLiquidity(1_000_000e18, 100e18, 1e22 - 1_000, LP); // sqrt(1e24 * 1e20) - MINIMUM_LIQUIDITY
        vm.stopPrank();

        bsairi.mint(TRADER, 1_000_000e18);
        weth.mint(TRADER, 1_000e18);
        vm.startPrank(TRADER);
        bsairi.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function testFuzz_poolFeeConservation(uint256 seed) public {
        for (uint256 i; i < STEPS; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 kBefore = pool.reserve0() * pool.reserve1();
            uint256 op = seed % 3;
            if (op == 2) {
                address token = ((seed >> 8) & 1) == 0 ? address(bsairi) : address(weth);
                if (collector.claimable(token) != 0) collector.claim(token);
            } else {
                _swap(op == 0, seed >> 8);
            }
            assertGe(pool.reserve0() * pool.reserve1(), kBefore, "k non-decreasing");
            _check();
        }
    }

    function _swap(bool sairiIn, uint256 r) internal {
        MockERC20 tokenIn = sairiIn ? bsairi : weth;
        uint256 balance = tokenIn.balanceOf(TRADER);
        if (balance == 0) return;
        uint256 cap = sairiIn ? 50_000e18 : 5e18;
        uint256 gross = bound(r, 1, cap < balance ? cap : balance);
        (uint256 creatorFee,, uint256 output) = pool.quoteExactInput(address(tokenIn), gross);
        if (output == 0) return;

        uint256 traderBefore = tokenIn.balanceOf(TRADER);
        vm.prank(TRADER);
        (uint256 consumed, uint256 got) = pool.swapExactInput(address(tokenIn), gross, cap, output, TRADER);
        assertEq(consumed, gross, "consumed");
        assertEq(got, output, "quoted output");
        assertEq(traderBefore - tokenIn.balanceOf(TRADER), gross, "only gross pulled");
        expectedFees[sairiIn ? 0 : 1] += creatorFee;
    }

    function _check() internal view {
        assertEq(bsairi.balanceOf(address(pool)), pool.reserve0(), "reserve0 == balance");
        assertEq(weth.balanceOf(address(pool)), pool.reserve1(), "reserve1 == balance");
        address[2] memory tokens = [address(bsairi), address(weth)];
        for (uint256 j; j < 2; ++j) {
            IERC20 t = IERC20(tokens[j]);
            assertEq(collector.accrued(address(t)), expectedFees[j], "accrued == sum of creator fees");
            assertEq(
                t.balanceOf(address(collector)) + t.balanceOf(CREATOR),
                collector.accrued(address(t)),
                "fees held + delivered == accrued"
            );
            assertEq(t.balanceOf(CREATOR), collector.delivered(address(t)), "delivered to fixed beneficiary");
            assertEq(
                t.balanceOf(address(pool)) + t.balanceOf(address(collector)) + t.balanceOf(CREATOR)
                    + t.balanceOf(TRADER) + t.balanceOf(LP),
                t.totalSupply(),
                "token conservation"
            );
        }
    }
}
