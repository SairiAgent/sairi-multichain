// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILocalEndpoint, ILocalMessageReceiver} from "../interfaces/ILocalMessaging.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";

/// @notice Shared logic for the EXPERIMENTAL lockbox / backed-representation pair (LOCAL HARNESS ONLY).
/// Messages travel through an `ILocalEndpoint`; this is not a LayerZero integration.
///
/// Amounts on the wire are in `sharedDecimals` units ("SD"). Local amounts ("LD") must be exact
/// multiples of `conversionRate`; dust is rejected rather than silently truncated.
///
/// Every outbound message is recorded by nonce (`outboundAmountSD`) and every consumed inbound nonce
/// is recorded (`inboundConsumed`), so in-flight liabilities can be reconstructed per message.
abstract contract BridgeAppBase is ILocalMessageReceiver, ReentrancyGuard {
    struct BridgeConfig {
        address endpoint;
        uint32 localEid;
        uint32 peerEid;
        bytes32 peer;
        address owner;
        uint8 sharedDecimals;
        uint256 exposureCap;
        uint256 rateWindowSeconds;
        uint256 rateLimitPerWindow;
    }

    error InvalidConfig();
    error NotOwner();
    error Paused();
    error UnauthorizedEndpoint();
    error UnauthorizedPeer();
    error Replay();
    error InvalidMessage();
    error InvalidRecipient();
    error ZeroAmount();
    error Dust();
    error RateLimitExceeded();
    error ExposureCapExceeded();
    error DuplicateOutboundNonce();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PausedSet(bool paused);
    event ExposureCapSet(uint256 exposureCap);
    event RateLimitSet(uint256 rateLimitPerWindow);
    event OutboundSent(uint64 indexed nonce, address indexed sender, address indexed recipient, uint256 amountSD);
    event InboundCredited(uint64 indexed nonce, address indexed recipient, uint256 amountSD);

    address public immutable endpoint;
    uint32 public immutable localEid;
    uint32 public immutable peerEid;
    bytes32 public immutable peer;
    uint8 public immutable sharedDecimals;
    uint8 public immutable localDecimals;
    uint256 public immutable conversionRate;
    uint256 public immutable rateWindowSeconds;

    address public owner;
    bool public paused;
    uint256 public exposureCap;
    uint256 public rateLimitPerWindow;
    uint256 public currentWindowId;
    uint256 public usedInWindow;

    mapping(uint64 => uint256) public outboundAmountSD;
    mapping(uint64 => bool) public inboundConsumed;
    uint256 public totalOutboundSD;
    uint256 public totalInboundSD;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(BridgeConfig memory cfg, uint8 localDecimals_) {
        if (
            cfg.endpoint == address(0) || cfg.owner == address(0) || cfg.peer == bytes32(0) || cfg.localEid == 0
                || cfg.peerEid == 0 || cfg.localEid == cfg.peerEid || cfg.rateWindowSeconds == 0
                || cfg.sharedDecimals > localDecimals_ || localDecimals_ - cfg.sharedDecimals > 30
        ) revert InvalidConfig();
        endpoint = cfg.endpoint;
        localEid = cfg.localEid;
        peerEid = cfg.peerEid;
        peer = cfg.peer;
        sharedDecimals = cfg.sharedDecimals;
        localDecimals = localDecimals_;
        conversionRate = 10 ** (localDecimals_ - cfg.sharedDecimals);
        rateWindowSeconds = cfg.rateWindowSeconds;
        owner = cfg.owner;
        exposureCap = cfg.exposureCap;
        rateLimitPerWindow = cfg.rateLimitPerWindow;
        emit OwnershipTransferred(address(0), cfg.owner);
    }

    // ---------------------------------------------------------------- owner
    // The owner controls liveness and exposure (pause, exposure cap, outbound rate limit) but cannot
    // directly mint or withdraw collateral. RESIDUAL GOVERNANCE RISK: pausing, or setting a zero
    // outbound rate limit / low exposure cap, can stall bridging and redemption indefinitely.

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidConfig();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setExposureCap(uint256 cap) external onlyOwner {
        exposureCap = cap;
        emit ExposureCapSet(cap);
    }

    function setRateLimit(uint256 limitPerWindow) external onlyOwner {
        rateLimitPerWindow = limitPerWindow;
        emit RateLimitSet(limitPerWindow);
    }

    // ---------------------------------------------------------------- inbound

    /// @inheritdoc ILocalMessageReceiver
    function receiveMessage(uint32 srcEid, bytes32 sender, uint64 nonce, bytes calldata payload) external nonReentrant {
        if (msg.sender != endpoint) revert UnauthorizedEndpoint();
        if (srcEid != peerEid || sender != peer) revert UnauthorizedPeer();
        if (inboundConsumed[nonce]) revert Replay();
        if (paused) revert Paused();
        if (payload.length != 64) revert InvalidMessage();
        (address recipient, uint256 amountSD) = abi.decode(payload, (address, uint256));
        if (recipient == address(0) || amountSD == 0) revert InvalidMessage();

        inboundConsumed[nonce] = true;
        totalInboundSD += amountSD;
        _creditInbound(recipient, amountSD * conversionRate);
        emit InboundCredited(nonce, recipient, amountSD);
    }

    // ---------------------------------------------------------------- outbound helpers

    /// @dev Validates an outbound request, consumes rate capacity and returns the shared-decimal amount.
    function _prepareOutbound(address recipient, uint256 amountLD) internal returns (uint256 amountSD) {
        if (paused) revert Paused();
        // The destination contract itself is never a valid recipient (self-alias on the peer side).
        if (recipient == address(0) || bytes32(uint256(uint160(recipient))) == peer) revert InvalidRecipient();
        if (amountLD == 0) revert ZeroAmount();
        if (amountLD % conversionRate != 0) revert Dust();
        _consumeRate(amountLD);
        amountSD = amountLD / conversionRate;
    }

    function _dispatch(address recipient, uint256 amountSD) internal returns (uint64 nonce) {
        nonce = ILocalEndpoint(endpoint).send(peerEid, peer, abi.encode(recipient, amountSD));
        if (outboundAmountSD[nonce] != 0) revert DuplicateOutboundNonce();
        outboundAmountSD[nonce] = amountSD;
        totalOutboundSD += amountSD;
        emit OutboundSent(nonce, msg.sender, recipient, amountSD);
    }

    /// @dev Fixed windows aligned to multiples of `rateWindowSeconds`.
    function _consumeRate(uint256 amountLD) private {
        uint256 windowId = block.timestamp / rateWindowSeconds;
        if (windowId != currentWindowId) {
            currentWindowId = windowId;
            usedInWindow = 0;
        }
        uint256 used = usedInWindow + amountLD;
        if (used > rateLimitPerWindow) revert RateLimitExceeded();
        usedInWindow = used;
    }

    /// @dev Credits an authenticated, non-replayed inbound amount (local decimals).
    function _creditInbound(address recipient, uint256 amountLD) internal virtual;
}
