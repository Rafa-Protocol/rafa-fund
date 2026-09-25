// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// LEGACY PROTOTYPE: retained for history. Use RafaFundV2 for new deployments.

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAerodromeRouter.sol";

contract BaseETF is ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Roles ---
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // --- State Variables ---
    IERC20 public immutable USDC;
    IAerodromeRouter public immutable ROUTER;

    // Limits to prevent gas DoS loop
    uint256 public constant MAX_ASSETS = 10;

    struct AssetConfig {
        bool isSupported;
        bool isStablePair; // Does this token trade against USDC in a Stable (true) or Volatile (false) pool?
        uint256 manualPrice; // Used if oracleMode = true (18 decimals)
    }

    address[] public activeAssets;
    mapping(address => AssetConfig) public assetConfig;

    bool public oracleMode = false;

    // --- Events ---
    event Deposited(address indexed user, uint256 usdcAmount, uint256 sharesMinted);
    event Redeemed(address indexed user, uint256 sharesBurned, uint256 usdcReceived);
    event RedeemedInKind(address indexed user, uint256 sharesBurned);
    event TradeExecuted(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    constructor(string memory _name, string memory _symbol, address _usdc, address _router) ERC20(_name, _symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        USDC = IERC20(_usdc);
        ROUTER = IAerodromeRouter(_router);
    }

    // =============================================================
    // VIEWS & NAV CALCULATIONS
    // =============================================================

    /**
     * @dev Calculates the total Value of the fund in USDC (6 decimals)
     * Warning: Loops through all assets. Gas cost scales with asset count.
     */
    function calculateTotalFundValue() public view returns (uint256) {
        uint256 totalValue = USDC.balanceOf(address(this)); // Start with idle USDC

        for (uint256 i = 0; i < activeAssets.length; i++) {
            address token = activeAssets[i];
            uint256 bal = IERC20(token).balanceOf(address(this));

            if (bal > 0) {
                totalValue += _getTokenValueInUSDC(token, bal);
            }
        }
        return totalValue;
    }

    function _getTokenValueInUSDC(address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;

        // ORACLE MODE
        if (oracleMode) {
            uint256 price = assetConfig[token].manualPrice; // Assumed 18 decimals price
            // Normalize: (Amount * Price) / 1e18
            return (amount * price) / 1e18;
        }

        // DEX MODE (Aerodrome)
        IAerodromeRouter.Route[] memory route = new IAerodromeRouter.Route[](1);
        route[0] = IAerodromeRouter.Route({
            from: token,
            to: address(USDC),
            stable: assetConfig[token].isStablePair,
            factory: ROUTER.defaultFactory()
        });

        try ROUTER.getAmountsOut(amount, route) returns (uint256[] memory amounts) {
            return amounts[amounts.length - 1];
        } catch {
            return 0; // Safety fallback
        }
    }

    // =============================================================
    // USER FUNCTIONS (MINT / BURN)
    // =============================================================

    /**
     * @dev Mint ETF tokens by depositing USDC
     */
    function mint(uint256 _usdcAmount) external nonReentrant {
        require(_usdcAmount > 0, "Zero amount");

        // 1. Calculate NAV before deposit
        uint256 currentTotalValue = calculateTotalFundValue();
        uint256 currentSupply = totalSupply();

        // 2. Transfer USDC in
        USDC.safeTransferFrom(msg.sender, address(this), _usdcAmount);

        // 3. Calculate Shares to Mint
        uint256 sharesToMint;
        if (currentSupply == 0) {
            // Initial mint: 1 USDC (6 dec) = 1 Share (18 dec)
            sharesToMint = _usdcAmount * 1e12;
        } else {
            // Formula: (Deposit / ExistingEquity) * ExistingShares
            sharesToMint = (_usdcAmount * currentSupply) / currentTotalValue;
        }

        _mint(msg.sender, sharesToMint);
        emit Deposited(msg.sender, _usdcAmount, sharesToMint);
    }

    /**
     * @dev Liquidate Shares: Burn ETF -> Sell all underlying -> Receive USDC
     */
    function burn(uint256 _shares) external nonReentrant {
        require(balanceOf(msg.sender) >= _shares, "Insufficient balance");

        uint256 currentSupply = totalSupply();
        uint256 shareRatio = (_shares * 1e18) / currentSupply;

        _burn(msg.sender, _shares);

        uint256 totalUsdcGenerated = 0;

        // 1. Sell proportionate share of every asset
        for (uint256 i = 0; i < activeAssets.length; i++) {
            address token = activeAssets[i];
            uint256 bal = IERC20(token).balanceOf(address(this));

            if (bal > 0) {
                uint256 amountToSell = (bal * shareRatio) / 1e18;
                if (amountToSell > 0) {
                    totalUsdcGenerated += _sellTokenForUSDC(token, amountToSell);
                }
            }
        }

        // 2. Send generated USDC + proportionate share of idle USDC
        uint256 idleUSDC = USDC.balanceOf(address(this)) - totalUsdcGenerated; // rough calc of original idle
        uint256 idleShare = (idleUSDC * shareRatio) / 1e18;

        USDC.safeTransfer(msg.sender, totalUsdcGenerated + idleShare);
        emit Redeemed(msg.sender, _shares, totalUsdcGenerated + idleShare);
    }

    /**
     * @dev In-Kind Redemption: Burn ETF -> Receive raw tokens
     */
    function burnInKind(uint256 _shares) external nonReentrant {
        uint256 currentSupply = totalSupply();
        uint256 shareRatio = (_shares * 1e18) / currentSupply;

        _burn(msg.sender, _shares);

        // Transfer Asset Shares
        for (uint256 i = 0; i < activeAssets.length; i++) {
            address token = activeAssets[i];
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) {
                uint256 amountToSend = (bal * shareRatio) / 1e18;
                IERC20(token).safeTransfer(msg.sender, amountToSend);
            }
        }

        // Transfer USDC Share
        uint256 usdcBal = USDC.balanceOf(address(this));
        uint256 usdcToSend = (usdcBal * shareRatio) / 1e18;
        USDC.safeTransfer(msg.sender, usdcToSend);

        emit RedeemedInKind(msg.sender, _shares);
    }

    // =============================================================
    // MANAGER FUNCTIONS (TRADING)
    // =============================================================

    function trade(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        onlyRole(MANAGER_ROLE)
    {
        IERC20(tokenIn).approve(address(ROUTER), amountIn);

        bool isStable = false;
        if (tokenIn == address(USDC) || tokenOut == address(USDC)) {
            if (assetConfig[tokenIn].isSupported) isStable = assetConfig[tokenIn].isStablePair;
            if (assetConfig[tokenOut].isSupported) isStable = assetConfig[tokenOut].isStablePair;
        }

        IAerodromeRouter.Route[] memory route = new IAerodromeRouter.Route[](1);
        route[0] =
            IAerodromeRouter.Route({from: tokenIn, to: tokenOut, stable: isStable, factory: ROUTER.defaultFactory()});

        ROUTER.swapExactTokensForTokens(amountIn, minAmountOut, route, address(this), block.timestamp);

        emit TradeExecuted(tokenIn, tokenOut, amountIn, minAmountOut);
    }

    // =============================================================
    // ADMIN / INTERNAL
    // =============================================================

    function whitelistToken(address _token, bool _isStablePair) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!assetConfig[_token].isSupported, "Already whitelisted");
        require(activeAssets.length < MAX_ASSETS, "Max assets reached");

        assetConfig[_token] = AssetConfig({isSupported: true, isStablePair: _isStablePair, manualPrice: 0});
        activeAssets.push(_token);
    }

    function _sellTokenForUSDC(address token, uint256 amount) internal returns (uint256) {
        IERC20(token).approve(address(ROUTER), amount);

        IAerodromeRouter.Route[] memory route = new IAerodromeRouter.Route[](1);
        route[0] = IAerodromeRouter.Route({
            from: token,
            to: address(USDC),
            stable: assetConfig[token].isStablePair,
            factory: ROUTER.defaultFactory()
        });

        uint256[] memory amounts = ROUTER.swapExactTokensForTokens(amount, 0, route, address(this), block.timestamp);
        return amounts[amounts.length - 1];
    }
}
