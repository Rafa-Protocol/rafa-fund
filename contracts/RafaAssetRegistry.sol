// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
    uint48 public constant RECONFIGURATION_DELAY = 48 hours;

    struct PendingAssetPolicy {
        AssetPolicy policy;
        uint48 executeAfter;
    }

    address public immutable override accountingAsset;
    mapping(address assetToken => AssetPolicy policy) private _assetPolicies;
    mapping(address assetToken => PendingAssetPolicy pendingPolicy) private _pendingAssetPolicies;

    error InvalidAddress();
    error InvalidAsset(address assetToken);
    error InvalidDecimals(uint8 decimals);
    error InvalidPriceAge(uint48 valuationMaxAge, uint48 tradeMaxAge);
    error InvalidExposure(uint16 maxExposureBps);
    error AssetNotConfigured(address assetToken);
    error AssetAlreadyConfigured(address assetToken);
    error AssetMustBeDisabled(address assetToken);
    error TokenDecimalsMismatch(address assetToken, uint8 configuredDecimals, uint8 tokenDecimals);
    error TokenDecimalsUnavailable(address assetToken);
    error ReconfigurationNotPending(address assetToken);
    error ReconfigurationDelayActive(address assetToken, uint256 executeAfter);

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
    event AssetPolicyReconfigurationProposed(
        address indexed assetToken, uint48 indexed executeAfter, address indexed oracle, address adapter
    );
    event AssetPolicyReconfigured(address indexed assetToken, address indexed oracle, address indexed adapter);
    event AssetPolicyReconfigurationCancelled(address indexed assetToken);
    event AssetExposureLimitReduced(address indexed assetToken, uint16 previousLimitBps, uint16 newLimitBps);

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
        if (_assetPolicies[assetToken].configured) revert AssetAlreadyConfigured(assetToken);
        AssetPolicy memory policy = _validatedPolicy(
            assetToken,
            decimals,
            oracle,
            valuationMaxAge,
            tradeMaxAge,
            maxExposureBps,
            adapter,
            assetClass,
            issuerId
        );
        policy.admissionEnabled = true;
        policy.buyEnabled = true;
        policy.sellEnabled = true;
        _assetPolicies[assetToken] = policy;
        _emitPolicyConfigured(assetToken, policy);
    }

    function proposeAssetReconfiguration(
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
        AssetPolicy memory current = _assetPolicies[assetToken];
        if (!current.configured) revert AssetNotConfigured(assetToken);
        if (current.admissionEnabled || current.buyEnabled) revert AssetMustBeDisabled(assetToken);

        AssetPolicy memory proposed = _validatedPolicy(
            assetToken,
            decimals,
            oracle,
            valuationMaxAge,
            tradeMaxAge,
            maxExposureBps,
            adapter,
            assetClass,
            issuerId
        );
        proposed.sellEnabled = current.sellEnabled;
        uint48 executeAfter = uint48(block.timestamp) + RECONFIGURATION_DELAY;
        _pendingAssetPolicies[assetToken] =
            PendingAssetPolicy({policy: proposed, executeAfter: executeAfter});
        emit AssetPolicyReconfigurationProposed(assetToken, executeAfter, oracle, adapter);
    }

    function executeAssetReconfiguration(address assetToken) external onlyOwner {
        PendingAssetPolicy storage pending = _pendingAssetPolicies[assetToken];
        uint48 executeAfter = pending.executeAfter;
        if (executeAfter == 0) revert ReconfigurationNotPending(assetToken);
        if (block.timestamp < executeAfter) revert ReconfigurationDelayActive(assetToken, executeAfter);

        AssetPolicy memory current = _assetPolicies[assetToken];
        if (current.admissionEnabled || current.buyEnabled) revert AssetMustBeDisabled(assetToken);

        AssetPolicy memory policy = pending.policy;
        policy.admissionEnabled = false;
        policy.buyEnabled = false;
        policy.sellEnabled = current.sellEnabled;
        _assetPolicies[assetToken] = policy;
        delete _pendingAssetPolicies[assetToken];

        emit AssetPolicyReconfigured(assetToken, address(policy.oracle), policy.adapter);
        _emitPolicyConfigured(assetToken, policy);
    }

    function cancelAssetReconfiguration(address assetToken) external onlyOwner {
        if (_pendingAssetPolicies[assetToken].executeAfter == 0) revert ReconfigurationNotPending(assetToken);
        delete _pendingAssetPolicies[assetToken];
        emit AssetPolicyReconfigurationCancelled(assetToken);
    }

    function reduceAssetExposureLimit(address assetToken, uint16 newLimitBps) external onlyOwner {
        AssetPolicy storage policy = _assetPolicies[assetToken];
        if (!policy.configured) revert AssetNotConfigured(assetToken);
        uint16 previousLimitBps = policy.maxExposureBps;
        if (newLimitBps == 0 || newLimitBps >= previousLimitBps) revert InvalidExposure(newLimitBps);
        policy.maxExposureBps = newLimitBps;
        emit AssetExposureLimitReduced(assetToken, previousLimitBps, newLimitBps);
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

    function getPendingAssetPolicy(address assetToken)
        external
        view
        returns (AssetPolicy memory policy, uint48 executeAfter)
    {
        PendingAssetPolicy storage pending = _pendingAssetPolicies[assetToken];
        return (pending.policy, pending.executeAfter);
    }

    function _validatedPolicy(
        address assetToken,
        uint8 decimals,
        address oracle,
        uint48 valuationMaxAge,
        uint48 tradeMaxAge,
        uint16 maxExposureBps,
        address adapter,
        bytes32 assetClass,
        bytes32 issuerId
    ) private view returns (AssetPolicy memory policy) {
        if (assetToken == address(0) || assetToken == accountingAsset) revert InvalidAsset(assetToken);
        if (oracle == address(0) || oracle.code.length == 0 || adapter == address(0) || adapter.code.length == 0) {
            revert InvalidAddress();
        }
        if (ITradeAdapter(adapter).accountingAsset() != accountingAsset) revert InvalidAddress();
        if (decimals > 18) revert InvalidDecimals(decimals);
        if (assetToken.code.length != 0) {
            uint8 tokenDecimals;
            try IERC20Metadata(assetToken).decimals() returns (uint8 reportedDecimals) {
                tokenDecimals = reportedDecimals;
            } catch {
                revert TokenDecimalsUnavailable(assetToken);
            }
            if (tokenDecimals != decimals) {
                revert TokenDecimalsMismatch(assetToken, decimals, tokenDecimals);
            }
        }
        if (
            tradeMaxAge == 0 || valuationMaxAge == 0 || tradeMaxAge > valuationMaxAge
                || valuationMaxAge > MAX_VALUATION_AGE
        ) {
            revert InvalidPriceAge(valuationMaxAge, tradeMaxAge);
        }
        if (maxExposureBps == 0 || maxExposureBps > BPS_DENOMINATOR) {
            revert InvalidExposure(maxExposureBps);
        }

        policy = AssetPolicy({
            configured: true,
            admissionEnabled: false,
            buyEnabled: false,
            sellEnabled: false,
            decimals: decimals,
            valuationMaxAge: valuationMaxAge,
            tradeMaxAge: tradeMaxAge,
            maxExposureBps: maxExposureBps,
            oracle: IPriceOracle(oracle),
            adapter: adapter,
            assetClass: assetClass,
            issuerId: issuerId
        });
    }

    function _emitPolicyConfigured(address assetToken, AssetPolicy memory policy) private {
        emit AssetPolicyConfigured(
            assetToken,
            address(policy.oracle),
            policy.adapter,
            policy.decimals,
            policy.valuationMaxAge,
            policy.tradeMaxAge,
            policy.maxExposureBps,
            policy.assetClass,
            policy.issuerId
        );
    }
}
