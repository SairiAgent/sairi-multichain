// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestBase, Vm} from "../utils/TestBase.sol";

/// @notice Test helper: extracts LayerZero PacketV1 data from a real `EndpointV2.PacketSent` event.
abstract contract LzPacketCodec is TestBase {
    bytes32 internal constant PACKET_SENT_TOPIC = keccak256("PacketSent(bytes,bytes,address)");

    struct Packet {
        uint32 srcEid;
        uint32 dstEid;
        uint64 nonce;
        bytes32 sender;
        address receiver;
        bytes32 guid;
        bytes header;
        bytes message;
        bytes32 payloadHash;
    }

    /// @dev Requires exactly one PacketSent from `endpoint` in the recorded logs, sent via `sendLib`.
    function _capturePacket(address endpoint, address sendLib) internal returns (Packet memory pkt) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == endpoint && logs[i].topics.length > 0 && logs[i].topics[0] == PACKET_SENT_TOPIC) {
                if (found) revert AssertionFailed("multiple PacketSent");
                (bytes memory encoded,, address lib) = abi.decode(logs[i].data, (bytes, bytes, address));
                assertEq(lib, sendLib, "packet sent through expected SendUln302");
                pkt = _decodePacket(encoded);
                found = true;
            }
        }
        assertTrue(found, "PacketSent emitted by EndpointV2");
    }

    function _decodePacket(bytes memory encoded) internal pure returns (Packet memory pkt) {
        // PacketV1: version(1) nonce(8) srcEid(4) sender(32) dstEid(4) receiver(32) | guid(32) message
        assertTrue(encoded.length >= 113 && uint8(encoded[0]) == 1, "packet v1");
        pkt.header = _slice(encoded, 0, 81);
        pkt.payloadHash = keccak256(_slice(encoded, 81, encoded.length - 81));
        pkt.nonce = uint64(bytes8(_word(encoded, 1)));
        pkt.srcEid = uint32(bytes4(_word(encoded, 9)));
        pkt.sender = _word(encoded, 13);
        pkt.dstEid = uint32(bytes4(_word(encoded, 45)));
        pkt.receiver = address(uint160(uint256(_word(encoded, 49))));
        pkt.guid = _word(encoded, 81);
        pkt.message = _slice(encoded, 113, encoded.length - 113);
    }

    function _word(bytes memory data, uint256 offset) internal pure returns (bytes32 out) {
        assembly ("memory-safe") {
            out := mload(add(add(data, 32), offset))
        }
    }

    function _slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = data[start + i];
        }
    }
}
