// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {EndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/EndpointV2.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SendUln302} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/uln302/SendUln302.sol";
import {ReceiveUln302} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/uln302/ReceiveUln302.sol";
import {UlnConfig, SetDefaultUlnConfigParam} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import {
    ExecutorConfig,
    SetDefaultExecutorConfigParam
} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/SendLibBase.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";

import {SairiOFTAdapter} from "../../src/layerzero/SairiOFTAdapter.sol";
import {SairiBackedOFT} from "../../src/layerzero/SairiBackedOFT.sol";
import {SairiOFTGuards} from "../../src/layerzero/SairiOFTGuards.sol";
import {MockERC20} from "../mocks/MockTokens.sol";
import {LzPacketCodec} from "./LzPacketCodec.sol";
import {TestDVN, TestExecutor} from "./LzTestWorkers.sol";

/// @notice Two LayerZero "chains" in one local EVM, wired with the GENUINE pinned EndpointV2, SendUln302 and
/// ReceiveUln302 code. Only the DVN and executor are local TEST WORKERS (see LzTestWorkers.sol). Packets are
/// taken from the real `PacketSent` event, attested on the destination ReceiveUln302, committed to the
/// destination EndpointV2 and executed through the permissionless `EndpointV2.lzReceive`.
/// This is local integration evidence, NOT proof of a live testnet roundtrip.
abstract contract LzOFTFixture is LzPacketCodec {
    using OptionsBuilder for bytes;

    // Real testnet endpoint IDs, used locally so encoded packets match the live route shape.
    uint32 internal constant EID_BASE_SEPOLIA = 40245;
    uint32 internal constant EID_ROBINHOOD_TESTNET = 40451;
    uint64 internal constant CONFIRMATIONS = 2;
    uint256 internal constant DVN_FEE = 1e12;
    uint256 internal constant EXECUTOR_FEE = 3e12;
    uint128 internal constant LZ_RECEIVE_GAS = 200_000;
    uint256 internal constant CAP = 1_000_000e18;
    uint256 internal constant WINDOW = 1 days;
    uint256 internal constant RATE = 500_000e18;
    uint256 internal constant CONVERSION = 1e12; // 18 local decimals, 6 shared decimals

    struct Chain {
        uint32 eid;
        EndpointV2 endpoint;
        SendUln302 sendLib;
        ReceiveUln302 receiveLib;
        TestDVN dvn;
        TestExecutor executor;
    }

    Chain internal base;
    Chain internal robinhood;
    MockERC20 internal token;
    SairiOFTAdapter internal adapter;
    SairiBackedOFT internal backed;

    address internal constant OWNER = address(0xA11CE);
    address internal constant USER = address(0xB0B);
    address internal constant OTHER = address(0xCAFE);

    function setUp() public virtual {
        base = _chain(EID_BASE_SEPOLIA, EID_ROBINHOOD_TESTNET);
        robinhood = _chain(EID_ROBINHOOD_TESTNET, EID_BASE_SEPOLIA);

        token = new MockERC20("Local canonical stand-in", "LSAIRI", 18);
        adapter = new SairiOFTAdapter(address(token), address(base.endpoint), OWNER, _guards(EID_ROBINHOOD_TESTNET));
        backed = new SairiBackedOFT(
            "Backed SAIRI (local)", "bSAIRI", address(robinhood.endpoint), OWNER, _guards(EID_BASE_SEPOLIA)
        );

        vm.startPrank(OWNER);
        adapter.setPeer(EID_ROBINHOOD_TESTNET, _b32(address(backed)));
        backed.setPeer(EID_BASE_SEPOLIA, _b32(address(adapter)));
        adapter.setEnforcedOptions(_enforced(EID_ROBINHOOD_TESTNET));
        backed.setEnforcedOptions(_enforced(EID_BASE_SEPOLIA));
        vm.stopPrank();

        token.mint(USER, 10_000_000e18);
        vm.deal(USER, 100 ether);
        vm.deal(OTHER, 100 ether);
    }

    // ------------------------------------------------------------------ chain wiring (real LZ code)

    function _chain(uint32 eid, uint32 remoteEid) internal returns (Chain memory c) {
        c.eid = eid;
        c.endpoint = new EndpointV2(eid, address(this));
        c.sendLib = new SendUln302(address(c.endpoint), 0, 0);
        c.receiveLib = new ReceiveUln302(address(c.endpoint));
        c.dvn = new TestDVN(DVN_FEE);
        c.executor = new TestExecutor(EXECUTOR_FEE);

        address[] memory dvns = new address[](1);
        dvns[0] = address(c.dvn);
        SetDefaultUlnConfigParam[] memory uln = new SetDefaultUlnConfigParam[](1);
        uln[0] = SetDefaultUlnConfigParam(remoteEid, UlnConfig(CONFIRMATIONS, 1, 0, 0, dvns, new address[](0)));
        c.sendLib.setDefaultUlnConfigs(uln);
        c.receiveLib.setDefaultUlnConfigs(uln);
        SetDefaultExecutorConfigParam[] memory exec = new SetDefaultExecutorConfigParam[](1);
        exec[0] = SetDefaultExecutorConfigParam(remoteEid, ExecutorConfig(10_000, address(c.executor)));
        c.sendLib.setDefaultExecutorConfigs(exec);

        c.endpoint.registerLibrary(address(c.sendLib));
        c.endpoint.registerLibrary(address(c.receiveLib));
        c.endpoint.setDefaultSendLibrary(remoteEid, address(c.sendLib));
        c.endpoint.setDefaultReceiveLibrary(remoteEid, address(c.receiveLib), 0);
    }

    function _guards(uint32 peerEid) internal pure returns (SairiOFTGuards.GuardConfig memory) {
        return SairiOFTGuards.GuardConfig(peerEid, CAP, WINDOW, RATE);
    }

    function _enforced(uint32 eid) internal pure returns (EnforcedOptionParam[] memory params) {
        params = new EnforcedOptionParam[](1);
        params[0] =
            EnforcedOptionParam(eid, 1, OptionsBuilder.newOptions().addExecutorLzReceiveOption(LZ_RECEIVE_GAS, 0));
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _chainFor(uint32 eid) internal view returns (Chain memory) {
        return eid == EID_BASE_SEPOLIA ? base : robinhood;
    }

    // ------------------------------------------------------------------ user actions

    function _param(uint32 dstEid, address to, uint256 amountLD) internal pure returns (SendParam memory) {
        return SendParam(dstEid, _b32(to), amountLD, amountLD, "", "", "");
    }

    /// @dev Locks on the Base-side adapter and returns the captured outbound packet.
    function _sendFromBase(address from, address to, uint256 amountLD) internal returns (Packet memory) {
        SendParam memory p = _param(EID_ROBINHOOD_TESTNET, to, amountLD);
        MessagingFee memory fee = adapter.quoteSend(p, false);
        vm.startPrank(from);
        token.approve(address(adapter), amountLD);
        vm.recordLogs();
        adapter.send{value: fee.nativeFee}(p, fee, from);
        vm.stopPrank();
        return _capture(base);
    }

    /// @dev Burns on the Robinhood-side representation and returns the captured outbound packet.
    function _sendFromRobinhood(address from, address to, uint256 amountLD) internal returns (Packet memory) {
        SendParam memory p = _param(EID_BASE_SEPOLIA, to, amountLD);
        MessagingFee memory fee = backed.quoteSend(p, false);
        vm.prank(from);
        vm.recordLogs();
        backed.send{value: fee.nativeFee}(p, fee, from);
        return _capture(robinhood);
    }

    // ------------------------------------------------------------------ packet transport

    function _capture(Chain memory src) internal returns (Packet memory) {
        return _capturePacket(address(src.endpoint), address(src.sendLib));
    }

    /// @dev DVN attestation + permissionless commit on the destination ReceiveUln302 / EndpointV2.
    function _verify(Packet memory pkt) internal {
        Chain memory dst = _chainFor(pkt.dstEid);
        dst.dvn.attest(dst.receiveLib, pkt.header, pkt.payloadHash, CONFIRMATIONS);
        dst.receiveLib.commitVerification(pkt.header, pkt.payloadHash);
    }

    /// @dev Permissionless execution at the destination EndpointV2.
    function _execute(Packet memory pkt) internal {
        Chain memory dst = _chainFor(pkt.dstEid);
        dst.endpoint.lzReceive(Origin(pkt.srcEid, pkt.sender, pkt.nonce), pkt.receiver, pkt.guid, pkt.message, "");
    }

    function _deliver(Packet memory pkt) internal {
        _verify(pkt);
        _execute(pkt);
    }

    /// @dev In-flight amount (local decimals) encoded in an OFT message: to(32) | amountSD(8).
    function _amountLD(Packet memory pkt) internal pure returns (uint256) {
        return uint256(uint64(bytes8(_word(pkt.message, 32)))) * CONVERSION;
    }
}
