// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {SairiPairedFeeHook} from "./SairiPairedFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @notice Permissionless deterministic deployment, no ownership or fee authority.
contract SairiPairedHookFactory {
    event HookDeployed(address indexed hook, address indexed manager, address indexed representation);

    function deploy(IPoolManager manager, address representation, bytes32 salt)
        external
        returns (SairiPairedFeeHook hook)
    {
        hook = new SairiPairedFeeHook{salt: salt}(manager, representation);
        emit HookDeployed(address(hook), address(manager), representation);
    }

    function findSalt(IPoolManager manager, address representation, uint256 start, uint256 attempts)
        external
        view
        returns (bytes32 salt, address predicted)
    {
        bytes32 hash =
            keccak256(abi.encodePacked(type(SairiPairedFeeHook).creationCode, abi.encode(manager, representation)));
        for (uint256 i = 0; i < attempts; i++) {
            salt = bytes32(start + i);
            predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (uint160(predicted) & 16383 == 8396 && predicted.code.length == 0) return (salt, predicted);
        }
        revert("No salt in range");
    }
}
