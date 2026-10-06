// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SairiCreatorFeeHook} from "../../src/v4/SairiCreatorFeeHook.sol";
import {V4LabVm} from "./SairiV4Lab.s.sol";

/// @notice Faucet-only quote, fixed supply, no public mint; never a real stablecoin.
contract SairiLabQuote is ERC20 {
    constructor(address operator) ERC20("SAIRI LAB ONLY quote", "LABQ") {
        require(block.chainid == 46630, "testnet only");
        _mint(operator, 100 ether);
    }
}

/// @notice One-shot operator-only lab, NOT a public router. No native currency or arbitrary operations.
contract SairiV4ProofDriver {
    IPoolManager public immutable manager;
    SairiCreatorFeeHook public immutable hook;
    address public immutable operator;
    address public immutable representation;
    address public immutable quote;
    bool public completed;
    bool private active;
    PoolKey private key;
    uint160 constant Q96 = 79228162514264337593543950336;
    event SwapProven(bool zeroForOne, bool exactInput, address feeAsset, uint256 fee, int128 delta0, int128 delta1);
    event ClaimProven(address asset, address beneficiary, uint256 amount);
    event ProofCompleted(address representation, uint256 supply);

    constructor(SairiCreatorFeeHook h, address q, address op) {
        require(block.chainid == 46630 && op != address(0), "testnet/operator");
        manager = h.manager();
        hook = h;
        representation = h.representation();
        quote = q;
        operator = op;
        require(q != representation && q.code.length != 0, "quote");
        (address a, address b) = representation < q ? (representation, q) : (q, representation);
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 60, IHooks(address(h)));
    }

    function runProof() external {
        require(block.chainid == 46630 && msg.sender == operator && !completed && !active, "restricted");
        active = true;
        uint256 supply = IERC20(representation).totalSupply();
        require(IERC20(representation).transferFrom(operator, address(this), 40 ether), "rep funding");
        require(IERC20(quote).transferFrom(operator, address(this), 40 ether), "quote funding");
        manager.initialize(key, Q96);
        manager.unlock(abi.encode(uint8(0), false, false));
        manager.unlock(abi.encode(uint8(1), true, true));
        manager.unlock(abi.encode(uint8(1), false, true));
        manager.unlock(abi.encode(uint8(1), true, false));
        manager.unlock(abi.encode(uint8(1), false, false));
        _claim(representation);
        _claim(quote);
        manager.unlock(abi.encode(uint8(2), false, false));
        require(IERC20(representation).totalSupply() == supply, "supply changed");
        require(
            IERC20(representation).transfer(operator, IERC20(representation).balanceOf(address(this))), "rep refund"
        );
        require(IERC20(quote).transfer(operator, IERC20(quote).balanceOf(address(this))), "quote refund");
        active = false;
        completed = true;
        emit ProofCompleted(representation, supply);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager) && active, "callback");
        (uint8 op, bool direction, bool exactInput) = abi.decode(data, (uint8, bool, bool));
        BalanceDelta delta;
        if (op != 1) {
            uint256 f0 = hook.accrued(representation);
            uint256 f1 = hook.accrued(quote);
            (delta,) = manager.modifyLiquidity(
                key, ModifyLiquidityParams(-600, 600, op == 0 ? int256(1000 ether) : -int256(1000 ether), 0), ""
            );
            require(hook.accrued(representation) == f0 && hook.accrued(quote) == f1, "LP taxed");
        } else {
            address asset = Currency.unwrap(direction == exactInput ? key.currency1 : key.currency0);
            uint256 beforeFee = hook.accrued(asset);
            delta = manager.swap(
                key,
                SwapParams(
                    direction,
                    exactInput ? -int256(1 ether) : int256(1 ether),
                    direction ? Q96 * 99 / 100 : Q96 * 101 / 100
                ),
                ""
            );
            uint256 fee = hook.accrued(asset) - beforeFee;
            int128 raw = asset == Currency.unwrap(key.currency0) ? delta.amount0() : delta.amount1();
            require(fee > 0, "zero fee");
            if (exactInput) require(raw > 0 && fee == (uint256(uint128(raw)) + fee) / 100, "output fee");
            else require(raw < 0 && fee == uint256(-int256(raw)) / 100, "input fee");
            int128 specified = direction == exactInput ? delta.amount0() : delta.amount1();
            require(specified == (exactInput ? -int128(1 ether) : int128(1 ether)), "partial fill");
            emit SwapProven(direction, exactInput, asset, fee, delta.amount0(), delta.amount1());
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency c, int128 delta) private {
        if (delta < 0) {
            manager.sync(c);
            uint256 amount = uint256(-int256(delta));
            require(IERC20(Currency.unwrap(c)).transfer(address(manager), amount), "settlement transfer");
            require(manager.settle() == amount, "inexact settlement");
        } else if (delta > 0) {
            manager.take(c, address(this), uint128(delta));
        }
    }

    function _claim(address asset) private {
        uint256 fee = hook.accrued(asset) - hook.delivered(asset);
        address recipient = hook.BENEFICIARY();
        uint256 balance = IERC20(asset).balanceOf(recipient);
        require(fee > 0, "missing accrual");
        hook.claim(asset);
        require(
            IERC20(asset).balanceOf(recipient) == balance + fee && hook.accrued(asset) == hook.delivered(asset),
            "claim proof"
        );
        require(manager.balanceOf(address(hook), uint256(uint160(asset))) == 0, "claim outstanding");
        emit ClaimProven(asset, recipient, fee);
    }
}

contract SairiV4Proof {
    V4LabVm constant vm = V4LabVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    event LabProofDeployed(address quote, address driver);

    function prove(address hookAddress) external {
        require(block.chainid == 46630, "Robinhood TESTNET only");
        require(keccak256(bytes(vm.envString("SAIRI_TESTNET_CONFIRM"))) == keccak256("testnet-only"), "acknowledgement");
        address operator = vm.envAddress("SAIRI_TESTNET_OPERATOR");
        SairiCreatorFeeHook hook = SairiCreatorFeeHook(hookAddress);
        require(IERC20(hook.representation()).balanceOf(operator) >= 40 ether, "need 40 faucet-backed tokens");
        vm.startBroadcast(operator);
        SairiLabQuote quote = new SairiLabQuote(operator);
        SairiV4ProofDriver driver = new SairiV4ProofDriver(hook, address(quote), operator);
        require(IERC20(hook.representation()).approve(address(driver), 40 ether), "rep approval");
        quote.approve(address(driver), 40 ether);
        driver.runProof();
        vm.stopBroadcast();
        emit LabProofDeployed(address(quote), address(driver));
    }
}
