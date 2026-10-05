// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TestBase} from "../utils/TestBase.sol";
import {LocalEndpointMock} from "../mocks/LocalEndpointMock.sol";
import {MockERC20, FeeOnTransferToken, SenderTaxToken} from "../mocks/MockTokens.sol";
import {IERC20, IERC20Metadata} from "../../src/interfaces/IERC20.sol";
import {ExactTransferLib} from "../../src/libraries/ExactTransferLib.sol";
import {BridgeAppBase} from "../../src/bridge/BridgeAppBase.sol";
import {SairiLockbox} from "../../src/bridge/SairiLockbox.sol";
import {BackedSairiRepresentation} from "../../src/bridge/BackedSairiRepresentation.sol";
import {LocalConstantProductPool} from "../../src/pool/LocalConstantProductPool.sol";
import {CreatorFeeCollector} from "../../src/fees/CreatorFeeCollector.sol";

/// @notice Regression tests for two-sided exact transfer validation (LOCAL HARNESS ONLY).
/// FeeOnTransferToken: sender debited `value`, recipient under-credited (recipient-side tax).
/// SenderTaxToken: recipient credited `value`, sender debited extra (sender-side tax).
/// Taxes are switched on only AFTER lossless deposits/accruals, and every rejected action must revert
/// atomically, leaving backing, fees and reserves unchanged.
contract ExactTransferTest is TestBase {
    uint32 internal constant EID_A = 101;
    uint32 internal constant EID_B = 202;
    address internal constant OWNER = address(0xA11CE);
    address internal constant ALICE = address(0xA1);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant LP = address(0x1111);
    address internal constant TRADER = address(0x2222);

    LocalEndpointMock internal endpointA;
    LocalEndpointMock internal endpointB;
    MockERC20 internal weth;

    function setUp() public {
        vm.warp(1_000 days);
        endpointA = new LocalEndpointMock(EID_A);
        endpointB = new LocalEndpointMock(EID_B);
        endpointA.connect(EID_B, endpointB);
        endpointB.connect(EID_A, endpointA);
        weth = new MockERC20("WETH-like (TEST MOCK)", "WETH", 18);
    }

    // ================================================================ bridge helpers

    function _cfg(address endpoint, uint32 localEid, uint32 peerEid, address peerAddr)
        internal
        pure
        returns (BridgeAppBase.BridgeConfig memory)
    {
        return BridgeAppBase.BridgeConfig({
            endpoint: endpoint,
            localEid: localEid,
            peerEid: peerEid,
            peer: bytes32(uint256(uint160(peerAddr))),
            owner: OWNER,
            sharedDecimals: 6,
            exposureCap: type(uint128).max,
            rateWindowSeconds: 1 days,
            rateLimitPerWindow: type(uint128).max
        });
    }

    function _deployPair(IERC20Metadata token) internal returns (SairiLockbox box, BackedSairiRepresentation rep) {
        uint256 nonce = vm.getNonce(address(this));
        address boxAddr = predictCreate(address(this), nonce);
        address repAddr = predictCreate(address(this), nonce + 1);
        box = new SairiLockbox(token, _cfg(address(endpointA), EID_A, EID_B, repAddr));
        rep = new BackedSairiRepresentation(
            "Backed (LOCAL HARNESS)", "bX", 12, _cfg(address(endpointB), EID_B, EID_A, boxAddr)
        );
        assertEq(address(box), boxAddr, "lockbox prediction");
        assertEq(address(rep), repAddr, "representation prediction");
    }

    /// @dev Locks 3e18 losslessly, credits it, then burns 1e12 (= 1e18 canonical) back to ALICE.
    /// @return id Outbox index of the pending release message on endpoint B.
    function _lockCreditBurn(IERC20 token, SairiLockbox box, BackedSairiRepresentation rep)
        internal
        returns (uint256 id)
    {
        vm.prank(ALICE);
        token.approve(address(box), type(uint256).max);
        vm.prank(ALICE);
        box.lockAndSend(3e18, ALICE);
        assertTrue(endpointA.relay(endpointA.messageCount() - 1), "credit delivered");
        vm.prank(ALICE);
        rep.burnAndSend(1e12, ALICE);
        id = endpointB.messageCount() - 1;
    }

    /// @dev Asserts the release reverts with NonExactTransfer, then that relaying it leaves it Failed
    /// with backing, balances and replay state untouched.
    function _assertReleaseRejected(IERC20 token, SairiLockbox box, uint256 id) internal {
        LocalEndpointMock.Message memory m = endpointB.messageAt(id);
        uint256 locked = box.totalLocked();
        uint256 boxBalance = token.balanceOf(address(box));
        uint256 aliceBalance = token.balanceOf(ALICE);

        vm.expectRevert(ExactTransferLib.NonExactTransfer.selector);
        endpointA.rawDeliver(address(box), m.srcEid, m.sender, m.nonce, m.payload);

        assertTrue(!endpointB.relay(id), "release delivery fails");
        assertTrue(endpointB.statusOf(id) == LocalEndpointMock.Status.Failed, "message stays retryable");
        assertEq(box.totalLocked(), locked, "backing unchanged");
        assertEq(token.balanceOf(address(box)), boxBalance, "lockbox balance unchanged");
        assertEq(token.balanceOf(ALICE), aliceBalance, "recipient balance unchanged");
        assertTrue(!box.inboundConsumed(m.nonce), "nonce not consumed");
        assertEq(box.totalInboundSD(), 0, "no inbound recorded");
    }

    // ================================================================ bridge

    function test_lock_senderExtraTax_reverts() public {
        SenderTaxToken stax = new SenderTaxToken();
        (SairiLockbox box,) = _deployPair(stax);
        stax.mint(ALICE, 10e18);
        vm.prank(ALICE);
        stax.approve(address(box), type(uint256).max);
        stax.setTaxOn(true);

        vm.expectRevert(ExactTransferLib.NonExactTransfer.selector);
        vm.prank(ALICE);
        box.lockAndSend(1e18, ALICE);

        assertEq(box.totalLocked(), 0, "nothing locked");
        assertEq(stax.balanceOf(ALICE), 10e18, "depositor untouched");
        assertEq(stax.balanceOf(address(box)), 0, "lockbox untouched");
        assertEq(endpointA.messageCount(), 0, "no message sent");
        assertEq(box.usedInWindow(), 0, "rate capacity not consumed");
    }

    function test_release_recipientUndercredit_taxEnabledAfterLock() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        (SairiLockbox box, BackedSairiRepresentation rep) = _deployPair(fot);
        fot.mint(ALICE, 10e18);
        uint256 id = _lockCreditBurn(fot, box, rep);

        fot.setFeeOn(true);
        _assertReleaseRejected(fot, box, id);

        fot.setFeeOn(false);
        assertTrue(endpointB.relay(id), "retry succeeds once lossless");
        assertEq(fot.balanceOf(ALICE), 8e18, "exact release");
        assertEq(box.totalLocked(), 2e18, "backing reduced exactly");
    }

    function test_release_senderExtraTax_taxEnabledAfterLock() public {
        SenderTaxToken stax = new SenderTaxToken();
        (SairiLockbox box, BackedSairiRepresentation rep) = _deployPair(stax);
        stax.mint(ALICE, 10e18);
        uint256 id = _lockCreditBurn(stax, box, rep);

        stax.setTaxOn(true);
        _assertReleaseRejected(stax, box, id);

        stax.setTaxOn(false);
        assertTrue(endpointB.relay(id), "retry succeeds once lossless");
        assertEq(stax.balanceOf(ALICE), 8e18, "exact release");
        assertEq(stax.balanceOf(address(box)), 2e18, "lockbox balance == backing");
    }

    function test_peerAsRecipient_rejected() public {
        MockERC20 token = new MockERC20("SAIRI canonical (TEST MOCK)", "SAIRI", 18);
        (SairiLockbox box, BackedSairiRepresentation rep) = _deployPair(token);
        token.mint(ALICE, 10e18);
        vm.prank(ALICE);
        token.approve(address(box), type(uint256).max);

        vm.expectRevert(BridgeAppBase.InvalidRecipient.selector);
        vm.prank(ALICE);
        box.lockAndSend(1e18, address(rep));

        vm.prank(ALICE);
        box.lockAndSend(1e18, ALICE);
        endpointA.relay(0);
        vm.expectRevert(BridgeAppBase.InvalidRecipient.selector);
        vm.prank(ALICE);
        rep.burnAndSend(1e12, address(box));
    }

    // ================================================================ pool

    function _seededPool(IERC20 token0) internal returns (LocalConstantProductPool pool) {
        pool = new LocalConstantProductPool(token0, weth, CREATOR);
        weth.mint(LP, 10e18);
        vm.startPrank(LP);
        token0.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        pool.addLiquidity(1_000e18, 10e18, 1e20 - 1_000, LP); // sqrt(1e21 * 1e19) - MINIMUM_LIQUIDITY
        vm.stopPrank();

        weth.mint(TRADER, 10e18);
        vm.startPrank(TRADER);
        token0.approve(address(pool), type(uint256).max);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function test_pool_incomingSenderExtraDebit_reverts() public {
        SenderTaxToken stax = new SenderTaxToken();
        stax.mint(LP, 1_000e18);
        stax.mint(TRADER, 100e18);
        LocalConstantProductPool pool = _seededPool(stax);
        CreatorFeeCollector collector = pool.feeCollector();
        stax.setTaxOn(true);

        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();
        vm.expectRevert(ExactTransferLib.NonExactTransfer.selector);
        vm.prank(TRADER);
        pool.swapExactInput(address(stax), 1e18, 1e18, 0, TRADER);

        assertEq(pool.reserve0(), r0, "reserve0 unchanged");
        assertEq(pool.reserve1(), r1, "reserve1 unchanged");
        assertEq(stax.balanceOf(TRADER), 100e18, "sender untouched");
        assertEq(weth.balanceOf(TRADER), 10e18, "no output paid");
        assertEq(collector.accrued(address(stax)), 0, "no fee accrued");
        assertEq(stax.balanceOf(address(collector)), 0, "collector untouched");
    }

    function test_pool_outgoingRecipientUndercredit_reverts() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(LP, 1_000e18);
        LocalConstantProductPool pool = _seededPool(fot);
        CreatorFeeCollector collector = pool.feeCollector();
        fot.setFeeOn(true);

        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();
        // WETH in is lossless; the FOT output would under-credit the recipient.
        vm.expectRevert(ExactTransferLib.NonExactTransfer.selector);
        vm.prank(TRADER);
        pool.swapExactInput(address(weth), 1e18, 1e18, 0, TRADER);

        assertEq(pool.reserve0(), r0, "reserve0 unchanged");
        assertEq(pool.reserve1(), r1, "reserve1 unchanged");
        assertEq(weth.balanceOf(TRADER), 10e18, "input refunded by revert");
        assertEq(fot.balanceOf(TRADER), 0, "no output");
        assertEq(collector.accrued(address(weth)), 0, "no fee accrued");
        assertEq(weth.balanceOf(address(collector)), 0, "collector untouched");

        uint256 shares = pool.sharesOf(LP);
        (uint256 min0, uint256 min1) = pool.quoteRemoveLiquidity(shares / 2);
        vm.expectRevert(ExactTransferLib.NonExactTransfer.selector);
        vm.prank(LP);
        pool.removeLiquidity(shares / 2, min0, min1, LP);
        assertEq(pool.sharesOf(LP), shares, "shares unchanged");
        assertEq(pool.reserve0(), r0, "reserve0 unchanged after failed removal");
    }

    // ================================================================ collector (this test acts as pool)

    function test_collector_beneficiaryUndercredit_taxAfterAccrual() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        CreatorFeeCollector c = new CreatorFeeCollector(CREATOR, address(fot), address(weth));
        fot.mint(address(c), 1_000);
        c.recordFee(address(fot), 1_000);
        fot.setFeeOn(true);

        vm.expectRevert(ExactTransferLib.NonExactTransfer.selector);
        c.claim(address(fot));
        assertEq(c.delivered(address(fot)), 0, "delivered rolled back");
        assertEq(c.claimable(address(fot)), 1_000, "fees still claimable");
        assertEq(fot.balanceOf(address(c)), 1_000, "collector balance unchanged");
        assertEq(fot.balanceOf(CREATOR), 0, "beneficiary unpaid");

        fot.setFeeOn(false);
        c.claim(address(fot));
        assertEq(fot.balanceOf(CREATOR), 1_000, "paid exactly once lossless");
    }

    function test_collector_extraCollectorDebit_reverts() public {
        SenderTaxToken stax = new SenderTaxToken();
        CreatorFeeCollector c = new CreatorFeeCollector(CREATOR, address(stax), address(weth));
        stax.mint(address(c), 1_000);
        c.recordFee(address(stax), 1_000);
        stax.mint(address(c), 100); // unaccounted donation so the tax itself can be paid
        stax.setTaxOn(true);

        vm.expectRevert(ExactTransferLib.NonExactTransfer.selector);
        c.claim(address(stax));
        assertEq(c.delivered(address(stax)), 0, "delivered rolled back");
        assertEq(c.accrued(address(stax)), 1_000, "accrued unchanged");
        assertEq(stax.balanceOf(address(c)), 1_100, "collector balance unchanged");
        assertEq(stax.balanceOf(CREATOR), 0, "beneficiary unpaid");
    }

    function test_collector_selfAliasBeneficiary_rejected() public {
        vm.expectRevert(CreatorFeeCollector.InvalidBeneficiary.selector);
        new CreatorFeeCollector(address(this), address(weth), address(0xBEEF));

        MockERC20 other = new MockERC20("Other (TEST MOCK)", "OTH", 18);
        address predictedPool = predictCreate(address(this), vm.getNonce(address(this)));
        vm.expectRevert(CreatorFeeCollector.InvalidBeneficiary.selector);
        new LocalConstantProductPool(other, weth, predictedPool);
    }
}
