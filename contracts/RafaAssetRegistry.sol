// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IRafaAssetRegistry} from "./interfaces/IRafaAssetRegistry.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ITradeAdapter} from "./interfaces/ITradeAdapter.sol";

/// @title RafaAssetRegistry
/// @notice RAFA-controlled, chain-local allowlist and risk policy for every
///         asset that an official fund may hold or trade.
/// @dev Token bytecode is deliberately not required. Base B20 assets are
///      native precompiles and can expose ERC-20 behavior with empty bytecode.
contract RafaAssetRegistry is IRafaAssetRegistry, Ownable2Step {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint48 public constant MAX_VALUATION_AGE = 7 days;

    address public immutable override accountingAsset;
    mapping(address assetToken => AssetPolicy policy) private _assetPolicies;

    error InvalidAddress();
    error InvalidAsset(address assetToken);
    error InvalidDecimals(uint8 decimals);
    error InvalidPriceAge(uint48 valuationMaxAge, uint48 tradeMaxAge);
    error InvalidExposure(uint16 maxExposureBps);
    error AssetNotConfigured(address assetToken);

    event AssetPolicyConfigured(
        address indexed assetToken,
        address indexed oracle,
        address indexed adapter,
        uint8 decimals,
        uint48 valuationMaxAge,
        uint48 tradeMaxAge,
        uint16 maxExposureBps,
        bytes32 assetClass,
        bytes32 issuerId
    );
    event AssetStatusUpdated(
        address indexed assetToken, bool admissionEnabled, bool buyEnabled, bool sellEnabled
    );

    constructor(address initialOwner, address accountingAsset_) Ownable(initialOwner) {
        if (initialOwner == address(0) || accountingAsset_ == address(0) || accountingAsset_.code.length == 0) {
            revert InvalidAddress();
        }
        accountingAsset = accountingAsset_;
    }

    function configureAsset(
        address assetToken,
        uint8 decimals,
        address oracle,
        uint48 valuationMaxAge,
        uint48 tradeMaxAge,
        uint16 maxExposureBps,
        address adapter,
        bytes32 assetClass,
        bytes32 issuerId
    ) external onlyOwner {
        if (assetToken == address(0) || assetToken == accountingAsset) revert InvalidAsset(assetToken);
        if (oracle == address(0) || oracle.code.length == 0 || adapter == address(0) || adapter.code.length == 0) {
            revert InvalidAddress();
        }
        if (ITradeAdapter(adapter).accountingAsset() != accountingAsset) revert InvalidAddress();
        if (decimals > 18) revert InvalidDecimals(decimals);
        if (
            tradeMaxAge == 0 || valuationMaxAge == 0 || tradeMaxAge > valuationMaxAge
                || valuationMaxAge > MAX_VALUATION_AGE
        ) {
            revert InvalidPriceAge(valuationMaxAge, tradeMaxAge);
        }
        if (maxExposureBps == 0 || maxExposureBps > BPS_DENOMINATOR) {
            revert InvalidExposure(maxExposureBps);
        }

        AssetPolicy storage policy = _assetPolicies[assetToken];
        bool firstConfiguration = !policy.configured;
        policy.configured = true;
        if (firstConfiguration) {
            policy.admissionEnabled = true;
            policy.buyEnabled = true;
            policy.sellEnabled = true;
        }
        policy.decimals = decimals;
        policy.valuationMaxAge = valuationMaxAge;
        policy.tradeMaxAge = tradeMaxAge;
        policy.maxExposureBps = maxExposureBps;
        policy.oracle = IPriceOracle(oracle);
        policy.adapter = adapter;
        policy.assetClass = assetClass;
        policy.issuerId = issuerId;

        emit AssetPolicyConfigured(
            assetToken,
            oracle,
            adapter,
            decimals,
            valuationMaxAge,
            tradeMaxAge,
            maxExposureBps,
            assetClass,
            issuerId
        );
    }

    function setAssetStatus(address assetToken, bool admissionEnabled, bool buyEnabled, bool sellEnabled)
        external
        onlyOwner
    {
        AssetPolicy storage policy = _assetPolicies[assetToken];
        if (!policy.configured) revert AssetNotConfigured(assetToken);

        policy.admissionEnabled = admissionEnabled;
        policy.buyEnabled = buyEnabled;
        policy.sellEnabled = sellEnabled;
        emit AssetStatusUpdated(assetToken, admissionEnabled, buyEnabled, sellEnabled);
    }

    function getAssetPolicy(address assetToken) external view returns (AssetPolicy memory) {
        return _assetPolicies[assetToken];
    }
}
