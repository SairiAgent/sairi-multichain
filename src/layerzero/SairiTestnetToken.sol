// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "../token/ERC20.sol";

/// @notice TESTNET STAND-IN ONLY. This is NOT canonical SAIRI and has no value or relationship to it.
/// Fixed supply minted once to `holder` at deployment; no further minting, no owner, no fees.
/// Used on Base Sepolia because canonical SAIRI does not exist on testnets.
contract SairiTestnetToken is ERC20 {
    constructor(address holder, uint256 supply) ERC20("SAIRI Testnet Stand-in (not SAIRI)", "tSAIRI-TEST", 18) {
        _mint(holder, supply);
    }
}
