// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice TESTNET-ONLY route constants for Base Sepolia <-> Robinhood Chain testnet.
/// Source: LayerZero metadata (https://metadata.layerzero-api.com/v1/metadata) cross-checked by read-only RPC
/// calls on 2026-10-06 (see config/testnet/ and docs/SOURCES.md). Mainnet chains are deliberately absent.
/// Every script re-reads these values on-chain and fails closed on any mismatch before broadcasting.
library TestnetRoutes {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant ROBINHOOD_TESTNET_CHAIN_ID = 46630;

    uint32 internal constant BASE_SEPOLIA_EID = 40245;
    uint32 internal constant ROBINHOOD_TESTNET_EID = 40451;

    struct Route {
        uint256 chainId;
        uint32 localEid;
        uint32 remoteEid;
        address endpoint;
        address sendLib;
        address receiveLib;
        address executor;
        address dvn; // LayerZero Labs DVN on the local chain (metadata `dvns`, id `layerzero-labs`)
        uint64 sendConfirmations; // observed default for local -> remote
        uint64 receiveConfirmations; // observed default for remote -> local
        uint32 maxMessageSize;
    }

    function baseSepolia() internal pure returns (Route memory) {
        return Route({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            localEid: BASE_SEPOLIA_EID,
            remoteEid: ROBINHOOD_TESTNET_EID,
            endpoint: 0x6EDCE65403992e310A62460808c4b910D972f10f,
            sendLib: 0xC1868e054425D378095A003EcbA3823a5D0135C9,
            receiveLib: 0x12523de19dc41c91F7d2093E0CFbB76b17012C8d,
            executor: 0x8A3D588D9f6AC041476b094f97FF94ec30169d3D,
            dvn: 0xe1a12515F9AB2764b887bF60B923Ca494EBbB2d6,
            sendConfirmations: 2,
            receiveConfirmations: 1,
            maxMessageSize: 10_000
        });
    }

    function robinhoodTestnet() internal pure returns (Route memory) {
        return Route({
            chainId: ROBINHOOD_TESTNET_CHAIN_ID,
            localEid: ROBINHOOD_TESTNET_EID,
            remoteEid: BASE_SEPOLIA_EID,
            endpoint: 0x3aCAAf60502791D199a5a5F0B173D78229eBFe32,
            sendLib: 0x45841dd1ca50265Da7614fC43A361e526c0e6160,
            receiveLib: 0xd682ECF100f6F4284138AA925348633B0611Ae21,
            executor: 0x701f3927871EfcEa1235dB722f9E608aE120d243,
            dvn: 0xa78A78a13074eD93aD447a26Ec57121f29E8feC2,
            sendConfirmations: 1,
            receiveConfirmations: 2,
            maxMessageSize: 10_000
        });
    }

    /// @dev Reverts unless the current chain is one of the two allowlisted testnets.
    function current() internal view returns (Route memory) {
        if (block.chainid == BASE_SEPOLIA_CHAIN_ID) return baseSepolia();
        if (block.chainid == ROBINHOOD_TESTNET_CHAIN_ID) return robinhoodTestnet();
        revert("SAIRI: chain not in testnet allowlist");
    }
}
