// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";

/// @notice EXPERIMENTAL, UNAUDITED. 1% on actual unspecified swap asset, ONLY in pools using this hook.
/// No token transfer tax. No admin, upgrades, fee setters, external router trust, or bridge authority.
/// Exact input: floor(output / 100). Exact output: floor(actual pool input / 99) added to input.
/// Creator claims are ERC6909 credits against the manager, not bridge collateral or LP positions.
contract SairiCreatorFeeHook is ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    uint256 public constant FEE_BPS = 100;
    address public constant BENEFICIARY = 0x26250e47500943464290A77ae3508a3001d9B69d;
    uint160 public constant FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    IPoolManager public immutable manager;
    address public immutable representation;
    mapping(address => uint256) public accrued;
    mapping(address => uint256) public delivered;
    error NotManager();
    error InvalidConfiguration();
    error UnsupportedPool();
    error InvalidDelta();
    error NothingToClaim();
    error NonExactTransfer();
    event FeeAccrued(bytes32 indexed poolId, address indexed asset, uint256 amount);
    event FeeClaimed(address indexed asset, uint256 amount);

    constructor(IPoolManager manager_, address representation_) {
        if (
            address(manager_).code.length == 0 || representation_.code.length == 0
                || address(manager_) == representation_ || representation_ == BENEFICIARY
                || uint160(address(this)) & Hooks.ALL_HOOK_MASK != FLAGS
        ) revert InvalidConfiguration();
        manager = manager_;
        representation = representation_;
    }
    modifier onlyManager() {
        if (msg.sender != address(manager)) revert NotManager();
        _;
    }

    function _check(PoolKey calldata key) internal view {
        if (
            address(key.hooks) != address(this)
                || (Currency.unwrap(key.currency0) != representation
                    && Currency.unwrap(key.currency1) != representation)
        ) {
            revert UnsupportedPool();
        }
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyManager returns (bytes4) {
        _check(key);
        return IHooks.beforeInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyManager
        returns (bytes4, int128)
    {
        _check(key);
        bool exactInput = params.amountSpecified < 0;
        bool unspecifiedIs0 = params.zeroForOne != exactInput;
        int128 raw = unspecifiedIs0 ? delta.amount0() : delta.amount1();
        if ((exactInput && raw < 0) || (!exactInput && raw > 0)) revert InvalidDelta();
        uint256 amount = uint256(exactInput ? int256(raw) : -int256(raw));
        // floor(input / 99) satisfies fee == floor((input + fee) / 100).
        uint256 fee = amount / (exactInput ? 100 : 99);
        if (fee > uint256(uint128(type(int128).max))) revert InvalidDelta();
        if (fee != 0) {
            Currency asset = unspecifiedIs0 ? key.currency0 : key.currency1;
            address token = Currency.unwrap(asset);
            accrued[token] += fee;
            // No external token call in swap callback. Mint internal manager claims.
            manager.mint(address(this), uint256(uint160(token)), fee);
            emit FeeAccrued(PoolId.unwrap(key.toId()), token, fee);
        }
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    function claim(address asset) external nonReentrant returns (uint256 amount) {
        amount = accrued[asset] - delivered[asset];
        if (amount == 0) revert NothingToClaim();
        delivered[asset] += amount;
        manager.unlock(abi.encode(asset, amount));
        emit FeeClaimed(asset, amount);
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        (address asset, uint256 amount) = abi.decode(data, (address, uint256));
        Currency currency = Currency.wrap(asset);
        uint256 beforeBalance = currency.balanceOf(BENEFICIARY);
        uint256 managerBefore = currency.balanceOf(address(manager));
        manager.burn(address(this), uint256(uint160(asset)), amount);
        manager.take(currency, BENEFICIARY, amount);
        if (
            currency.balanceOf(BENEFICIARY) != beforeBalance + amount
                || currency.balanceOf(address(manager)) != managerBefore - amount
        ) revert NonExactTransfer();
        return bytes("");
    }
}
