// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BridgeFixture} from "../utils/BridgeFixture.sol";
import {MockERC20} from "../mocks/MockTokens.sol";
import {LocalConstantProductPool} from "../../src/pool/LocalConstantProductPool.sol";
import {CreatorFeeCollector} from "../../src/fees/CreatorFeeCollector.sol";

/// @notice LOCAL HARNESS end-to-end demonstration: canonical lock on "chain A", backed representation
/// on "chain B", a local constant-product pool against a WETH-like mock, creator fee claims, and
/// bridging back. Nothing here exercises LayerZero, a real DEX, or any deployed contract.
contract LocalHarnessFlowTest is BridgeFixture {
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant TRADER = address(0x7777);

    MockERC20 internal weth;
    LocalConstantProductPool internal pool;
    CreatorFeeCollector internal collector;

    function setUp() public {
        vm.warp(1_000 * WINDOW);
        _deployBridge(type(uint128).max, type(uint128).max, type(uint128).max, type(uint128).max);
        _fundAndApprove(ALICE, 1_000_000e18);
        _fundAndApprove(TRADER, 10_000e18);
        weth = new MockERC20("WETH-like (TEST MOCK)", "WETH", 18);
        pool = new LocalConstantProductPool(rep, weth, CREATOR);
        collector = pool.feeCollector();
    }

    function _roundToShared(uint256 amountLD) internal pure returns (uint256) {
        return amountLD - (amountLD % REP_RATE);
    }

    function test_endToEnd_lockTradeClaimReturn() public {
        // 1. Bridge canonical liquidity and trader funds to chain B.
        endpointA.relay(_lock(ALICE, 500_000e18, ALICE));
        uint256 traderLock = _lock(TRADER, 5_000e18, TRADER);
        _assertConservation(); // trader lock still in flight (P > 0)
        endpointA.relay(traderLock);
        _assertConservation();
        assertEq(rep.balanceOf(ALICE), 500_000e12, "alice representation");

        // 2. Seed the local pool with locally supplied backed-SAIRI and WETH-like.
        weth.mint(ALICE, 50e18);
        vm.startPrank(ALICE);
        rep.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        pool.addLiquidity(500_000e12, 50e18, 5e18 - 1_000, ALICE); // sqrt(5e17 * 5e19) - MINIMUM_LIQUIDITY
        vm.stopPrank();

        // 3. Trader buys with WETH-like, then sells backed-SAIRI.
        weth.mint(TRADER, 10e18);
        vm.startPrank(TRADER);
        weth.approve(address(pool), type(uint256).max);
        rep.approve(address(pool), type(uint256).max);
        pool.swapExactInput(address(weth), 2e18, 2e18, 1, TRADER);
        pool.swapExactInput(address(rep), 3_000e12, 3_000e12, 1, TRADER);
        vm.stopPrank();
        _assertConservation(); // swaps move representation between holders; supply unchanged

        // 4. Anyone can trigger claims; fees always go to the fixed creator beneficiary.
        uint256 repFee = _claimAll();

        // 5. Creator and trader bridge representation back; sub-shared-decimal dust must be excluded.
        uint256 creatorBack = _roundToShared(repFee);
        uint256 traderBack = _roundToShared(rep.balanceOf(TRADER));
        uint256 c = _burn(CREATOR, creatorBack, CREATOR);
        uint256 t = _burn(TRADER, traderBack, TRADER);
        _assertConservation(); // Q > 0
        endpointB.relay(t);
        _assertConservation();
        endpointB.relay(c);
        _assertConservation();

        assertEq(canonical.balanceOf(CREATOR), creatorBack * (CANON_RATE / REP_RATE), "creator canonical");
        assertEq(canonical.balanceOf(TRADER), 5_000e18 + traderBack * (CANON_RATE / REP_RATE), "trader canonical");
        assertEq(lockbox.totalLocked(), rep.totalSupply() * (CANON_RATE / REP_RATE), "fully backed, nothing in flight");
    }

    /// @return repFee Representation fees delivered to the creator.
    function _claimAll() internal returns (uint256 repFee) {
        uint256 wethFee = collector.claimable(address(weth));
        repFee = collector.claimable(address(rep));
        assertEq(wethFee, 2e18 / 100, "1% of WETH input");
        assertEq(repFee, 3_000e12 / 100, "1% of bSAIRI input");
        vm.startPrank(MALLORY);
        collector.claim(address(weth));
        collector.claim(address(rep));
        vm.stopPrank();
        assertEq(weth.balanceOf(CREATOR), wethFee, "creator weth");
        assertEq(rep.balanceOf(CREATOR), repFee, "creator bSAIRI");
        assertEq(weth.balanceOf(MALLORY), 0, "caller received nothing");
    }
}
