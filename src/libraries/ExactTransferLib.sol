// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "./SafeTransferLib.sol";

/// @notice Transfers validated by balance deltas at BOTH ends: the sender must be debited exactly
/// `amount` and the recipient credited exactly `amount`. Rejects fee/tax tokens on either side,
/// including a tax enabled after funds were deposited. Self-transfers are rejected explicitly because
/// both deltas would net to zero.
/// @dev Assumes `balanceOf` is honest and non-rebasing during the call; arbitrary malicious tokens are
/// out of scope.
library ExactTransferLib {
    using SafeTransferLib for IERC20;

    error NonExactTransfer();
    error SelfTransfer();

    /// @dev Pulls `amount` from `from` into this contract.
    function pullExact(IERC20 token, address from, uint256 amount) internal {
        address to = address(this);
        if (from == to) revert SelfTransfer();
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        token.safeTransferFrom(from, to, amount);
        _checkDebit(token.balanceOf(from), fromBefore, amount);
        _checkCredit(token.balanceOf(to), toBefore, amount);
    }

    /// @dev Pushes `amount` from this contract to `to`.
    function pushExact(IERC20 token, address to, uint256 amount) internal {
        address from = address(this);
        if (from == to) revert SelfTransfer();
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        _checkDebit(token.balanceOf(from), fromBefore, amount);
        _checkCredit(token.balanceOf(to), toBefore, amount);
    }

    function _checkDebit(uint256 balanceAfter, uint256 balanceBefore, uint256 amount) private pure {
        if (balanceAfter > balanceBefore || balanceBefore - balanceAfter != amount) revert NonExactTransfer();
    }

    function _checkCredit(uint256 balanceAfter, uint256 balanceBefore, uint256 amount) private pure {
        if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != amount) revert NonExactTransfer();
    }
}
