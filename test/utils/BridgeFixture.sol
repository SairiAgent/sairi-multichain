// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestBase} from "./TestBase.sol";
import {LocalEndpointMock} from "../mocks/LocalEndpointMock.sol";
import {MockERC20} from "../mocks/MockTokens.sol";
import {BridgeAppBase} from "../../src/bridge/BridgeAppBase.sol";
import {SairiLockbox} from "../../src/bridge/SairiLockbox.sol";
import {BackedSairiRepresentation} from "../../src/bridge/BackedSairiRepresentation.sol";

/// @notice Deploys a LOCAL HARNESS two-"chain" bridge in one EVM and checks conservation against the
/// endpoint message ledger:  L >= R + P + Q  (all in shared-decimal units), where
///   L = canonical locked in the lockbox, R = representation supply,
///   P = lock messages not yet credited, Q = burn messages not yet released.
abstract contract BridgeFixture is TestBase {
    uint32 internal constant EID_A = 101; // canonical side
    uint32 internal constant EID_B = 202; // representation side
    uint8 internal constant SHARED_DECIMALS = 6;
    uint8 internal constant REP_DECIMALS = 12;
    uint256 internal constant CANON_RATE = 1e12; // 18 -> 6
    uint256 internal constant REP_RATE = 1e6; // 12 -> 6
    uint256 internal constant WINDOW = 1 days;

    address internal constant OWNER = address(0xA11CE);
    address internal constant ALICE = address(0xA1);
    address internal constant BOB = address(0xB0B);
    address internal constant MALLORY = address(0xBAD);

    LocalEndpointMock internal endpointA;
    LocalEndpointMock internal endpointB;
    MockERC20 internal canonical;
    SairiLockbox internal lockbox;
    BackedSairiRepresentation internal rep;

    function _deployBridge(uint256 lockboxCap, uint256 repCap, uint256 lockboxRate, uint256 repRate) internal {
        endpointA = new LocalEndpointMock(EID_A);
        endpointB = new LocalEndpointMock(EID_B);
        endpointA.connect(EID_B, endpointB);
        endpointB.connect(EID_A, endpointA);
        canonical = new MockERC20("SAIRI canonical (TEST MOCK)", "SAIRI", 18);

        // Peers are immutable, so predict both CREATE addresses before deploying.
        uint256 nonce = vm.getNonce(address(this));
        address lockboxAddr = predictCreate(address(this), nonce);
        address repAddr = predictCreate(address(this), nonce + 1);

        lockbox = new SairiLockbox(canonical, _cfg(address(endpointA), EID_A, EID_B, repAddr, lockboxCap, lockboxRate));
        rep = new BackedSairiRepresentation(
            "Backed SAIRI (LOCAL HARNESS)",
            "bSAIRI",
            REP_DECIMALS,
            _cfg(address(endpointB), EID_B, EID_A, lockboxAddr, repCap, repRate)
        );
        assertEq(address(lockbox), lockboxAddr, "lockbox address prediction");
        assertEq(address(rep), repAddr, "representation address prediction");
    }

    function _cfg(address endpoint, uint32 localEid, uint32 peerEid, address peerAddr, uint256 cap, uint256 rate)
        internal
        pure
        returns (BridgeAppBase.BridgeConfig memory)
    {
        return BridgeAppBase.BridgeConfig({
            endpoint: endpoint,
            localEid: localEid,
            peerEid: peerEid,
            peer: _b32(peerAddr),
            owner: OWNER,
            sharedDecimals: SHARED_DECIMALS,
            exposureCap: cap,
            rateWindowSeconds: WINDOW,
            rateLimitPerWindow: rate
        });
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    // ---------------------------------------------------------------- actions

    function _fundAndApprove(address user, uint256 amount) internal {
        canonical.mint(user, amount);
        vm.prank(user);
        canonical.approve(address(lockbox), type(uint256).max);
    }

    /// @return id Outbox index on endpoint A.
    function _lock(address user, uint256 amountLD, address recipient) internal returns (uint256 id) {
        vm.prank(user);
        lockbox.lockAndSend(amountLD, recipient);
        id = endpointA.messageCount() - 1;
    }

    /// @return id Outbox index on endpoint B.
    function _burn(address user, uint256 amountLD, address recipient) internal returns (uint256 id) {
        vm.prank(user);
        rep.burnAndSend(amountLD, recipient);
        id = endpointB.messageCount() - 1;
    }

    // ---------------------------------------------------------------- ledger

    /// @dev Sum (SD units) of messages sent by `app` through `ep` that are not yet delivered.
    function _inFlightSD(LocalEndpointMock ep, address app) internal view returns (uint256 sum) {
        uint256 n = ep.messageCount();
        for (uint256 i; i < n; ++i) {
            LocalEndpointMock.Message memory m = ep.messageAt(i);
            if (m.sender == _b32(app) && m.status != LocalEndpointMock.Status.Delivered) {
                (, uint256 amountSD) = abi.decode(m.payload, (address, uint256));
                sum += amountSD;
            }
        }
    }

    function _assertConservation() internal view {
        uint256 lockedLD = lockbox.totalLocked();
        uint256 supplyLD = rep.totalSupply();
        assertEq(lockedLD % CANON_RATE, 0, "locked has no dust");
        assertEq(supplyLD % REP_RATE, 0, "supply has no dust");

        uint256 l = lockedLD / CANON_RATE;
        uint256 r = supplyLD / REP_RATE;
        uint256 p = _inFlightSD(endpointA, address(lockbox));
        uint256 q = _inFlightSD(endpointB, address(rep));

        assertGe(l, r + p + q, "L >= R + P + Q");
        assertEq(l, r + p + q, "L == R + P + Q (no leakage)");
        assertGe(canonical.balanceOf(address(lockbox)), lockedLD, "lockbox balance covers L");

        // Cross-check the endpoint ledger against the apps' own per-message records.
        assertEq(p, lockbox.totalOutboundSD() - rep.totalInboundSD(), "P matches app records");
        assertEq(q, rep.totalOutboundSD() - lockbox.totalInboundSD(), "Q matches app records");
    }
}
