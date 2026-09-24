// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITradeAdapter} from "../interfaces/ITradeAdapter.sol";
import {IUniswapV3SwapRouter} from "../interfaces/IUniswapV3SwapRouter.sol";

/// @title UniswapV3Adapter
/// @notice Executes only RAFA-approved, direct accounting-asset pools on
///         Ethereum or another chain with the canonical V3 router interface.
contract UniswapV3Adapter is ITradeAdapter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapV3SwapRouter public immutable router;
    address public immutable override accountingAsset;
    mapping(address assetToken => uint24 poolFee) public poolFees;

    error InvalidAddress();
    error InvalidAmount();
    error InvalidPair(address tokenIn, address tokenOut);
    error PoolNotConfigured(address assetToken);
    error DeadlineExpired(uint256 deadline);

    event PoolConfigured(address indexed assetToken, uint24 poolFee);
    event PoolDisabled(address indexed assetToken);

    constructor(address initialOwner, address accountingAsset_, address router_) Ownable(initialOwner) {
        if (
            initialOwner == address(0) || accountingAsset_ == address(0) || accountingAsset_.code.length == 0
                || router_ == address(0) || router_.code.length == 0
        ) revert InvalidAddress();

        accountingAsset = accountingAsset_;
        router = IUniswapV3SwapRouter(router_);
    }

    function configurePool(address assetToken, uint24 poolFee) external onlyOwner {
        if (assetToken == address(0) || assetToken == accountingAsset || poolFee == 0) revert InvalidAddress();
        poolFees[assetToken] = poolFee;
        emit PoolConfigured(assetToken, poolFee);
    }

    function disablePool(address assetToken) external onlyOwner {
        delete poolFees[assetToken];
        emit PoolDisabled(assetToken);
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
        uint24 poolFee = poolFees[assetToken];
        if (poolFee == 0) revert PoolNotConfigured(assetToken);

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        amountOut = router.exactInputSingle(
            IUniswapV3SwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: poolFee,
                recipient: recipient,
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minimumAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(tokenIn).forceApprove(address(router), 0);
    }

    function _assetForPair(address tokenIn, address tokenOut) private view returns (address assetToken) {
        bool inputIsAccountingAsset = tokenIn == accountingAsset;
        bool outputIsAccountingAsset = tokenOut == accountingAsset;
        if (inputIsAccountingAsset == outputIsAccountingAsset) revert InvalidPair(tokenIn, tokenOut);
        assetToken = inputIsAccountingAsset ? tokenOut : tokenIn;
    }
}
