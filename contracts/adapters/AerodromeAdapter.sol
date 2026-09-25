// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAerodromeRouter} from "../interfaces/IAerodromeRouter.sol";
import {ITradeAdapter} from "../interfaces/ITradeAdapter.sol";

/// @title AerodromeAdapter
/// @notice Executes only RAFA-approved, direct accounting-asset pairs on Base.
contract AerodromeAdapter is ITradeAdapter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct RouteConfig {
        bool configured;
        bool stablePair;
        address factory;
    }

    IAerodromeRouter public immutable router;
    address public immutable override accountingAsset;
    mapping(address assetToken => RouteConfig config) public routes;

    error InvalidAddress();
    error InvalidAmount();
    error InvalidPair(address tokenIn, address tokenOut);
    error RouteNotConfigured(address assetToken);
    error DeadlineExpired(uint256 deadline);

    event RouteConfigured(address indexed assetToken, bool stablePair, address indexed factory);
    event RouteDisabled(address indexed assetToken);

    constructor(address initialOwner, address accountingAsset_, address router_) Ownable(initialOwner) {
        if (
            initialOwner == address(0) || accountingAsset_ == address(0) || accountingAsset_.code.length == 0
                || router_ == address(0) || router_.code.length == 0
        ) revert InvalidAddress();

        accountingAsset = accountingAsset_;
        router = IAerodromeRouter(router_);
    }

    function configureRoute(address assetToken, bool stablePair, address factory) external onlyOwner {
        if (assetToken == address(0) || assetToken == accountingAsset) revert InvalidAddress();
        address selectedFactory = factory == address(0) ? router.defaultFactory() : factory;
        if (selectedFactory == address(0)) revert InvalidAddress();
        routes[assetToken] = RouteConfig({configured: true, stablePair: stablePair, factory: selectedFactory});
        emit RouteConfigured(assetToken, stablePair, selectedFactory);
    }

    function disableRoute(address assetToken) external onlyOwner {
        delete routes[assetToken];
        emit RouteDisabled(assetToken);
    }

    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minimumAmountOut,
        address recipient,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0 || recipient == address(0)) revert InvalidAmount();
        if (deadline < block.timestamp) revert DeadlineExpired(deadline);

        address assetToken = _assetForPair(tokenIn, tokenOut);
        RouteConfig memory config = routes[assetToken];
        if (!config.configured) revert RouteNotConfigured(assetToken);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        IAerodromeRouter.Route[] memory swapRoutes = new IAerodromeRouter.Route[](1);
        swapRoutes[0] = IAerodromeRouter.Route({
            from: tokenIn, to: tokenOut, stable: config.stablePair, factory: config.factory
        });

        uint256[] memory amounts =
            router.swapExactTokensForTokens(amountIn, minimumAmountOut, swapRoutes, recipient, deadline);
        amountOut = amounts[amounts.length - 1];
        IERC20(tokenIn).forceApprove(address(router), 0);
    }

    function _assetForPair(address tokenIn, address tokenOut) private view returns (address assetToken) {
        bool inputIsAccountingAsset = tokenIn == accountingAsset;
        bool outputIsAccountingAsset = tokenOut == accountingAsset;
        if (inputIsAccountingAsset == outputIsAccountingAsset) revert InvalidPair(tokenIn, tokenOut);
        assetToken = inputIsAccountingAsset ? tokenOut : tokenIn;
    }
}
