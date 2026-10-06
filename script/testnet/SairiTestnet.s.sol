// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    ILayerZeroEndpointV2,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {UlnConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import {ExecutorConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/SendLibBase.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {SendParam, OFTReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {SairiOFTAdapter} from "../../src/layerzero/SairiOFTAdapter.sol";
import {SairiBackedOFT} from "../../src/layerzero/SairiBackedOFT.sol";
import {SairiOFTGuards} from "../../src/layerzero/SairiOFTGuards.sol";
import {SairiTestnetToken} from "../../src/layerzero/SairiTestnetToken.sol";
import {TestnetRoutes} from "./TestnetRoutes.sol";

/// @notice Foundry script cheatcodes used here (no forge-std dependency).
interface ScriptVm {
    function startBroadcast(address signer) external;
    function stopBroadcast() external;
    function envAddress(string calldata name) external view returns (address);
}

/// @dev Public `delegates` mapping getter of EndpointV2 (not part of ILayerZeroEndpointV2).
interface IEndpointDelegates {
    function delegates(address oapp) external view returns (address);
}

interface IUlnDefaults {
    function getUlnConfig(address oapp, uint32 remoteEid) external view returns (UlnConfig memory);
    function getExecutorConfig(address oapp, uint32 remoteEid) external view returns (ExecutorConfig memory);
}

/// @notice EXPERIMENTAL TESTNET-ONLY deployment / wiring / roundtrip-leg script for
/// Base Sepolia (canonical stand-in + SairiOFTAdapter) <-> Robinhood Chain testnet (SairiBackedOFT).
///
/// Safety properties:
/// - every entry point first requires `block.chainid` to be 84532 or 46630 (no mainnet, no other chain)
///   and re-verifies the LayerZero endpoint, default libraries, DVN, confirmations and executor on-chain
///   against `TestnetRoutes`; any mismatch reverts before a transaction is broadcast;
/// - the signer is the explicit `SAIRI_TESTNET_OPERATOR` address; keys are supplied only through Foundry's
///   own signer flags by the operator (this script never reads key material);
/// - deployments use a valueless stand-in token (NOT SAIRI), conservative caps and a once-only peer.
///
/// Usage (see docs/TESTNET_RUNBOOK.md; the Makefile runs the read-only Python preflight first):
///   forge script script/testnet/SairiTestnet.s.sol:SairiTestnet --sig 'preflight()' --rpc-url <RPC>
///   ... --sig 'deployCanonical()'      on Base Sepolia, with --broadcast and signer flags
///   ... --sig 'deployRepresentation()' on Robinhood testnet
///   ... --sig 'wire()'                 on each chain (needs SAIRI_TESTNET_ADAPTER and SAIRI_TESTNET_BACKED)
///   ... --sig 'send(uint256,uint256)' <amountLD> <maxNativeFeeWei>   one roundtrip leg from the current chain
contract SairiTestnet {
    using OptionsBuilder for bytes;

    ScriptVm internal constant vm = ScriptVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 public constant STAND_IN_SUPPLY = 1_000_000e18;
    uint256 public constant EXPOSURE_CAP = 1_000_000e18;
    uint256 public constant RATE_WINDOW_SECONDS = 1 days;
    uint256 public constant RATE_LIMIT_PER_WINDOW = 100_000e18;
    uint128 public constant LZ_RECEIVE_GAS = 120_000;
    uint16 internal constant MSG_TYPE_SEND = 1;
    uint32 internal constant CONFIG_TYPE_EXECUTOR = 1;
    uint32 internal constant CONFIG_TYPE_ULN = 2;

    // ------------------------------------------------------------------ read-only

    /// @notice Fails closed unless the current chain and its LayerZero route match the pinned evidence.
    function preflight() public view returns (TestnetRoutes.Route memory r) {
        r = TestnetRoutes.current();
        _preflightRoute(r);
    }

    /// @dev Checks the endpoint's DEFAULT route. Per-app overrides are checked separately by `_verifyWiring`.
    function _preflightRoute(TestnetRoutes.Route memory r) internal view {
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(r.endpoint);
        require(r.endpoint.code.length > 0, "SAIRI: endpoint has no code");
        require(ep.eid() == r.localEid, "SAIRI: endpoint eid mismatch");
        require(ep.isSupportedEid(r.remoteEid), "SAIRI: remote eid unsupported");
        require(ep.defaultSendLibrary(r.remoteEid) == r.sendLib, "SAIRI: default send library changed");
        require(ep.defaultReceiveLibrary(r.remoteEid) == r.receiveLib, "SAIRI: default receive library changed");
        require(r.dvn.code.length > 0 && r.executor.code.length > 0, "SAIRI: worker has no code");
        _requireUln(IUlnDefaults(r.sendLib).getUlnConfig(address(0), r.remoteEid), r.dvn, r.sendConfirmations);
        _requireUln(IUlnDefaults(r.receiveLib).getUlnConfig(address(0), r.remoteEid), r.dvn, r.receiveConfirmations);
        ExecutorConfig memory exec = IUlnDefaults(r.sendLib).getExecutorConfig(address(0), r.remoteEid);
        require(exec.executor == r.executor, "SAIRI: default executor changed");
        require(exec.maxMessageSize >= r.maxMessageSize, "SAIRI: max message size too small");
    }

    // ------------------------------------------------------------------ deployment

    /// @notice Base Sepolia only: deploys the valueless stand-in token and the SairiOFTAdapter lockbox.
    function deployCanonical() external returns (address token, address adapter) {
        TestnetRoutes.Route memory r = preflight();
        require(r.chainId == TestnetRoutes.BASE_SEPOLIA_CHAIN_ID, "SAIRI: deployCanonical is Base Sepolia only");
        address operator = _operator();
        vm.startBroadcast(operator);
        token = address(new SairiTestnetToken(operator, STAND_IN_SUPPLY));
        adapter = address(new SairiOFTAdapter(token, r.endpoint, operator, _guards(r.remoteEid)));
        vm.stopBroadcast();
    }

    /// @notice Robinhood Chain testnet only: deploys the backed representation (no admin mint).
    function deployRepresentation() external returns (address backed) {
        TestnetRoutes.Route memory r = preflight();
        require(r.chainId == TestnetRoutes.ROBINHOOD_TESTNET_CHAIN_ID, "SAIRI: deployRepresentation is RH only");
        address operator = _operator();
        vm.startBroadcast(operator);
        backed = address(
            new SairiBackedOFT(
                "Backed SAIRI Testnet Stand-in (not SAIRI)", "bSAIRI-TEST", r.endpoint, operator, _guards(r.remoteEid)
            )
        );
        vm.stopBroadcast();
    }

    // ------------------------------------------------------------------ wiring

    /// @notice Sets the once-only peer, enforced lzReceive gas, and PINS the send/receive libraries, the
    /// LayerZero Labs DVN, confirmations and executor explicitly (so later default changes cannot silently
    /// alter the route). Idempotent where LayerZero allows; reverts on any conflicting existing value.
    function wire() external {
        TestnetRoutes.Route memory r = preflight();
        (address local, address remote) = _apps(r);
        address operator = _operator();
        _requireApp(local, r, operator);

        vm.startBroadcast(operator);
        _wirePeerAndOptions(local, remote, r);
        _pinLibraries(local, r);
        _pinConfig(local, r);
        vm.stopBroadcast();

        verifyWiring(local, remote);
    }

    /// @notice Read-only check of the current chain's app: the EFFECTIVE per-app route (peer, libraries, DVN,
    /// confirmations, executor, exact enforced options) must equal the pinned route. Defaults being unchanged is
    /// not enough, because the owner/delegate can override any of these per app.
    function verifyWiring(address local, address remote) public view {
        _verifyWiring(preflight(), local, remote);
    }

    /// @notice Exact enforced options for SEND: type-3 executor lzReceive option with `LZ_RECEIVE_GAS`, no value.
    function expectedEnforcedOptions() public pure returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(LZ_RECEIVE_GAS, 0);
    }

    function _verifyWiring(TestnetRoutes.Route memory r, address local, address remote) internal view {
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(r.endpoint);
        require(SairiOFTAdapter(local).peers(r.remoteEid) == bytes32(uint256(uint160(remote))), "SAIRI: peer mismatch");
        require(ep.getSendLibrary(local, r.remoteEid) == r.sendLib, "SAIRI: send library not pinned");
        require(!ep.isDefaultSendLibrary(local, r.remoteEid), "SAIRI: send library still default");
        (address recvLib, bool recvDefault) = ep.getReceiveLibrary(local, r.remoteEid);
        require(recvLib == r.receiveLib && !recvDefault, "SAIRI: receive library not pinned");
        ExecutorConfig memory exec =
            abi.decode(ep.getConfig(local, r.sendLib, r.remoteEid, CONFIG_TYPE_EXECUTOR), (ExecutorConfig));
        require(exec.executor == r.executor && exec.maxMessageSize == r.maxMessageSize, "SAIRI: executor");
        _requireUln(
            abi.decode(ep.getConfig(local, r.sendLib, r.remoteEid, CONFIG_TYPE_ULN), (UlnConfig)),
            r.dvn,
            r.sendConfirmations
        );
        _requireUln(
            abi.decode(ep.getConfig(local, r.receiveLib, r.remoteEid, CONFIG_TYPE_ULN), (UlnConfig)),
            r.dvn,
            r.receiveConfirmations
        );
        require(
            keccak256(SairiOFTAdapter(local).enforcedOptions(r.remoteEid, MSG_TYPE_SEND))
                == keccak256(expectedEnforcedOptions()),
            "SAIRI: enforced options mismatch"
        );
    }

    function _wirePeerAndOptions(address local, address remote, TestnetRoutes.Route memory r) internal {
        bytes32 remotePeer = bytes32(uint256(uint160(remote)));
        bytes32 currentPeer = SairiOFTAdapter(local).peers(r.remoteEid);
        if (currentPeer == bytes32(0)) {
            SairiOFTAdapter(local).setPeer(r.remoteEid, remotePeer);
        } else {
            require(currentPeer == remotePeer, "SAIRI: different peer already set");
        }
        EnforcedOptionParam[] memory enforced = new EnforcedOptionParam[](1);
        enforced[0] = EnforcedOptionParam(r.remoteEid, MSG_TYPE_SEND, expectedEnforcedOptions());
        SairiOFTAdapter(local).setEnforcedOptions(enforced);
    }

    function _pinLibraries(address local, TestnetRoutes.Route memory r) internal {
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(r.endpoint);
        if (ep.isDefaultSendLibrary(local, r.remoteEid)) {
            ep.setSendLibrary(local, r.remoteEid, r.sendLib);
        } else {
            require(ep.getSendLibrary(local, r.remoteEid) == r.sendLib, "SAIRI: different send library set");
        }
        (address recvLib, bool recvDefault) = ep.getReceiveLibrary(local, r.remoteEid);
        if (recvDefault) ep.setReceiveLibrary(local, r.remoteEid, r.receiveLib, 0);
        else require(recvLib == r.receiveLib, "SAIRI: different receive library already set");
    }

    function _pinConfig(address local, TestnetRoutes.Route memory r) internal {
        SetConfigParam[] memory sendCfg = new SetConfigParam[](2);
        sendCfg[0] =
            SetConfigParam(r.remoteEid, CONFIG_TYPE_EXECUTOR, abi.encode(ExecutorConfig(r.maxMessageSize, r.executor)));
        sendCfg[1] = SetConfigParam(r.remoteEid, CONFIG_TYPE_ULN, abi.encode(_uln(r.dvn, r.sendConfirmations)));
        ILayerZeroEndpointV2(r.endpoint).setConfig(local, r.sendLib, sendCfg);
        SetConfigParam[] memory recvCfg = new SetConfigParam[](1);
        recvCfg[0] = SetConfigParam(r.remoteEid, CONFIG_TYPE_ULN, abi.encode(_uln(r.dvn, r.receiveConfirmations)));
        ILayerZeroEndpointV2(r.endpoint).setConfig(local, r.receiveLib, recvCfg);
    }

    // ------------------------------------------------------------------ roundtrip leg

    /// @notice Sends `amountLD` from the current chain's app to the operator on the peer chain.
    /// Base Sepolia: locks stand-in tokens in the adapter. Robinhood testnet: burns backed tokens.
    /// Reverts if the LayerZero quote exceeds `maxNativeFee` (wei).
    function send(uint256 amountLD, uint256 maxNativeFee)
        external
        returns (bytes32 guid, uint64 nonce, uint256 nativeFee, uint256 amountReceivedLD)
    {
        TestnetRoutes.Route memory r = preflight();
        (address local, address remote) = _apps(r);
        address operator = _operator();
        _requireSendReady(r, local, remote, operator);
        SendParam memory p = SendParam(r.remoteEid, bytes32(uint256(uint160(operator))), amountLD, amountLD, "", "", "");
        MessagingFee memory fee = SairiOFTAdapter(local).quoteSend(p, false);
        require(fee.nativeFee <= maxNativeFee, "SAIRI: LayerZero fee above maxNativeFee");
        require(fee.lzTokenFee == 0, "SAIRI: unexpected lzToken fee");

        vm.startBroadcast(operator);
        if (r.chainId == TestnetRoutes.BASE_SEPOLIA_CHAIN_ID) {
            SairiTestnetToken(SairiOFTAdapter(local).token()).approve(local, amountLD);
        }
        (MessagingReceipt memory receipt, OFTReceipt memory oft) =
            SairiOFTAdapter(local).send{value: fee.nativeFee}(p, fee, operator);
        vm.stopBroadcast();
        return (receipt.guid, receipt.nonce, receipt.fee.nativeFee, oft.amountReceivedLD);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Everything `send` requires before broadcasting: our app, owned/delegated by the operator, and its
    /// effective per-app route still exactly the pinned one.
    function _requireSendReady(TestnetRoutes.Route memory r, address local, address remote, address operator)
        internal
        view
    {
        _requireApp(local, r, operator);
        _verifyWiring(r, local, remote);
    }

    function _operator() internal view returns (address operator) {
        operator = vm.envAddress("SAIRI_TESTNET_OPERATOR");
        require(operator != address(0), "SAIRI: SAIRI_TESTNET_OPERATOR unset");
    }

    function _apps(TestnetRoutes.Route memory r) internal view returns (address local, address remote) {
        address adapter = vm.envAddress("SAIRI_TESTNET_ADAPTER");
        address backed = vm.envAddress("SAIRI_TESTNET_BACKED");
        require(adapter != address(0) && backed != address(0) && adapter != backed, "SAIRI: app addresses unset");
        (local, remote) = r.chainId == TestnetRoutes.BASE_SEPOLIA_CHAIN_ID ? (adapter, backed) : (backed, adapter);
    }

    /// @dev Local app must be our contract on this endpoint, owned by the operator, routed to the remote EID.
    function _requireApp(address app, TestnetRoutes.Route memory r, address operator) internal view {
        require(app.code.length > 0, "SAIRI: local app has no code");
        require(address(SairiOFTAdapter(app).endpoint()) == r.endpoint, "SAIRI: app endpoint mismatch");
        require(SairiOFTAdapter(app).owner() == operator, "SAIRI: operator is not app owner");
        require(SairiOFTGuards(app).peerEid() == r.remoteEid, "SAIRI: app peerEid mismatch");
        require(IEndpointDelegates(r.endpoint).delegates(app) == operator, "SAIRI: operator is not delegate");
    }

    function _guards(uint32 peerEid) internal pure returns (SairiOFTGuards.GuardConfig memory) {
        return SairiOFTGuards.GuardConfig(peerEid, EXPOSURE_CAP, RATE_WINDOW_SECONDS, RATE_LIMIT_PER_WINDOW);
    }

    function _uln(address dvn, uint64 confirmations) internal pure returns (UlnConfig memory cfg) {
        address[] memory required = new address[](1);
        required[0] = dvn;
        cfg = UlnConfig(confirmations, 1, 0, 0, required, new address[](0));
    }

    function _requireUln(UlnConfig memory cfg, address dvn, uint64 confirmations) internal pure {
        require(cfg.confirmations == confirmations, "SAIRI: ULN confirmations mismatch");
        require(cfg.requiredDVNCount == 1 && cfg.requiredDVNs.length == 1, "SAIRI: ULN required DVN count");
        require(cfg.requiredDVNs[0] == dvn, "SAIRI: ULN required DVN mismatch");
        require(cfg.optionalDVNCount == 0 && cfg.optionalDVNThreshold == 0, "SAIRI: ULN optional DVNs present");
    }
}
