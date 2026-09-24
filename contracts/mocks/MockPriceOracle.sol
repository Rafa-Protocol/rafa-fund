// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

contract MockPriceOracle is IPriceOracle {
    uint256 public priceWad;
    uint256 public updatedAt;

    constructor(uint256 priceWad_, uint256 updatedAt_) {
        priceWad = priceWad_;
        updatedAt = updatedAt_;
    }

    function setPrice(uint256 priceWad_, uint256 updatedAt_) external {
        priceWad = priceWad_;
        updatedAt = updatedAt_;
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (priceWad, updatedAt);
    }
}
