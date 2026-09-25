// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @notice Fixed-price oracle for public testnet integration testing only.
/// @dev Never deploy or configure this oracle on a production network.
contract TestnetPriceOracle is IPriceOracle {
    uint256 public immutable priceWad;

    constructor(uint256 priceWad_) {
        priceWad = priceWad_;
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (priceWad, block.timestamp);
    }
}

