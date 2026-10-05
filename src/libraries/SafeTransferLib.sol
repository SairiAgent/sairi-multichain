// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "../interfaces/IERC20.sol";

/// @notice Transfer helpers tolerating tokens that return no data, rejecting `false` and codeless targets.
library SafeTransferLib {
    error TransferFailed();
    error TransferFromFailed();

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!_succeeded(address(token), ok, data)) revert TransferFailed();
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!_succeeded(address(token), ok, data)) revert TransferFromFailed();
    }

    function _succeeded(address token, bool ok, bytes memory data) private view returns (bool) {
        if (!ok) return false;
        if (data.length == 0) return token.code.length != 0;
        if (data.length != 32) return false;
        return abi.decode(data, (bool));
    }
}
