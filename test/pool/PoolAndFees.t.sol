// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestBase} from "../utils/TestBase.sol";
import {MockERC20, FeeOnTransferToken, FailingToken, ReentrantToken} from "../mocks/MockTokens.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {SafeTransferLib} from "../../src/libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "../../src/utils/ReentrancyGuard.sol";
import {LocalConstantProductPool} from "../../src/pool/LocalConstantProductPool.sol";
import {CreatorFeeCollector} from "../../src/fees/CreatorFeeCollector.sol";

/// @notice LOCAL HARNESS pool + creator-fee tests. No real DEX or router is involved.
contract PoolAndFeesTest is TestBase {
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant LP = address(0x1111);
    address internal constant TRADER = address(0x2222);
    address internal constant MALLORY = address(0xBAD);

    uint256 internal constant SEED_SAIRI = 1_000_000e18;
    uint256 internal constant SEED_WETH = 100e18;

    MockERC20 internal bsairi;
    MockERC20 internal weth;
    LocalConstantProductPool internal pool;
    CreatorFeeCollector internal collector;

    function setUp() public {
        bsairi = new MockERC20("Backed SAIRI (TEST MOCK)", "bSAIRI", 18);
        weth = new MockERC20("WETH-like (TEST MOCK)", "WETH", 18);
        pool = new LocalConstantProductPool(bsairi, weth, CREATOR);
        collector = pool.feeCollector();

        _seed(pool, bsairi, weth, SEED_SAIRI, SEED_WETH);

        bsairi.mint(TRADER, 100_000e18);
        weth.mint(TRADER, 1_000e18);
        vm.startPrank(TRADER);
        bsairi.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _seed(LocalConstantProductPool p, MockERC20 a, MockERC20 b, uint256 amountA, uint256 amountB) internal {
        a.mint(LP, amountA);
        b.mint(LP, amountB);
        vm.startPrank(LP);
        a.approve(address(p), type(uint256).max);
        b.approve(address(p), type(uint256).max);
        // First deposit: floor(sqrt(a * b)) minus the permanently locked minimum.
        uint256 expectedShares = _isqrt(amountA * amountB) - p.MINIMUM_LIQUIDITY();
        (uint256 used0, uint256 used1, uint256 shares) = p.addLiquidity(amountA, amountB, expectedShares, LP);
        vm.stopPrank();
        assertEq(used0, amountA, "seed consumes amount0");
        assertEq(used1, amountB, "seed consumes amount1");
        assertEq(shares, expectedShares, "seed shares");
    }

    function _isqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        z = y;
        uint256 x = y / 2 + 1;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    }

    /// @dev Independent restatement of the fee/output formula.
    function _expected(uint256 gross, uint256 rIn, uint256 rOut)
        internal
        pure
        returns (uint256 creatorFee, uint256 lpFee, uint256 output)
    {
        creatorFee = (gross * 100) / 10_000;
        lpFee = ((gross - creatorFee) * 30) / 10_000;
        uint256 net = gross - creatorFee - lpFee;
        output = (rOut * net) / (rIn + net);
    }

    function _swap(address tokenIn, uint256 gross) internal returns (uint256 output) {
        vm.prank(TRADER);
        (, output) = pool.swapExactInput(tokenIn, gross, gross, 0, TRADER);
    }

    function _assertPoolAccounting() internal view {
        assertEq(bsairi.balanceOf(address(pool)), pool.reserve0(), "reserve0 == balance");
        assertEq(weth.balanceOf(address(pool)), pool.reserve1(), "reserve1 == balance");
        address[2] memory tokens = [address(bsairi), address(weth)];
        for (uint256 i; i < 2; ++i) {
            address t = tokens[i];
            assertEq(
                IERC20(t).balanceOf(address(collector)),
                collector.accrued(t) - collector.delivered(t),
                "collector balance == accrued - delivered"
            );
            assertEq(IERC20(t).balanceOf(CREATOR), collector.delivered(t), "beneficiary received delivered");
            uint256 sum = IERC20(t).balanceOf(address(pool)) + IERC20(t).balanceOf(address(collector))
                + IERC20(t).balanceOf(CREATOR) + IERC20(t).balanceOf(TRADER) + IERC20(t).balanceOf(LP);
            assertEq(sum, IERC20(t).totalSupply(), "token conservation");
        }
    }

    // ---------------------------------------------------------------- fee math

    function test_buy_feeMath() public {
        uint256 gross = 10e18;
        (uint256 cf, uint256 lf, uint256 out) = _expected(gross, SEED_WETH, SEED_SAIRI);
        uint256 k0 = pool.reserve0() * pool.reserve1();

        uint256 got = _swap(address(weth), gross);

        assertEq(got, out, "output");
        assertEq(cf, 0.1e18, "creator fee 1%");
        assertEq(lf, (gross - cf) * 30 / 10_000, "lp fee 0.3% of remainder");
        assertEq(bsairi.balanceOf(TRADER), 100_000e18 + out, "trader output");
        assertEq(weth.balanceOf(address(collector)), cf, "creator fee in input token");
        assertEq(collector.accrued(address(weth)), cf, "accrued");
        assertEq(collector.accrued(address(bsairi)), 0, "no output-token fee");
        assertEq(pool.reserve1(), SEED_WETH + gross - cf, "lp fee stays in reserves");
        assertEq(pool.reserve0(), SEED_SAIRI - out, "reserve out");
        assertGe(pool.reserve0() * pool.reserve1(), k0, "k non-decreasing");
        _assertPoolAccounting();
    }

    function test_sell_feeMath() public {
        uint256 gross = 12_345e18;
        (uint256 cf,, uint256 out) = _expected(gross, SEED_SAIRI, SEED_WETH);
        uint256 got = _swap(address(bsairi), gross);
        assertEq(got, out, "output");
        assertEq(collector.accrued(address(bsairi)), cf, "creator fee in bSAIRI");
        assertEq(pool.reserve0(), SEED_SAIRI + gross - cf, "lp fee stays");
        assertEq(weth.balanceOf(TRADER), 1_000e18 + out, "trader weth");
        _assertPoolAccounting();
    }

    function test_feeRounding_floors() public view {
        (uint256 cf, uint256 lf,) = pool.quoteExactInput(address(weth), 12_345);
        assertEq(cf, 123, "floor(12345 * 100 / 10000)");
        assertEq(lf, 36, "floor(12222 * 30 / 10000)");
        (cf, lf,) = pool.quoteExactInput(address(weth), 99);
        assertEq(cf, 0, "sub-unit creator fee floors to zero");
        assertEq(lf, 0, "sub-unit lp fee floors to zero");
    }

    function test_manySwaps_feeConservation() public {
        uint256 expectedWeth;
        uint256 expectedSairi;
        for (uint256 i; i < 6; ++i) {
            uint256 g = (i + 1) * 0.7e18;
            (uint256 cf,,) = pool.quoteExactInput(address(weth), g);
            expectedWeth += cf;
            _swap(address(weth), g);
            uint256 s = (i + 1) * 3_333e18 + i;
            (cf,,) = pool.quoteExactInput(address(bsairi), s);
            expectedSairi += cf;
            _swap(address(bsairi), s);
        }
        assertEq(collector.accrued(address(weth)), expectedWeth, "weth fees");
        assertEq(collector.accrued(address(bsairi)), expectedSairi, "sairi fees");
        _assertPoolAccounting();

        vm.prank(MALLORY);
        collector.claim(address(weth));
        _assertPoolAccounting();
    }

    // ---------------------------------------------------------------- input consumption

    function test_partialConsumption_unusedInputStaysWithSender() public {
        address user = address(0x3333);
        weth.mint(user, 10e18);
        vm.startPrank(user);
        weth.approve(address(pool), 5e18);
        (uint256 consumed,) = pool.swapExactInput(address(weth), 3e18, 5e18, 0, user);
        vm.stopPrank();

        assertEq(consumed, 3e18, "consumed gross only");
        assertEq(weth.balanceOf(user), 7e18, "unconsumed balance remains");
        assertEq(weth.allowance(user, address(pool)), 2e18, "unconsumed allowance remains");
    }

    function test_maxInputExceeded_reverts() public {
        vm.expectRevert(LocalConstantProductPool.MaxInputExceeded.selector);
        vm.prank(TRADER);
        pool.swapExactInput(address(weth), 2e18, 1e18, 0, TRADER);
    }

    function test_exactOutput_unsupported() public {
        vm.expectRevert(LocalConstantProductPool.ExactOutputUnsupported.selector);
        pool.swapExactOutput(address(weth), 1e18, 1e18, TRADER);
    }

    // ---------------------------------------------------------------- rejections

    function test_rejects_invalidSwaps() public {
        vm.startPrank(TRADER);
        vm.expectRevert(LocalConstantProductPool.ZeroAddress.selector);
        pool.swapExactInput(address(weth), 1e18, 1e18, 0, address(0));

        vm.expectRevert(LocalConstantProductPool.InvalidRecipient.selector);
        pool.swapExactInput(address(weth), 1e18, 1e18, 0, address(collector));

        vm.expectRevert(LocalConstantProductPool.InvalidRecipient.selector);
        pool.swapExactInput(address(weth), 1e18, 1e18, 0, address(pool));

        vm.expectRevert(LocalConstantProductPool.ZeroInput.selector);
        pool.swapExactInput(address(weth), 0, 1e18, 0, TRADER);

        vm.expectRevert(LocalConstantProductPool.ZeroOutput.selector);
        pool.swapExactInput(address(bsairi), 1, 1, 0, TRADER);

        vm.expectRevert(LocalConstantProductPool.UnsupportedToken.selector);
        pool.swapExactInput(address(0xdead), 1e18, 1e18, 0, TRADER);

        (,, uint256 quoted) = pool.quoteExactInput(address(weth), 1e18);
        vm.expectRevert(LocalConstantProductPool.Slippage.selector);
        pool.swapExactInput(address(weth), 1e18, 1e18, quoted + 1, TRADER);
        vm.stopPrank();

        _assertPoolAccounting();
    }

    function test_noLiquidity_reverts() public {
        LocalConstantProductPool empty = new LocalConstantProductPool(bsairi, weth, CREATOR);
        vm.expectRevert(LocalConstantProductPool.NoLiquidity.selector);
        vm.prank(TRADER);
        empty.swapExactInput(address(weth), 1e18, 1e18, 0, TRADER);
    }

    function test_feeOnTransferInput_rejected() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        LocalConstantProductPool fotPool = new LocalConstantProductPool(fot, weth, CREATOR);
        fot.mint(LP, 1_010e18);
        weth.mint(LP, 11e18);
        vm.startPrank(LP);
        fot.approve(address(fotPool), type(uint256).max);
        weth.approve(address(fotPool), type(uint256).max);
        fotPool.addLiquidity(1_000e18, 10e18, 1, LP);
        vm.stopPrank();

        fot.setFeeOn(true);
        fot.mint(TRADER, 10e18);
        vm.prank(TRADER);
        fot.approve(address(fotPool), type(uint256).max);

        vm.expectRevert(LocalConstantProductPool.NonExactTransfer.selector);
        vm.prank(TRADER);
        fotPool.swapExactInput(address(fot), 1e18, 1e18, 0, TRADER);

        vm.expectRevert(LocalConstantProductPool.NonExactTransfer.selector);
        vm.prank(LP);
        fotPool.addLiquidity(1e18, 1e16, 1, LP);
    }

    // ---------------------------------------------------------------- liquidity

    function test_liquidity_addRemove_proportional() public {
        address lp2 = address(0x4444);
        bsairi.mint(lp2, 10_000e18);
        weth.mint(lp2, 1e18);
        vm.startPrank(lp2);
        bsairi.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        // Reserves 1e24/1e20, S = 1e22: exactly 1/100 of the pool.
        (,, uint256 shares) = pool.addLiquidity(10_000e18, 1e18, 1e20, lp2);
        (uint256 a0, uint256 a1) = pool.removeLiquidity(shares, 10_000e18, 1e18, lp2);
        vm.stopPrank();
        assertEq(shares, 1e20, "shares");
        assertLe(a0, 10_000e18, "no value extracted (0)");
        assertLe(a1, 1e18, "no value extracted (1)");
        assertEq(pool.sharesOf(address(0)), pool.MINIMUM_LIQUIDITY(), "minimum liquidity locked");
    }

    function test_feeCollector_cannotWithdrawLiquidity() public {
        _swap(address(weth), 1e18);
        assertEq(pool.sharesOf(address(collector)), 0, "collector holds no shares");

        vm.expectRevert(LocalConstantProductPool.InsufficientShares.selector);
        vm.prank(address(collector));
        pool.removeLiquidity(1, 0, 0, CREATOR);

        vm.expectRevert(LocalConstantProductPool.InvalidRecipient.selector);
        vm.prank(LP);
        pool.addLiquidity(1e18, 1e18, 1, address(collector));

        vm.expectRevert(LocalConstantProductPool.InvalidRecipient.selector);
        vm.prank(LP);
        pool.removeLiquidity(1, 0, 0, address(collector));
    }

    // ---------------------------------------------------------------- collector

    function test_collector_bindingAndBeneficiary() public view {
        assertEq(collector.pool(), address(pool), "bound to pool");
        assertEq(collector.beneficiary(), CREATOR, "beneficiary");
        assertEq(collector.token0(), address(bsairi), "token0");
        assertEq(collector.token1(), address(weth), "token1");
    }

    function test_constructor_zeroBeneficiary_reverts() public {
        vm.expectRevert(CreatorFeeCollector.ZeroAddress.selector);
        new LocalConstantProductPool(bsairi, weth, address(0));

        vm.expectRevert(CreatorFeeCollector.ZeroAddress.selector);
        new CreatorFeeCollector(address(0), address(bsairi), address(weth));
    }

    function test_claim_permissionless_fixedRecipient_repeated() public {
        _swap(address(weth), 5e18);
        uint256 fee1 = collector.claimable(address(weth));
        assertGe(fee1, 1, "fee accrued");

        vm.prank(MALLORY);
        uint256 paid = collector.claim(address(weth));
        assertEq(paid, fee1, "paid all accrued");
        assertEq(weth.balanceOf(CREATOR), fee1, "beneficiary paid");
        assertEq(weth.balanceOf(MALLORY), 0, "caller paid nothing");
        assertEq(collector.delivered(address(weth)), fee1, "delivered");

        vm.expectRevert(CreatorFeeCollector.NothingToClaim.selector);
        collector.claim(address(weth));

        _swap(address(weth), 2e18);
        uint256 fee2 = collector.claimable(address(weth));
        collector.claim(address(weth));
        assertEq(weth.balanceOf(CREATOR), fee1 + fee2, "second claim pays only new fees");
        assertEq(collector.accrued(address(weth)), collector.delivered(address(weth)), "fully delivered");
        _assertPoolAccounting();
    }

    function test_collector_recordFee_guards() public {
        vm.expectRevert(CreatorFeeCollector.NotPool.selector);
        vm.prank(MALLORY);
        collector.recordFee(address(weth), 1);

        vm.expectRevert(CreatorFeeCollector.UnsupportedToken.selector);
        collector.claim(address(0xdead));

        // A standalone collector whose `pool` is this test contract: fees must be backed by balance.
        CreatorFeeCollector c = new CreatorFeeCollector(CREATOR, address(bsairi), address(weth));
        vm.expectRevert(CreatorFeeCollector.UnbackedFee.selector);
        c.recordFee(address(weth), 1);
        vm.expectRevert(CreatorFeeCollector.ZeroAmount.selector);
        c.recordFee(address(weth), 0);
    }

    function test_claim_recipientTokenFailure_isAtomic() public {
        FailingToken bad = new FailingToken();
        CreatorFeeCollector c = new CreatorFeeCollector(CREATOR, address(bad), address(weth));
        bad.mint(address(c), 100);
        c.recordFee(address(bad), 100);

        bad.setFailure(true, false);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        c.claim(address(bad));
        assertEq(c.delivered(address(bad)), 0, "not delivered on revert");

        bad.setFailure(false, true);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        c.claim(address(bad));
        assertEq(c.claimable(address(bad)), 100, "still claimable");

        bad.setFailure(false, false);
        c.claim(address(bad));
        assertEq(bad.balanceOf(CREATOR), 100, "paid after recovery");
        assertEq(c.claimable(address(bad)), 0, "nothing left");
    }

    // ---------------------------------------------------------------- reentrancy

    function test_claim_reentrancyBlocked() public {
        ReentrantToken rt = new ReentrantToken();
        CreatorFeeCollector c = new CreatorFeeCollector(CREATOR, address(rt), address(weth));
        rt.mint(address(c), 1_000);
        c.recordFee(address(rt), 1_000);

        rt.arm(address(c), abi.encodeCall(CreatorFeeCollector.claim, (address(rt))));
        vm.prank(MALLORY);
        c.claim(address(rt));

        assertTrue(rt.hookAttempted(), "reentry attempted");
        assertTrue(!rt.hookSucceeded(), "reentry blocked");
        assertEq(
            uint256(keccak256(rt.hookRevertData())),
            uint256(keccak256(abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector))),
            "Reentrancy error"
        );
        assertEq(rt.balanceOf(CREATOR), 1_000, "paid exactly once");
        assertEq(c.delivered(address(rt)), 1_000, "delivered once");
    }

    function test_swap_reentrancyBlocked() public {
        ReentrantToken rt = new ReentrantToken();
        LocalConstantProductPool rp = new LocalConstantProductPool(rt, weth, CREATOR);
        rt.mint(LP, 1_000e18);
        weth.mint(LP, 10e18);
        vm.startPrank(LP);
        rt.approve(address(rp), type(uint256).max);
        weth.approve(address(rp), type(uint256).max);
        rp.addLiquidity(1_000e18, 10e18, 1e20 - 1_000, LP); // sqrt(1e21 * 1e19) - MINIMUM_LIQUIDITY
        vm.stopPrank();

        rt.mint(TRADER, 10e18);
        vm.prank(TRADER);
        rt.approve(address(rp), type(uint256).max);

        rt.arm(
            address(rp),
            abi.encodeCall(LocalConstantProductPool.swapExactInput, (address(weth), 1e18, 1e18, 0, MALLORY))
        );
        vm.prank(TRADER);
        rp.swapExactInput(address(rt), 1e18, 1e18, 0, TRADER);

        assertTrue(rt.hookAttempted(), "reentry attempted");
        assertTrue(!rt.hookSucceeded(), "reentry blocked");
        assertEq(
            uint256(keccak256(rt.hookRevertData())),
            uint256(keccak256(abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector))),
            "Reentrancy error"
        );
        assertEq(rt.balanceOf(address(rp)), rp.reserve0(), "reserve0 == balance");
        assertEq(weth.balanceOf(address(rp)), rp.reserve1(), "reserve1 == balance");
    }
}
