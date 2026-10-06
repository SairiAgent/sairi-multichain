// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SairiTestnet} from "../../script/testnet/SairiTestnet.s.sol";
import {TestnetRoutes} from "../../script/testnet/TestnetRoutes.sol";
import {TestBase} from "../utils/TestBase.sol";

/// @notice Offline checks that the testnet script fails closed outside the two allowlisted testnets and
/// that the pinned route constants are mutually consistent. No RPC is used.
contract TestnetScriptGuardsTest is TestBase {
    SairiTestnet internal script;

    function setUp() public {
        script = new SairiTestnet();
    }

    function _expectChainRejected(uint256 id) internal {
        vm.chainId(id);
        vm.expectRevert(bytes("SAIRI: chain not in testnet allowlist"));
        script.preflight();
    }

    function test_mainnetsAndUnknownChainsRejected() public {
        _expectChainRejected(1); // Ethereum
        _expectChainRejected(8453); // Base mainnet
        _expectChainRejected(4663); // Robinhood Chain mainnet
        _expectChainRejected(11155111); // Sepolia (not allowlisted)
        _expectChainRejected(31337); // local
    }

    function test_allowlistedChainWithoutLiveEndpoint_failsClosed() public {
        vm.chainId(TestnetRoutes.BASE_SEPOLIA_CHAIN_ID);
        vm.expectRevert(bytes("SAIRI: endpoint has no code"));
        script.preflight();
        vm.chainId(TestnetRoutes.ROBINHOOD_TESTNET_CHAIN_ID);
        vm.expectRevert(bytes("SAIRI: endpoint has no code"));
        script.deployRepresentation();
    }

    function test_routeConstantsAreMirrored() public pure {
        TestnetRoutes.Route memory b = TestnetRoutes.baseSepolia();
        TestnetRoutes.Route memory r = TestnetRoutes.robinhoodTestnet();
        assertEq(uint256(b.remoteEid), uint256(r.localEid), "base -> rh eid");
        assertEq(uint256(r.remoteEid), uint256(b.localEid), "rh -> base eid");
        assertEq(uint256(b.sendConfirmations), uint256(r.receiveConfirmations), "base->rh confirmations");
        assertEq(uint256(r.sendConfirmations), uint256(b.receiveConfirmations), "rh->base confirmations");
        assertTrue(b.chainId != 8453 && r.chainId != 4663, "no mainnet ids");
    }
}
