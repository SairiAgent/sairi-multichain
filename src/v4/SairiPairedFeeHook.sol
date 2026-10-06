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
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";

/// @notice EXPERIMENTAL, UNAUDITED. Static 1% LP pools plus 0.2% on the paired (non-representation) asset.
/// No transfer tax; fixed beneficiary. Specified-paired swaps require full fill or atomically revert.
/// Unspecified-paired swaps charge actual core delta and permit partial fills. Fees floor in raw units.
contract SairiPairedFeeHook is ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    uint256 public constant FEE_BPS = 20;
    address public constant BENEFICIARY = 0x26250e47500943464290A77ae3508a3001d9B69d;
    uint160 public constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    IPoolManager public immutable manager;
    address public immutable representation;
    mapping(address => uint256) public accrued;
    mapping(address => uint256) public delivered;
    error NotManager();
    error InvalidConfiguration();
    error UnsupportedPool();
    error InvalidDelta();
    error PartialFillUnsupported();
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
            address(key.hooks) != address(this) || key.fee != 10000
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

    function _pairedIs0(PoolKey calldata key) private view returns (bool) {
        return Currency.unwrap(key.currency0) != representation;
    }

    function _specifiedFee(int256 specified) private pure returns (uint256) {
        // Paired input reserves floor(gross budget * 2 / 1002).
        // Paired output reserves floor(net target * 2 / 998).
        if (specified == type(int256).min) revert InvalidDelta();
        uint256 amount = uint256(specified < 0 ? -specified : specified);
        if (amount > uint256(uint128(type(int128).max))) revert InvalidDelta();
        return amount * 2 / (specified < 0 ? 1002 : 998);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _check(key);
        bool specifiedIs0 = params.zeroForOne == (params.amountSpecified < 0);
        uint256 fee;
        if (specifiedIs0 == _pairedIs0(key)) {
            fee = _specifiedFee(params.amountSpecified);
            _accrue(key, fee);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyManager
        returns (bytes4, int128)
    {
        _check(key);
        bool exactInput = params.amountSpecified < 0;
        bool pairedIs0 = _pairedIs0(key);
        int128 raw = pairedIs0 ? delta.amount0() : delta.amount1();
        bool specifiedPaired = (params.zeroForOne == exactInput) == pairedIs0;
        if (specifiedPaired) {
            // The specified fee was reserved before core execution. Never charge an unfilled amount.
            int256 expected = params.amountSpecified + int256(_specifiedFee(params.amountSpecified));
            if (int256(raw) != expected) revert PartialFillUnsupported();
            return (IHooks.afterSwap.selector, 0);
        }
        if ((exactInput && raw < 0) || (!exactInput && raw > 0)) revert InvalidDelta();
        uint256 amount = uint256(raw < 0 ? -int256(raw) : int256(raw));
        uint256 fee = amount * 2 / 1000;
        _accrue(key, fee);
        return (IHooks.afterSwap.selector, int128(int256(fee)));
    }

    function _accrue(PoolKey calldata key, uint256 fee) private {
        if (fee == 0) return;
        address token = Currency.unwrap(_pairedIs0(key) ? key.currency0 : key.currency1);
        accrued[token] += fee;
        manager.mint(address(this), uint256(uint160(token)), fee);
        emit FeeAccrued(PoolId.unwrap(key.toId()), token, fee);
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
