// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";

/// @notice EXPERIMENTAL LP-position custody, NOT a transfer tax or universal DEX revenue claim.
/// One static-1% pool with an explicitly selected hook (or none), ERC20 pairs only. Only this position's earned fees split 60/40.
/// Operator can withdraw principal: NOT a liquidity lock. No shares, upgrades or rescue authority.
contract SairiV4LpVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;
    address public immutable operator;
    address public immutable firstRecipient;
    address public immutable secondRecipient;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    PoolKey private key;
    uint128 public liquidity;
    bool private active;
    mapping(address => uint256) public earned;
    mapping(address => uint256) public paidFirst;
    mapping(address => uint256) public paidSecond;
    event FeesHarvested(address indexed asset, uint256 amount);
    event FeesClaimed(address indexed asset, uint256 firstAmount, uint256 secondAmount);
    event PositionChanged(int256 liquidityDelta, int128 principal0, int128 principal1);
    error InvalidConfiguration();
    error Unauthorized();
    error Limits();
    error NonExactTransfer();

    constructor(IPoolManager m, PoolKey memory k, int24 lower, int24 upper, address op, address first, address second) {
        if (
            address(m).code.length == 0 || op == address(0) || first == address(0) || second == address(0)
                || k.fee != 10000 || k.tickSpacing <= 0 || lower >= upper || lower % k.tickSpacing != 0
                || upper % k.tickSpacing != 0 || Currency.unwrap(k.currency0) >= Currency.unwrap(k.currency1)
                || Currency.unwrap(k.currency0).code.length == 0 || Currency.unwrap(k.currency1).code.length == 0
                || first == address(m) || second == address(m) || first == address(this) || second == address(this)
        ) {
            revert InvalidConfiguration();
        }
        manager = m;
        key = k;
        tickLower = lower;
        tickUpper = upper;
        operator = op;
        firstRecipient = first;
        secondRecipient = second;
    }

    function poolKey() external view returns (PoolKey memory) {
        return key;
    }

    /// @param limit0 Max principal spent when adding, minimum principal received when removing.
    /// @param limit1 Same bound for currency1. Fees never satisfy withdrawal minima.
    function modify(int256 change, uint256 limit0, uint256 limit1, uint256 deadline) external nonReentrant {
        if (msg.sender != operator) revert Unauthorized();
        if (
            block.timestamp > deadline || change == 0 || change > int256(uint256(type(uint128).max))
                || change < -int256(uint256(liquidity))
        ) revert Limits();
        if (change > 0) liquidity += uint128(uint256(change));
        else liquidity -= uint128(uint256(-change));
        _modify(change, limit0, limit1);
    }

    function harvest() external nonReentrant {
        _modify(0, 0, 0);
    }

    function _modify(int256 change, uint256 limit0, uint256 limit1) private {
        active = true;
        manager.unlock(abi.encode(uint8(0), change, limit0, limit1));
        active = false;
    }

    function claim(address asset) external nonReentrant {
        if (asset != Currency.unwrap(key.currency0) && asset != Currency.unwrap(key.currency1)) {
            revert InvalidConfiguration();
        }
        uint256 total = earned[asset];
        uint256 firstTotal = total / 100 * 60 + total % 100 * 60 / 100;
        uint256 first = firstTotal - paidFirst[asset];
        uint256 second = total - firstTotal - paidSecond[asset];
        paidFirst[asset] = firstTotal;
        paidSecond[asset] = total - firstTotal;
        active = true;
        manager.unlock(abi.encode(uint8(1), asset, first, second));
        active = false;
        emit FeesClaimed(asset, first, second);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager) || !active) revert Unauthorized();
        uint8 op = abi.decode(data, (uint8));
        if (op == 0) {
            (, int256 change, uint256 limit0, uint256 limit1) = abi.decode(data, (uint8, int256, uint256, uint256));
            (BalanceDelta delta, BalanceDelta fees) =
                manager.modifyLiquidity(key, ModifyLiquidityParams(tickLower, tickUpper, change, bytes32(0)), "");
            BalanceDelta principal = delta - fees;
            _book(key.currency0, fees.amount0());
            _book(key.currency1, fees.amount1());
            _principal(key.currency0, principal.amount0(), change, limit0);
            _principal(key.currency1, principal.amount1(), change, limit1);
            emit PositionChanged(change, principal.amount0(), principal.amount1());
        } else {
            (, address asset, uint256 first, uint256 second) = abi.decode(data, (uint8, address, uint256, uint256));
            manager.burn(address(this), uint256(uint160(asset)), first + second);
            _take(Currency.wrap(asset), firstRecipient, first);
            _take(Currency.wrap(asset), secondRecipient, second);
        }
        return "";
    }

    function _book(Currency currency, int128 amount) private {
        if (amount < 0) revert NonExactTransfer();
        if (amount == 0) return;
        address asset = Currency.unwrap(currency);
        earned[asset] += uint128(amount);
        manager.mint(address(this), uint256(uint160(asset)), uint128(amount));
        emit FeesHarvested(asset, uint128(amount));
    }

    function _principal(Currency currency, int128 amount, int256 change, uint256 limit) private {
        if (change > 0) {
            if (amount > 0 || uint256(-int256(amount)) > limit) revert Limits();
        } else if (amount < 0 || uint256(uint128(amount)) < limit) {
            revert Limits();
        }
        if (amount < 0) {
            uint256 debt = uint256(-int256(amount));
            manager.sync(currency);
            uint256 beforeBalance = currency.balanceOf(operator);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(operator, address(manager), debt);
            if (manager.settle() != debt || currency.balanceOf(operator) != beforeBalance - debt) {
                revert NonExactTransfer();
            }
        } else if (amount > 0) {
            _take(currency, operator, uint128(amount));
        }
    }

    function _take(Currency currency, address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeBalance = currency.balanceOf(to);
        uint256 managerBefore = currency.balanceOf(address(manager));
        manager.take(currency, to, amount);
        if (
            currency.balanceOf(to) != beforeBalance + amount
                || currency.balanceOf(address(manager)) != managerBefore - amount
        ) revert NonExactTransfer();
    }
}
