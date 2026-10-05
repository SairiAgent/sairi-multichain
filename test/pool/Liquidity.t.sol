// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestBase} from "../utils/TestBase.sol";
import {MockERC20} from "../mocks/MockTokens.sol";
import {LocalConstantProductPool} from "../../src/pool/LocalConstantProductPool.sol";

/// @notice LOCAL HARNESS liquidity API regressions: proportional consumption, no hidden donation,
/// minShares / min-amount slippage guards, and reserve movement between quote and action.
contract LiquidityTest is TestBase {
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant LP = address(0x1111);
    address internal constant LP2 = address(0x4444);
    address internal constant TRADER = address(0x2222);

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    LocalConstantProductPool internal pool;

    function setUp() public {
        tokenA = new MockERC20("Backed SAIRI (TEST MOCK)", "bSAIRI", 18);
        tokenB = new MockERC20("WETH-like (TEST MOCK)", "WETH", 18);
        pool = new LocalConstantProductPool(tokenA, tokenB, CREATOR);

        // Seed 100/100: S = sqrt(100e18 * 100e18) = 100e18.
        _fund(LP, 100e18, 100e18, type(uint256).max, type(uint256).max);
        vm.prank(LP);
        pool.addLiquidity(100e18, 100e18, 100e18 - 1_000, LP);

        _fund(TRADER, 0, 100e18, 0, type(uint256).max);
    }

    function _fund(address who, uint256 a, uint256 b, uint256 allowA, uint256 allowB) internal {
        tokenA.mint(who, a);
        tokenB.mint(who, b);
        vm.startPrank(who);
        tokenA.approve(address(pool), allowA);
        tokenB.approve(address(pool), allowB);
        vm.stopPrank();
    }

    function _moveReservesWithSwap() internal {
        vm.prank(TRADER);
        pool.swapExactInput(address(tokenB), 5e18, 5e18, 1, TRADER);
    }

    // ---------------------------------------------------------------- proportional consumption

    function test_offRatioAdd_consumesProportionalOnly() public {
        _fund(LP2, 100e18, 1e18, type(uint256).max, type(uint256).max);

        vm.prank(LP2);
        (uint256 used0, uint256 used1, uint256 shares) = pool.addLiquidity(100e18, 1e18, 1e18, LP2);

        assertEq(used0, 1e18, "consumes ~1 tokenA, not 100");
        assertEq(used1, 1e18, "consumes 1 tokenB");
        assertEq(shares, 1e18, "1% of supply");
        assertEq(tokenA.balanceOf(LP2), 99e18, "unconsumed tokenA stays with caller");
        assertEq(tokenB.balanceOf(LP2), 0, "tokenB fully used");
        assertEq(pool.reserve0(), 101e18, "reserve0");
        assertEq(pool.reserve1(), 101e18, "reserve1");

        // No hidden donation: immediately withdrawing returns exactly what was consumed.
        vm.prank(LP2);
        (uint256 out0, uint256 out1) = pool.removeLiquidity(shares, 1e18, 1e18, LP2);
        assertEq(out0, used0, "round trip tokenA");
        assertEq(out1, used1, "round trip tokenB");
    }

    function test_maxInput_unusedAllowancePreserved() public {
        _fund(LP2, 100e18, 1e18, 100e18, 1e18);
        vm.prank(LP2);
        pool.addLiquidity(100e18, 1e18, 1e18, LP2);
        assertEq(tokenA.allowance(LP2, address(pool)), 99e18, "unused allowance A preserved");
        assertEq(tokenB.allowance(LP2, address(pool)), 0, "allowance B consumed");
    }

    function test_firstSeed_consumesProvided_locksMinimum() public {
        LocalConstantProductPool fresh = new LocalConstantProductPool(tokenA, tokenB, CREATOR);
        tokenA.mint(LP2, 4e18);
        tokenB.mint(LP2, 1e18);
        vm.startPrank(LP2);
        tokenA.approve(address(fresh), type(uint256).max);
        tokenB.approve(address(fresh), type(uint256).max);
        (uint256 used0, uint256 used1, uint256 shares) = fresh.addLiquidity(4e18, 1e18, 2e18 - 1_000, LP2);
        vm.stopPrank();
        assertEq(used0, 4e18, "seed consumes provided A");
        assertEq(used1, 1e18, "seed consumes provided B");
        assertEq(shares, 2e18 - 1_000, "sqrt(4e36) - minimum");
        assertEq(fresh.sharesOf(address(0)), 1_000, "minimum locked");
        assertEq(fresh.totalShares(), 2e18, "total shares");
    }

    // ---------------------------------------------------------------- slippage guards

    function test_minShares_rejected() public {
        _fund(LP2, 10e18, 10e18, type(uint256).max, type(uint256).max);
        (,, uint256 quoted) = pool.quoteAddLiquidity(10e18, 10e18);
        vm.expectRevert(LocalConstantProductPool.MinSharesNotMet.selector);
        vm.prank(LP2);
        pool.addLiquidity(10e18, 10e18, quoted + 1, LP2);
        assertEq(tokenA.balanceOf(LP2), 10e18, "nothing pulled");
        assertEq(pool.sharesOf(LP2), 0, "nothing minted");
    }

    function test_removeMinima_rejected() public {
        uint256 shares = pool.sharesOf(LP) / 2;
        (uint256 q0, uint256 q1) = pool.quoteRemoveLiquidity(shares);
        uint256 r0 = pool.reserve0();

        vm.expectRevert(LocalConstantProductPool.MinAmountsNotMet.selector);
        vm.prank(LP);
        pool.removeLiquidity(shares, q0 + 1, q1, LP);

        vm.expectRevert(LocalConstantProductPool.MinAmountsNotMet.selector);
        vm.prank(LP);
        pool.removeLiquidity(shares, q0, q1 + 1, LP);

        assertEq(pool.sharesOf(LP), 100e18 - 1_000, "shares unchanged");
        assertEq(pool.reserve0(), r0, "reserves unchanged");
        assertEq(tokenA.balanceOf(LP), 0, "nothing paid");

        vm.prank(LP);
        (uint256 out0, uint256 out1) = pool.removeLiquidity(shares, q0, q1, LP);
        assertEq(out0, q0, "exact quote 0");
        assertEq(out1, q1, "exact quote 1");
    }

    function test_reservesMovedBetweenQuoteAndAdd_rejected() public {
        _fund(LP2, 10e18, 10e18, type(uint256).max, type(uint256).max);
        (,, uint256 quoted) = pool.quoteAddLiquidity(10e18, 10e18);
        _moveReservesWithSwap();
        (,, uint256 nowShares) = pool.quoteAddLiquidity(10e18, 10e18);
        assertTrue(nowShares < quoted, "reserve move reduces shares");

        vm.expectRevert(LocalConstantProductPool.MinSharesNotMet.selector);
        vm.prank(LP2);
        pool.addLiquidity(10e18, 10e18, quoted, LP2);
    }

    function test_reservesMovedBetweenQuoteAndRemove_rejected() public {
        uint256 shares = pool.sharesOf(LP) / 2;
        (uint256 q0, uint256 q1) = pool.quoteRemoveLiquidity(shares);
        _moveReservesWithSwap(); // tokenB in, tokenA out: reserve0 falls

        vm.expectRevert(LocalConstantProductPool.MinAmountsNotMet.selector);
        vm.prank(LP);
        pool.removeLiquidity(shares, q0, q1, LP);
    }

    // ---------------------------------------------------------------- degenerate inputs

    function test_zeroInputOrZeroShares_rejected() public {
        vm.expectRevert(LocalConstantProductPool.ZeroInput.selector);
        vm.prank(LP);
        pool.addLiquidity(0, 1e18, 0, LP);

        vm.expectRevert(LocalConstantProductPool.ZeroInput.selector);
        vm.prank(LP);
        pool.removeLiquidity(0, 0, 0, LP);

        // Pool with S = 1e18 against r0 = 1e30: < 1e12 of tokenA rounds to zero shares.
        LocalConstantProductPool skewed = new LocalConstantProductPool(tokenA, tokenB, CREATOR);
        tokenA.mint(LP2, 1e30);
        tokenB.mint(LP2, 1e6 + 1e6);
        vm.startPrank(LP2);
        tokenA.approve(address(skewed), type(uint256).max);
        tokenB.approve(address(skewed), type(uint256).max);
        skewed.addLiquidity(1e30, 1e6, 1e18 - 1_000, LP2);
        vm.expectRevert(LocalConstantProductPool.InsufficientLiquidityMinted.selector);
        skewed.addLiquidity(1e11, 1e6, 0, LP2);
        vm.stopPrank();
    }

    function test_seedOverflow_reverts() public {
        LocalConstantProductPool fresh = new LocalConstantProductPool(tokenA, tokenB, CREATOR);
        vm.expectRevert();
        vm.prank(LP2);
        fresh.addLiquidity(type(uint256).max, 2, 0, LP2);
    }

    // ---------------------------------------------------------------- rounding property

    /// @dev For arbitrary maxima after arbitrary reserve movement: never pulls more than max, pays at
    /// least pro-rata per share (no dilution), and the ceil is tight (< 1 wei excess per token).
    function testFuzz_addRounding_noDilutionNoOverpull(uint256 m0, uint256 m1, uint256 swapIn) public {
        m0 = bound(m0, 1e6, 1e24);
        m1 = bound(m1, 1e6, 1e24);
        swapIn = bound(swapIn, 1e9, 50e18);
        vm.prank(TRADER);
        pool.swapExactInput(address(tokenB), swapIn, swapIn, 1, TRADER);

        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();
        uint256 supply = pool.totalShares();
        _fund(LP2, m0, m1, type(uint256).max, type(uint256).max);

        vm.prank(LP2);
        (uint256 used0, uint256 used1, uint256 shares) = pool.addLiquidity(m0, m1, 1, LP2);

        assertLe(used0, m0, "used0 <= max0");
        assertLe(used1, m1, "used1 <= max1");
        assertEq(tokenA.balanceOf(LP2), m0 - used0, "only used0 pulled");
        assertEq(tokenB.balanceOf(LP2), m1 - used1, "only used1 pulled");
        assertGe(used0 * supply, shares * r0, "no dilution (0)");
        assertGe(used1 * supply, shares * r1, "no dilution (1)");
        assertTrue((used0 - 1) * supply < shares * r0, "tight ceil (0)");
        assertTrue((used1 - 1) * supply < shares * r1, "tight ceil (1)");
    }
}
