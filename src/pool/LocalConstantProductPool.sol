// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "../interfaces/IERC20.sol";
import {ExactTransferLib} from "../libraries/ExactTransferLib.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";
import {CreatorFeeCollector} from "../fees/CreatorFeeCollector.sol";

/// @notice LOCAL HARNESS constant-product pool (e.g. backed-SAIRI / WETH-like test tokens).
/// This is NOT an integration with any real DEX and has no external router.
///
/// Exact-input swaps only:
///   creatorFee = floor(gross * 100 / 10000)                  (input token, sent to the fee collector)
///   lpFee      = floor((gross - creatorFee) * 30 / 10000)     (input token, stays in reserves)
///   net        = gross - creatorFee - lpFee
///   output     = floor(reserveOut * net / (reserveIn + net))
contract LocalConstantProductPool is ReentrancyGuard {
    using ExactTransferLib for IERC20;

    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant CREATOR_FEE_BPS = 100;
    uint256 public constant LP_FEE_BPS = 30;
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;

    error ZeroAddress();
    error IdenticalTokens();
    error UnsupportedToken();
    error InvalidRecipient();
    error ZeroInput();
    error ZeroOutput();
    error MaxInputExceeded();
    error Slippage();
    error NoLiquidity();
    /// @dev Same selector as `ExactTransferLib.NonExactTransfer`; declared here for the ABI.
    error NonExactTransfer();
    error InsufficientShares();
    error InsufficientLiquidityMinted();
    error MinSharesNotMet();
    error MinAmountsNotMet();
    error ExactOutputUnsupported();

    event LiquidityAdded(
        address indexed provider, address indexed to, uint256 amount0, uint256 amount1, uint256 shares
    );
    event LiquidityRemoved(
        address indexed provider, address indexed to, uint256 amount0, uint256 amount1, uint256 shares
    );
    event Swap(
        address indexed sender,
        address indexed tokenIn,
        address indexed recipient,
        uint256 grossInput,
        uint256 creatorFee,
        uint256 lpFee,
        uint256 output
    );

    IERC20 public immutable token0;
    IERC20 public immutable token1;
    CreatorFeeCollector public immutable feeCollector;

    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    constructor(IERC20 token0_, IERC20 token1_, address creatorBeneficiary) {
        if (address(token0_) == address(0) || address(token1_) == address(0)) revert ZeroAddress();
        if (address(token0_) == address(token1_)) revert IdenticalTokens();
        token0 = token0_;
        token1 = token1_;
        feeCollector = new CreatorFeeCollector(creatorBeneficiary, address(token0_), address(token1_));
    }

    // ---------------------------------------------------------------- liquidity (locally supplied assets only)

    /// @notice Adds liquidity from locally supplied assets, consuming at most (`max0`, `max1`).
    /// Integer rounding (S = totalShares, rX = reserveX before the call):
    ///   - First deposit consumes exactly (max0, max1) and mints floor(sqrt(max0 * max1)) shares, of which
    ///     MINIMUM_LIQUIDITY are permanently assigned to address(0); the caller receives the rest.
    ///   - Later deposits mint shares = min(floor(max0 * S / r0), floor(max1 * S / r1)) and consume
    ///     amountX = ceil(shares * rX / S) <= maxX. Rounding the consumed amounts UP means each minted
    ///     share is paid at no less than its pro-rata reserve value (by < 1 wei per token), so existing
    ///     LPs are never diluted, while off-ratio excess is never pulled and stays with the caller.
    /// Reverts on zero input, zero shares, `shares < minShares`, or multiplication overflow.
    function addLiquidity(uint256 max0, uint256 max1, uint256 minShares, address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        _checkRecipient(to);
        (amount0, amount1, shares) = _liquidityAmounts(max0, max1);
        if (shares < minShares) revert MinSharesNotMet();

        uint256 supply = totalShares;
        if (supply == 0) {
            sharesOf[address(0)] = MINIMUM_LIQUIDITY;
            supply = MINIMUM_LIQUIDITY;
        }
        totalShares = supply + shares;
        sharesOf[to] += shares;
        reserve0 += amount0;
        reserve1 += amount1;
        _pullExact(token0, amount0);
        _pullExact(token1, amount1);
        emit LiquidityAdded(msg.sender, to, amount0, amount1, shares);
    }

    /// @notice Burns `shares` for amountX = floor(shares * rX / S). Minima are checked before any state
    /// change or transfer.
    function removeLiquidity(uint256 shares, uint256 minAmount0, uint256 minAmount1, address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroInput();
        _checkRecipient(to);
        if (sharesOf[msg.sender] < shares) revert InsufficientShares();
        (amount0, amount1) = _removalAmounts(shares);
        if (amount0 < minAmount0 || amount1 < minAmount1) revert MinAmountsNotMet();

        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        reserve0 -= amount0;
        reserve1 -= amount1;
        _pushExact(token0, to, amount0);
        _pushExact(token1, to, amount1);
        emit LiquidityRemoved(msg.sender, to, amount0, amount1, shares);
    }

    /// @notice Amounts `addLiquidity(max0, max1, ...)` would consume and shares it would mint now.
    function quoteAddLiquidity(uint256 max0, uint256 max1)
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        return _liquidityAmounts(max0, max1);
    }

    /// @notice Amounts `removeLiquidity(shares, ...)` would return now.
    function quoteRemoveLiquidity(uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        if (shares == 0) revert ZeroInput();
        return _removalAmounts(shares);
    }

    // ---------------------------------------------------------------- swaps

    /// @notice Exact-input swap. Exactly `grossInput` is pulled (must be <= `maxInput`); any other
    /// balance or allowance of the sender is untouched.
    /// @return consumed Input actually pulled from the sender (always `grossInput` on success).
    /// @return output Output token amount sent to `recipient`.
    function swapExactInput(address tokenIn, uint256 grossInput, uint256 maxInput, uint256 minOutput, address recipient)
        external
        nonReentrant
        returns (uint256 consumed, uint256 output)
    {
        if (grossInput == 0) revert ZeroInput();
        if (grossInput > maxInput) revert MaxInputExceeded();
        _checkRecipient(recipient);
        (bool zeroForOne, IERC20 inToken, IERC20 outToken) = _route(tokenIn);

        uint256 creatorFee;
        (creatorFee, output) = _applySwap(zeroForOne, address(inToken), grossInput, minOutput, recipient);

        _pullExact(inToken, grossInput);
        consumed = grossInput;
        if (creatorFee != 0) {
            _pushExact(inToken, address(feeCollector), creatorFee);
            feeCollector.recordFee(address(inToken), creatorFee);
        }
        _pushExact(outToken, recipient, output);
    }

    /// @notice Exact-output swaps are deliberately unsupported in this harness.
    function swapExactOutput(address, uint256, uint256, address) external pure returns (uint256, uint256) {
        revert ExactOutputUnsupported();
    }

    function quoteExactInput(address tokenIn, uint256 grossInput)
        external
        view
        returns (uint256 creatorFee, uint256 lpFee, uint256 output)
    {
        (bool zeroForOne,,) = _route(tokenIn);
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        return _quote(grossInput, reserveIn, reserveOut);
    }

    // ---------------------------------------------------------------- internals

    function _liquidityAmounts(uint256 max0, uint256 max1)
        internal
        view
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        if (max0 == 0 || max1 == 0) revert ZeroInput();
        uint256 supply = totalShares;
        if (supply == 0) {
            shares = _sqrt(max0 * max1);
            if (shares <= MINIMUM_LIQUIDITY) revert InsufficientLiquidityMinted();
            return (max0, max1, shares - MINIMUM_LIQUIDITY);
        }
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        uint256 s0 = max0 * supply / r0;
        uint256 s1 = max1 * supply / r1;
        shares = s0 < s1 ? s0 : s1;
        if (shares == 0) revert InsufficientLiquidityMinted();
        amount0 = _ceilDiv(shares * r0, supply);
        amount1 = _ceilDiv(shares * r1, supply);
    }

    function _removalAmounts(uint256 shares) internal view returns (uint256 amount0, uint256 amount1) {
        uint256 supply = totalShares;
        if (shares > supply) revert InsufficientShares();
        amount0 = shares * reserve0 / supply;
        amount1 = shares * reserve1 / supply;
        if (amount0 == 0 || amount1 == 0) revert ZeroOutput();
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev Quotes, enforces output bounds and updates reserves. The LP fee stays in reserves; only the
    /// creator fee leaves the input side. Token transfers are performed by the caller.
    function _applySwap(bool zeroForOne, address inToken, uint256 grossInput, uint256 minOutput, address recipient)
        internal
        returns (uint256 creatorFee, uint256 output)
    {
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 lpFee;
        (creatorFee, lpFee, output) = _quote(grossInput, reserveIn, reserveOut);
        if (output == 0) revert ZeroOutput();
        if (output < minOutput) revert Slippage();

        if (zeroForOne) {
            reserve0 = reserveIn + grossInput - creatorFee;
            reserve1 = reserveOut - output;
        } else {
            reserve1 = reserveIn + grossInput - creatorFee;
            reserve0 = reserveOut - output;
        }
        emit Swap(msg.sender, inToken, recipient, grossInput, creatorFee, lpFee, output);
    }

    function _quote(uint256 grossInput, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 creatorFee, uint256 lpFee, uint256 output)
    {
        if (reserveIn == 0 || reserveOut == 0) revert NoLiquidity();
        creatorFee = grossInput * CREATOR_FEE_BPS / FEE_DENOMINATOR;
        lpFee = (grossInput - creatorFee) * LP_FEE_BPS / FEE_DENOMINATOR;
        uint256 net = grossInput - creatorFee - lpFee;
        output = reserveOut * net / (reserveIn + net);
    }

    function _route(address tokenIn) internal view returns (bool zeroForOne, IERC20 inToken, IERC20 outToken) {
        if (tokenIn == address(token0)) return (true, token0, token1);
        if (tokenIn == address(token1)) return (false, token1, token0);
        revert UnsupportedToken();
    }

    function _checkRecipient(address to) internal view {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this) || to == address(feeCollector)) revert InvalidRecipient();
    }

    /// @dev Sender debited and pool credited exactly `amount`; rejects fee/tax on either side.
    function _pullExact(IERC20 token, uint256 amount) internal {
        token.pullExact(msg.sender, amount);
    }

    /// @dev Pool debited and `to` credited exactly `amount`; rejects fee/tax on either side.
    function _pushExact(IERC20 token, address to, uint256 amount) internal {
        token.pushExact(to, amount);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
