// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILocalEndpoint, ILocalMessageReceiver} from "../../src/interfaces/ILocalMessaging.sol";

/// @notice TEST MOCK ONLY. Simulates one chain's messaging endpoint inside a single local EVM.
/// It is NOT LayerZero and performs no verification; delivery is driven manually by the test operator.
/// Every sent message stays in `outbox` with its status, which tests use as the in-flight ledger.
contract LocalEndpointMock is ILocalEndpoint {
    enum Status {
        None,
        Pending,
        Delivered,
        Failed
    }

    struct Message {
        uint32 srcEid;
        bytes32 sender;
        uint32 dstEid;
        bytes32 receiver;
        uint64 nonce;
        bytes payload;
        Status status;
    }

    error NotOperator();
    error UnknownRemote();
    error NotRemote();
    error NotRetryable();

    event MessageSent(uint256 indexed id, uint32 dstEid, bytes32 receiver, uint64 nonce);
    event MessageRelayed(uint256 indexed id, bool delivered);

    uint32 public immutable eid;
    address public immutable operator;

    mapping(uint32 => LocalEndpointMock) public remotes;
    mapping(bytes32 => uint64) public pathNonce;
    Message[] internal _outbox;

    constructor(uint32 eid_) {
        eid = eid_;
        operator = msg.sender;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    function connect(uint32 remoteEid, LocalEndpointMock remote) external onlyOperator {
        remotes[remoteEid] = remote;
    }

    function send(uint32 dstEid, bytes32 receiver, bytes calldata payload) external returns (uint64 nonce) {
        if (address(remotes[dstEid]) == address(0)) revert UnknownRemote();
        nonce = ++pathNonce[keccak256(abi.encode(msg.sender, dstEid, receiver))];
        _outbox.push(
            Message({
                srcEid: eid,
                sender: bytes32(uint256(uint160(msg.sender))),
                dstEid: dstEid,
                receiver: receiver,
                nonce: nonce,
                payload: payload,
                status: Status.Pending
            })
        );
        emit MessageSent(_outbox.length - 1, dstEid, receiver, nonce);
    }

    /// @notice Delivers a pending message, or retries a previously failed one. Delivered messages
    /// cannot be relayed again.
    function relay(uint256 id) external onlyOperator returns (bool delivered) {
        Message storage m = _outbox[id];
        if (m.status != Status.Pending && m.status != Status.Failed) revert NotRetryable();
        delivered = remotes[m.dstEid].deliverFromRemote(m.srcEid, m.sender, m.receiver, m.nonce, m.payload);
        m.status = delivered ? Status.Delivered : Status.Failed;
        emit MessageRelayed(id, delivered);
    }

    /// @notice Destination half of `relay`; only the connected source endpoint may call it.
    function deliverFromRemote(uint32 srcEid, bytes32 sender, bytes32 receiver, uint64 nonce, bytes calldata payload)
        external
        returns (bool ok)
    {
        if (msg.sender != address(remotes[srcEid]) || msg.sender == address(0)) revert NotRemote();
        address target = address(uint160(uint256(receiver)));
        try ILocalMessageReceiver(target).receiveMessage(srcEid, sender, nonce, payload) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    /// @notice ADVERSARIAL TEST HOOK: simulates a faulty/compromised endpoint calling a receiver with
    /// arbitrary data. Reverts propagate so tests can assert the receiver's own checks.
    function rawDeliver(address receiver, uint32 srcEid, bytes32 sender, uint64 nonce, bytes calldata payload)
        external
        onlyOperator
    {
        ILocalMessageReceiver(receiver).receiveMessage(srcEid, sender, nonce, payload);
    }

    function messageCount() external view returns (uint256) {
        return _outbox.length;
    }

    function messageAt(uint256 id) external view returns (Message memory) {
        return _outbox[id];
    }

    function statusOf(uint256 id) external view returns (Status) {
        return _outbox[id].status;
    }
}
