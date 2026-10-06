// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import {SendParam, OFTReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";

import {IERC20 as ISairiERC20} from "../interfaces/IERC20.sol";
import {ExactTransferLib} from "../libraries/ExactTransferLib.sol";
import {SairiOFTGuards} from "./SairiOFTGuards.sol";

/// @notice EXPERIMENTAL, UNAUDITED canonical-chain lockbox built on LayerZero's OFTAdapter (testnet only).
/// Locks the canonical token and releases it only on authenticated LayerZero deliveries from the single
/// configured peer. There is no owner withdrawal path.
///
/// Differences from the upstream default OFTAdapter:
/// - exact-transfer checks on both sender and recipient (fee/tax tokens revert instead of under-backing);
/// - `totalLocked` tracks backing (excludes donations) and bounds every release, so even a forged delivery
///   cannot release more than was locked through this adapter;
/// - single peer route, set once; pause; outbound rate limit; exposure cap on `totalLocked`;
/// - dust, compose messages and invalid recipients are rejected at the source.
///
/// Upstream warning applies: only ONE adapter may exist for a token in a mesh.
contract SairiOFTAdapter is OFTAdapter, SairiOFTGuards {
    using ExactTransferLib for ISairiERC20;

    error InsufficientBacking();

    /// @notice Canonical tokens locked as backing for the remote representation.
    uint256 public totalLocked;

    /// @dev `owner_` becomes both the Ownable owner and the LayerZero endpoint delegate (non-zero enforced
    /// by OAppCore). OpenZeppelin 4.x Ownable starts with the deployer, so ownership is moved explicitly.
    constructor(address token_, address endpoint_, address owner_, GuardConfig memory guards)
        OFTAdapter(token_, endpoint_, owner_)
        SairiOFTGuards(guards)
    {
        _transferOwnership(owner_);
    }

    function renounceOwnership() public view override(Ownable, SairiOFTGuards) {
        super.renounceOwnership();
    }

    function setPeer(uint32 eid, bytes32 newPeer) public override onlyOwner {
        _assertPeerUpdate(eid, newPeer, peers[eid]);
        _setPeer(eid, newPeer);
    }

    function _send(SendParam calldata sendParam, MessagingFee calldata fee, address refundAddress)
        internal
        override
        returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt)
    {
        _assertOutbound(sendParam.dstEid, sendParam.to, sendParam.composeMsg.length, peers[sendParam.dstEid]);
        return super._send(sendParam, fee, refundAddress);
    }

    function _debitView(uint256 amountLD, uint256 minAmountLD, uint32 dstEid)
        internal
        view
        override
        returns (uint256 amountSentLD, uint256 amountReceivedLD)
    {
        if (amountLD % decimalConversionRate != 0) revert DustAmount(amountLD);
        return super._debitView(amountLD, minAmountLD, dstEid);
    }

    function _debit(address from, uint256 amountLD, uint256 minAmountLD, uint32 dstEid)
        internal
        override
        returns (uint256 amountSentLD, uint256 amountReceivedLD)
    {
        _assertNotPaused();
        (amountSentLD, amountReceivedLD) = _debitView(amountLD, minAmountLD, dstEid);
        _consumeRate(amountSentLD);
        if (totalLocked + amountSentLD > exposureCap) revert ExposureCapExceeded();
        ISairiERC20(address(innerToken)).pullExact(from, amountSentLD);
        totalLocked += amountSentLD;
    }

    /// @dev Reverts (message stays retryable at the endpoint) when paused, under-backed or non-exact.
    function _credit(address to, uint256 amountLD, uint32) internal override returns (uint256 amountReceivedLD) {
        _assertNotPaused();
        if (amountLD > totalLocked) revert InsufficientBacking();
        if (to == address(0)) to = address(0xdead);
        totalLocked -= amountLD;
        ISairiERC20(address(innerToken)).pushExact(to, amountLD);
        return amountLD;
    }
}
