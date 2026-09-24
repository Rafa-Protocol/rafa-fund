// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlDefaultAdminRules} from
    "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IRafaAssetRegistry} from "./interfaces/IRafaAssetRegistry.sol";
import {ITradeAdapter} from "./interfaces/ITradeAdapter.sol";

/// @title RafaFundV2
/// @notice A USDC-accounted, ERC-4626-compatible fund whose shares represent a
///         proportional claim on a bounded basket of supported assets.
/// @dev Standard ERC-4626 withdrawals consume idle accounting-asset liquidity.
///      Holders can always use `redeemInKind` to exit proportionally without
///      depending on a DEX or price oracle.
contract RafaFundV2 is ERC4626, AccessControlDefaultAdminRules, ReentrancyGuard {
    using Math for uint256;
    using SafeERC20 for IERC20;

    bytes32 public constant IMPLEMENTATION_ID = keccak256("RAFA_FUND_V2");
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 3_000;
    uint16 public constant MAX_TRADE_SLIPPAGE_BPS = 2_000;
    uint8 public constant MAX_ASSETS = 10;

    bytes32 public constant TRADER_ROLE = keccak256("TRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    struct FundInitParams {
        string name;
        string symbol;
        string metadataURI;
        address accountingAsset;
        address assetRegistry;
        address admin;
        address trader;
        address guardian;
        address feeRecipient;
        uint16 performanceFeeBps;
        uint16 maxTradeSlippageBps;
        uint16 maxTradeValueBps;
        uint48 adminTransferDelay;
        uint256 depositCap;
    }

    struct AssetConfig {
        bool supported;
        uint16 maxExposureBps;
    }

    IRafaAssetRegistry public immutable assetRegistry;
    uint8 public immutable accountingAssetDecimals;
    uint16 public immutable performanceFeeBps;
    uint16 public immutable maxTradeSlippageBps;

    address public feeRecipient;
    uint256 public depositCap;
    uint16 public maxTradeValueBps;
    uint256 public highWaterMarkWad = 1e18;
    string public metadataURI;
    bool public depositsPaused;
    bool public tradingPaused;

    address[] private _activeAssets;
    mapping(address assetToken => AssetConfig config) private _assetConfigs;
    mapping(address assetToken => uint256 indexPlusOne) private _assetIndexPlusOne;

    error InvalidAddress();
    error InvalidAmount();
    error InvalidFee(uint256 feeBps);
    error InvalidSlippage(uint256 slippageBps);
    error InvalidRiskLimit(uint256 riskLimitBps);
    error UnsupportedDecimals(uint8 decimals);
    error DepositsArePaused();
    error TradingIsPaused();
    error DepositCapExceeded(uint256 requestedAssets, uint256 maximumAssets);
    error InsufficientShares(uint256 actualShares, uint256 minimumShares);
    error InsufficientAssets(uint256 actualAssets, uint256 minimumAssets);
    error AssetAlreadySupported(address assetToken);
    error AssetNotSupported(address assetToken);
    error AssetAdmissionDisabled(address assetToken);
    error AssetBuyingDisabled(address assetToken);
    error AssetSellingDisabled(address assetToken);
    error AssetPolicyNotConfigured(address assetToken);
    error AssetBalanceNotZero(address assetToken, uint256 balance);
    error MaximumAssetsReached();
    error InvalidOraclePrice(address assetToken, uint256 price);
    error StaleOraclePrice(address assetToken, uint256 updatedAt, uint256 maxPriceAge);
    error InvalidTradePair(address tokenIn, address tokenOut);
    error TradeDeadlineExpired(uint256 deadline);
    error TradeSlippageTooHigh(uint256 minimumAmountOut, uint256 oracleMinimumAmountOut);
    error TradeValueAboveLimit(uint256 tradeValue, uint256 maximumTradeValue);
    error AssetExposureAboveLimit(address assetToken, uint256 exposureBps, uint256 maximumExposureBps);
    error InsufficientLiquidity(uint256 requestedAssets, uint256 availableAssets);
    error CannotRecoverSupportedAsset(address assetToken);
    error InvalidTradeInput(uint256 expectedAmount, uint256 actualAmount);

    event AssetAdded(
        address indexed assetToken,
        address indexed oracle,
        address indexed adapter,
        uint16 maxExposureBps
    );
    event AssetExposureUpdated(address indexed assetToken, uint16 previousMaxExposureBps, uint16 newMaxExposureBps);
    event AssetRemoved(address indexed assetToken);
    event TradeExecuted(
        address indexed trader, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event InKindRedemption(address indexed caller, address indexed owner, address indexed receiver, uint256 shares);
    event PerformanceFeeAccrued(
        address indexed recipient, uint256 feeAssetsWad, uint256 feeShares, uint256 highWaterMarkWad
    );
    event PerformanceFeeAccrualSkipped();
    event FeeRecipientUpdated(address indexed previousRecipient, address indexed newRecipient);
    event DepositCapUpdated(uint256 previousCap, uint256 newCap);
    event MaxTradeValueUpdated(uint16 previousLimitBps, uint16 newLimitBps);
    event MetadataURIUpdated(string previousURI, string newURI);
    event DepositsPauseUpdated(bool paused);
    event TradingPauseUpdated(bool paused);
    event UnsupportedTokenRecovered(address indexed assetToken, address indexed recipient, uint256 amount);

    constructor(FundInitParams memory params)
        ERC20(params.name, params.symbol)
        ERC4626(IERC20(params.accountingAsset))
        AccessControlDefaultAdminRules(params.adminTransferDelay, params.admin)
    {
        if (
            params.accountingAsset == address(0) || params.assetRegistry == address(0) || params.admin == address(0)
                || params.trader == address(0) || params.guardian == address(0) || params.feeRecipient == address(0)
        ) revert InvalidAddress();
        if (params.accountingAsset.code.length == 0 || params.assetRegistry.code.length == 0) revert InvalidAddress();
        if (params.performanceFeeBps > MAX_PERFORMANCE_FEE_BPS) revert InvalidFee(params.performanceFeeBps);
        if (params.maxTradeSlippageBps > MAX_TRADE_SLIPPAGE_BPS) {
            revert InvalidSlippage(params.maxTradeSlippageBps);
        }
        if (params.maxTradeValueBps == 0 || params.maxTradeValueBps > BPS_DENOMINATOR) {
            revert InvalidRiskLimit(params.maxTradeValueBps);
        }
        if (params.depositCap == 0) revert InvalidAmount();

        uint8 assetDecimals = IERC20Metadata(params.accountingAsset).decimals();
        if (assetDecimals > 18) revert UnsupportedDecimals(assetDecimals);

        assetRegistry = IRafaAssetRegistry(params.assetRegistry);
        if (assetRegistry.accountingAsset() != params.accountingAsset) revert InvalidAddress();
        accountingAssetDecimals = assetDecimals;
        performanceFeeBps = params.performanceFeeBps;
        maxTradeSlippageBps = params.maxTradeSlippageBps;
        feeRecipient = params.feeRecipient;
        depositCap = params.depositCap;
        maxTradeValueBps = params.maxTradeValueBps;
        metadataURI = params.metadataURI;

        _grantRole(TRADER_ROLE, params.trader);
        _grantRole(GUARDIAN_ROLE, params.guardian);
    }

    // ---------------------------------------------------------------------
    // ERC-4626 accounting and guarded entry/exit
    // ---------------------------------------------------------------------

    function totalAssets() public view override returns (uint256 totalValue) {
        return _calculateTotalAssets(false);
    }

    /// @notice Portfolio value using the stricter freshness threshold required
    ///         for deposits, cash exits, fees, and trades.
    function settlementTotalAssets() public view returns (uint256 totalValue) {
        return _calculateTotalAssets(true);
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (depositsPaused) return 0;
        uint256 currentAssets = totalAssets();
        return currentAssets >= depositCap ? 0 : depositCap - currentAssets;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 ownerAssets = super.maxWithdraw(owner);
        return Math.min(ownerAssets, IERC20(asset()).balanceOf(address(this)));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 ownerShares = balanceOf(owner);
        if (ownerShares == 0) return 0;

        uint256 liquidAssets = IERC20(asset()).balanceOf(address(this));
        uint256 managedAssets = totalAssets();
        if (liquidAssets >= managedAssets) return ownerShares;

        return Math.min(ownerShares, _convertToShares(liquidAssets, Math.Rounding.Floor));
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        _accruePerformanceFee();
        shares = _depositWithMinimum(assets, receiver, 0);
    }

    function depositWithSlippage(uint256 assets, address receiver, uint256 minSharesOut)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _accruePerformanceFee();
        shares = _depositWithMinimum(assets, receiver, minSharesOut);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        _accruePerformanceFee();
        if (depositsPaused) revert DepositsArePaused();

        uint256 maximumShares = maxMint(receiver);
        if (shares == 0 || shares > maximumShares) revert DepositCapExceeded(shares, maximumShares);

        assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _accruePerformanceFee();
        uint256 availableAssets = maxWithdraw(owner);
        if (assets == 0 || assets > availableAssets) revert InsufficientLiquidity(assets, availableAssets);

        shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _accruePerformanceFee();
        assets = _redeemWithMinimum(shares, receiver, owner, 0);
    }

    function redeemWithSlippage(uint256 shares, address receiver, address owner, uint256 minAssetsOut)
        external
        nonReentrant
        returns (uint256 assets)
    {
        _accruePerformanceFee();
        assets = _redeemWithMinimum(shares, receiver, owner, minAssetsOut);
    }

    /// @notice Burns shares and transfers a proportional slice of every held
    ///         token. This path intentionally does not require functioning
    ///         oracles or DEX liquidity and remains available during pauses.
    function redeemInKind(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        if (shares == 0 || receiver == address(0)) revert InvalidAmount();
        _tryAccruePerformanceFee();
        uint256 supply = totalSupply();
        if (supply == 0 || shares > balanceOf(owner)) revert InvalidAmount();

        if (_msgSender() != owner) _spendAllowance(owner, _msgSender(), shares);

        uint256 length = _activeAssets.length;
        tokens = new address[](length + 1);
        amounts = new uint256[](length + 1);

        tokens[0] = asset();
        amounts[0] = Math.mulDiv(IERC20(asset()).balanceOf(address(this)), shares, supply);

        for (uint256 i; i < length; ++i) {
            address assetToken = _activeAssets[i];
            tokens[i + 1] = assetToken;
            amounts[i + 1] = Math.mulDiv(IERC20(assetToken).balanceOf(address(this)), shares, supply);
        }

        _burn(owner, shares);

        for (uint256 i; i < tokens.length; ++i) {
            if (amounts[i] != 0) IERC20(tokens[i]).safeTransfer(receiver, amounts[i]);
        }

        if (totalSupply() == 0) highWaterMarkWad = 1e18;
        emit InKindRedemption(_msgSender(), owner, receiver, shares);
    }

    // ---------------------------------------------------------------------
    // Performance fee
    // ---------------------------------------------------------------------

    function pricePerShareWad() external view returns (uint256) {
        return _pricePerShareWad(totalAssets(), totalSupply());
    }

    function accruePerformanceFee() external nonReentrant returns (uint256 feeShares) {
        feeShares = _accruePerformanceFee();
    }

    // ---------------------------------------------------------------------
    // Manager trading
    // ---------------------------------------------------------------------

    function trade(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        nonReentrant
        onlyRole(TRADER_ROLE)
        returns (uint256 amountOut)
    {
        if (tradingPaused) revert TradingIsPaused();
        if (amountIn == 0) revert InvalidAmount();
        if (deadline < block.timestamp) revert TradeDeadlineExpired(deadline);

        (address adapter, uint256 oracleMinimum) = _validateTrade(tokenIn, tokenOut, amountIn);
        if (minAmountOut < oracleMinimum) revert TradeSlippageTooHigh(minAmountOut, oracleMinimum);

        amountOut = _executeTrade(tokenIn, tokenOut, amountIn, minAmountOut, deadline, adapter);
        if (tokenIn == asset()) _enforceExposure(tokenOut);
        emit TradeExecuted(_msgSender(), tokenIn, tokenOut, amountIn, amountOut);
    }

    // ---------------------------------------------------------------------
    // Fund administration
    // ---------------------------------------------------------------------

    function addAsset(address assetToken, uint16 maxExposureBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (assetToken == address(0) || assetToken == asset()) revert InvalidAddress();
        if (_assetConfigs[assetToken].supported) revert AssetAlreadySupported(assetToken);
        if (_activeAssets.length >= MAX_ASSETS) revert MaximumAssetsReached();

        IRafaAssetRegistry.AssetPolicy memory policy = _assetPolicy(assetToken);
        if (!policy.admissionEnabled) revert AssetAdmissionDisabled(assetToken);
        _validateExposure(maxExposureBps);
        if (maxExposureBps > policy.maxExposureBps) revert InvalidRiskLimit(maxExposureBps);
        _freshPrice(assetToken, policy, policy.tradeMaxAge);

        _assetConfigs[assetToken] = AssetConfig({supported: true, maxExposureBps: maxExposureBps});
        _activeAssets.push(assetToken);
        _assetIndexPlusOne[assetToken] = _activeAssets.length;

        emit AssetAdded(assetToken, address(policy.oracle), policy.adapter, maxExposureBps);
    }

    function updateAssetExposure(address assetToken, uint16 maxExposureBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        AssetConfig storage config = _assetConfigs[assetToken];
        if (!config.supported) revert AssetNotSupported(assetToken);
        _validateExposure(maxExposureBps);
        IRafaAssetRegistry.AssetPolicy memory policy = _assetPolicy(assetToken);
        if (maxExposureBps > policy.maxExposureBps) revert InvalidRiskLimit(maxExposureBps);
        uint16 previousMaxExposureBps = config.maxExposureBps;
        config.maxExposureBps = maxExposureBps;
        emit AssetExposureUpdated(assetToken, previousMaxExposureBps, maxExposureBps);
    }

    function removeAsset(address assetToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        AssetConfig memory config = _assetConfigs[assetToken];
        if (!config.supported) revert AssetNotSupported(assetToken);

        uint256 balance = IERC20(assetToken).balanceOf(address(this));
        if (balance != 0) revert AssetBalanceNotZero(assetToken, balance);

        uint256 index = _assetIndexPlusOne[assetToken] - 1;
        uint256 lastIndex = _activeAssets.length - 1;
        if (index != lastIndex) {
            address lastAsset = _activeAssets[lastIndex];
            _activeAssets[index] = lastAsset;
            _assetIndexPlusOne[lastAsset] = index + 1;
        }

        _activeAssets.pop();
        delete _assetIndexPlusOne[assetToken];
        delete _assetConfigs[assetToken];
        emit AssetRemoved(assetToken);
    }

    function setDepositCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCap == 0) revert InvalidAmount();
        uint256 previousCap = depositCap;
        depositCap = newCap;
        emit DepositCapUpdated(previousCap, newCap);
    }

    function setMaxTradeValueBps(uint16 newLimitBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newLimitBps == 0 || newLimitBps > BPS_DENOMINATOR) revert InvalidRiskLimit(newLimitBps);
        uint16 previousLimitBps = maxTradeValueBps;
        maxTradeValueBps = newLimitBps;
        emit MaxTradeValueUpdated(previousLimitBps, newLimitBps);
    }

    function setFeeRecipient(address newRecipient) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRecipient == address(0)) revert InvalidAddress();
        _accruePerformanceFee();
        address previousRecipient = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(previousRecipient, newRecipient);
    }

    function setMetadataURI(string calldata newURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        string memory previousURI = metadataURI;
        metadataURI = newURI;
        emit MetadataURIUpdated(previousURI, newURI);
    }

    function pauseDeposits() external {
        _checkGuardianOrAdmin();
        if (!depositsPaused) {
            depositsPaused = true;
            emit DepositsPauseUpdated(true);
        }
    }

    function unpauseDeposits() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (depositsPaused) {
            depositsPaused = false;
            emit DepositsPauseUpdated(false);
        }
    }

    function pauseTrading() external {
        _checkGuardianOrAdmin();
        if (!tradingPaused) {
            tradingPaused = true;
            emit TradingPauseUpdated(true);
        }
    }

    function unpauseTrading() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tradingPaused) {
            tradingPaused = false;
            emit TradingPauseUpdated(false);
        }
    }

    function recoverUnsupportedToken(address assetToken, address recipient, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (recipient == address(0) || amount == 0) revert InvalidAmount();
        if (assetToken == asset() || _assetConfigs[assetToken].supported) {
            revert CannotRecoverSupportedAsset(assetToken);
        }

        IERC20(assetToken).safeTransfer(recipient, amount);
        emit UnsupportedTokenRecovered(assetToken, recipient, amount);
    }

    function getActiveAssets() external view returns (address[] memory) {
        return _activeAssets;
    }

    function getAssetConfig(address assetToken) external view returns (AssetConfig memory) {
        return _assetConfigs[assetToken];
    }

    function getAssetPolicy(address assetToken) external view returns (IRafaAssetRegistry.AssetPolicy memory) {
        return _assetPolicy(assetToken);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _depositWithMinimum(uint256 assets, address receiver, uint256 minSharesOut)
        private
        returns (uint256 shares)
    {
        if (depositsPaused) revert DepositsArePaused();
        if (assets == 0 || receiver == address(0)) revert InvalidAmount();

        uint256 maximumAssets = maxDeposit(receiver);
        if (assets > maximumAssets) revert DepositCapExceeded(assets, maximumAssets);

        shares = previewDeposit(assets);
        if (shares == 0 || shares < minSharesOut) revert InsufficientShares(shares, minSharesOut);
        _deposit(_msgSender(), receiver, assets, shares);
    }

    function _redeemWithMinimum(uint256 shares, address receiver, address owner, uint256 minAssetsOut)
        private
        returns (uint256 assets)
    {
        if (shares == 0 || receiver == address(0)) revert InvalidAmount();
        uint256 availableShares = maxRedeem(owner);
        if (shares > availableShares) {
            revert InsufficientLiquidity(previewRedeem(shares), IERC20(asset()).balanceOf(address(this)));
        }

        assets = previewRedeem(shares);
        if (assets == 0 || assets < minAssetsOut) revert InsufficientAssets(assets, minAssetsOut);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        super._withdraw(caller, receiver, owner, assets, shares);
        if (totalSupply() == 0) highWaterMarkWad = 1e18;
    }

    function _accruePerformanceFee() private returns (uint256 feeShares) {
        uint256 managedAssets = settlementTotalAssets();
        uint256 supply = totalSupply();
        if (supply == 0 || performanceFeeBps == 0) return 0;

        return _accruePerformanceFeeFromAssets(managedAssets, supply);
    }

    function _tryAccruePerformanceFee() private returns (uint256 feeShares) {
        uint256 supply = totalSupply();
        if (supply == 0 || performanceFeeBps == 0) return 0;

        try this.settlementTotalAssets() returns (uint256 managedAssets) {
            return _accruePerformanceFeeFromAssets(managedAssets, supply);
        } catch {
            emit PerformanceFeeAccrualSkipped();
            return 0;
        }
    }

    function _accruePerformanceFeeFromAssets(uint256 managedAssets, uint256 supply)
        private
        returns (uint256 feeShares)
    {
        uint256 grossPriceWad = _pricePerShareWad(managedAssets, supply);
        if (grossPriceWad <= highWaterMarkWad) return 0;

        uint256 managedAssetsWad = _toWad(managedAssets, accountingAssetDecimals);
        uint256 assetsAtHighWaterMarkWad = Math.mulDiv(supply, highWaterMarkWad, 1e18);
        uint256 profitWad = managedAssetsWad - assetsAtHighWaterMarkWad;
        uint256 feeAssetsWad = Math.mulDiv(profitWad, performanceFeeBps, BPS_DENOMINATOR);
        if (feeAssetsWad == 0 || feeAssetsWad >= managedAssetsWad) return 0;

        feeShares = Math.mulDiv(feeAssetsWad, supply, managedAssetsWad - feeAssetsWad);
        if (feeShares == 0) return 0;

        _mint(feeRecipient, feeShares);
        highWaterMarkWad = _pricePerShareWad(managedAssets, supply + feeShares);
        emit PerformanceFeeAccrued(feeRecipient, feeAssetsWad, feeShares, highWaterMarkWad);
    }

    function _pricePerShareWad(uint256 managedAssets, uint256 supply) private view returns (uint256) {
        if (supply == 0) return 1e18;
        return Math.mulDiv(_toWad(managedAssets, accountingAssetDecimals), 1e18, supply);
    }

    function _calculateTotalAssets(bool settlementPrice) private view returns (uint256 totalValue) {
        totalValue = IERC20(asset()).balanceOf(address(this));

        uint256 length = _activeAssets.length;
        for (uint256 i; i < length; ++i) {
            address assetToken = _activeAssets[i];
            uint256 balance = IERC20(assetToken).balanceOf(address(this));
            if (balance == 0) continue;

            IRafaAssetRegistry.AssetPolicy memory policy = _assetPolicy(assetToken);
            uint48 maxPriceAge = settlementPrice ? policy.tradeMaxAge : policy.valuationMaxAge;
            totalValue += _valueInAccountingAsset(assetToken, balance, policy, maxPriceAge);
        }
    }

    function _valueInAccountingAsset(
        address assetToken,
        uint256 amount,
        IRafaAssetRegistry.AssetPolicy memory policy,
        uint48 maxPriceAge
    ) private view returns (uint256) {
        uint256 priceWad = _freshPrice(assetToken, policy, maxPriceAge);
        uint256 tokenAmountWad = _toWad(amount, policy.decimals);
        uint256 accountingValueWad = Math.mulDiv(tokenAmountWad, priceWad, 1e18);
        return _fromWad(accountingValueWad, accountingAssetDecimals);
    }

    function _validateTrade(address tokenIn, address tokenOut, uint256 amountIn)
        private
        view
        returns (address adapter, uint256 oracleMinimum)
    {
        bool inputIsAccountingAsset = tokenIn == asset();
        bool outputIsAccountingAsset = tokenOut == asset();
        if (inputIsAccountingAsset == outputIsAccountingAsset) revert InvalidTradePair(tokenIn, tokenOut);

        address managedToken = inputIsAccountingAsset ? tokenOut : tokenIn;
        AssetConfig memory config = _assetConfigs[managedToken];
        if (!config.supported) revert AssetNotSupported(managedToken);
        IRafaAssetRegistry.AssetPolicy memory policy = _assetPolicy(managedToken);
        if (inputIsAccountingAsset && !policy.buyEnabled) revert AssetBuyingDisabled(managedToken);
        if (outputIsAccountingAsset && !policy.sellEnabled) revert AssetSellingDisabled(managedToken);

        uint256 tradeValue = inputIsAccountingAsset
            ? amountIn
            : _valueInAccountingAsset(tokenIn, amountIn, policy, policy.tradeMaxAge);
        uint256 maximumTradeValue = Math.mulDiv(settlementTotalAssets(), maxTradeValueBps, BPS_DENOMINATOR);
        if (tradeValue > maximumTradeValue) revert TradeValueAboveLimit(tradeValue, maximumTradeValue);

        uint256 expectedOut = inputIsAccountingAsset
            ? _amountFromAccountingAsset(tokenOut, amountIn, policy, policy.tradeMaxAge)
            : tradeValue;
        oracleMinimum =
            Math.mulDiv(expectedOut, BPS_DENOMINATOR - maxTradeSlippageBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
        adapter = policy.adapter;
    }

    function _executeTrade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        address adapter
    ) private returns (uint256 amountOut) {
        uint256 inputBalanceBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outputBalanceBefore = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(adapter, amountIn);

        ITradeAdapter(adapter).swapExactInput(
            tokenIn, tokenOut, amountIn, minAmountOut, address(this), deadline
        );
        IERC20(tokenIn).forceApprove(adapter, 0);

        uint256 inputBalanceAfter = IERC20(tokenIn).balanceOf(address(this));
        uint256 actualInput = inputBalanceBefore - inputBalanceAfter;
        if (actualInput != amountIn) revert InvalidTradeInput(amountIn, actualInput);

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outputBalanceBefore;
        if (amountOut < minAmountOut) revert InsufficientAssets(amountOut, minAmountOut);
    }

    function _enforceExposure(address assetToken) private view {
        AssetConfig memory config = _assetConfigs[assetToken];
        uint256 managedAssets = settlementTotalAssets();
        if (managedAssets == 0) return;

        IRafaAssetRegistry.AssetPolicy memory policy = _assetPolicy(assetToken);
        uint256 effectiveMaximum = Math.min(uint256(config.maxExposureBps), uint256(policy.maxExposureBps));
        uint256 assetValue = _valueInAccountingAsset(
            assetToken, IERC20(assetToken).balanceOf(address(this)), policy, policy.tradeMaxAge
        );
        uint256 exposureBps = Math.mulDiv(assetValue, BPS_DENOMINATOR, managedAssets, Math.Rounding.Ceil);
        if (exposureBps > effectiveMaximum) {
            revert AssetExposureAboveLimit(assetToken, exposureBps, effectiveMaximum);
        }
    }

    function _amountFromAccountingAsset(
        address assetToken,
        uint256 accountingAmount,
        IRafaAssetRegistry.AssetPolicy memory policy,
        uint48 maxPriceAge
    ) private view returns (uint256) {
        uint256 priceWad = _freshPrice(assetToken, policy, maxPriceAge);
        uint256 accountingAmountWad = _toWad(accountingAmount, accountingAssetDecimals);
        uint256 tokenAmountWad = Math.mulDiv(accountingAmountWad, 1e18, priceWad);
        return _fromWad(tokenAmountWad, policy.decimals);
    }

    function _freshPrice(address assetToken, IRafaAssetRegistry.AssetPolicy memory policy, uint48 maxPriceAge)
        private
        view
        returns (uint256 priceWad)
    {
        uint256 updatedAt;
        (priceWad, updatedAt) = policy.oracle.latestPrice();
        if (priceWad == 0) revert InvalidOraclePrice(assetToken, priceWad);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxPriceAge) {
            revert StaleOraclePrice(assetToken, updatedAt, maxPriceAge);
        }
    }

    function _assetPolicy(address assetToken) private view returns (IRafaAssetRegistry.AssetPolicy memory policy) {
        policy = assetRegistry.getAssetPolicy(assetToken);
        if (!policy.configured) revert AssetPolicyNotConfigured(assetToken);
    }

    function _validateExposure(uint16 maxExposureBps) private pure {
        if (maxExposureBps == 0 || maxExposureBps > BPS_DENOMINATOR) {
            revert InvalidRiskLimit(maxExposureBps);
        }
    }

    function _checkGuardianOrAdmin() private view {
        if (!hasRole(GUARDIAN_ROLE, _msgSender()) && !hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
            _checkRole(GUARDIAN_ROLE, _msgSender());
        }
    }

    function _toWad(uint256 amount, uint8 amountDecimals) private pure returns (uint256) {
        return amount * (10 ** (18 - amountDecimals));
    }

    function _fromWad(uint256 amountWad, uint8 targetDecimals) private pure returns (uint256) {
        return amountWad / (10 ** (18 - targetDecimals));
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return 18 - accountingAssetDecimals;
    }
}
