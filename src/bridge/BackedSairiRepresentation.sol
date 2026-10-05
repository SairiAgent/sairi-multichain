// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "../token/ERC20.sol";
import {BridgeAppBase} from "./BridgeAppBase.sol";

/// @notice EXPERIMENTAL backed representation of the canonical token (LOCAL HARNESS ONLY).
/// Supply is minted exclusively by authenticated, non-replayed lock messages from the peer lockbox and
/// burned when holders bridge back. There is no owner or admin mint.
///
/// The exposure cap bounds outstanding supply. If a credit would exceed it (or the contract is paused)
/// the delivery reverts and the message stays in flight until it can be retried.
contract BackedSairiRepresentation is ERC20, BridgeAppBase {
    constructor(string memory name_, string memory symbol_, uint8 decimals_, BridgeConfig memory cfg)
        ERC20(name_, symbol_, decimals_)
        BridgeAppBase(cfg, decimals_)
    {}

    /// @notice Burns `amountLD` from the caller and emits a release message to the peer lockbox.
    function burnAndSend(uint256 amountLD, address recipient) external nonReentrant returns (uint64 nonce) {
        uint256 amountSD = _prepareOutbound(recipient, amountLD);
        _burn(msg.sender, amountLD);
        nonce = _dispatch(recipient, amountSD);
    }

    function _creditInbound(address recipient, uint256 amountLD) internal override {
        if (totalSupply + amountLD > exposureCap) revert ExposureCapExceeded();
        _mint(recipient, amountLD);
    }
}
