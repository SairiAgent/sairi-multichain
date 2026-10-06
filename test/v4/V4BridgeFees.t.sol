// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {LzOFTFixture} from "../layerzero/LzOFTFixture.sol";
import {V4Driver, ArtifactVm} from "./V4FeeIntegration.t.sol";
import {SairiCreatorFeeHook} from "../../src/v4/SairiCreatorFeeHook.sol";
import {MockERC20} from "../mocks/MockTokens.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract V4BridgeFeesTest is LzOFTFixture {
    function testRealOFTFeeSwapClaimAndReturnConserveBacking() public {
        Packet memory out = _sendFromBase(USER, USER, 1000e18);
        assertEq(adapter.totalLocked(), backed.totalSupply() + 1000e18, "L=R+P");
        _deliver(out);
        bytes memory code = abi.encodePacked(
            ArtifactVm(address(vm)).getCode("out/PoolManager.sol/PoolManager.json"), abi.encode(address(this))
        );
        address addr;
        assembly { addr := create(0, add(code, 32), mload(code)) }
        IPoolManager m = IPoolManager(addr);
        bytes32 hash =
            keccak256(abi.encodePacked(type(SairiCreatorFeeHook).creationCode, abi.encode(m, address(backed))));
        uint256 salt;
        for (;; salt++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), hash))))
            );
            if (uint160(predicted) & 16383 == 8260) break;
        }
        SairiCreatorFeeHook hook = new SairiCreatorFeeHook{salt: bytes32(salt)}(m, address(backed));
        MockERC20 quote = new MockERC20("Quote", "Q", 18);
        bool is0 = address(backed) < address(quote);
        PoolKey memory key = PoolKey(
            Currency.wrap(is0 ? address(backed) : address(quote)),
            Currency.wrap(is0 ? address(quote) : address(backed)),
            3000,
            60,
            IHooks(address(hook))
        );
        uint160 q96 = 79228162514264337593543950336;
        m.initialize(key, q96);
        V4Driver driver = new V4Driver(m);
        quote.mint(USER, 1000e18);
        vm.startPrank(USER);
        backed.approve(address(driver), type(uint256).max);
        quote.approve(address(driver), type(uint256).max);
        driver.run(key, 1, 1e22, true, 0, false);
        driver.run(key, 0, -int256(1e18), !is0, is0 ? q96 * 2 : q96 / 2, false);
        vm.stopPrank();
        uint256 fee = hook.accrued(address(backed));
        assertTrue(fee > 1e12, "backed fee accrues");
        assertEq(adapter.totalLocked(), backed.totalSupply(), "fees remain in R");
        hook.claim(address(backed));
        assertEq(backed.balanceOf(hook.BENEFICIARY()), fee, "beneficiary owns backed fee");
        uint256 amount = fee / 1e12 * 1e12;
        vm.deal(hook.BENEFICIARY(), 1 ether);
        Packet memory back = _sendFromRobinhood(hook.BENEFICIARY(), hook.BENEFICIARY(), amount);
        assertEq(adapter.totalLocked(), backed.totalSupply() + amount, "L=R+Q");
        _deliver(back);
        assertEq(adapter.totalLocked(), backed.totalSupply(), "settled L=R");
        assertEq(token.balanceOf(hook.BENEFICIARY()), amount, "fees redeem canonical");
        assertEq(token.balanceOf(address(adapter)), adapter.totalLocked(), "no collateral leakage");
    }
}
