// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "../interfaces/IERC20.sol";
import {ExactTransferLib} from "../libraries/ExactTransferLib.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";

/// @notice EXPERIMENTAL creator-fee collector for a single LOCAL pool harness.
/// Deployed by the pool constructor, so `pool` is fixed at creation and can never be rebound.
/// Claims are permissionless but always pay the immutable `beneficiary`. The collector holds no
/// liquidity shares and has no call path into the pool or bridge (no collateral authority).
contract CreatorFeeCollector is ReentrancyGuard {
    using ExactTransferLib for IERC20;

    /// @dev Same selector as `ExactTransferLib.NonExactTransfer`; declared here for the ABI.
    error NonExactTransfer();
    error ZeroAddress();
    error InvalidBeneficiary();
    error NotPool();
    error UnsupportedToken();
    error ZeroAmount();
    error UnbackedFee();
    error NothingToClaim();

    event FeeAccrued(address indexed token, uint256 amount);
    event FeeClaimed(address indexed token, address indexed beneficiary, address indexed caller, uint256 amount);

    address public immutable beneficiary;
    address public immutable pool;
    address public immutable token0;
    address public immutable token1;

    /// @notice Lifetime fees recorded by the pool, per token.
    mapping(address => uint256) public accrued;
    /// @notice Lifetime fees paid to the beneficiary, per token.
    mapping(address => uint256) public delivered;

    constructor(address beneficiary_, address token0_, address token1_) {
        if (beneficiary_ == address(0) || token0_ == address(0) || token1_ == address(0)) revert ZeroAddress();
        // Self-aliases would make claim deltas net to zero or recycle fees into pool balances.
        if (beneficiary_ == address(this) || beneficiary_ == msg.sender) revert InvalidBeneficiary();
        beneficiary = beneficiary_;
        pool = msg.sender;
        token0 = token0_;
        token1 = token1_;
    }

    /// @notice Records a creator fee the pool has already transferred to this contract.
    function recordFee(address token, uint256 amount) external nonReentrant {
        if (msg.sender != pool) revert NotPool();
        if (token != token0 && token != token1) revert UnsupportedToken();
        if (amount == 0) revert ZeroAmount();
        uint256 newAccrued = accrued[token] + amount;
        if (IERC20(token).balanceOf(address(this)) < newAccrued - delivered[token]) revert UnbackedFee();
        accrued[token] = newAccrued;
        emit FeeAccrued(token, amount);
    }

    /// @notice Pays all undelivered fees of `token` to the fixed beneficiary. Callable by anyone.
    /// The collector must be debited, and the beneficiary credited, exactly `amount`; any mismatch
    /// (e.g. a token tax enabled after accrual) reverts the whole claim, including `delivered`.
    function claim(address token) external nonReentrant returns (uint256 amount) {
        if (token != token0 && token != token1) revert UnsupportedToken();
        amount = accrued[token] - delivered[token];
        if (amount == 0) revert NothingToClaim();
        delivered[token] += amount;
        IERC20(token).pushExact(beneficiary, amount);
        emit FeeClaimed(token, beneficiary, msg.sender, amount);
    }

    function claimable(address token) external view returns (uint256) {
        return accrued[token] - delivered[token];
    }
}
