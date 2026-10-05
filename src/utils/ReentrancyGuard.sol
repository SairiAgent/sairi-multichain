// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Single-lock reentrancy guard (original project code).
abstract contract ReentrancyGuard {
    error Reentrancy();

    uint256 private _lock = 1;

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }
}
