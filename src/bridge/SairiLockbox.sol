// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20, IERC20Metadata} from "../interfaces/IERC20.sol";
import {ExactTransferLib} from "../libraries/ExactTransferLib.sol";
import {BridgeAppBase} from "./BridgeAppBase.sol";

/// @notice EXPERIMENTAL source-chain lockbox for the canonical token (LOCAL HARNESS ONLY).
/// Tokens leave only via an authenticated, non-replayed burn message from the peer representation.
/// There is intentionally no owner withdrawal path.
contract SairiLockbox is BridgeAppBase {
    using ExactTransferLib for IERC20;

    /// @dev Same selector as `ExactTransferLib.NonExactTransfer`; declared here for the ABI.
    error NonExactTransfer();
    error InsufficientBacking();

    IERC20 public immutable token;

    /// @notice Canonical tokens locked as backing (excludes unsolicited donations).
    uint256 public totalLocked;

    constructor(IERC20Metadata token_, BridgeConfig memory cfg) BridgeAppBase(cfg, token_.decimals()) {
        token = token_;
    }

    /// @notice Locks `amountLD` canonical tokens and emits a credit message to the peer representation.
    /// The depositor must be debited, and the lockbox credited, exactly `amountLD`.
    function lockAndSend(uint256 amountLD, address recipient) external nonReentrant returns (uint64 nonce) {
        uint256 amountSD = _prepareOutbound(recipient, amountLD);
        if (totalLocked + amountLD > exposureCap) revert ExposureCapExceeded();

        token.pullExact(msg.sender, amountLD);

        totalLocked += amountLD;
        nonce = _dispatch(recipient, amountSD);
    }

    /// @dev The lockbox must be debited, and the recipient credited, exactly `amountLD`; otherwise the
    /// whole delivery reverts (backing and replay state unchanged) and the message stays retryable.
    function _creditInbound(address recipient, uint256 amountLD) internal override {
        if (amountLD > totalLocked) revert InsufficientBacking();
        totalLocked -= amountLD;
        token.pushExact(recipient, amountLD);
    }
}
