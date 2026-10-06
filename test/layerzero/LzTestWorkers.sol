// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ILayerZeroDVN} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/interfaces/ILayerZeroDVN.sol";
import {ILayerZeroExecutor} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/interfaces/ILayerZeroExecutor.sol";
import {ReceiveUln302} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/uln302/ReceiveUln302.sol";

/// @notice TEST WORKER ONLY — NOT a LayerZero DVN. Quotes a fixed fee and, when the test tells it to,
/// attests a packet on the destination ReceiveUln302 exactly as an off-chain DVN would. It performs no
/// independent source-chain verification; a real deployment relies on the configured live DVNs instead.
contract TestDVN is ILayerZeroDVN {
    uint256 public immutable fee;
    uint256 public jobs;

    constructor(uint256 fee_) {
        fee = fee_;
    }

    function assignJob(AssignJobParam calldata, bytes calldata) external payable returns (uint256) {
        jobs++;
        return fee;
    }

    function getFee(uint32, uint64, address, bytes calldata) external view returns (uint256) {
        return fee;
    }

    function attest(ReceiveUln302 lib, bytes calldata header, bytes32 payloadHash, uint64 confirmations) external {
        lib.verify(header, payloadHash, confirmations);
    }
}

/// @notice TEST WORKER ONLY — NOT a LayerZero executor. Quotes a fixed fee; the test itself calls
/// `EndpointV2.lzReceive` (which is permissionless) to model execution.
contract TestExecutor is ILayerZeroExecutor {
    uint256 public immutable fee;
    uint256 public jobs;

    constructor(uint256 fee_) {
        fee = fee_;
    }

    function assignJob(uint32, address, uint256, bytes calldata) external returns (uint256) {
        jobs++;
        return fee;
    }

    function getFee(uint32, address, uint256, bytes calldata) external view returns (uint256) {
        return fee;
    }
}
