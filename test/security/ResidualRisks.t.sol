// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BridgeFixture} from "../utils/BridgeFixture.sol";
import {BridgeAppBase} from "../../src/bridge/BridgeAppBase.sol";

/// @notice Evidence of RESIDUAL risks that the local contracts do NOT mitigate (LOCAL HARNESS ONLY).
///
/// 1. Trusted-verifier compromise: the bridge apps authenticate only "the configured endpoint says the
///    configured peer sent this". If the endpoint / verification network itself is compromised, it can
///    forge credits without any lock (R > L) and releases within backing, bypassing the outbound rate
///    limit. These tests intentionally demonstrate the conservation violation with explicit
///    comparisons; no production verifier is implemented here and local checks cannot fix this.
/// 2. Governance liveness: the owner cannot mint or withdraw, but can stall redemption indefinitely.
contract ResidualRisksTest is BridgeFixture {
    uint256 internal constant BIG = type(uint128).max;

    function setUp() public {
        vm.warp(1_000 * WINDOW);
        _deployBridge(BIG, BIG, BIG, BIG);
        _fundAndApprove(ALICE, 100e18);
    }

    function _forgedPayload(address recipient, uint256 amountSD) internal pure returns (bytes memory) {
        return abi.encode(recipient, amountSD);
    }

    /// @dev Returns (L, R + P + Q) in shared-decimal units.
    function _sides() internal view returns (uint256 l, uint256 liabilities) {
        l = lockbox.totalLocked() / CANON_RATE;
        liabilities = rep.totalSupply() / REP_RATE + _inFlightSD(endpointA, address(lockbox))
            + _inFlightSD(endpointB, address(rep));
    }

    // ---------------------------------------------------------------- trusted-verifier compromise

    function test_residualRisk_compromisedEndpoint_forgesCreditWithoutLock() public {
        (uint256 l0, uint256 liab0) = _sides();
        assertEq(l0, liab0, "balanced before compromise");

        // Compromised endpoint B claims the lockbox sent a credit that was never locked.
        endpointB.rawDeliver(address(rep), EID_A, _b32(address(lockbox)), 1_000, _forgedPayload(MALLORY, 5e6));

        assertEq(rep.balanceOf(MALLORY), 5e12, "unbacked representation minted");
        assertEq(lockbox.totalLocked(), 0, "nothing was locked");
        (uint256 l, uint256 liabilities) = _sides();
        assertTrue(l < liabilities, "RESIDUAL RISK: L < R + P + Q after forged credit");

        // The representation exposure cap is the only local bound on this damage.
        vm.prank(OWNER);
        rep.setExposureCap(5e12);
        vm.expectRevert(BridgeAppBase.ExposureCapExceeded.selector);
        endpointB.rawDeliver(address(rep), EID_A, _b32(address(lockbox)), 1_001, _forgedPayload(MALLORY, 1e6));
    }

    function test_residualRisk_compromisedEndpoint_drainsBackingWithinLimit() public {
        endpointA.relay(_lock(ALICE, 10e18, BOB));
        _assertConservation();

        // Outbound rate limits are set to the minimum; they do not constrain inbound releases.
        vm.startPrank(OWNER);
        lockbox.setRateLimit(0);
        rep.setRateLimit(0);
        vm.stopPrank();
        uint256 usedBefore = lockbox.usedInWindow();

        // Compromised endpoint A claims the representation burned 10e6 SD; no burn happened.
        endpointA.rawDeliver(address(lockbox), EID_B, _b32(address(rep)), 777, _forgedPayload(MALLORY, 10e6));

        assertEq(canonical.balanceOf(MALLORY), 10e18, "backing drained to attacker");
        assertEq(lockbox.totalLocked(), 0, "all backing released");
        assertEq(rep.balanceOf(BOB), 10e12, "honest holder's representation now unbacked");
        assertEq(lockbox.usedInWindow(), usedBefore, "outbound rate limit not consulted");
        (uint256 l, uint256 liabilities) = _sides();
        assertTrue(l < liabilities, "RESIDUAL RISK: L < R + P + Q after forged release");
    }

    function test_ownerCannotDirectlyMintOrRelease() public {
        endpointA.relay(_lock(ALICE, 10e18, BOB));
        bytes memory payload = _forgedPayload(OWNER, 1e6);

        vm.expectRevert(BridgeAppBase.UnauthorizedEndpoint.selector);
        vm.prank(OWNER);
        rep.receiveMessage(EID_A, _b32(address(lockbox)), 500, payload);

        vm.expectRevert(BridgeAppBase.UnauthorizedEndpoint.selector);
        vm.prank(OWNER);
        lockbox.receiveMessage(EID_B, _b32(address(rep)), 500, payload);

        assertEq(rep.balanceOf(OWNER), 0, "no owner mint");
        assertEq(canonical.balanceOf(OWNER), 0, "no owner release");
        _assertConservation();
    }

    // ---------------------------------------------------------------- governance liveness

    function test_residualGovernanceRisk_pauseStallsRedemptionIndefinitely() public {
        endpointA.relay(_lock(ALICE, 10e18, BOB));
        uint256 id = _burn(BOB, 4e12, BOB);

        vm.prank(OWNER);
        lockbox.setPaused(true);
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 365 days);
            assertTrue(!endpointB.relay(id), "release stalled while paused");
        }
        assertEq(canonical.balanceOf(BOB), 0, "redemption never paid");
        _assertConservation(); // still accounted as in flight (Q), but not redeemable

        vm.prank(OWNER);
        lockbox.setPaused(false);
        assertTrue(endpointB.relay(id), "liveness restored only by owner");
    }

    function test_residualGovernanceRisk_zeroBurnRateBlocksRedemption() public {
        endpointA.relay(_lock(ALICE, 10e18, BOB));
        vm.prank(OWNER);
        rep.setRateLimit(0);

        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 30 * WINDOW);
            vm.expectRevert(BridgeAppBase.RateLimitExceeded.selector);
            vm.prank(BOB);
            rep.burnAndSend(1e12, BOB);
        }
        assertEq(rep.balanceOf(BOB), 10e12, "holder cannot exit");
        _assertConservation();
    }
}
