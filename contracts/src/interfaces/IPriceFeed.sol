// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Aggregator-style price feed interface.
/// @dev The Atlas BNB/USD feed is consumed through this interface. If the
///      deployed Atlas feed exposes a different ABI, wrap it in a small adapter
///      that implements this interface and point the launcher at the adapter.
interface IPriceFeed {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
