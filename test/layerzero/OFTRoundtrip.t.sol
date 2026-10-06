// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Errors} from "@layerzerolabs/lz-evm-protocol-v2/contracts/libs/Errors.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";

import {SairiOFTAdapter} from "../../src/layerzero/SairiOFTAdapter.sol";
import {SairiBackedOFT} from "../../src/layerzero/SairiBackedOFT.sol";
import {SairiOFTGuards} from "../../src/layerzero/SairiOFTGuards.sol";
import {ExactTransferLib} from "../../src/libraries/ExactTransferLib.sol";
import {FeeOnTransferToken} from "../mocks/MockTokens.sol";
import {LzOFTFixture} from "./LzOFTFixture.sol";

/// @notice Local integration tests: SAIRI OFTAdapter / backed OFT over genuine pinned LayerZero EndpointV2 +
/// ULN302 code. Test-only DVN/executor workers. Not a live testnet result.
contract OFTRoundtripTest is LzOFTFixture {
    /// Backing invariant: locked canonical == representation supply + in-flight (both directions).
    function _assertBacked(uint256 inFlightToRobinhood, uint256 inFlightToBase, string memory step) internal view {
        assertEq(adapter.totalLocked(), backed.totalSupply() + inFlightToRobinhood + inFlightToBase, step);
        assertEq(token.balanceOf(address(adapter)), adapter.totalLocked(), "no donations: observed == tracked");
    }

    function test_roundtrip_baseToRobinhoodAndBack() public {
        uint256 start = token.balanceOf(USER);

        Packet memory out = _sendFromBase(USER, USER, 100e18);
        assertEq(out.srcEid, EID_BASE_SEPOLIA, "src eid");
        assertEq(out.dstEid, EID_ROBINHOOD_TESTNET, "dst eid");
        assertEq(out.sender, _b32(address(adapter)), "sender is adapter");
        assertEq(out.receiver, address(backed), "receiver is backed OFT");
        assertEq(_amountLD(out), 100e18, "encoded amount");
        assertEq(token.balanceOf(USER), start - 100e18, "debited exactly");
        _assertBacked(100e18, 0, "locked, in flight");

        _deliver(out);
        assertEq(backed.balanceOf(USER), 100e18, "minted on representation");
        _assertBacked(0, 0, "delivered");

        Packet memory back = _sendFromRobinhood(USER, USER, 40e18);
        assertEq(back.sender, _b32(address(backed)), "return sender");
        assertEq(back.receiver, address(adapter), "return receiver");
        assertEq(backed.totalSupply(), 60e18, "burned on send");
        _assertBacked(0, 40e18, "burned, in flight back");

        _deliver(back);
        assertEq(token.balanceOf(USER), start - 60e18, "released exactly");
        _assertBacked(0, 0, "returned");

        Packet memory rest = _sendFromRobinhood(USER, USER, 60e18);
        _deliver(rest);
        assertEq(token.balanceOf(USER), start, "full roundtrip restores canonical balance");
        assertEq(adapter.totalLocked(), 0, "nothing locked");
        assertEq(backed.totalSupply(), 0, "no representation supply");
    }

    /// The testnet script enforces 120,000 lzReceive gas; executor gas covers EndpointV2.lzReceive including
    /// payload clearing. Keep a margin for cold recipients on both directions.
    function test_lzReceiveGas_fitsEnforcedOptionWithMargin() public {
        uint256 budget = 90_000; // 75% of the scripted 120,000
        Packet memory out = _sendFromBase(USER, OTHER, 3e18); // fresh recipient: cold balance slot
        _verify(out);
        uint256 before = gasleft();
        _execute(out);
        uint256 used = before - gasleft();
        assertLe(used, budget, "mint-side lzReceive gas");

        Packet memory back = _sendFromRobinhood(OTHER, address(0xF00D), 3e18); // fresh canonical recipient
        _verify(back);
        before = gasleft();
        _execute(back);
        used = before - gasleft();
        assertLe(used, budget, "release-side lzReceive gas");
    }

    function test_quote_paysRealLibraryWorkers() public {
        SendParam memory p = _param(EID_ROBINHOOD_TESTNET, USER, 1e18);
        MessagingFee memory fee = adapter.quoteSend(p, false);
        assertEq(fee.nativeFee, DVN_FEE + EXECUTOR_FEE, "ULN302 quote = DVN + executor (no treasury)");
        _sendFromBase(USER, USER, 1e18);
        assertEq(base.sendLib.fees(address(base.dvn)), DVN_FEE, "DVN fee accrued in SendUln302");
        assertEq(base.sendLib.fees(address(base.executor)), EXECUTOR_FEE, "executor fee accrued");
        assertEq(base.dvn.jobs(), 1, "DVN job assigned");
    }

    function test_underpaidFee_reverts() public {
        SendParam memory p = _param(EID_ROBINHOOD_TESTNET, USER, 1e18);
        MessagingFee memory fee = adapter.quoteSend(p, false);
        fee.nativeFee -= 1;
        vm.startPrank(USER);
        token.approve(address(adapter), 1e18);
        vm.expectRevert();
        adapter.send{value: fee.nativeFee}(p, fee, USER);
        vm.stopPrank();
        _assertBacked(0, 0, "nothing locked");
    }

    function test_unverifiedPacket_cannotExecute() public {
        Packet memory out = _sendFromBase(USER, USER, 5e18);
        vm.expectRevert(abi.encodeWithSelector(Errors.LZ_InvalidNonce.selector, uint64(1)));
        _execute(out);
        assertEq(backed.totalSupply(), 0, "no credit without verification");
    }

    function test_commitWithoutDvnAttestation_reverts() public {
        Packet memory out = _sendFromBase(USER, USER, 5e18);
        vm.expectRevert(abi.encodeWithSignature("LZ_ULN_Verifying()"));
        robinhood.receiveLib.commitVerification(out.header, out.payloadHash);
    }

    function test_insufficientConfirmations_reverts() public {
        Packet memory out = _sendFromBase(USER, USER, 5e18);
        robinhood.dvn.attest(robinhood.receiveLib, out.header, out.payloadHash, CONFIRMATIONS - 1);
        vm.expectRevert(abi.encodeWithSignature("LZ_ULN_Verifying()"));
        robinhood.receiveLib.commitVerification(out.header, out.payloadHash);
    }

    function test_replay_rejectedByEndpoint() public {
        Packet memory out = _sendFromBase(USER, USER, 5e18);
        _deliver(out);
        vm.expectRevert(abi.encodeWithSelector(Errors.LZ_PayloadHashNotFound.selector, bytes32(0), out.payloadHash));
        _execute(out);
        robinhood.dvn.attest(robinhood.receiveLib, out.header, out.payloadHash, CONFIRMATIONS);
        vm.expectRevert(); // nonce already executed: the endpoint refuses to re-verify it
        robinhood.receiveLib.commitVerification(out.header, out.payloadHash);
        assertEq(backed.totalSupply(), 5e18, "credited once");
    }

    function test_tamperedMessage_cannotExecute() public {
        Packet memory out = _sendFromBase(USER, USER, 5e18);
        _verify(out);
        bytes memory forged = out.message;
        forged[39] = bytes1(uint8(forged[39]) + 1); // bump amountSD
        out.message = forged;
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.LZ_PayloadHashNotFound.selector, out.payloadHash, keccak256(abi.encodePacked(out.guid, forged))
            )
        );
        _execute(out);
    }

    function test_nonPeerSender_rejectedAtDelivery() public {
        // An attacker deploys its own adapter on the Base side pointing at the real representation.
        SairiOFTAdapter rogue =
            new SairiOFTAdapter(address(token), address(base.endpoint), OTHER, _guards(EID_ROBINHOOD_TESTNET));
        vm.startPrank(OTHER);
        rogue.setPeer(EID_ROBINHOOD_TESTNET, _b32(address(backed)));
        rogue.setEnforcedOptions(_enforced(EID_ROBINHOOD_TESTNET));
        vm.stopPrank();
        token.mint(OTHER, 1e18);
        SendParam memory p = _param(EID_ROBINHOOD_TESTNET, OTHER, 1e18);
        MessagingFee memory fee = rogue.quoteSend(p, false);
        vm.startPrank(OTHER);
        token.approve(address(rogue), 1e18);
        vm.recordLogs();
        rogue.send{value: fee.nativeFee}(p, fee, OTHER);
        vm.stopPrank();
        Packet memory pkt = _capture(base);
        robinhood.dvn.attest(robinhood.receiveLib, pkt.header, pkt.payloadHash, CONFIRMATIONS);
        // The path is not initializable for an unknown peer, so the endpoint refuses the commit.
        vm.expectRevert(Errors.LZ_PathNotInitializable.selector);
        robinhood.receiveLib.commitVerification(pkt.header, pkt.payloadHash);
        assertEq(backed.totalSupply(), 0, "no unbacked mint");
    }

    function test_setPeer_onceOnly_singleEid_nonZero() public {
        vm.startPrank(OWNER);
        vm.expectRevert(SairiOFTGuards.PeerAlreadySet.selector);
        adapter.setPeer(EID_ROBINHOOD_TESTNET, _b32(OTHER));
        vm.expectRevert(abi.encodeWithSelector(SairiOFTGuards.UnsupportedEid.selector, uint32(30184)));
        adapter.setPeer(30184, _b32(OTHER));
        vm.stopPrank();

        SairiBackedOFT fresh =
            new SairiBackedOFT("x", "x", address(robinhood.endpoint), OWNER, _guards(EID_BASE_SEPOLIA));
        vm.prank(OWNER);
        vm.expectRevert(SairiOFTGuards.InvalidPeer.selector);
        fresh.setPeer(EID_BASE_SEPOLIA, bytes32(0));
        vm.prank(OTHER);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        fresh.setPeer(EID_BASE_SEPOLIA, _b32(address(adapter)));
    }

    function test_invalidOutboundRequests_rejected() public {
        vm.startPrank(USER);
        token.approve(address(adapter), type(uint256).max);
        SendParam memory p = _param(EID_ROBINHOOD_TESTNET, USER, 1e18 + 1);
        p.minAmountLD = 0;
        vm.expectRevert(abi.encodeWithSelector(SairiOFTGuards.DustAmount.selector, 1e18 + 1));
        adapter.send{value: 1 ether}(p, MessagingFee(1 ether, 0), USER);

        p = _param(EID_ROBINHOOD_TESTNET, address(0), 1e18);
        vm.expectRevert(SairiOFTGuards.InvalidSendRecipient.selector);
        adapter.send{value: 1 ether}(p, MessagingFee(1 ether, 0), USER);

        p = _param(EID_ROBINHOOD_TESTNET, address(backed), 1e18);
        vm.expectRevert(SairiOFTGuards.InvalidSendRecipient.selector);
        adapter.send{value: 1 ether}(p, MessagingFee(1 ether, 0), USER);

        p = _param(EID_ROBINHOOD_TESTNET, USER, 1e18);
        p.to = bytes32(type(uint256).max); // not an EVM address
        vm.expectRevert(SairiOFTGuards.InvalidSendRecipient.selector);
        adapter.send{value: 1 ether}(p, MessagingFee(1 ether, 0), USER);

        p = _param(EID_ROBINHOOD_TESTNET, USER, 1e18);
        p.composeMsg = hex"01";
        vm.expectRevert(SairiOFTGuards.ComposeUnsupported.selector);
        adapter.send{value: 1 ether}(p, MessagingFee(1 ether, 0), USER);

        p = _param(30416, USER, 1e18); // mainnet Robinhood EID: not the configured route
        vm.expectRevert(abi.encodeWithSelector(SairiOFTGuards.UnsupportedEid.selector, uint32(30416)));
        adapter.send{value: 1 ether}(p, MessagingFee(1 ether, 0), USER);
        vm.stopPrank();
        _assertBacked(0, 0, "nothing locked");
    }

    function test_pause_blocksSend_inboundStaysRetryable() public {
        Packet memory out = _sendFromBase(USER, USER, 7e18);
        vm.prank(OWNER);
        backed.setPaused(true);
        _verify(out);
        vm.expectRevert(SairiOFTGuards.GuardPaused.selector);
        _execute(out);
        assertEq(backed.totalSupply(), 0, "paused: no credit");
        _assertBacked(7e18, 0, "still in flight");

        vm.prank(OWNER);
        backed.setPaused(false);
        _execute(out); // retry of the already-verified packet
        assertEq(backed.balanceOf(USER), 7e18, "credited after unpause");

        vm.prank(OWNER);
        adapter.setPaused(true);
        SendParam memory p = _param(EID_ROBINHOOD_TESTNET, USER, 1e18);
        vm.startPrank(USER);
        token.approve(address(adapter), 1e18);
        vm.expectRevert(SairiOFTGuards.GuardPaused.selector);
        adapter.send{value: 1 ether}(p, MessagingFee(1 ether, 0), USER);
        vm.stopPrank();
    }

    function test_exposureCap_outboundAndInbound() public {
        vm.prank(OWNER);
        adapter.setExposureCap(10e18);
        Packet memory a = _sendFromBase(USER, USER, 10e18);
        SendParam memory p = _param(EID_ROBINHOOD_TESTNET, USER, 1e18);
        vm.startPrank(USER);
        token.approve(address(adapter), 1e18);
        vm.expectRevert(SairiOFTGuards.ExposureCapExceeded.selector);
        adapter.send{value: 1 ether}(p, MessagingFee(1 ether, 0), USER);
        vm.stopPrank();

        vm.prank(OWNER);
        backed.setExposureCap(9e18);
        _verify(a);
        vm.expectRevert(SairiOFTGuards.ExposureCapExceeded.selector);
        _execute(a);
        vm.prank(OWNER);
        backed.setExposureCap(10e18);
        _execute(a);
        _assertBacked(0, 0, "delivered after cap raised");
    }

    function test_rateLimit_perWindow() public {
        vm.prank(OWNER);
        adapter.setRateLimit(5e18);
        _sendFromBase(USER, USER, 5e18);
        SendParam memory p = _param(EID_ROBINHOOD_TESTNET, USER, 1e18);
        vm.startPrank(USER);
        token.approve(address(adapter), 1e18);
        vm.expectRevert(SairiOFTGuards.RateLimitExceeded.selector);
        adapter.send{value: 1 ether}(p, MessagingFee(1 ether, 0), USER);
        vm.stopPrank();
        vm.warp(block.timestamp + WINDOW);
        _sendFromBase(USER, USER, 1e18);
    }

    function test_feeOnTransferToken_rejected() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        SairiOFTAdapter fotAdapter =
            new SairiOFTAdapter(address(fot), address(base.endpoint), OWNER, _guards(EID_ROBINHOOD_TESTNET));
        vm.startPrank(OWNER);
        fotAdapter.setPeer(EID_ROBINHOOD_TESTNET, _b32(address(backed)));
        fotAdapter.setEnforcedOptions(_enforced(EID_ROBINHOOD_TESTNET));
        vm.stopPrank();
        fot.mint(USER, 10e18);
        fot.setFeeOn(true);
        SendParam memory p = _param(EID_ROBINHOOD_TESTNET, USER, 1e18);
        MessagingFee memory fee = fotAdapter.quoteSend(p, false);
        vm.startPrank(USER);
        fot.approve(address(fotAdapter), 1e18);
        vm.expectRevert(ExactTransferLib.NonExactTransfer.selector);
        fotAdapter.send{value: fee.nativeFee}(p, fee, USER);
        vm.stopPrank();
        assertEq(fotAdapter.totalLocked(), 0, "no under-backed lock");
    }

    /// RESIDUAL RISK demonstration: a compromised verifier configuration on the Base side can forge a
    /// "release" from the peer. The adapter bounds it by `totalLocked`, but a forged release within backing
    /// succeeds and leaves the representation under-backed. Verifier choice is a trust assumption.
    function test_compromisedVerifier_forgedRelease_boundedByTotalLocked() public {
        Packet memory out = _sendFromBase(USER, USER, 10e18);
        _deliver(out);

        Packet memory forged = _forgedRelease(1, OTHER, 11e18);
        _verify(forged);
        vm.expectRevert(SairiOFTAdapter.InsufficientBacking.selector);
        _execute(forged);

        Packet memory within = _forgedRelease(1, OTHER, 10e18);
        _verify(within);
        _execute(within);
        assertEq(token.balanceOf(OTHER), 10e18, "forged release within backing succeeds");
        assertEq(adapter.totalLocked(), 0, "backing drained");
        assertEq(backed.totalSupply(), 10e18, "representation now UNBACKED");
    }

    function test_ownerCannotMintOrWithdraw() public {
        Packet memory out = _sendFromBase(USER, USER, 10e18);
        _deliver(out);
        // No mint/withdraw entry points exist; the only owner levers are the documented guard/LZ settings.
        (bool ok,) = address(adapter).call(abi.encodeWithSignature("withdraw(address,uint256)", OWNER, 1));
        assertTrue(!ok, "no withdraw");
        (ok,) = address(backed).call(abi.encodeWithSignature("mint(address,uint256)", OWNER, 1));
        assertTrue(!ok, "no mint");
        vm.prank(OWNER);
        vm.expectRevert(SairiOFTGuards.InvalidGuardConfig.selector);
        adapter.renounceOwnership(); // cannot strand a paused route
        assertEq(adapter.owner(), OWNER, "owner kept");
        assertEq(token.balanceOf(address(adapter)), 10e18, "backing intact");
    }

    function _forgedRelease(uint64 nonce, address to, uint256 amountLD) internal view returns (Packet memory pkt) {
        pkt.srcEid = EID_ROBINHOOD_TESTNET;
        pkt.dstEid = EID_BASE_SEPOLIA;
        pkt.nonce = nonce;
        pkt.sender = _b32(address(backed));
        pkt.receiver = address(adapter);
        pkt.guid = keccak256(abi.encodePacked("forged", nonce));
        pkt.header = abi.encodePacked(
            uint8(1), nonce, EID_ROBINHOOD_TESTNET, pkt.sender, EID_BASE_SEPOLIA, _b32(address(adapter))
        );
        pkt.message = abi.encodePacked(_b32(to), uint64(amountLD / CONVERSION));
        pkt.payloadHash = keccak256(abi.encodePacked(pkt.guid, pkt.message));
    }

    function test_endpointOrigin_isAuthenticated() public {
        // Direct calls to the OApp receive hook are rejected; only the endpoint may deliver.
        vm.expectRevert();
        backed.lzReceive(
            Origin(EID_BASE_SEPOLIA, _b32(address(adapter)), 1),
            bytes32(0),
            abi.encodePacked(_b32(USER), uint64(1)),
            address(0),
            ""
        );
    }
}
