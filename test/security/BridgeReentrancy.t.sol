// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestBase} from "../utils/TestBase.sol";
import {LocalEndpointMock} from "../mocks/LocalEndpointMock.sol";
import {ReentrantToken} from "../mocks/MockTokens.sol";
import {ReentrancyGuard} from "../../src/utils/ReentrancyGuard.sol";
import {ILocalMessageReceiver} from "../../src/interfaces/ILocalMessaging.sol";
import {BridgeAppBase} from "../../src/bridge/BridgeAppBase.sol";
import {SairiLockbox} from "../../src/bridge/SairiLockbox.sol";
import {BackedSairiRepresentation} from "../../src/bridge/BackedSairiRepresentation.sol";

/// @notice Canonical-token callback reentrancy into the lockbox (LOCAL HARNESS ONLY). The token makes
/// one nested call during transfer/transferFrom; the nested call must fail with `Reentrancy()` while the
/// truthful outer transfer completes with accounting conserved.
contract BridgeReentrancyTest is TestBase {
    uint32 internal constant EID_A = 101;
    uint32 internal constant EID_B = 202;
    address internal constant OWNER = address(0xA11CE);
    address internal constant ALICE = address(0xA1);
    address internal constant MALLORY = address(0xBAD);

    LocalEndpointMock internal endpointA;
    LocalEndpointMock internal endpointB;
    ReentrantToken internal rt;
    SairiLockbox internal box;
    BackedSairiRepresentation internal rep;

    function setUp() public {
        vm.warp(1_000 days);
        endpointA = new LocalEndpointMock(EID_A);
        endpointB = new LocalEndpointMock(EID_B);
        endpointA.connect(EID_B, endpointB);
        endpointB.connect(EID_A, endpointA);
        rt = new ReentrantToken();

        uint256 nonce = vm.getNonce(address(this));
        address boxAddr = predictCreate(address(this), nonce);
        address repAddr = predictCreate(address(this), nonce + 1);
        box = new SairiLockbox(rt, _cfg(address(endpointA), EID_A, EID_B, repAddr));
        rep = new BackedSairiRepresentation(
            "Backed (LOCAL HARNESS)", "bX", 12, _cfg(address(endpointB), EID_B, EID_A, boxAddr)
        );
        assertEq(address(box), boxAddr, "lockbox prediction");
        assertEq(address(rep), repAddr, "representation prediction");

        rt.mint(ALICE, 10e18);
        vm.prank(ALICE);
        rt.approve(address(box), type(uint256).max);
    }

    function _cfg(address endpoint, uint32 localEid, uint32 peerEid, address peerAddr)
        internal
        pure
        returns (BridgeAppBase.BridgeConfig memory)
    {
        return BridgeAppBase.BridgeConfig({
            endpoint: endpoint,
            localEid: localEid,
            peerEid: peerEid,
            peer: bytes32(uint256(uint160(peerAddr))),
            owner: OWNER,
            sharedDecimals: 6,
            exposureCap: type(uint128).max,
            rateWindowSeconds: 1 days,
            rateLimitPerWindow: type(uint128).max
        });
    }

    function _assertHookBlocked() internal view {
        assertTrue(rt.hookAttempted(), "reentry attempted");
        assertTrue(!rt.hookSucceeded(), "reentry blocked");
        assertEq(
            uint256(keccak256(rt.hookRevertData())),
            uint256(keccak256(abi.encodeWithSelector(ReentrancyGuard.Reentrancy.selector))),
            "Reentrancy() error"
        );
    }

    /// @dev Exact identity in shared units; nothing is in flight when called.
    function _assertBalanced() internal view {
        assertEq(box.totalLocked() / 1e12, rep.totalSupply() / 1e6, "L == R");
        assertEq(rt.balanceOf(address(box)), box.totalLocked(), "lockbox balance == L");
    }

    function test_lock_nestedLockDuringTransferFrom_blocked() public {
        rt.arm(address(box), abi.encodeCall(SairiLockbox.lockAndSend, (1e18, MALLORY)));

        vm.prank(ALICE);
        box.lockAndSend(2e18, ALICE);

        _assertHookBlocked();
        assertEq(box.totalLocked(), 2e18, "only outer lock recorded");
        assertEq(rt.balanceOf(address(box)), 2e18, "only outer deposit");
        assertEq(endpointA.messageCount(), 1, "single message");
        assertEq(box.totalOutboundSD(), 2e6, "single outbound record");

        assertTrue(endpointA.relay(0), "credit delivered");
        _assertBalanced();
    }

    function test_release_nestedReceiveDuringTransfer_blocked() public {
        vm.prank(ALICE);
        box.lockAndSend(3e18, ALICE);
        assertTrue(endpointA.relay(0), "credit delivered");
        vm.prank(ALICE);
        rep.burnAndSend(1e12, ALICE);

        // During the release transfer, the token tries to re-enter with a forged inbound message.
        rt.arm(
            address(box),
            abi.encodeCall(
                ILocalMessageReceiver.receiveMessage,
                (EID_B, bytes32(uint256(uint160(address(rep)))), 999, abi.encode(MALLORY, uint256(1e6)))
            )
        );
        assertTrue(endpointB.relay(0), "outer release succeeds");

        _assertHookBlocked();
        assertEq(rt.balanceOf(ALICE), 8e18, "truthful release paid");
        assertEq(rt.balanceOf(MALLORY), 0, "nested release paid nothing");
        assertTrue(!box.inboundConsumed(999), "nested nonce not consumed");
        assertEq(box.totalLocked(), 2e18, "backing reduced once");
        _assertBalanced();
    }

    function test_release_nestedLockDuringTransfer_blocked() public {
        vm.prank(ALICE);
        box.lockAndSend(3e18, ALICE);
        assertTrue(endpointA.relay(0), "credit delivered");
        vm.prank(ALICE);
        rep.burnAndSend(1e12, ALICE);

        rt.arm(address(box), abi.encodeCall(SairiLockbox.lockAndSend, (1e18, MALLORY)));
        assertTrue(endpointB.relay(0), "outer release succeeds");

        _assertHookBlocked();
        assertEq(endpointA.messageCount(), 1, "no nested lock message");
        assertEq(box.totalLocked(), 2e18, "backing reduced once");
        _assertBalanced();
    }
}
