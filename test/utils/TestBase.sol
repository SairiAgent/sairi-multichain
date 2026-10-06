// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal subset of Foundry cheatcodes used by this repository (no forge-std dependency).
interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
    function deal(address account, uint256 newBalance) external;
    function chainId(uint256 newChainId) external;
    function setEnv(string calldata name, string calldata value) external;
    function toString(address value) external pure returns (string memory);
    function createSelectFork(string calldata urlOrAlias, uint256 blockNumber) external returns (uint256 forkId);
    function rpc(string calldata urlOrAlias, string calldata method, string calldata params)
        external
        returns (bytes memory data);
    function selectFork(uint256 forkId) external;
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function warp(uint256 timestamp) external;
    function expectRevert() external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function getNonce(address account) external view returns (uint64);
}

/// @notice Minimal assertion helpers. Failures revert with a descriptive custom error.
abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bool public constant IS_TEST = true;

    error AssertionFailed(string reason);
    error AssertEqUint(uint256 left, uint256 right, string reason);
    error AssertEqAddress(address left, address right, string reason);
    error AssertGeUint(uint256 left, uint256 right, string reason);
    error AssertLeUint(uint256 left, uint256 right, string reason);

    function assertTrue(bool condition, string memory reason) internal pure {
        if (!condition) revert AssertionFailed(reason);
    }

    function assertEq(uint256 left, uint256 right, string memory reason) internal pure {
        if (left != right) revert AssertEqUint(left, right, reason);
    }

    function assertEq(address left, address right, string memory reason) internal pure {
        if (left != right) revert AssertEqAddress(left, right, reason);
    }

    function assertEq(bytes32 left, bytes32 right, string memory reason) internal pure {
        if (left != right) revert AssertionFailed(reason);
    }

    function assertEq(bool left, bool right, string memory reason) internal pure {
        if (left != right) revert AssertionFailed(reason);
    }

    function assertGe(uint256 left, uint256 right, string memory reason) internal pure {
        if (left < right) revert AssertGeUint(left, right, reason);
    }

    function assertLe(uint256 left, uint256 right, string memory reason) internal pure {
        if (left > right) revert AssertLeUint(left, right, reason);
    }

    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (min > max) revert AssertionFailed("bound: min > max");
        if (max - min == type(uint256).max) return x;
        return min + (x % (max - min + 1));
    }

    /// @dev CREATE address prediction (RLP of [deployer, nonce]) for nonces below 2**16.
    function predictCreate(address deployer, uint256 nonce) internal pure returns (address) {
        bytes memory data;
        if (nonce == 0) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80));
        } else if (nonce <= 0x7f) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce));
        } else if (nonce <= 0xff) {
            data = abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployer, bytes1(0x81), uint8(nonce));
        } else if (nonce <= 0xffff) {
            data = abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployer, bytes1(0x82), uint16(nonce));
        } else {
            revert AssertionFailed("predictCreate: nonce too large");
        }
        return address(uint160(uint256(keccak256(data))));
    }
}
