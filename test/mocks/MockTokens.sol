// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "../../src/token/ERC20.sol";

/// @notice TEST MOCK ONLY: freely mintable token (canonical SAIRI stand-in, WETH-like stand-in).
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_, decimals_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice TEST MOCK ONLY: burns a 1% fee on every transfer while `feeOn` is set.
contract FeeOnTransferToken is ERC20 {
    bool public feeOn;

    constructor() ERC20("Fee-on-transfer mock", "FOT", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeOn(bool on) external {
        feeOn = on;
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        _feeTransfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < value) revert InsufficientAllowance();
        allowance[from][msg.sender] = allowed - value;
        _feeTransfer(from, to, value);
        return true;
    }

    function _feeTransfer(address from, address to, uint256 value) internal {
        uint256 fee = feeOn ? value / 100 : 0;
        if (fee != 0) _burn(from, fee);
        _transfer(from, to, value - fee);
    }
}

/// @notice TEST MOCK ONLY: while `taxOn`, the sender is debited an EXTRA `value / 100 + 1` (burned)
/// on top of `value`; the recipient still receives exactly `value`. Invisible to recipient-side checks.
contract SenderTaxToken is ERC20 {
    bool public taxOn;

    constructor() ERC20("Sender-tax mock", "STAX", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTaxOn(bool on) external {
        taxOn = on;
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        _taxedTransfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - value;
        }
        _taxedTransfer(from, to, value);
        return true;
    }

    function _taxedTransfer(address from, address to, uint256 value) internal {
        if (taxOn) _burn(from, value / 100 + 1);
        _transfer(from, to, value);
    }
}

/// @notice TEST MOCK ONLY: transfers can be switched to revert or return false.
contract FailingToken is ERC20 {
    bool public shouldRevert;
    bool public shouldReturnFalse;

    constructor() ERC20("Failing mock", "FAIL", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailure(bool revert_, bool returnFalse_) external {
        shouldRevert = revert_;
        shouldReturnFalse = returnFalse_;
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        if (shouldRevert) revert("FailingToken: transfer disabled");
        if (shouldReturnFalse) return false;
        _transfer(msg.sender, to, value);
        return true;
    }
}

/// @notice TEST MOCK ONLY: on transfer/transferFrom, optionally performs one re-entrant call and
/// records its outcome.
contract ReentrantToken is ERC20 {
    address public hookTarget;
    bytes public hookData;
    bool public hookAttempted;
    bool public hookSucceeded;
    bytes public hookRevertData;

    constructor() ERC20("Reentrant mock", "REENT", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
        hookAttempted = false;
        hookSucceeded = false;
        delete hookRevertData;
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        _hook();
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        _hook();
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _hook() internal {
        address target = hookTarget;
        if (target == address(0)) return;
        hookTarget = address(0); // single shot
        hookAttempted = true;
        (bool ok, bytes memory ret) = target.call(hookData);
        hookSucceeded = ok;
        hookRevertData = ret;
    }
}
