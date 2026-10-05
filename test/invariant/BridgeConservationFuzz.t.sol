// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BridgeFixture} from "../utils/BridgeFixture.sol";
import {LocalEndpointMock} from "../mocks/LocalEndpointMock.sol";

/// @notice Bounded stateful fuzz (fuzz runs = 128 via foundry.toml). Each run derives a sequence of
/// locks, burns, out-of-order/failed relays, pauses, dust attempts and time warps from one seed and
/// checks L >= R + P + Q against the endpoint message ledger after every transition.
contract BridgeConservationFuzzTest is BridgeFixture {
    uint256 internal constant STEPS = 32;
    uint256 internal constant START_BALANCE = 1_000e18;

    function setUp() public {
        vm.warp(1_000 * WINDOW);
        // Tight caps so cap and rate-limit failures are exercised.
        _deployBridge(600e18, 500e12, 300e18, 300e12);
        _fundAndApprove(ALICE, START_BALANCE);
        _fundAndApprove(BOB, START_BALANCE);
    }

    function testFuzz_bridgeConservation(uint256 seed) public {
        for (uint256 i; i < STEPS; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _step(seed % 7, seed >> 8);
            _assertConservation();
            assertEq(
                canonical.balanceOf(ALICE) + canonical.balanceOf(BOB) + canonical.balanceOf(address(lockbox)),
                2 * START_BALANCE,
                "canonical conserved"
            );
        }
        _drain();
        assertEq(_inFlightSD(endpointA, address(lockbox)), 0, "P drained");
        assertEq(_inFlightSD(endpointB, address(rep)), 0, "Q drained");
        assertEq(lockbox.totalLocked(), rep.totalSupply() * (CANON_RATE / REP_RATE), "fully backed");
        _assertConservation();
    }

    function _step(uint256 op, uint256 r) internal {
        address user = (r & 1) == 0 ? ALICE : BOB;
        r >>= 1;
        if (op == 0) {
            uint256 amountLD = bound(r, 1, 200e6) * CANON_RATE;
            if (canonical.balanceOf(user) < amountLD) return;
            vm.prank(user);
            try lockbox.lockAndSend(amountLD, user) {} catch {}
        } else if (op == 1) {
            _relayRandom(endpointA, r);
        } else if (op == 2) {
            uint256 balSD = rep.balanceOf(user) / REP_RATE;
            if (balSD == 0) return;
            vm.prank(user);
            try rep.burnAndSend(bound(r, 1, balSD) * REP_RATE, user) {} catch {}
        } else if (op == 3) {
            _relayRandom(endpointB, r);
        } else if (op == 4) {
            vm.startPrank(OWNER);
            if ((r & 1) == 0) lockbox.setPaused(!lockbox.paused());
            else rep.setPaused(!rep.paused());
            vm.stopPrank();
        } else if (op == 5) {
            vm.warp(block.timestamp + bound(r, 1, 2 * WINDOW));
        } else {
            // Dust must always be rejected, whatever the other state is.
            uint256 dustLD = bound(r, 1, 10e6) * CANON_RATE + bound(r >> 64, 1, CANON_RATE - 1);
            vm.prank(user);
            try lockbox.lockAndSend(dustLD, user) {
                revert AssertionFailed("dust lock accepted");
            } catch {}
        }
    }

    function _relayRandom(LocalEndpointMock ep, uint256 r) internal {
        uint256 n = ep.messageCount();
        if (n == 0) return;
        uint256 start = r % n;
        for (uint256 k; k < n; ++k) {
            uint256 id = (start + k) % n;
            if (ep.statusOf(id) != LocalEndpointMock.Status.Delivered) {
                ep.relay(id); // may fail (paused / cap); stays in flight and is retryable
                return;
            }
        }
    }

    function _drain() internal {
        vm.startPrank(OWNER);
        lockbox.setPaused(false);
        rep.setPaused(false);
        rep.setExposureCap(type(uint128).max);
        vm.stopPrank();
        _relayAll(endpointA);
        _relayAll(endpointB);
    }

    function _relayAll(LocalEndpointMock ep) internal {
        uint256 n = ep.messageCount();
        for (uint256 id; id < n; ++id) {
            if (ep.statusOf(id) != LocalEndpointMock.Status.Delivered) {
                assertTrue(ep.relay(id), "pending message deliverable after unpause");
            }
        }
    }
}
