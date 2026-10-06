// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {SairiPairedFeeHook} from "../../src/v4/SairiPairedFeeHook.sol";
import {SairiPairedHookFactory} from "../../src/v4/SairiPairedHookFactory.sol";
import {TestBase} from "../utils/TestBase.sol";
import {MockERC20} from "../mocks/MockTokens.sol";
import {ArtifactVm} from "./V4FeeIntegration.t.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SairiLabQuote} from "../../script/testnet/SairiV4Proof.s.sol";
import {SairiV4LpProofDriver} from "../../script/testnet/SairiV4LpProof.s.sol";

contract V4LpProofTest is TestBase {
    MockERC20 rep;
    SairiLabQuote quote;
    IPoolManager manager;
    SairiV4LpProofDriver proof;
    SairiPairedFeeHook hook;
    address constant OP = 0x26250e47500943464290A77ae3508a3001d9B69d;

    function setUp() public {
        vm.chainId(46630);
        bytes memory code = abi.encodePacked(
            ArtifactVm(address(vm)).getCode("out/PoolManager.sol/PoolManager.json"), abi.encode(address(0))
        );
        address deployed;
        assembly { deployed := create(0, add(code, 32), mload(code)) }
        manager = IPoolManager(deployed);
        rep = new MockERC20("Representation stand-in", "REP", 18);
        rep.mint(OP, 100 ether);
        quote = new SairiLabQuote(OP);
        SairiPairedHookFactory factory = new SairiPairedHookFactory();
        (bytes32 salt,) = factory.findSalt(manager, address(rep), 0, 200_000);
        hook = factory.deploy(manager, address(rep), salt);
        proof = new SairiV4LpProofDriver(manager, address(rep), address(quote), OP, hook);
        vm.startPrank(OP);
        rep.approve(address(proof), 40 ether);
        quote.approve(address(proof), 40 ether);
    }

    function testProofAllModesClaimsAndCleanup() public {
        proof.runProof();
        assertTrue(proof.completed(), "completed");
        assertEq(rep.totalSupply(), 100 ether, "no mint or burn");
        assertEq(proof.vault().liquidity(), 0, "withdrawn");
        assertEq(rep.balanceOf(address(proof)), 0, "refund");
        assertEq(rep.balanceOf(address(proof.vault())), 0, "no assets stuck in vault");
        uint256 dust = 100 ether - rep.balanceOf(OP);
        assertLe(dust, 20, "bounded rounding");
        assertEq(rep.balanceOf(address(manager)), dust, "dust exactly accounted");
        assertTrue(proof.vault().earned(address(rep)) > 0, "real fees");
        assertTrue(proof.vault().earned(address(quote)) > 0, "both assets");
        assertEq(
            proof.vault().paidFirst(address(rep)) + proof.vault().paidSecond(address(rep)),
            proof.vault().earned(address(rep)),
            "all fees paid"
        );
        assertEq(rep.allowance(OP, address(proof)), 0, "bounded funding consumed");
        assertEq(rep.allowance(address(proof), address(proof.vault())), 0, "vault approval revoked");
        vm.expectRevert();
        proof.runProof();
    }

    function testProofRestrictedAndChainGate() public {
        vm.stopPrank();
        vm.prank(address(123));
        vm.expectRevert();
        proof.runProof();
        vm.expectRevert();
        proof.unlockCallback(abi.encode(true, true));
        vm.startPrank(OP);
        vm.chainId(1);
        vm.expectRevert();
        proof.runProof();
        vm.expectRevert();
        new SairiV4LpProofDriver(manager, address(rep), address(quote), OP, hook);
    }

    function testFundingFailureRollsBackThenRetry() public {
        quote.approve(address(proof), 0);
        vm.expectRevert();
        proof.runProof();
        assertEq(rep.balanceOf(OP), 100 ether, "funds atomic");
        assertEq(proof.vault().liquidity(), 0, "no position");
        quote.approve(address(proof), 40 ether);
        proof.runProof();
        assertTrue(proof.completed(), "retry");
    }
}
