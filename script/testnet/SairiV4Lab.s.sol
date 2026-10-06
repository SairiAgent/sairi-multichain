// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SairiHookFactory} from "../../src/v4/SairiHookFactory.sol";
import {SairiCreatorFeeHook} from "../../src/v4/SairiCreatorFeeHook.sol";

interface V4LabVm {
    function getCode(string calldata) external returns (bytes memory);
    function envString(string calldata) external returns (string memory);
    function envAddress(string calldata) external returns (address);
    function startBroadcast(address) external;
    function stopBroadcast() external;
}

/// @notice SELF-DEPLOYED REAL-CORE LAB ONLY. NOT canonical Uniswap infrastructure.
/// Deploys no bridge, no new representation, no LP position. Attach existing test stand-in OFT.
contract SairiV4Lab {
    V4LabVm constant vm = V4LabVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    event LabDeployed(address manager, address factory, address hook, address representation, address beneficiary);

    function deployLab(address representation) external {
        require(block.chainid == 46630, "Robinhood TESTNET only");
        require(keccak256(bytes(vm.envString("SAIRI_TESTNET_CONFIRM"))) == keccak256("testnet-only"), "acknowledgement");
        address operator = vm.envAddress("SAIRI_TESTNET_OPERATOR");
        require(operator != address(0) && representation.code.length != 0, "invalid operator/representation");
        bytes memory code = abi.encodePacked(vm.getCode("out/PoolManager.sol/PoolManager.json"), abi.encode(operator));
        vm.startBroadcast(operator);
        address manager;
        assembly { manager := create(0, add(code, 32), mload(code)) }
        require(manager != address(0), "manager deploy");
        SairiHookFactory factory = new SairiHookFactory();
        vm.stopBroadcast();
        // Read-only local EVM mining; never include search in a signed transaction.
        (bytes32 salt,) = factory.findSalt(IPoolManager(manager), representation, 0, 200_000);
        vm.startBroadcast(operator);
        SairiCreatorFeeHook hook = factory.deploy(IPoolManager(manager), representation, salt);
        vm.stopBroadcast();
        emit LabDeployed(manager, address(factory), address(hook), representation, hook.BENEFICIARY());
    }
}
