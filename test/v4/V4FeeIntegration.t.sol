// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {TestBase} from "../utils/TestBase.sol";
import {MockERC20, FeeOnTransferToken, SenderTaxToken} from "../mocks/MockTokens.sol";
import {SairiCreatorFeeHook} from "../../src/v4/SairiCreatorFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface ArtifactVm {
    function getCode(string calldata) external returns (bytes memory);
}

/// @dev TEST driver only, not a user-facing router. Real manager enforces settlement.
contract V4Driver {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function run(PoolKey memory key, uint8 op, int256 amount, bool direction, uint160 limit, bool cheat)
        external
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(key, op, amount, direction, limit, cheat, msg.sender)), (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, uint8 op, int256 amount, bool direction, uint160 limit, bool cheat, address payer) =
            abi.decode(data, (PoolKey, uint8, int256, bool, uint160, bool, address));
        BalanceDelta delta;
        if (op == 0) delta = manager.swap(key, SwapParams(direction, amount, limit), hex"feedface");
        else if (op == 1) (delta,) = manager.modifyLiquidity(key, ModifyLiquidityParams(-600, 600, amount, 0), "");
        else delta = manager.donate(key, uint256(amount), uint256(amount), "");
        if (!cheat) _settle(key.currency0, delta.amount0(), payer);
        _settle(key.currency1, delta.amount1(), payer);
        return abi.encode(delta);
    }

    function _settle(Currency asset, int128 delta, address payer) internal {
        if (delta < 0) {
            manager.sync(asset);
            if (Currency.unwrap(asset) == address(0)) {
                manager.settle{value: uint256(-int256(delta))}();
            } else {
                MockERC20(Currency.unwrap(asset)).transferFrom(payer, address(manager), uint256(-int256(delta)));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(asset, payer, uint128(delta));
        }
    }
}

contract ReentrantQuote is MockERC20 {
    SairiCreatorFeeHook public hook;
    bool public blocked;
    constructor() MockERC20("Reentrant quote", "RQ", 18) {}

    function arm(SairiCreatorFeeHook h) external {
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

contract V4FeeIntegrationTest is TestBase {
    IPoolManager m;
    SairiCreatorFeeHook hook;
    MockERC20 a;
    MockERC20 b;
    V4Driver driver;
    PoolKey key;
    uint160 constant Q96 = 79228162514264337593543950336;

    function setUp() public {
        bytes memory code = abi.encodePacked(
            ArtifactVm(address(vm)).getCode("out/PoolManager.sol/PoolManager.json"), abi.encode(address(this))
        );
        address deployed;
        assembly { deployed := create(0, add(code, 32), mload(code)) }
        require(deployed != address(0));
        m = IPoolManager(deployed);
        MockERC20 x = new MockERC20("A", "A", 18);
        MockERC20 y = new MockERC20("B", "B", 18);
        (a, b) = address(x) < address(y) ? (x, y) : (y, x);
        bytes memory init = abi.encodePacked(type(SairiCreatorFeeHook).creationCode, abi.encode(m, address(a)));
        bytes32 hash = keccak256(init);
        uint256 salt;
        for (;; salt++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), hash))))
            );
            if (uint160(predicted) & 16383 == 8256 + 4) break;
        }
        hook = new SairiCreatorFeeHook{salt: bytes32(salt)}(m, address(a));
        key = PoolKey(Currency.wrap(address(a)), Currency.wrap(address(b)), 3000, 60, IHooks(address(hook)));
        m.initialize(key, Q96);
        driver = new V4Driver(m);
        a.mint(address(this), 1e30);
        b.mint(address(this), 1e30);
        a.approve(address(driver), type(uint256).max);
        b.approve(address(driver), type(uint256).max);
        driver.run(key, 1, 1e24, true, 0, false);
    }

    function limit(bool direction) internal pure returns (uint160) {
        return direction ? Q96 / 2 : Q96 * 2;
    }

    function swap(bool direction, bool exactInput, uint256 amount) internal returns (BalanceDelta delta) {
        delta = driver.run(key, 0, exactInput ? -int256(amount) : int256(amount), direction, limit(direction), false);
    }

    function verifySwap(bool direction, bool exactInput) internal {
        address asset = direction == exactInput ? address(b) : address(a);
        uint256 beforeFee = hook.accrued(asset);
        uint256 supply = a.totalSupply();
        BalanceDelta delta = swap(direction, exactInput, 1e18);
        uint256 fee = hook.accrued(asset) - beforeFee;
        int128 raw = asset == address(a) ? delta.amount0() : delta.amount1();
        if (exactInput) assertEq(fee, (uint256(uint128(raw)) + fee) / 100, "output fee");
        else assertEq(fee, uint256(-int256(raw)) / 100, "gross input fee");
        assertTrue(fee > 0, "fee accrued");
        assertEq(a.totalSupply(), supply, "no mint burn");
        assertEq(m.balanceOf(address(hook), uint256(uint160(asset))), fee, "backed manager credit");
        uint256 bal = MockERC20(asset).balanceOf(hook.BENEFICIARY());
        vm.prank(address(123));
        hook.claim(asset);
        assertEq(MockERC20(asset).balanceOf(hook.BENEFICIARY()), bal + fee, "fixed recipient");
        assertEq(m.balanceOf(address(hook), uint256(uint160(asset))), 0, "credit consumed");
    }

    function testExactInputSell() public {
        verifySwap(true, true);
    }

    function testExactInputBuy() public {
        verifySwap(false, true);
    }

    function testExactOutputSell() public {
        verifySwap(true, false);
    }

    function testExactOutputBuy() public {
        verifySwap(false, false);
    }

    function testWalletTransferLiquidityAndDonationUntaxed() public {
        a.transfer(address(123), 1e18);
        driver.run(key, 1, 1e18, true, 0, false);
        driver.run(key, 2, 1e10, true, 0, false);
        driver.run(key, 1, 0, true, 0, false);
        driver.run(key, 1, -int256(1e18), true, 0, false);
        assertEq(hook.accrued(address(a)) + hook.accrued(address(b)), 0, "no non-swap tax");
    }

    function testPartialFillChargesActualOutput() public {
        BalanceDelta delta = driver.run(key, 0, -int256(1e28), true, Q96 - 1e20, false);
        uint256 fee = hook.accrued(address(b));
        assertEq(fee, (uint256(uint128(delta.amount1())) + fee) / 100, "actual output only");
        assertTrue(uint256(-int256(delta.amount0())) < 1e28, "partial consumed");
    }

    function testUnhookedPoolBypassesCreatorFeeExplicitly() public {
        key.hooks = IHooks(address(0));
        m.initialize(key, Q96);
        driver.run(key, 1, 1e24, true, 0, false);
        swap(true, true, 1e18);
        assertEq(hook.accrued(address(a)) + hook.accrued(address(b)), 0, "universal coverage impossible");
    }

    function testDifferentRouterCannotBypassHook() public {
        V4Driver other = new V4Driver(m);
        a.approve(address(other), type(uint256).max);
        b.approve(address(other), type(uint256).max);
        other.run(key, 0, -int256(1e18), false, limit(false), false);
        assertTrue(hook.accrued(address(a)) > 0, "any router through pool");
    }

    function testUnsettledMaliciousRouterRevertsAndRollsBackFee() public {
        vm.expectRevert();
        driver.run(key, 0, -int256(1e18), true, limit(true), true);
        assertEq(hook.accrued(address(b)), 0, "atomic rollback");
    }

    function testSpoofedCallbackRejected() public {
        vm.expectRevert(SairiCreatorFeeHook.NotManager.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -100, 1), BalanceDelta.wrap(0), "");
        vm.expectRevert(SairiCreatorFeeHook.NotManager.selector);
        hook.unlockCallback(abi.encode(address(a), 100));
    }

    function testUnrelatedPoolRejected() public {
        MockERC20 c = new MockERC20("C", "C", 18);
        MockERC20 d = new MockERC20("D", "D", 18);
        key.currency0 = Currency.wrap(address(c) < address(d) ? address(c) : address(d));
        key.currency1 = Currency.wrap(address(c) < address(d) ? address(d) : address(c));
        vm.expectRevert();
        m.initialize(key, Q96);
    }

    function testDustAndNoDoubleClaim() public {
        swap(true, true, 99);
        assertEq(hook.accrued(address(b)), 0, "dust rounds down");
        vm.expectRevert(SairiCreatorFeeHook.NothingToClaim.selector);
        hook.claim(address(b));
        swap(true, true, 1e18);
        hook.claim(address(b));
        vm.expectRevert(SairiCreatorFeeHook.NothingToClaim.selector);
        hook.claim(address(b));
    }

    function testTaxedInputFailsRealManagerSettlement() public {
        FeeOnTransferToken taxed = new FeeOnTransferToken();
        PoolKey memory tk = PoolKey(
            Currency.wrap(address(a) < address(taxed) ? address(a) : address(taxed)),
            Currency.wrap(address(a) < address(taxed) ? address(taxed) : address(a)),
            3000,
            60,
            IHooks(address(hook))
        );
        m.initialize(tk, Q96);
        taxed.mint(address(this), 1e28);
        taxed.approve(address(driver), type(uint256).max);
        driver.run(tk, 1, 1e24, true, 0, false);
        taxed.setFeeOn(true);
        bool direction = address(taxed) < address(a);
        vm.expectRevert();
        driver.run(tk, 0, -int256(1e18), direction, limit(direction), false);
        assertEq(hook.accrued(address(taxed)), 0, "tax input rolled back");
    }

    function testTaxEnabledAfterAccrualCannotUnderpayBeneficiary() public {
        FeeOnTransferToken taxed = new FeeOnTransferToken();
        bool direction = address(a) < address(taxed);
        PoolKey memory tk = PoolKey(
            Currency.wrap(direction ? address(a) : address(taxed)),
            Currency.wrap(direction ? address(taxed) : address(a)),
            3000,
            60,
            IHooks(address(hook))
        );
        m.initialize(tk, Q96);
        taxed.mint(address(this), 1e28);
        taxed.approve(address(driver), type(uint256).max);
        driver.run(tk, 1, 1e24, true, 0, false);
        driver.run(tk, 0, -int256(1e18), direction, limit(direction), false);
        uint256 fee = hook.accrued(address(taxed));
        taxed.setFeeOn(true);
        vm.expectRevert(SairiCreatorFeeHook.NonExactTransfer.selector);
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
            3000,
            60,
            IHooks(address(hook))
        );
        m.initialize(tk, Q96);
        taxed.mint(address(this), 1e28);
        taxed.approve(address(driver), type(uint256).max);
        driver.run(tk, 1, 1e24, true, 0, false);
        driver.run(tk, 0, -int256(1e18), direction, limit(direction), false);
        taxed.setTaxOn(true);
        vm.expectRevert(SairiCreatorFeeHook.NonExactTransfer.selector);
        hook.claim(address(taxed));
        assertEq(hook.delivered(address(taxed)), 0, "no manager subsidy");
    }

    function testTokenCannotReenterClaim() public {
        ReentrantQuote quoted = new ReentrantQuote();
        bool direction = address(a) < address(quoted);
        PoolKey memory rk = PoolKey(
            Currency.wrap(direction ? address(a) : address(quoted)),
            Currency.wrap(direction ? address(quoted) : address(a)),
            3000,
            60,
            IHooks(address(hook))
        );
        m.initialize(rk, Q96);
        quoted.mint(address(this), 1e28);
        quoted.approve(address(driver), type(uint256).max);
        driver.run(rk, 1, 1e24, true, 0, false);
        driver.run(rk, 0, -int256(1e18), direction, limit(direction), false);
        uint256 fee = hook.accrued(address(quoted));
        quoted.arm(hook);
        hook.claim(address(quoted));
        assertTrue(quoted.blocked(), "reentry blocked");
        assertEq(quoted.balanceOf(hook.BENEFICIARY()), fee, "single payment");
    }
    receive() external payable {}

    function testNativeEthFeeClaim() public {
        PoolKey memory nativeKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(a)), 3000, 60, IHooks(address(hook)));
        m.initialize(nativeKey, Q96);
        vm.deal(address(driver), 1e28);
        driver.run(nativeKey, 1, 1e24, true, 0, false);
        driver.run(nativeKey, 0, int256(1e18), true, limit(true), false);
        driver.run(nativeKey, 0, -int256(1e18), false, limit(false), false);
        uint256 fee = hook.accrued(address(0));
        uint256 bal = hook.BENEFICIARY().balance;
        assertTrue(fee > 0, "native accrued");
        hook.claim(address(0));
        assertEq(hook.BENEFICIARY().balance, bal + fee, "native claim");
    }

    function testExactOutputPartialFillChargesActualInput() public {
        BalanceDelta delta = driver.run(key, 0, int256(1e28), true, Q96 - 1e20, false);
        uint256 fee = hook.accrued(address(a));
        assertEq(fee, uint256(-int256(delta.amount0())) / 100, "partial actual input");
        assertTrue(uint256(uint128(delta.amount1())) < 1e28, "not requested full output");
    }

    function testFuzzFeeBasis(bool direction, bool exactInput, uint96 amount) public {
        uint256 value = bound(amount, 10000, 1e22);
        address asset = direction == exactInput ? address(b) : address(a);
        BalanceDelta d = swap(direction, exactInput, value);
        uint256 fee = hook.accrued(asset);
        int128 raw = asset == address(a) ? d.amount0() : d.amount1();
        assertEq(fee, exactInput ? (uint256(uint128(raw)) + fee) / 100 : uint256(-int256(raw)) / 100, "fee basis");
    }
}
