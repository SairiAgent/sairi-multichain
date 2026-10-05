// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice LOCAL HARNESS messaging interface. This is NOT LayerZero or any production messaging
/// protocol; it only lets tests drive delivery through a mock endpoint.
interface ILocalEndpoint {
    /// @return nonce Per-path nonce assigned by the endpoint.
    function send(uint32 dstEid, bytes32 receiver, bytes calldata payload) external returns (uint64 nonce);
}

/// @notice Receiver hook invoked by the local endpoint on delivery.
interface ILocalMessageReceiver {
    function receiveMessage(uint32 srcEid, bytes32 sender, uint64 nonce, bytes calldata payload) external;
}
