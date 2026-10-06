// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {TestBase} from "../utils/TestBase.sol";
import {MockERC20, FeeOnTransferToken, SenderTaxToken} from "../mocks/MockTokens.sol";
import {SairiPairedFeeHook} from "../../src/v4/SairiPairedFeeHook.sol";
import {SairiPairedHookFactory} from "../../src/v4/SairiPairedHookFactory.sol";
import {ArtifactVm, V4Driver} from "./V4FeeIntegration.t.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract PairedReentrantQuote is MockERC20 {
    SairiPairedFeeHook public hook;
    bool public blocked;
    constructor() MockERC20("Reentrant quote", "RQ", 18) {}

    function arm(SairiPairedFeeHook h) external {
        hook = h;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (address(hook) != address(0)) {
            (bool success,) = address(hook).call(abi.encodeCall(hook.claim, (address(this))));
            blocked = !success;
        }
        _transfer(msg.sender, to, amount);
        return true;
    }
}

contract V4PairedFeeTest is TestBase {
    IPoolManager m;
    SairiPairedFeeHook hook;
    MockERC20 a;
    MockERC20 b;
    V4Driver driver;
    PoolKey key;
    uint160 constant Q96 = 79228162514264337593543950336;

    function setUp() public {
        bytes memory code = abi.encodePacked(
            ArtifactVm(address(vm)).getCode("out/PoolManager.sol/PoolManager.json"), abi.encode(address(0))
        );
        address deployed;
        assembly { deployed := create(0, add(code, 32), mload(code)) }
        m = IPoolManager(deployed);
        MockERC20 x = new MockERC20("A", "A", 18);
        MockERC20 y = new MockERC20("B", "B", 18);
        (a, b) = address(x) < address(y) ? (x, y) : (y, x);
        driver = new V4Driver(m);
        a.mint(address(this), 1e30);
        b.mint(address(this), 1e30);
        a.approve(address(driver), type(uint256).max);
        b.approve(address(driver), type(uint256).max);
        _pool(address(a));
    }

    function _pool(address representation) private {
        SairiPairedHookFactory factory = new SairiPairedHookFactory();
        (bytes32 salt, address predicted) = factory.findSalt(m, representation, 0, 200000);
        hook = factory.deploy(m, representation, salt);
        assertEq(address(hook), predicted, "mined hook");
        key = PoolKey(Currency.wrap(address(a)), Currency.wrap(address(b)), 10000, 60, IHooks(address(hook)));
        m.initialize(key, Q96);
        driver.run(key, 1, 1e24, true, 0, false);
    }

    function _verify(bool direction, bool exactInput, uint256 amount) private {
        address paired = hook.representation() == address(a) ? address(b) : address(a);
        bool pairedIs0 = paired == address(a);
        uint256 beforeFee = hook.accrued(paired);
        BalanceDelta delta = driver.run(
            key, 0, exactInput ? -int256(amount) : int256(amount), direction, direction ? Q96 / 2 : Q96 * 2, false
        );
        uint256 fee = hook.accrued(paired) - beforeFee;
        bool specifiedPaired = (direction == exactInput) == pairedIs0;
        int128 raw = pairedIs0 ? delta.amount0() : delta.amount1();
        if (specifiedPaired) {
            assertTrue(int256(raw) == (exactInput ? -int256(amount) : int256(amount)), "specified preserved");
            assertEq(fee, amount * 2 / (exactInput ? 1002 : 998), "specified reserve");
        } else if (exactInput) {
            assertEq(fee, (uint256(uint128(raw)) + fee) * 2 / 1000, "actual paired output");
        } else {
            assertEq(fee, (uint256(-int256(raw)) - fee) * 2 / 1000, "actual paired input");
        }
        assertEq(hook.accrued(hook.representation()), 0, "representation never taxed");
        uint256 pending = hook.accrued(paired) - hook.delivered(paired);
        assertEq(m.balanceOf(address(hook), uint256(uint160(paired))), pending, "backed credits");
        if (pending > 0) {
            uint256 old = MockERC20(paired).balanceOf(hook.BENEFICIARY());
            vm.prank(address(123));
            hook.claim(paired);
            assertEq(MockERC20(paired).balanceOf(hook.BENEFICIARY()), old + pending, "fixed recipient");
        }
        assertEq(
            a.balanceOf(address(this)) + a.balanceOf(address(m)) + a.balanceOf(hook.BENEFICIARY()),
            a.totalSupply(),
            "A conservation"
        );
        assertEq(
            b.balanceOf(address(this)) + b.balanceOf(address(m)) + b.balanceOf(hook.BENEFICIARY()),
            b.totalSupply(),
            "B conservation"
        );
    }

    function testAllModesAndClaims() public {
        _verify(true, true, 1e18);
        _verify(false, true, 1e18);
        _verify(true, false, 1e18);
        _verify(false, false, 1e18);
    }

    function testReversedRepresentationAllModes() public {
        _pool(address(b));
        _verify(true, true, 1e18);
        _verify(false, true, 1e18);
        _verify(true, false, 1e18);
        _verify(false, false, 1e18);
    }

    function testFuzzFeesAndConservation(uint96 amount, bool direction, bool exactInput) public {
        _verify(direction, exactInput, bound(amount, 10000, 1e20));
    }

    function testRoundingThresholds() public {
        _verify(false, true, 500);
        _verify(false, true, 501);
        _verify(true, false, 498);
        _verify(true, false, 499);
        _verify(true, true, 1);
        _verify(false, false, 1);
    }

    function testSpecifiedPairedPartialFillsRevertAtomically() public {
        uint256 old = b.balanceOf(address(this));
        vm.expectRevert();
        driver.run(key, 0, -int256(1e28), false, Q96 + 1e20, false);
        vm.expectRevert();
        driver.run(key, 0, int256(1e28), true, Q96 - 1e20, false);
        assertEq(hook.accrued(address(b)), 0, "no fee on rejected fill");
        assertEq(b.balanceOf(address(this)), old, "atomic funds");
    }

    function testUnspecifiedPairedPartialFillsChargeActual() public {
        BalanceDelta delta = driver.run(key, 0, -int256(1e28), true, Q96 - 1e20, false);
        uint256 fee = hook.accrued(address(b));
        assertEq(fee, (uint256(uint128(delta.amount1())) + fee) * 2 / 1000, "actual partial output");
        assertTrue(uint256(-int256(delta.amount0())) < 1e28, "partial input");
        delta = driver.run(key, 0, int256(1e28), false, Q96 + 1e20, false);
        uint256 nextFee = hook.accrued(address(b)) - fee;
        assertEq(nextFee, (uint256(-int256(delta.amount1())) - nextFee) * 2 / 1000, "actual partial input");
        assertTrue(uint256(uint128(delta.amount0())) < 1e28, "partial output");
    }

    function testLiquidityTransfersAndDonationsUntaxed() public {
        a.transfer(address(123), 1e18);
        driver.run(key, 1, 1e18, true, 0, false);
        driver.run(key, 2, 1e10, true, 0, false);
        driver.run(key, 1, -int256(1e18), true, 0, false);
        assertEq(hook.accrued(address(b)), 0, "only swaps");
    }

    function testInvalidPoolCallbacksAndSettlementRollback() public {
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.expectRevert();
        m.initialize(wrong, Q96);
        vm.expectRevert();
        hook.beforeSwap(address(this), key, SwapParams(true, -1, Q96 - 1), "");
        vm.expectRevert();
        hook.afterSwap(address(this), key, SwapParams(true, -1, Q96 - 1), BalanceDelta.wrap(0), "");
        vm.expectRevert();
        hook.unlockCallback(abi.encode(address(b), 1));
        vm.expectRevert();
        driver.run(key, 0, -int256(1e18), true, Q96 / 2, true);
        assertEq(hook.accrued(address(b)), 0, "failed settlement rolls fee back");
    }

    function testUnhookedPoolHasNoCreatorFee() public {
        PoolKey memory plain = key;
        plain.hooks = IHooks(address(0));
        m.initialize(plain, Q96);
        driver.run(plain, 1, 1e24, true, 0, false);
        driver.run(plain, 0, -int256(1e18), true, Q96 / 2, false);
        assertEq(hook.accrued(address(b)), 0, "pool-scoped not universal");
    }

    function testTaxEnabledAfterAccrualCannotUnderpayBeneficiary() public {
        FeeOnTransferToken taxed = new FeeOnTransferToken();
        bool direction = address(a) < address(taxed);
        PoolKey memory tk = PoolKey(
            Currency.wrap(direction ? address(a) : address(taxed)),
            Currency.wrap(direction ? address(taxed) : address(a)),
            10000,
            60,
            IHooks(address(hook))
        );
        m.initialize(tk, Q96);
        taxed.mint(address(this), 1e28);
        taxed.approve(address(driver), type(uint256).max);
        driver.run(tk, 1, 1e24, true, 0, false);
        driver.run(tk, 0, -int256(1e18), direction, direction ? Q96 / 2 : Q96 * 2, false);
        uint256 fee = hook.accrued(address(taxed));
        taxed.setFeeOn(true);
        vm.expectRevert(SairiPairedFeeHook.NonExactTransfer.selector);
        hook.claim(address(taxed));
        assertEq(hook.delivered(address(taxed)), 0, "failed claim unchanged");
        assertEq(m.balanceOf(address(hook), uint256(uint160(address(taxed)))), fee, "credits retained");
        taxed.setFeeOn(false);
        hook.claim(address(taxed));
        assertEq(taxed.balanceOf(hook.BENEFICIARY()), fee, "retry");
    }

    function testSenderTaxClaimRejected() public {
        SenderTaxToken taxed = new SenderTaxToken();
        bool direction = address(a) < address(taxed);
        PoolKey memory tk = PoolKey(
            Currency.wrap(direction ? address(a) : address(taxed)),
            Currency.wrap(direction ? address(taxed) : address(a)),
            10000,
            60,
            IHooks(address(hook))
        );
        m.initialize(tk, Q96);
        taxed.mint(address(this), 1e28);
        taxed.approve(address(driver), type(uint256).max);
        driver.run(tk, 1, 1e24, true, 0, false);
        driver.run(tk, 0, -int256(1e18), direction, direction ? Q96 / 2 : Q96 * 2, false);
        taxed.setTaxOn(true);
        vm.expectRevert(SairiPairedFeeHook.NonExactTransfer.selector);
        hook.claim(address(taxed));
        assertEq(hook.delivered(address(taxed)), 0, "no manager subsidy");
    }

    function testTokenCannotReenterClaim() public {
        PairedReentrantQuote quoted = new PairedReentrantQuote();
        bool direction = address(a) < address(quoted);
        PoolKey memory rk = PoolKey(
            Currency.wrap(direction ? address(a) : address(quoted)),
            Currency.wrap(direction ? address(quoted) : address(a)),
            10000,
            60,
            IHooks(address(hook))
        );
        m.initialize(rk, Q96);
        quoted.mint(address(this), 1e28);
        quoted.approve(address(driver), type(uint256).max);
        driver.run(rk, 1, 1e24, true, 0, false);
        driver.run(rk, 0, -int256(1e18), direction, direction ? Q96 / 2 : Q96 * 2, false);
        uint256 fee = hook.accrued(address(quoted));
        quoted.arm(hook);
        hook.claim(address(quoted));
        assertTrue(quoted.blocked(), "reentry blocked");
        assertEq(quoted.balanceOf(hook.BENEFICIARY()), fee, "single payment");
    }
}
