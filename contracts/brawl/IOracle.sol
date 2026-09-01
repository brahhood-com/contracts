// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IOracle
 * @notice The read shape brawl resolution expects from a price source.
 *         Testnet serves it from KeeperOracle; mainnet puts a real feed
 *         adapter behind the same two return values, so the escrow never
 *         has to know which one it is talking to.
 */
interface IOracle {
    /**
     * @param feedId opaque feed identifier, e.g. keccak256("ETH/USD")
     * @return value latest reported value, signed
     * @return updatedAt unix timestamp of the last write
     */
    function latestValue(
        bytes32 feedId
    ) external view returns (int256 value, uint256 updatedAt);
}
