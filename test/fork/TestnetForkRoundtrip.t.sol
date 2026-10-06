// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {UlnConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";

import {SairiOFTAdapter} from "../../src/layerzero/SairiOFTAdapter.sol";
import {SairiBackedOFT} from "../../src/layerzero/SairiBackedOFT.sol";
import {SairiTestnetToken} from "../../src/layerzero/SairiTestnetToken.sol";
import {SairiTestnet} from "../../script/testnet/SairiTestnet.s.sol";
import {TestnetRoutes} from "../../script/testnet/TestnetRoutes.sol";
import {LzPacketCodec} from "../layerzero/LzPacketCodec.sol";

interface IReceiveUlnVerify {
    function verify(bytes calldata packetHeader, bytes32 payloadHash, uint64 confirmations) external;
    function commitVerification(bytes calldata packetHeader, bytes32 payloadHash) external;
}

/// @notice OPT-IN FORK SIMULATION (`make testnet-fork-check`; excluded from `make test`, needs public RPC).
/// Runs the real testnet script entry points (deploy, wire, send) on forks of Base Sepolia and Robinhood Chain
/// testnet against the LIVE LayerZero EndpointV2 / SendUln302 / ReceiveUln302 / DVN / executor deployments.
///
/// SIMULATED, NOT LIVE PROOF: no DVN actually observes these fork-local packets, so the test impersonates the
/// configured LayerZero Labs DVN to attest, then uses the permissionless commit/lzReceive paths. Nothing is
/// broadcast. A live roundtrip must be performed and evidenced separately (docs/TESTNET_RUNBOOK.md).
contract TestnetForkRoundtripTest is LzPacketCodec {
    string internal constant BASE_SEPOLIA_RPC = "https://sepolia.base.org";
    string internal constant ROBINHOOD_TESTNET_RPC = "https://rpc.testnet.chain.robinhood.com";
    address internal constant OPERATOR = address(0x5A1E1);
    uint256 internal constant AMOUNT = 25e18;

    uint256 internal baseFork;
    uint256 internal rhFork;
    SairiTestnet internal baseScript;
    SairiTestnet internal rhScript;
    address internal token;
    address internal adapter;
    address internal backed;

    function test_fork_scriptedRoundtrip_throughLiveLayerZeroContracts() public {
        vm.setEnv("SAIRI_TESTNET_OPERATOR", vm.toString(OPERATOR));

        baseFork = vm.createSelectFork(BASE_SEPOLIA_RPC, _laggedHead(BASE_SEPOLIA_RPC));
        assertEq(block.chainid, TestnetRoutes.BASE_SEPOLIA_CHAIN_ID, "base sepolia fork");
        vm.deal(OPERATOR, 1 ether);
        baseScript = new SairiTestnet();
        (token, adapter) = baseScript.deployCanonical();

        rhFork = vm.createSelectFork(ROBINHOOD_TESTNET_RPC, _laggedHead(ROBINHOOD_TESTNET_RPC));
        assertEq(block.chainid, TestnetRoutes.ROBINHOOD_TESTNET_CHAIN_ID, "robinhood testnet fork");
        vm.deal(OPERATOR, 1 ether);
        rhScript = new SairiTestnet();
        backed = rhScript.deployRepresentation();

        vm.setEnv("SAIRI_TESTNET_ADAPTER", vm.toString(adapter));
        vm.setEnv("SAIRI_TESTNET_BACKED", vm.toString(backed));
        rhScript.wire();
        vm.selectFork(baseFork);
        baseScript.wire();

        // Leg 1: Base Sepolia -> Robinhood testnet (lock).
        TestnetRoutes.Route memory b = TestnetRoutes.baseSepolia();
        TestnetRoutes.Route memory r = TestnetRoutes.robinhoodTestnet();
        uint256 startBalance = SairiTestnetToken(token).balanceOf(OPERATOR);
        vm.recordLogs();
        (,, uint256 fee1,) = baseScript.send(AMOUNT, 0.01 ether);
        Packet memory out = _capturePacket(b.endpoint, b.sendLib);
        assertTrue(fee1 > 0, "live executor/DVN fee quoted");
        assertEq(SairiOFTAdapter(adapter).totalLocked(), AMOUNT, "locked on fork");

        vm.selectFork(rhFork);
        _simulateDvnAndExecute(out, r, b.sendConfirmations);
        assertEq(SairiBackedOFT(backed).balanceOf(OPERATOR), AMOUNT, "minted on robinhood fork");

        // Leg 2: Robinhood testnet -> Base Sepolia (burn).
        vm.recordLogs();
        (,, uint256 fee2,) = rhScript.send(AMOUNT, 0.01 ether);
        Packet memory back = _capturePacket(r.endpoint, r.sendLib);
        assertTrue(fee2 > 0, "live return fee quoted");
        assertEq(SairiBackedOFT(backed).totalSupply(), 0, "burned on robinhood fork");

        vm.selectFork(baseFork);
        _simulateDvnAndExecute(back, b, r.sendConfirmations);
        assertEq(SairiTestnetToken(token).balanceOf(OPERATOR), startBalance, "stand-in balance restored");
        assertEq(SairiOFTAdapter(adapter).totalLocked(), 0, "nothing locked");

        // Live defaults untouched, but the delegate overrides this app's send DVN: send() must refuse before
        // broadcasting even though preflight() (defaults) still passes.
        baseScript.preflight();
        address[] memory dvns = new address[](1);
        dvns[0] = address(0xD00D);
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] =
            SetConfigParam(b.remoteEid, 2, abi.encode(UlnConfig(b.sendConfirmations, 1, 0, 0, dvns, new address[](0))));
        vm.prank(OPERATOR);
        ILayerZeroEndpointV2(b.endpoint).setConfig(adapter, b.sendLib, p);
        vm.expectRevert(bytes("SAIRI: ULN required DVN mismatch"));
        baseScript.send(AMOUNT, 0.01 ether);
    }

    /// @dev Some public RPCs briefly refuse state at their newest block; fork a little behind head.
    function _laggedHead(string memory url) internal returns (uint256) {
        bytes memory raw = vm.rpc(url, "eth_blockNumber", "[]");
        assertTrue(raw.length > 0 && raw.length <= 32, "eth_blockNumber");
        uint256 head = uint256(bytes32(raw)) >> (256 - 8 * raw.length);
        assertTrue(head > 64, "head");
        return head - 32;
    }

    /// @dev SIMULATION: impersonates the configured DVN (not a real attestation), then permissionless paths.
    function _simulateDvnAndExecute(Packet memory pkt, TestnetRoutes.Route memory dst, uint64 confirmations) internal {
        assertEq(uint256(pkt.dstEid), uint256(dst.localEid), "packet routed to destination eid");
        vm.prank(dst.dvn);
        IReceiveUlnVerify(dst.receiveLib).verify(pkt.header, pkt.payloadHash, confirmations);
        IReceiveUlnVerify(dst.receiveLib).commitVerification(pkt.header, pkt.payloadHash);
        ILayerZeroEndpointV2(dst.endpoint)
            .lzReceive(Origin(pkt.srcEid, pkt.sender, pkt.nonce), pkt.receiver, pkt.guid, pkt.message, "");
    }
}
