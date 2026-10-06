// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {EndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/EndpointV2.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";

import {SairiOFTAdapter} from "../../src/layerzero/SairiOFTAdapter.sol";
import {SairiBackedOFT} from "../../src/layerzero/SairiBackedOFT.sol";
import {ExactTransferLib} from "../../src/libraries/ExactTransferLib.sol";
import {SafeTransferLib} from "../../src/libraries/SafeTransferLib.sol";
import {ERC20} from "../../src/token/ERC20.sol";
import {ReentrantToken, SenderTaxToken, FeeOnTransferToken} from "../mocks/MockTokens.sol";
import {LzOFTFixture} from "./LzOFTFixture.sol";

/// @notice TEST HELPER ONLY: when invoked from a token callback, re-locks its own tokens through the adapter.
contract Relocker {
    function relock(SairiOFTAdapter adapter, ERC20 token, uint32 dstEid, uint256 amountLD) external {
        token.approve(address(adapter), amountLD);
        SendParam memory p = SendParam(dstEid, bytes32(uint256(uint160(address(this)))), amountLD, amountLD, "", "", "");
        MessagingFee memory fee = adapter.quoteSend(p, false);
        adapter.send{value: fee.nativeFee}(p, fee, address(this));
    }

    receive() external payable {}
}

/// @notice SairiOFTAdapter-specific token risks over the genuine EndpointV2 + ULN302 stack: callback reentrancy
/// on lock and release is atomic (no partial lock, no partial release, message stays retryable), and a tax
/// switched on AFTER collateral was deposited makes redemption revert without losing backing, then succeed on
/// retry once the tax is removed.
contract OFTAdapterTokenRisksTest is LzOFTFixture {
    Relocker internal relocker;

    function setUp() public override {
        super.setUp();
        relocker = new Relocker();
        vm.deal(address(relocker), 10 ether);
    }

    function _pair(address tok) internal returns (SairiOFTAdapter a, SairiBackedOFT bk) {
        a = new SairiOFTAdapter(tok, address(base.endpoint), OWNER, _guards(EID_ROBINHOOD_TESTNET));
        bk = new SairiBackedOFT("b", "b", address(robinhood.endpoint), OWNER, _guards(EID_BASE_SEPOLIA));
        vm.startPrank(OWNER);
        a.setPeer(EID_ROBINHOOD_TESTNET, _b32(address(bk)));
        bk.setPeer(EID_BASE_SEPOLIA, _b32(address(a)));
        a.setEnforcedOptions(_enforced(EID_ROBINHOOD_TESTNET));
        bk.setEnforcedOptions(_enforced(EID_BASE_SEPOLIA));
        vm.stopPrank();
    }

    function _lock(SairiOFTAdapter a, ERC20 tok, address from, uint256 amountLD) internal returns (Packet memory) {
        SendParam memory p = _param(EID_ROBINHOOD_TESTNET, from, amountLD);
        MessagingFee memory fee = a.quoteSend(p, false);
        vm.prank(from);
        tok.approve(address(a), amountLD);
        vm.prank(from);
        vm.recordLogs();
        a.send{value: fee.nativeFee}(p, fee, from);
        return _capture(base);
    }

    function _burn(SairiBackedOFT bk, address from, uint256 amountLD) internal returns (Packet memory) {
        SendParam memory p = _param(EID_BASE_SEPOLIA, from, amountLD);
        MessagingFee memory fee = bk.quoteSend(p, false);
        vm.prank(from);
        vm.recordLogs();
        bk.send{value: fee.nativeFee}(p, fee, from);
        return _capture(robinhood);
    }

    function _assertBacking(SairiOFTAdapter a, ERC20 tok, uint256 locked, string memory step) internal view {
        assertEq(a.totalLocked(), locked, step);
        assertEq(tok.balanceOf(address(a)), locked, "observed backing == tracked");
    }

    // ------------------------------------------------------------------ callback reentrancy

    function test_reentrantRelockDuringLock_revertsAtomically() public {
        ReentrantToken rt = new ReentrantToken();
        (SairiOFTAdapter a, SairiBackedOFT bk) = _pair(address(rt));
        rt.mint(USER, 10e18);
        rt.mint(address(relocker), 10e18);
        rt.arm(address(relocker), abi.encodeCall(Relocker.relock, (a, rt, EID_ROBINHOOD_TESTNET, 1e18)));

        SendParam memory p = _param(EID_ROBINHOOD_TESTNET, USER, 5e18);
        MessagingFee memory fee = a.quoteSend(p, false);
        vm.startPrank(USER);
        rt.approve(address(a), 5e18);
        // The nested lock succeeds on its own, but the outer exact-transfer check sees the extra credit and the
        // whole transaction (including the nested lock and its packet) reverts.
        vm.expectRevert(ExactTransferLib.NonExactTransfer.selector);
        a.send{value: fee.nativeFee}(p, fee, USER);
        vm.stopPrank();

        _assertBacking(a, rt, 0, "no partial lock");
        assertEq(rt.balanceOf(USER), 10e18, "user untouched");
        assertEq(rt.balanceOf(address(relocker)), 10e18, "nested locker untouched");
        assertEq(base.endpoint.outboundNonce(address(a), EID_ROBINHOOD_TESTNET, _b32(address(bk))), 0, "no packet");
        assertTrue(!rt.hookAttempted(), "hook state rolled back too");
    }

    function test_reentrantRelockDuringRelease_revertsAndStaysRetryable() public {
        ReentrantToken rt = new ReentrantToken();
        (SairiOFTAdapter a, SairiBackedOFT bk) = _pair(address(rt));
        rt.mint(USER, 10e18);
        rt.mint(address(relocker), 10e18);
        _deliver(_lock(a, rt, USER, 5e18));
        Packet memory back = _burn(bk, USER, 5e18);
        _verify(back);

        rt.arm(address(relocker), abi.encodeCall(Relocker.relock, (a, rt, EID_ROBINHOOD_TESTNET, 1e18)));
        vm.expectRevert(ExactTransferLib.NonExactTransfer.selector);
        _execute(back);
        _assertBacking(a, rt, 5e18, "release reverted, backing intact");
        assertEq(rt.balanceOf(USER), 5e18, "no partial release");
        assertEq(bk.totalSupply(), 0, "burn already final on source; amount still in flight");

        rt.arm(address(0), ""); // callback removed
        _execute(back); // retry the same verified message
        _assertBacking(a, rt, 0, "released on retry");
        assertEq(rt.balanceOf(USER), 10e18, "user made whole");
    }

    function test_reentrantSecondDeliveryDuringRelease_revertsBothRetryable() public {
        ReentrantToken rt = new ReentrantToken();
        (SairiOFTAdapter a, SairiBackedOFT bk) = _pair(address(rt));
        rt.mint(USER, 10e18);
        _deliver(_lock(a, rt, USER, 5e18));
        Packet memory first = _burn(bk, USER, 2e18);
        Packet memory second = _burn(bk, USER, 3e18);
        _verify(first);
        _verify(second);

        // During the first release push, the token re-enters the endpoint to execute the second release.
        rt.arm(
            address(base.endpoint),
            abi.encodeCall(
                EndpointV2.lzReceive,
                (Origin(second.srcEid, second.sender, second.nonce), second.receiver, second.guid, second.message, "")
            )
        );
        vm.expectRevert(ExactTransferLib.NonExactTransfer.selector);
        _execute(first);
        _assertBacking(a, rt, 5e18, "neither release applied");

        rt.arm(address(0), "");
        _execute(first);
        _execute(second);
        _assertBacking(a, rt, 0, "both released after retry");
        assertEq(rt.balanceOf(USER), 10e18, "user made whole");
    }

    // ------------------------------------------------------------------ tax enabled after deposit

    function test_senderTaxEnabledAfterDeposit_blocksRedemptionUntilRemoved() public {
        SenderTaxToken st = new SenderTaxToken();
        (SairiOFTAdapter a, SairiBackedOFT bk) = _pair(address(st));
        st.mint(USER, 10e18);
        _deliver(_lock(a, st, USER, 5e18)); // tax off: exact deposit
        Packet memory back = _burn(bk, USER, 5e18);
        _verify(back);

        st.setTaxOn(true); // adapter would be debited value + tax on release
        // The adapter holds exactly the backing, so the extra sender-side tax cannot be paid: the token transfer
        // itself fails (before the exact-transfer check would). Either way the delivery reverts atomically.
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        _execute(back);
        _assertBacking(a, st, 5e18, "no under-backed partial release");

        // With a donation covering the tax, the transfer succeeds but over-debits the adapter: the exact-transfer
        // check rejects it instead of silently spending backing.
        st.mint(address(this), 1e18);
        st.setTaxOn(false);
        st.transfer(address(a), 1e18);
        st.setTaxOn(true);
        vm.expectRevert(ExactTransferLib.NonExactTransfer.selector);
        _execute(back);
        assertEq(a.totalLocked(), 5e18, "tracked backing unchanged");
        assertEq(st.balanceOf(address(a)), 6e18, "observed = backing + donation");
        st.setTaxOn(false);
        vm.prank(address(a));
        st.transfer(address(0xD0D0), 1e18); // test-only: remove the donation so balances stay exact
        st.setTaxOn(true);
        _assertBacking(a, st, 5e18, "no under-backed partial release");

        // New locks are refused while the tax is on (the depositor would be over-debited).
        SendParam memory p = _param(EID_ROBINHOOD_TESTNET, USER, 1e18);
        MessagingFee memory fee = a.quoteSend(p, false);
        vm.startPrank(USER);
        st.approve(address(a), 1e18);
        vm.expectRevert(ExactTransferLib.NonExactTransfer.selector);
        a.send{value: fee.nativeFee}(p, fee, USER);
        vm.stopPrank();

        st.setTaxOn(false);
        _execute(back); // same verified message, retried
        _assertBacking(a, st, 0, "redeemed after tax removed");
        assertEq(st.balanceOf(USER), 10e18, "user made whole");
    }

    function test_recipientFeeEnabledAfterDeposit_blocksRedemptionUntilRemoved() public {
        FeeOnTransferToken ft = new FeeOnTransferToken();
        (SairiOFTAdapter a, SairiBackedOFT bk) = _pair(address(ft));
        ft.mint(USER, 10e18);
        _deliver(_lock(a, ft, USER, 5e18));
        Packet memory back = _burn(bk, USER, 5e18);
        _verify(back);

        ft.setFeeOn(true); // recipient would receive less than released
        vm.expectRevert(ExactTransferLib.NonExactTransfer.selector);
        _execute(back);
        _assertBacking(a, ft, 5e18, "backing intact while fee on");

        ft.setFeeOn(false);
        _execute(back);
        _assertBacking(a, ft, 0, "redeemed after fee removed");
        assertEq(ft.balanceOf(USER), 10e18, "user made whole");
    }
}
