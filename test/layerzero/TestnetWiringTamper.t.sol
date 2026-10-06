// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {SendUln302} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/uln302/SendUln302.sol";
import {ReceiveUln302} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/uln302/ReceiveUln302.sol";
import {UlnConfig, SetDefaultUlnConfigParam} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import {
    ExecutorConfig,
    SetDefaultExecutorConfigParam
} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/SendLibBase.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {SairiOFTAdapter} from "../../src/layerzero/SairiOFTAdapter.sol";
import {SairiBackedOFT} from "../../src/layerzero/SairiBackedOFT.sol";
import {SairiTestnet} from "../../script/testnet/SairiTestnet.s.sol";
import {TestnetRoutes} from "../../script/testnet/TestnetRoutes.sol";
import {LzOFTFixture} from "./LzOFTFixture.sol";
import {TestDVN, TestExecutor} from "./LzTestWorkers.sol";

/// @notice TEST HARNESS ONLY: exposes the script's internal route checks for an arbitrary (local) route, so the
/// exact code paths used by `wire()` / `verifyWiring()` / `send()` can be exercised offline.
contract SairiTestnetHarness is SairiTestnet {
    function preflightFor(TestnetRoutes.Route memory r) external view {
        _preflightRoute(r);
    }

    function wireFor(TestnetRoutes.Route memory r, address local, address remote) external {
        _wirePeerAndOptions(local, remote, r);
        _pinLibraries(local, r);
        _pinConfig(local, r);
    }

    function verifyWiringFor(TestnetRoutes.Route memory r, address local, address remote) external view {
        _verifyWiring(r, local, remote);
    }

    function sendReadyFor(TestnetRoutes.Route memory r, address local, address remote, address operator) external view {
        _requireSendReady(r, local, remote, operator);
    }
}

/// @notice The pinned DEFAULT route stays untouched (preflight passes) while the owner/delegate alters the
/// per-app configuration; the send readiness check used by `send()` must reject every such change.
contract TestnetWiringTamperTest is LzOFTFixture {
    using OptionsBuilder for bytes;

    SairiTestnetHarness internal harness;
    SairiOFTAdapter internal app;
    SairiBackedOFT internal remoteApp;
    TestnetRoutes.Route internal route;

    function setUp() public override {
        super.setUp();
        harness = new SairiTestnetHarness();
        // Apps owned and delegated by the harness (the "operator" for these checks).
        app = new SairiOFTAdapter(
            address(token), address(base.endpoint), address(harness), _guards(EID_ROBINHOOD_TESTNET)
        );
        remoteApp =
            new SairiBackedOFT("r", "r", address(robinhood.endpoint), address(harness), _guards(EID_BASE_SEPOLIA));
        route = TestnetRoutes.Route({
            chainId: block.chainid,
            localEid: EID_BASE_SEPOLIA,
            remoteEid: EID_ROBINHOOD_TESTNET,
            endpoint: address(base.endpoint),
            sendLib: address(base.sendLib),
            receiveLib: address(base.receiveLib),
            executor: address(base.executor),
            dvn: address(base.dvn),
            sendConfirmations: CONFIRMATIONS,
            receiveConfirmations: CONFIRMATIONS,
            maxMessageSize: 10_000
        });
        harness.wireFor(route, address(app), address(remoteApp));
    }

    function _assertDefaultsUnchangedButSendRejected(string memory reason) internal {
        harness.preflightFor(route); // default libraries / DVN / executor unchanged
        vm.expectRevert(bytes(reason));
        harness.verifyWiringFor(route, address(app), address(remoteApp));
        vm.expectRevert(bytes(reason));
        harness.sendReadyFor(route, address(app), address(remoteApp), address(harness));
    }

    function _uln(address dvn, uint64 confirmations) internal pure returns (UlnConfig memory) {
        address[] memory required = new address[](1);
        required[0] = dvn;
        return UlnConfig(confirmations, 1, 0, 0, required, new address[](0));
    }

    function _setUln(address lib, UlnConfig memory cfg) internal {
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] = SetConfigParam(EID_ROBINHOOD_TESTNET, 2, abi.encode(cfg));
        vm.prank(address(harness));
        base.endpoint.setConfig(address(app), lib, p);
    }

    function test_pinnedWiring_isSendReady() public view {
        harness.preflightFor(route);
        harness.verifyWiringFor(route, address(app), address(remoteApp));
        harness.sendReadyFor(route, address(app), address(remoteApp), address(harness));
        assertEq(
            keccak256(app.enforcedOptions(EID_ROBINHOOD_TESTNET, 1)),
            keccak256(OptionsBuilder.newOptions().addExecutorLzReceiveOption(120_000, 0)),
            "exact 120k lzReceive option"
        );
    }

    function test_perAppSendDvnChanged_rejected() public {
        _setUln(address(base.sendLib), _uln(address(new TestDVN(0)), CONFIRMATIONS));
        _assertDefaultsUnchangedButSendRejected("SAIRI: ULN required DVN mismatch");
    }

    function test_perAppReceiveDvnChanged_rejected() public {
        _setUln(address(base.receiveLib), _uln(address(new TestDVN(0)), CONFIRMATIONS));
        _assertDefaultsUnchangedButSendRejected("SAIRI: ULN required DVN mismatch");
    }

    function test_perAppConfirmationsLowered_rejected() public {
        _setUln(address(base.receiveLib), _uln(address(base.dvn), 1));
        _assertDefaultsUnchangedButSendRejected("SAIRI: ULN confirmations mismatch");
    }

    function test_perAppOptionalDvnAdded_rejected() public {
        address[] memory required = new address[](1);
        required[0] = address(base.dvn);
        address[] memory optional = new address[](1);
        optional[0] = address(new TestDVN(0));
        _setUln(address(base.sendLib), UlnConfig(CONFIRMATIONS, 1, 1, 1, required, optional));
        _assertDefaultsUnchangedButSendRejected("SAIRI: ULN optional DVNs present");
    }

    function test_perAppExecutorChanged_rejected() public {
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] =
            SetConfigParam(EID_ROBINHOOD_TESTNET, 1, abi.encode(ExecutorConfig(10_000, address(new TestExecutor(0)))));
        vm.prank(address(harness));
        base.endpoint.setConfig(address(app), address(base.sendLib), p);
        _assertDefaultsUnchangedButSendRejected("SAIRI: executor");
    }

    function test_perAppMaxMessageSizeChanged_rejected() public {
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] = SetConfigParam(EID_ROBINHOOD_TESTNET, 1, abi.encode(ExecutorConfig(64, address(base.executor))));
        vm.prank(address(harness));
        base.endpoint.setConfig(address(app), address(base.sendLib), p);
        _assertDefaultsUnchangedButSendRejected("SAIRI: executor");
    }

    function test_perAppSendLibraryChanged_rejected() public {
        SendUln302 other = new SendUln302(address(base.endpoint), 0, 0);
        SetDefaultUlnConfigParam[] memory uln = new SetDefaultUlnConfigParam[](1);
        uln[0] = SetDefaultUlnConfigParam(EID_ROBINHOOD_TESTNET, _uln(address(base.dvn), CONFIRMATIONS));
        other.setDefaultUlnConfigs(uln);
        SetDefaultExecutorConfigParam[] memory exec = new SetDefaultExecutorConfigParam[](1);
        exec[0] = SetDefaultExecutorConfigParam(EID_ROBINHOOD_TESTNET, ExecutorConfig(10_000, address(base.executor)));
        other.setDefaultExecutorConfigs(exec);
        base.endpoint.registerLibrary(address(other));
        vm.prank(address(harness));
        base.endpoint.setSendLibrary(address(app), EID_ROBINHOOD_TESTNET, address(other));
        _assertDefaultsUnchangedButSendRejected("SAIRI: send library not pinned");
    }

    function test_perAppReceiveLibraryChanged_rejected() public {
        ReceiveUln302 other = new ReceiveUln302(address(base.endpoint));
        SetDefaultUlnConfigParam[] memory uln = new SetDefaultUlnConfigParam[](1);
        uln[0] = SetDefaultUlnConfigParam(EID_ROBINHOOD_TESTNET, _uln(address(base.dvn), CONFIRMATIONS));
        other.setDefaultUlnConfigs(uln);
        base.endpoint.registerLibrary(address(other));
        vm.prank(address(harness));
        base.endpoint.setReceiveLibrary(address(app), EID_ROBINHOOD_TESTNET, address(other), 0);
        _assertDefaultsUnchangedButSendRejected("SAIRI: receive library not pinned");
    }

    function test_enforcedOptionsChanged_rejected() public {
        bytes[3] memory variants = [
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0), // different gas
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(119_999, 0), // lower gas
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(120_000, 1) // extra native value
        ];
        for (uint256 i = 0; i < variants.length; i++) {
            EnforcedOptionParam[] memory p = new EnforcedOptionParam[](1);
            p[0] = EnforcedOptionParam(EID_ROBINHOOD_TESTNET, 1, variants[i]);
            vm.prank(address(harness));
            app.setEnforcedOptions(p);
            _assertDefaultsUnchangedButSendRejected("SAIRI: enforced options mismatch");
        }
    }

    function test_operatorMustOwnApp() public {
        vm.expectRevert(bytes("SAIRI: operator is not app owner"));
        harness.sendReadyFor(route, address(app), address(remoteApp), OTHER);
    }

    function test_rewiringRestoresReadiness() public {
        _setUln(address(base.sendLib), _uln(address(new TestDVN(0)), CONFIRMATIONS));
        vm.expectRevert(bytes("SAIRI: ULN required DVN mismatch"));
        harness.verifyWiringFor(route, address(app), address(remoteApp));
        harness.wireFor(route, address(app), address(remoteApp)); // pins the expected values again
        harness.sendReadyFor(route, address(app), address(remoteApp), address(harness));
    }
}
