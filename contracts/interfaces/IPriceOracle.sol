// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Returns the price of one whole asset token in accounting-asset units.
/// @dev The price is always scaled to 18 decimals. `updatedAt` is the timestamp
///      of the oldest observation used to calculate the price.
interface IPriceOracle {
    function latestPrice() external view returns (uint256 priceWad, uint256 updatedAt);
}
