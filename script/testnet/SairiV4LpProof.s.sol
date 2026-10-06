// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SairiPairedFeeHook} from "../../src/v4/SairiPairedFeeHook.sol";
import {SairiPairedHookFactory} from "../../src/v4/SairiPairedHookFactory.sol";
import {SairiV4LpVault} from "../../src/v4/SairiV4LpVault.sol";
import {SairiLabQuote} from "./SairiV4Proof.s.sol";
import {V4LabVm} from "./SairiV4Lab.s.sol";

interface LabManagerOwner {
    function owner() external view returns (address);
}

/// @notice One-shot faucet-only lab, not a public router or production liquidity policy.
contract SairiV4LpProofDriver {
    IPoolManager public immutable manager;
    SairiV4LpVault public immutable vault;
    SairiPairedFeeHook public immutable hook;
    address public immutable operator;
    address public immutable representation;
    address public immutable quote;
    bool public completed;
    bool private active;
    PoolKey private key;
    uint160 constant Q96 = 79228162514264337593543950336;
    event SwapProven(bool zeroForOne, bool exactInput, int128 delta0, int128 delta1);
    event ClaimProven(address asset, uint256 earned, uint256 first, uint256 second);
    event ProofCompleted(address representation, uint256 supply, uint256 representationDust, uint256 quoteDust);

    constructor(IPoolManager m, address r, address q, address op, SairiPairedFeeHook h) {
        require(block.chainid == 46630 && op != address(0), "testnet/operator");
        require(
            op == h.BENEFICIARY() && address(h.manager()) == address(m) && h.representation() == r, "hook configuration"
        );
        hook = h;
        require(r != q && r.code.length != 0 && q.code.length != 0, "assets");
        require(
            m.protocolFeeController() == address(0) && LabManagerOwner(address(m)).owner() == address(0),
            "protocol authority"
        );
        manager = m;
        representation = r;
        quote = q;
        operator = op;
        (address a, address b) = r < q ? (r, q) : (q, r);
        key = PoolKey(Currency.wrap(a), Currency.wrap(b), 10000, 60, IHooks(address(h)));
        // Lab recipients coincide ONLY so faucet assets can be returned; production split is undecided.
        vault = new SairiV4LpVault(m, key, -600, 600, address(this), op, op);
    }

    function runProof() external {
        require(block.chainid == 46630 && msg.sender == operator && !completed && !active, "restricted");
        require(manager.protocolFeeController() == address(0), "protocol fees enabled");
        active = true;
        uint256 supply = IERC20(representation).totalSupply();
        uint256 beforeR = IERC20(representation).balanceOf(operator);
        uint256 beforeQ = IERC20(quote).balanceOf(operator);
        require(IERC20(representation).transferFrom(operator, address(this), 40 ether), "rep funding");
        require(IERC20(quote).transferFrom(operator, address(this), 40 ether), "quote funding");
        require(IERC20(representation).approve(address(vault), 40 ether), "rep approval");
        require(IERC20(quote).approve(address(vault), 40 ether), "quote approval");
        manager.initialize(key, Q96);
        vault.modify(1000 ether, 40 ether, 40 ether, block.timestamp);
        manager.unlock(abi.encode(true, true));
        manager.unlock(abi.encode(false, true));
        manager.unlock(abi.encode(true, false));
        manager.unlock(abi.encode(false, false));
        vault.harvest();
        uint256 hookFee = hook.accrued(quote) - hook.delivered(quote);
        require(hookFee > 0 && hook.accrued(representation) == 0, "paired fees only");
        uint256 hookBalance = IERC20(quote).balanceOf(operator);
        hook.claim(quote);
        require(IERC20(quote).balanceOf(operator) == hookBalance + hookFee, "hook claim");
        require(manager.balanceOf(address(hook), uint256(uint160(quote))) == 0, "hook claim remains");
        _claim(representation);
        _claim(quote);
        vault.modify(-int256(1000 ether), 0, 0, block.timestamp);
        _claim(representation);
        _claim(quote);
        require(vault.liquidity() == 0, "LP remains");
        require(IERC20(representation).approve(address(vault), 0), "rep revoke");
        require(IERC20(quote).approve(address(vault), 0), "quote revoke");
        require(
            IERC20(representation).transfer(operator, IERC20(representation).balanceOf(address(this))), "rep refund"
        );
        require(IERC20(quote).transfer(operator, IERC20(quote).balanceOf(address(this))), "quote refund");
        require(IERC20(representation).totalSupply() == supply, "supply changed");
        uint256 dustR = beforeR - IERC20(representation).balanceOf(operator);
        uint256 dustQ = beforeQ - IERC20(quote).balanceOf(operator);
        // Core feeGrowth/add/remove rounding can leave raw units, never hidden as full recovery.
        require(dustR <= 20 && dustQ <= 20, "unexpected loss");
        active = false;
        completed = true;
        emit ProofCompleted(representation, supply, dustR, dustQ);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager) && active, "callback");
        (bool direction, bool exactInput) = abi.decode(data, (bool, bool));
        BalanceDelta delta = manager.swap(
            key,
            SwapParams(
                direction, exactInput ? -int256(1 ether) : int256(1 ether), direction ? Q96 * 99 / 100 : Q96 * 101 / 100
            ),
            ""
        );
        int128 specified = direction == exactInput ? delta.amount0() : delta.amount1();
        require(specified == (exactInput ? -int128(1 ether) : int128(1 ether)), "partial fill");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        emit SwapProven(direction, exactInput, delta.amount0(), delta.amount1());
        return "";
    }

    function _settle(Currency c, int128 delta) private {
        if (delta < 0) {
            manager.sync(c);
            uint256 amount = uint256(-int256(delta));
            require(IERC20(Currency.unwrap(c)).transfer(address(manager), amount), "settlement");
            require(manager.settle() == amount, "inexact settlement");
        } else if (delta > 0) {
            manager.take(c, address(this), uint128(delta));
        }
    }

    function _claim(address asset) private {
        uint256 amount = vault.earned(asset) - vault.paidFirst(asset) - vault.paidSecond(asset);
        uint256 balance = IERC20(asset).balanceOf(operator);
        vault.claim(asset);
        require(IERC20(asset).balanceOf(operator) == balance + amount, "claim proof");
        require(manager.balanceOf(address(vault), uint256(uint160(asset))) == 0, "claim remains");
        emit ClaimProven(asset, vault.earned(asset), vault.paidFirst(asset), vault.paidSecond(asset));
    }
}

contract SairiV4LpProof {
    V4LabVm constant vm = V4LabVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    event LabDeployed(address manager, address representation, address factory, address hook);
    event LabProofDeployed(address quote, address driver, address vault);

    function _operator() private returns (address op) {
        require(block.chainid == 46630, "Robinhood TESTNET only");
        require(keccak256(bytes(vm.envString("SAIRI_TESTNET_CONFIRM"))) == keccak256("testnet-only"), "acknowledgement");
        op = vm.envAddress("SAIRI_TESTNET_OPERATOR");
        require(op != address(0), "operator");
    }

    function deployLab(address representation) external {
        address op = _operator();
        require(representation.code.length != 0, "representation");
        // Zero owner: no one can enable core protocol fees in this isolated lab manager.
        bytes memory code = abi.encodePacked(vm.getCode("out/PoolManager.sol/PoolManager.json"), abi.encode(address(0)));
        vm.startBroadcast(op);
        address manager;
        assembly { manager := create(0, add(code, 32), mload(code)) }
        require(manager != address(0), "manager deploy");
        SairiPairedHookFactory factory = new SairiPairedHookFactory();
        vm.stopBroadcast();
        (bytes32 salt,) = factory.findSalt(IPoolManager(manager), representation, 0, 200_000);
        vm.startBroadcast(op);
        SairiPairedFeeHook hook = factory.deploy(IPoolManager(manager), representation, salt);
        vm.stopBroadcast();
        emit LabDeployed(manager, representation, address(factory), address(hook));
    }

    function prove(address manager, address representation, address hookAddress) external {
        address op = _operator();
        require(IERC20(representation).balanceOf(op) >= 40 ether, "need 40 faucet-backed tokens");
        vm.startBroadcast(op);
        SairiLabQuote quote = new SairiLabQuote(op);
        SairiV4LpProofDriver driver = new SairiV4LpProofDriver(
            IPoolManager(manager), representation, address(quote), op, SairiPairedFeeHook(hookAddress)
        );
        require(IERC20(representation).approve(address(driver), 40 ether), "rep approval");
        quote.approve(address(driver), 40 ether);
        driver.runProof();
        vm.stopBroadcast();
        emit LabProofDeployed(address(quote), address(driver), address(driver.vault()));
    }
}
