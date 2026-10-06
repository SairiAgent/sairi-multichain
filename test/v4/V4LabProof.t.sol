// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {TestBase} from "../utils/TestBase.sol";
import {MockERC20} from "../mocks/MockTokens.sol";
import {ArtifactVm} from "./V4FeeIntegration.t.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SairiHookFactory} from "../../src/v4/SairiHookFactory.sol";
import {SairiCreatorFeeHook} from "../../src/v4/SairiCreatorFeeHook.sol";
import {SairiLabQuote, SairiV4ProofDriver} from "../../script/testnet/SairiV4Proof.s.sol";

contract V4LabProofTest is TestBase {
    MockERC20 a;
    SairiCreatorFeeHook hook;
    SairiLabQuote quote;
    SairiV4ProofDriver proof;

    function setUp() public {
        bytes memory code = abi.encodePacked(
            ArtifactVm(address(vm)).getCode("out/PoolManager.sol/PoolManager.json"), abi.encode(address(this))
        );
        address manager;
        assembly { manager := create(0, add(code, 32), mload(code)) }
        require(manager != address(0));
        a = new MockERC20("Representation stand-in", "REP", 18);
        a.mint(address(this), 100 ether);
        SairiHookFactory factory = new SairiHookFactory();
        (bytes32 salt,) = factory.findSalt(IPoolManager(manager), address(a), 0, 200_000);
        hook = factory.deploy(IPoolManager(manager), address(a), salt);
        vm.chainId(46630);
        quote = new SairiLabQuote(address(this));
        proof = new SairiV4ProofDriver(hook, address(quote), address(this));
        a.approve(address(proof), 40 ether);
        quote.approve(address(proof), 40 ether);
    }

    function testLabFullProofAndNoRepeat() public {
        uint256 supply = a.totalSupply();
        uint256 recipientRep = a.balanceOf(hook.BENEFICIARY());
        uint256 recipientQuote = quote.balanceOf(hook.BENEFICIARY());
        proof.runProof();
        assertTrue(proof.completed(), "complete");
        assertEq(a.totalSupply(), supply, "supply unchanged");
        assertTrue(a.balanceOf(hook.BENEFICIARY()) > recipientRep, "real rep claim");
        assertTrue(quote.balanceOf(hook.BENEFICIARY()) > recipientQuote, "real quote claim");
        assertEq(a.balanceOf(address(proof)), 0, "rep returned");
        assertEq(quote.balanceOf(address(proof)), 0, "quote returned");
        assertEq(a.allowance(address(this), address(proof)), 0, "approval consumed");
        vm.expectRevert();
        proof.runProof();
    }

    function testLabUnauthorizedAndSpoofedCallback() public {
        vm.prank(address(123));
        vm.expectRevert();
        proof.runProof();
        vm.expectRevert();
        proof.unlockCallback(abi.encode(uint8(1), true, true));
        assertTrue(!proof.completed(), "not executed");
    }

    function testLabFundingFailureAtomic() public {
        uint256 bal = a.balanceOf(address(this));
        quote.approve(address(proof), 0);
        vm.expectRevert();
        proof.runProof();
        assertEq(a.balanceOf(address(this)), bal, "first transfer rolled back");
        assertTrue(!proof.completed(), "retryable");
        quote.approve(address(proof), 40 ether);
        proof.runProof();
        assertTrue(proof.completed(), "retry succeeded");
    }

    function testLabBeneficiaryIsOperatorCleanup() public {
        address operator = hook.BENEFICIARY();
        SairiV4ProofDriver same = new SairiV4ProofDriver(hook, address(quote), operator);
        a.transfer(operator, 100 ether);
        quote.transfer(operator, 100 ether);
        vm.startPrank(operator);
        a.approve(address(same), 40 ether);
        quote.approve(address(same), 40 ether);
        same.runProof();
        vm.stopPrank();
        assertEq(a.balanceOf(address(same)), 0, "all driver rep refunded");
        assertLe(100 ether - a.balanceOf(operator), 10, "only core raw-unit rounding dust");
        assertEq(hook.accrued(address(a)), hook.delivered(address(a)), "all rep fees claimed");
    }

    function testLabChainGate() public {
        vm.chainId(1);
        vm.expectRevert();
        proof.runProof();
        vm.expectRevert();
        new SairiLabQuote(address(this));
        vm.expectRevert();
        new SairiV4ProofDriver(hook, address(quote), address(this));
    }
}
