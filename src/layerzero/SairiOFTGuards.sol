// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice EXPERIMENTAL safety controls shared by the SAIRI LayerZero OFT adapter and backed OFT.
/// UNAUDITED; intended for testnet integration only.
///
/// - Single route: exactly one remote endpoint ID (`peerEid`); the peer for it can be set once and never
///   replaced, so the owner cannot later re-point the route at a different (possibly unbacked) contract.
/// - Pause: blocks outbound sends and inbound credits. Paused inbound deliveries revert at the
///   destination and stay verified/retryable at the LayerZero endpoint; nothing is confiscated.
/// - Outbound rate limit (local decimals) over fixed windows, and an exposure cap enforced by each side.
/// - Shared-decimal dust is rejected instead of silently left with the sender.
///
/// RESIDUAL GOVERNANCE RISK: the owner/delegate can still change message libraries, DVNs and executors at
/// the LayerZero endpoint, pause indefinitely or set a zero rate limit / low cap. A compromised verifier
/// configuration can authorize unbacked credits (bounded on the canonical side by `totalLocked`).
abstract contract SairiOFTGuards is Ownable {
    struct GuardConfig {
        uint32 peerEid;
        uint256 exposureCap;
        uint256 rateWindowSeconds;
        uint256 rateLimitPerWindow;
    }

    error InvalidGuardConfig();
    error UnsupportedEid(uint32 eid);
    error PeerAlreadySet();
    error InvalidPeer();
    error GuardPaused();
    error InvalidSendRecipient();
    error ComposeUnsupported();
    error DustAmount(uint256 amountLD);
    error RateLimitExceeded();
    error ExposureCapExceeded();

    event PausedSet(bool paused);
    event ExposureCapSet(uint256 exposureCap);
    event RateLimitSet(uint256 rateLimitPerWindow);

    uint32 public immutable peerEid;
    uint256 public immutable rateWindowSeconds;

    bool public paused;
    uint256 public exposureCap;
    uint256 public rateLimitPerWindow;
    uint256 public currentWindowId;
    uint256 public usedInWindow;

    constructor(GuardConfig memory cfg) {
        if (cfg.peerEid == 0 || cfg.rateWindowSeconds == 0) revert InvalidGuardConfig();
        peerEid = cfg.peerEid;
        rateWindowSeconds = cfg.rateWindowSeconds;
        exposureCap = cfg.exposureCap;
        rateLimitPerWindow = cfg.rateLimitPerWindow;
        emit ExposureCapSet(cfg.exposureCap);
        emit RateLimitSet(cfg.rateLimitPerWindow);
    }

    /// @dev Disabled: renouncing while paused (or with a zero rate limit) would strand redemptions forever.
    function renounceOwnership() public view virtual override onlyOwner {
        revert InvalidGuardConfig();
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

    /// @dev Peer may be set exactly once, only for `peerEid`, and never to zero.
    function _assertPeerUpdate(uint32 eid, bytes32 newPeer, bytes32 currentPeer) internal view {
        if (eid != peerEid) revert UnsupportedEid(eid);
        if (newPeer == bytes32(0)) revert InvalidPeer();
        if (currentPeer != bytes32(0)) revert PeerAlreadySet();
    }

    function _assertNotPaused() internal view {
        if (paused) revert GuardPaused();
    }

    /// @dev Validates an outbound request before LayerZero processing. `self` is the destination peer.
    function _assertOutbound(uint32 dstEid, bytes32 to, uint256 composeLength, bytes32 destinationPeer) internal view {
        _assertNotPaused();
        if (dstEid != peerEid) revert UnsupportedEid(dstEid);
        // The destination contract itself is never a valid recipient (self-alias on the peer side).
        if (to == bytes32(0) || to == destinationPeer || uint256(to) >> 160 != 0) revert InvalidSendRecipient();
        if (composeLength != 0) revert ComposeUnsupported();
    }

    /// @dev Fixed windows aligned to multiples of `rateWindowSeconds`.
    function _consumeRate(uint256 amountLD) internal {
        uint256 windowId = block.timestamp / rateWindowSeconds;
        if (windowId != currentWindowId) {
            currentWindowId = windowId;
            usedInWindow = 0;
        }
        uint256 used = usedInWindow + amountLD;
        if (used > rateLimitPerWindow) revert RateLimitExceeded();
        usedInWindow = used;
    }
}
