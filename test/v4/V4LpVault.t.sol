// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {TestBase} from "../utils/TestBase.sol";
import {MockERC20, FeeOnTransferToken} from "../mocks/MockTokens.sol";
import {V4Driver, ArtifactVm} from "./V4FeeIntegration.t.sol";
import {SairiV4LpVault} from "../../src/v4/SairiV4LpVault.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract VaultReentrantToken is MockERC20 {
    SairiV4LpVault public vault;
    bool public blocked;
    constructor() MockERC20("Reentrant", "RE", 18) {}

    function arm(SairiV4LpVault v) external {
        vault = v;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (address(vault) != address(0)) {
            (bool success,) = address(vault).call(abi.encodeCall(vault.harvest, ()));
            blocked = !success;
        }
        _transfer(msg.sender, to, amount);
        return true;
    }
}

contract V4LpVaultTest is TestBase {
    IPoolManager m;
    MockERC20 a;
    MockERC20 b;
    V4Driver driver;
    SairiV4LpVault vault;
    PoolKey key;
    address constant FIRST = 0x26250e47500943464290A77ae3508a3001d9B69d;
    address constant SECOND = address(456);
    uint160 constant Q96 = 79228162514264337593543950336;

    function setUp() public {
        bytes memory code = abi.encodePacked(
            ArtifactVm(address(vm)).getCode("out/PoolManager.sol/PoolManager.json"), abi.encode(address(this))
        );
        address deployed;
        assembly { deployed := create(0, add(code, 32), mload(code)) }
        m = IPoolManager(deployed);
        MockERC20 x = new MockERC20("A", "A", 18);
        MockERC20 y = new MockERC20("B", "B", 18);
        (a, b) = address(x) < address(y) ? (x, y) : (y, x);
        key = PoolKey(Currency.wrap(address(a)), Currency.wrap(address(b)), 10000, 60, IHooks(address(0)));
        m.initialize(key, Q96);
        vault = new SairiV4LpVault(m, key, -600, 600, address(this), FIRST, SECOND);
        driver = new V4Driver(m);
        a.mint(address(this), 1e30);
        b.mint(address(this), 1e30);
        a.approve(address(vault), type(uint256).max);
        b.approve(address(vault), type(uint256).max);
        a.approve(address(driver), type(uint256).max);
        b.approve(address(driver), type(uint256).max);
        vault.modify(1e24, 1e30, 1e30, block.timestamp);
    }

    function swap(bool direction, bool exactInput) internal returns (BalanceDelta) {
        return
            driver.run(
                key, 0, exactInput ? -int256(1e18) : int256(1e18), direction, direction ? Q96 / 2 : Q96 * 2, false
            );
    }

    function verify(bool direction, bool exactInput) internal {
        BalanceDelta delta = swap(direction, exactInput);
        uint256 input = uint256(-int256(direction ? delta.amount0() : delta.amount1()));
        uint256 output = uint256(uint128(direction ? delta.amount1() : delta.amount0()));
        assertEq(exactInput ? input : output, 1e18, "specified amount, no additive tax");
        vault.harvest();
        address asset = direction ? address(a) : address(b);
        uint256 fee = vault.earned(asset);
        // FeeGrowth truncation costs at most one raw unit here; core rounds swap fees upward.
        assertLe(fee, (input + 99) / 100, "at most one percent of gross input");
        assertGe(fee + 2, input / 100, "one percent LP accrual rounding");
        vm.prank(address(777));
        vault.claim(asset);
        assertEq(MockERC20(asset).balanceOf(FIRST), fee * 60 / 100, "60 percent earned fees");
        assertEq(MockERC20(asset).balanceOf(SECOND), fee - fee * 60 / 100, "40 percent earned fees");
        assertEq(m.balanceOf(address(vault), uint256(uint160(asset))), 0, "credits fully paid");
        assertEq(vault.liquidity(), 1e24, "claim never withdraws liquidity");
    }

    function testExactInputBothDirections() public {
        verify(true, true);
        verify(false, true);
    }

    function testExactOutputBothDirections() public {
        verify(true, false);
        verify(false, false);
    }

    function testPrincipalCannotBeClaimedAndFullWithdrawal() public {
        uint256 beforeA = a.balanceOf(address(this));
        vault.harvest();
        vault.claim(address(a));
        assertEq(a.balanceOf(FIRST), 0, "principal not fees");
        vault.modify(-int256(1e24), 0, 0, block.timestamp);
        assertTrue(a.balanceOf(address(this)) > beforeA, "principal owner refund");
        assertEq(vault.earned(address(a)), 0, "withdrawal not fees");
        assertEq(vault.liquidity(), 0, "closed");
    }

    function testWithdrawalSeparatesEarnedFeesAndPrincipal() public {
        swap(true, true);
        vault.modify(-int256(1e24), 0, 0, block.timestamp);
        assertTrue(vault.earned(address(a)) > 0, "fees still credited on withdrawal");
        assertEq(a.balanceOf(FIRST), 0, "no implicit distribution");
        vault.claim(address(a));
        assertTrue(a.balanceOf(FIRST) > 0, "only rewards distributed");
    }

    function testOtherLiquidityOwnsItsOwnFees() public {
        driver.run(key, 1, 1e24, true, 0, false);
        swap(true, true);
        vault.harvest();
        uint256 ourFees = vault.earned(address(a));
        assertLe(ourFees, 5e15, "half active liquidity earns half fees");
        assertGe(ourFees, 5e15 - 2, "not all pool fees");
        uint256 beforeA = a.balanceOf(address(this));
        driver.run(key, 1, 0, true, 0, false);
        assertEq(a.balanceOf(address(this)) - beforeA, ourFees, "external LP reward untouched");
    }

    function testPermissionsDeadlineLimitsAndSpoofing() public {
        vm.prank(address(123));
        vm.expectRevert();
        vault.modify(1, 10, 10, block.timestamp);
        vm.expectRevert();
        vault.unlockCallback(abi.encode(uint8(0), int256(0), uint256(0), uint256(0)));
        vm.expectRevert();
        vault.modify(1e24, 0, 0, block.timestamp);
        vm.expectRevert();
        vault.modify(-int256(1e24), 1e30, 1e30, block.timestamp);
        vm.warp(10);
        vm.expectRevert();
        vault.modify(1, 1e30, 1e30, 9);
        assertEq(vault.liquidity(), 1e24, "all failed changes rollback");
    }

    function testSettlementFailureRollsBackPosition() public {
        a.approve(address(vault), 0);
        vm.expectRevert();
        vault.modify(1e24, 1e30, 1e30, block.timestamp);
        assertEq(vault.liquidity(), 1e24, "no phantom liquidity");
        a.approve(address(vault), type(uint256).max);
        vault.modify(1e24, 1e30, 1e30, block.timestamp);
        assertEq(vault.liquidity(), 2e24, "retry");
    }

    function testPartialFillOnlyActualInputPaysFee() public {
        BalanceDelta delta = driver.run(key, 0, -int256(1e28), true, Q96 - 1e20, false);
        uint256 input = uint256(-int256(delta.amount0()));
        vault.harvest();
        assertTrue(input < 1e28, "partial");
        assertLe(vault.earned(address(a)), (input + 99) / 100, "actual input fee");
    }

    function testDirectDonationNotDistributableCoreDonationIsLpReward() public {
        a.transfer(address(vault), 12345);
        vault.harvest();
        vault.claim(address(a));
        assertEq(a.balanceOf(FIRST), 0, "direct balance never becomes fee");
        driver.run(key, 2, 1e18, true, 0, false);
        vault.harvest();
        assertGe(vault.earned(address(a)), 1e18 - 1, "core donate intentionally is LP feeGrowth");
        vault.claim(address(a));
        assertEq(a.balanceOf(address(vault)), 12345, "direct donation remains isolated");
    }

    function testCumulativeSplitNoDoubleClaim() public {
        for (uint256 i; i < 3; i++) {
            swap(true, true);
            vault.harvest();
            vault.claim(address(a));
        }
        uint256 earned = vault.earned(address(a));
        assertEq(a.balanceOf(FIRST), earned * 60 / 100, "cumulative rounding");
        vault.claim(address(a));
        assertEq(a.balanceOf(FIRST), earned * 60 / 100, "no double payment");
    }

    function testUnsettledRouterRollsBackFees() public {
        vm.expectRevert();
        driver.run(key, 0, -int256(1e18), true, Q96 / 2, true);
        vault.harvest();
        assertEq(vault.earned(address(a)), 0, "no fees from failed swap");
    }

    function testReentrantClaimCannotHarvestAgain() public {
        VaultReentrantToken token = new VaultReentrantToken();
        PoolKey memory k = PoolKey(
            Currency.wrap(address(token) < address(a) ? address(token) : address(a)),
            Currency.wrap(address(token) < address(a) ? address(a) : address(token)),
            10000,
            60,
            IHooks(address(0))
        );
        m.initialize(k, Q96);
        SairiV4LpVault v = new SairiV4LpVault(m, k, -600, 600, address(this), FIRST, SECOND);
        token.mint(address(this), 1e30);
        token.approve(address(v), type(uint256).max);
        token.approve(address(driver), type(uint256).max);
        a.approve(address(v), type(uint256).max);
        v.modify(1e24, 1e30, 1e30, block.timestamp);
        bool direction = address(token) < address(a);
        driver.run(k, 0, -int256(1e18), direction, direction ? Q96 / 2 : Q96 * 2, false);
        v.harvest();
        token.arm(v);
        v.claim(address(token));
        assertTrue(token.blocked(), "reentrancy blocked");
    }

    function testTaxedClaimRetainsCreditsForRetry() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        PoolKey memory k = PoolKey(
            Currency.wrap(address(token) < address(a) ? address(token) : address(a)),
            Currency.wrap(address(token) < address(a) ? address(a) : address(token)),
            10000,
            60,
            IHooks(address(0))
        );
        m.initialize(k, Q96);
        SairiV4LpVault v = new SairiV4LpVault(m, k, -600, 600, address(this), FIRST, SECOND);
        token.mint(address(this), 1e30);
        token.approve(address(v), type(uint256).max);
        token.approve(address(driver), type(uint256).max);
        a.approve(address(v), type(uint256).max);
        v.modify(1e24, 1e30, 1e30, block.timestamp);
        bool direction = address(token) < address(a);
        driver.run(k, 0, -int256(1e18), direction, direction ? Q96 / 2 : Q96 * 2, false);
        v.harvest();
        uint256 fees = v.earned(address(token));
        token.setFeeOn(true);
        vm.expectRevert();
        v.claim(address(token));
        assertEq(v.paidFirst(address(token)), 0, "claim rollback");
        assertEq(m.balanceOf(address(v), uint256(uint160(address(token)))), fees, "backed credit retained");
        token.setFeeOn(false);
        v.claim(address(token));
        assertEq(token.balanceOf(FIRST), fees * 60 / 100, "retry paid");
    }
}
