// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LzOFTFixture} from "../layerzero/LzOFTFixture.sol";

/// @notice Bounded random sequences of sends / in-order deliveries in both directions over the genuine
/// pinned EndpointV2 + ULN302 stack. Invariant after every step:
///   observed adapter balance == totalLocked == representation supply + in-flight (both directions),
/// and once everything is delivered the user's canonical balance is fully restored.
contract LzOFTConservationFuzzTest is LzOFTFixture {
    Packet[] internal toRobinhood;
    Packet[] internal toBase;
    uint256 internal nextToRobinhood;
    uint256 internal nextToBase;

    function testFuzz_conservation(uint256 seed) public {
        uint256 start = token.balanceOf(USER);
        for (uint256 i = 0; i < 12; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = r % 4;
            if (action == 0) {
                toRobinhood.push(_sendFromBase(USER, USER, bound(r >> 8, 1, 1_000_000) * CONVERSION));
            } else if (action == 1 && nextToRobinhood < toRobinhood.length) {
                _deliver(toRobinhood[nextToRobinhood++]);
            } else if (action == 2 && backed.balanceOf(USER) >= CONVERSION) {
                uint256 maxSD = backed.balanceOf(USER) / CONVERSION;
                toBase.push(_sendFromRobinhood(USER, USER, bound(r >> 8, 1, maxSD) * CONVERSION));
            } else if (action == 3 && nextToBase < toBase.length) {
                _deliver(toBase[nextToBase++]);
            }
            _assertConserved();
        }
        while (nextToRobinhood < toRobinhood.length) _deliver(toRobinhood[nextToRobinhood++]);
        while (nextToBase < toBase.length) _deliver(toBase[nextToBase++]);
        if (backed.balanceOf(USER) != 0) _deliver(_sendFromRobinhood(USER, USER, backed.balanceOf(USER)));
        _assertConserved();
        assertEq(token.balanceOf(USER), start, "canonical balance restored");
        assertEq(adapter.totalLocked(), 0, "nothing locked");
    }

    function _assertConserved() internal view {
        uint256 inFlight;
        for (uint256 j = nextToRobinhood; j < toRobinhood.length; j++) {
            inFlight += _amountLD(toRobinhood[j]);
        }
        for (uint256 j = nextToBase; j < toBase.length; j++) {
            inFlight += _amountLD(toBase[j]);
        }
        assertEq(token.balanceOf(address(adapter)), adapter.totalLocked(), "observed == tracked");
        assertEq(adapter.totalLocked(), backed.totalSupply() + inFlight, "locked == supply + in flight");
    }
}
