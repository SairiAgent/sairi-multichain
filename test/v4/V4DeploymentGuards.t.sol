// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {TestBase} from "../utils/TestBase.sol";
import {MockERC20} from "../mocks/MockTokens.sol";
import {SairiV4Lab} from "../../script/testnet/SairiV4Lab.s.sol";
import {SairiHookFactory} from "../../src/v4/SairiHookFactory.sol";
import {SairiCreatorFeeHook} from "../../src/v4/SairiCreatorFeeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract V4DeploymentGuardsTest is TestBase {
    function testNoMainnetLabDeployment() public {
        SairiV4Lab lab = new SairiV4Lab();
        vm.chainId(4663);
        vm.expectRevert(bytes("Robinhood TESTNET only"));
        lab.deployLab(address(1));
        vm.chainId(8453);
        vm.expectRevert(bytes("Robinhood TESTNET only"));
        lab.deployLab(address(1));
    }

    function testAcknowledgementRequired() public {
        SairiV4Lab lab = new SairiV4Lab();
        vm.chainId(46630);
        vm.setEnv("SAIRI_TESTNET_CONFIRM", "not-approved");
        vm.expectRevert(bytes("acknowledgement"));
        lab.deployLab(address(1));
    }

    function testFactorySaltAndImmutableBinding() public {
        SairiHookFactory factory = new SairiHookFactory();
        // Code-length validation is NOT manager authentication, intentionally illustrated here.
        MockERC20 managerStandin = new MockERC20("Not a manager", "NM", 18);
        MockERC20 token = new MockERC20("Token", "T", 18);
        (bytes32 salt, address predicted) =
            factory.findSalt(IPoolManager(address(managerStandin)), address(token), 0, 200000);
        SairiCreatorFeeHook hook = factory.deploy(IPoolManager(address(managerStandin)), address(token), salt);
        assertEq(address(hook), predicted, "CREATE2 binding");
        assertEq(hook.representation(), address(token), "token binding");
        assertEq(address(hook.manager()), address(managerStandin), "manager binding");
        assertEq(uint160(address(hook)) & 16383, 8260, "permissions");
        vm.expectRevert();
        factory.deploy(IPoolManager(address(managerStandin)), address(token), salt);
    }
}
