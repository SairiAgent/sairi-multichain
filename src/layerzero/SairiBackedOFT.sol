// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {SendParam, OFTReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";

import {SairiOFTGuards} from "./SairiOFTGuards.sol";

/// @notice EXPERIMENTAL, UNAUDITED backed representation built on LayerZero's OFT (testnet only).
/// Supply is minted exclusively by authenticated LayerZero deliveries from the single canonical-chain
/// adapter peer and burned when holders bridge back. There is no owner or admin mint.
///
/// If a credit would exceed `exposureCap` (or the contract is paused) the delivery reverts and the message
/// stays verified/retryable at the endpoint until it can be executed.
contract SairiBackedOFT is OFT, SairiOFTGuards {
    constructor(
        string memory name_,
        string memory symbol_,
        address endpoint_,
        address owner_,
        GuardConfig memory guards
    ) OFT(name_, symbol_, endpoint_, owner_) SairiOFTGuards(guards) {
        _transferOwnership(owner_); // OpenZeppelin 4.x Ownable starts with the deployer
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
        (amountSentLD, amountReceivedLD) = super._debit(from, amountLD, minAmountLD, dstEid);
        _consumeRate(amountSentLD);
    }

    function _credit(address to, uint256 amountLD, uint32 srcEid) internal override returns (uint256) {
        _assertNotPaused();
        if (totalSupply() + amountLD > exposureCap) revert ExposureCapExceeded();
        return super._credit(to, amountLD, srcEid);
    }
}
