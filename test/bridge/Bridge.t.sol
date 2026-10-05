// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BridgeFixture} from "../utils/BridgeFixture.sol";
import {LocalEndpointMock} from "../mocks/LocalEndpointMock.sol";
import {FeeOnTransferToken} from "../mocks/MockTokens.sol";
import {BridgeAppBase} from "../../src/bridge/BridgeAppBase.sol";
import {SairiLockbox} from "../../src/bridge/SairiLockbox.sol";
import {BackedSairiRepresentation} from "../../src/bridge/BackedSairiRepresentation.sol";

/// @notice LOCAL HARNESS bridge tests. Delivery is driven by `LocalEndpointMock`; no LayerZero.
contract BridgeTest is BridgeFixture {
    uint256 internal constant BIG = type(uint128).max;

    function setUp() public {
        vm.warp(1_000 * WINDOW);
        _deployBridge(BIG, BIG, BIG, BIG);
        _fundAndApprove(ALICE, 100e18);
    }

    // ---------------------------------------------------------------- roundtrip

    function test_roundtrip_tracksInflightAndConvertsDecimals() public {
        _assertConservation();

        uint256 lockId = _lock(ALICE, 4e18, BOB);
        assertEq(lockbox.totalLocked(), 4e18, "locked");
        assertEq(rep.totalSupply(), 0, "nothing minted before delivery");
        assertEq(_inFlightSD(endpointA, address(lockbox)), 4e6, "P = 4e6 SD");
        assertEq(lockbox.outboundAmountSD(1), 4e6, "outbound record");
        _assertConservation();

        assertTrue(endpointA.relay(lockId), "credit delivered");
        assertEq(rep.balanceOf(BOB), 4e12, "18 -> 6 -> 12 decimals");
        assertEq(_inFlightSD(endpointA, address(lockbox)), 0, "P cleared");
        _assertConservation();

        uint256 burnId = _burn(BOB, 1.5e12, ALICE);
        assertEq(rep.totalSupply(), 2.5e12, "burned");
        assertEq(_inFlightSD(endpointB, address(rep)), 1.5e6, "Q = 1.5e6 SD");
        assertEq(lockbox.totalLocked(), 4e18, "not released before delivery");
        _assertConservation();

        assertTrue(endpointB.relay(burnId), "release delivered");
        assertEq(canonical.balanceOf(ALICE), 96e18 + 1.5e18, "released 1.5e18");
        assertEq(lockbox.totalLocked(), 2.5e18, "locked reduced");
        _assertConservation();
    }

    function test_multipleInflightMessages_outOfOrderDelivery() public {
        uint256 id1 = _lock(ALICE, 1e18, BOB);
        uint256 id2 = _lock(ALICE, 2e18, BOB);
        uint256 id3 = _lock(ALICE, 3e18, ALICE);
        _assertConservation();
        assertEq(_inFlightSD(endpointA, address(lockbox)), 6e6, "P");

        endpointA.relay(id3);
        _assertConservation();
        endpointA.relay(id1);
        _assertConservation();
        assertEq(_inFlightSD(endpointA, address(lockbox)), 2e6, "P after two");
        endpointA.relay(id2);
        _assertConservation();
        assertEq(rep.balanceOf(BOB), 3e12, "bob");
        assertEq(rep.balanceOf(ALICE), 3e12, "alice");
    }

    function test_conversionParameters() public view {
        assertEq(lockbox.conversionRate(), CANON_RATE, "canonical rate");
        assertEq(rep.conversionRate(), REP_RATE, "representation rate");
        assertEq(rep.decimals(), REP_DECIMALS, "rep decimals");
        assertEq(lockbox.peer(), _b32(address(rep)), "lockbox peer");
        assertEq(rep.peer(), _b32(address(lockbox)), "rep peer");
    }

    // ---------------------------------------------------------------- dust / input validation

    function test_dust_rejectedOnLock() public {
        vm.expectRevert(BridgeAppBase.Dust.selector);
        vm.prank(ALICE);
        lockbox.lockAndSend(1e12 + 1, BOB);
    }

    function test_dust_rejectedOnBurn() public {
        endpointA.relay(_lock(ALICE, 1e18, BOB));
        vm.expectRevert(BridgeAppBase.Dust.selector);
        vm.prank(BOB);
        rep.burnAndSend(1e6 - 1, ALICE);
    }

    function test_zeroAmountAndRecipientRejected() public {
        vm.expectRevert(BridgeAppBase.ZeroAmount.selector);
        vm.prank(ALICE);
        lockbox.lockAndSend(0, BOB);

        vm.expectRevert(BridgeAppBase.InvalidRecipient.selector);
        vm.prank(ALICE);
        lockbox.lockAndSend(1e18, address(0));
    }

    function test_feeOnTransferCanonical_rejected() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        SairiLockbox fotBox = new SairiLockbox(fot, _cfg(address(endpointA), EID_A, EID_B, address(0xCAFE), BIG, BIG));
        fot.mint(ALICE, 10e18);
        fot.setFeeOn(true);
        vm.prank(ALICE);
        fot.approve(address(fotBox), type(uint256).max);

        vm.expectRevert(SairiLockbox.NonExactTransfer.selector);
        vm.prank(ALICE);
        fotBox.lockAndSend(1e18, BOB);
        assertEq(fotBox.totalLocked(), 0, "nothing locked");
    }

    // ---------------------------------------------------------------- authentication / replay

    function test_auth_directCallRejected() public {
        bytes memory payload = abi.encode(MALLORY, uint256(1e6));
        vm.expectRevert(BridgeAppBase.UnauthorizedEndpoint.selector);
        vm.prank(MALLORY);
        rep.receiveMessage(EID_A, _b32(address(lockbox)), 1, payload);

        // The owner has no mint or release authority either.
        vm.expectRevert(BridgeAppBase.UnauthorizedEndpoint.selector);
        vm.prank(OWNER);
        lockbox.receiveMessage(EID_B, _b32(address(rep)), 1, payload);
        assertEq(rep.totalSupply(), 0, "no mint");
    }

    function test_auth_wrongPeerOrSourceRejected() public {
        bytes memory payload = abi.encode(MALLORY, uint256(1e6));
        vm.expectRevert(BridgeAppBase.UnauthorizedPeer.selector);
        endpointB.rawDeliver(address(rep), EID_A, _b32(MALLORY), 1, payload);

        vm.expectRevert(BridgeAppBase.UnauthorizedPeer.selector);
        endpointB.rawDeliver(address(rep), 999, _b32(address(lockbox)), 1, payload);
        _assertConservation();
    }

    function test_malformedPayloadRejected() public {
        vm.expectRevert(BridgeAppBase.InvalidMessage.selector);
        endpointB.rawDeliver(address(rep), EID_A, _b32(address(lockbox)), 7, hex"1234");

        vm.expectRevert(BridgeAppBase.InvalidMessage.selector);
        endpointB.rawDeliver(address(rep), EID_A, _b32(address(lockbox)), 7, abi.encode(BOB, uint256(0)));
    }

    function test_replay_rejected() public {
        uint256 id = _lock(ALICE, 2e18, BOB);
        endpointA.relay(id);
        LocalEndpointMock.Message memory m = endpointA.messageAt(id);

        vm.expectRevert(BridgeAppBase.Replay.selector);
        endpointB.rawDeliver(address(rep), m.srcEid, m.sender, m.nonce, m.payload);

        vm.expectRevert(LocalEndpointMock.NotRetryable.selector);
        endpointA.relay(id);

        assertEq(rep.totalSupply(), 2e12, "single mint");
        _assertConservation();
    }

    function test_forgedOverRelease_rejectedByBacking() public {
        endpointA.relay(_lock(ALICE, 1e18, BOB));
        // A compromised endpoint replaying the peer identity cannot release more than is locked.
        vm.expectRevert(SairiLockbox.InsufficientBacking.selector);
        endpointA.rawDeliver(address(lockbox), EID_B, _b32(address(rep)), 99, abi.encode(MALLORY, uint256(2e6)));
        assertEq(lockbox.totalLocked(), 1e18, "backing intact");
    }

    // ---------------------------------------------------------------- failed delivery and retry

    function test_failedCredit_retriedAfterUnpause() public {
        vm.prank(OWNER);
        rep.setPaused(true);

        uint256 id = _lock(ALICE, 3e18, BOB);
        assertTrue(!endpointA.relay(id), "credit fails while paused");
        assertTrue(endpointA.statusOf(id) == LocalEndpointMock.Status.Failed, "failed status");
        assertEq(_inFlightSD(endpointA, address(lockbox)), 3e6, "still in flight");
        _assertConservation();

        assertTrue(!endpointA.relay(id), "retry still fails");
        _assertConservation();

        vm.prank(OWNER);
        rep.setPaused(false);
        assertTrue(endpointA.relay(id), "retry succeeds");
        assertEq(rep.balanceOf(BOB), 3e12, "credited once");
        _assertConservation();

        vm.expectRevert(LocalEndpointMock.NotRetryable.selector);
        endpointA.relay(id);
    }

    function test_failedRelease_retriedAfterUnpause() public {
        endpointA.relay(_lock(ALICE, 3e18, BOB));
        uint256 id = _burn(BOB, 1e12, ALICE);

        vm.prank(OWNER);
        lockbox.setPaused(true);
        assertTrue(!endpointB.relay(id), "release fails while paused");
        assertEq(_inFlightSD(endpointB, address(rep)), 1e6, "Q holds");
        _assertConservation();

        vm.prank(OWNER);
        lockbox.setPaused(false);
        assertTrue(endpointB.relay(id), "release retried");
        assertEq(canonical.balanceOf(ALICE), 98e18, "alice released");
        _assertConservation();
    }

    // ---------------------------------------------------------------- pause / owner

    function test_pause_blocksOutbound_onlyOwner() public {
        vm.expectRevert(BridgeAppBase.NotOwner.selector);
        vm.prank(MALLORY);
        lockbox.setPaused(true);

        vm.prank(OWNER);
        lockbox.setPaused(true);
        vm.expectRevert(BridgeAppBase.Paused.selector);
        vm.prank(ALICE);
        lockbox.lockAndSend(1e18, BOB);

        vm.prank(OWNER);
        lockbox.setPaused(false);
        endpointA.relay(_lock(ALICE, 1e18, BOB));

        vm.prank(OWNER);
        rep.setPaused(true);
        vm.expectRevert(BridgeAppBase.Paused.selector);
        vm.prank(BOB);
        rep.burnAndSend(1e12, ALICE);
    }

    function test_ownershipTransfer() public {
        vm.prank(OWNER);
        lockbox.transferOwnership(BOB);
        assertEq(lockbox.owner(), BOB, "new owner");
        vm.expectRevert(BridgeAppBase.NotOwner.selector);
        vm.prank(OWNER);
        lockbox.setPaused(true);
    }

    // ---------------------------------------------------------------- caps

    function test_rateCap_fixedWindow() public {
        vm.prank(OWNER);
        lockbox.setRateLimit(10e18);

        _lock(ALICE, 6e18, BOB);
        vm.expectRevert(BridgeAppBase.RateLimitExceeded.selector);
        vm.prank(ALICE);
        lockbox.lockAndSend(5e18, BOB);
        _lock(ALICE, 4e18, BOB); // exactly at the limit

        vm.warp(block.timestamp + WINDOW - 1); // same fixed window (aligned start)
        vm.expectRevert(BridgeAppBase.RateLimitExceeded.selector);
        vm.prank(ALICE);
        lockbox.lockAndSend(1e12, BOB);

        vm.warp(block.timestamp + 1); // next window
        _lock(ALICE, 10e18, BOB);
        _assertConservation();
    }

    function test_rateCap_appliesToBurns() public {
        endpointA.relay(_lock(ALICE, 10e18, BOB));
        vm.prank(OWNER);
        rep.setRateLimit(2e12);
        _burn(BOB, 2e12, ALICE);
        vm.expectRevert(BridgeAppBase.RateLimitExceeded.selector);
        vm.prank(BOB);
        rep.burnAndSend(1e6, ALICE);
    }

    function test_exposureCap_lockbox() public {
        vm.prank(OWNER);
        lockbox.setExposureCap(10e18);
        _lock(ALICE, 10e18, BOB);
        vm.expectRevert(BridgeAppBase.ExposureCapExceeded.selector);
        vm.prank(ALICE);
        lockbox.lockAndSend(1e12, BOB);
    }

    function test_exposureCap_representation_failsThenRetries() public {
        vm.prank(OWNER);
        rep.setExposureCap(5e12);
        uint256 a = _lock(ALICE, 4e18, BOB);
        uint256 b = _lock(ALICE, 2e18, BOB);
        assertTrue(endpointA.relay(a), "within cap");
        assertTrue(!endpointA.relay(b), "exceeds representation cap");
        _assertConservation();

        vm.prank(OWNER);
        rep.setExposureCap(6e12);
        assertTrue(endpointA.relay(b), "retry after cap raise");
        assertEq(rep.totalSupply(), 6e12, "supply");
        _assertConservation();
    }

    // ---------------------------------------------------------------- config

    function test_invalidConfig_reverts() public {
        BridgeAppBase.BridgeConfig memory cfg = _cfg(address(endpointA), EID_A, EID_B, address(0), BIG, BIG);
        vm.expectRevert(BridgeAppBase.InvalidConfig.selector);
        new SairiLockbox(canonical, cfg);

        cfg = _cfg(address(endpointB), EID_B, EID_B, address(lockbox), BIG, BIG);
        vm.expectRevert(BridgeAppBase.InvalidConfig.selector);
        new BackedSairiRepresentation("x", "x", 12, cfg);

        cfg = _cfg(address(endpointB), EID_B, EID_A, address(lockbox), BIG, BIG);
        vm.expectRevert(BridgeAppBase.InvalidConfig.selector);
        new BackedSairiRepresentation("x", "x", 4, cfg); // local decimals below shared decimals
    }
}
