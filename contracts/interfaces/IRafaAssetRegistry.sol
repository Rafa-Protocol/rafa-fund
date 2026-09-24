// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "./IPriceOracle.sol";

/// @notice Chain-local source of truth for assets permitted by RAFA Protocol.
interface IRafaAssetRegistry {
    struct AssetPolicy {
        bool configured;
        bool admissionEnabled;
        bool buyEnabled;
        bool sellEnabled;
        uint8 decimals;
        uint48 valuationMaxAge;
        uint48 tradeMaxAge;
        uint16 maxExposureBps;
        IPriceOracle oracle;
        address adapter;
        bytes32 assetClass;
        bytes32 issuerId;
    }

    function accountingAsset() external view returns (address);

    function getAssetPolicy(address assetToken) external view returns (AssetPolicy memory);
}
