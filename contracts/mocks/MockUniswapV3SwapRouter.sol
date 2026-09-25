// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3SwapRouter} from "../interfaces/IUniswapV3SwapRouter.sol";

contract MockUniswapV3SwapRouter is IUniswapV3SwapRouter {
    using SafeERC20 for IERC20;

    struct Rate {
        uint256 numerator;
        uint256 denominator;
    }

    mapping(bytes32 poolKey => Rate rate) public rates;

    error InvalidRate();
    error InvalidPool();
    error DeadlineExpired();
    error InsufficientOutput(uint256 actualAmountOut, uint256 minimumAmountOut);

    function setRate(address tokenIn, address tokenOut, uint24 fee, uint256 numerator, uint256 denominator) external {
        if (fee == 0 || numerator == 0 || denominator == 0) revert InvalidRate();
        rates[_poolKey(tokenIn, tokenOut, fee)] = Rate(numerator, denominator);
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        if (params.deadline < block.timestamp) revert DeadlineExpired();
        Rate memory rate = rates[_poolKey(params.tokenIn, params.tokenOut, params.fee)];
        if (rate.denominator == 0) revert InvalidPool();

        amountOut = Math.mulDiv(params.amountIn, rate.numerator, rate.denominator);
        if (amountOut < params.amountOutMinimum) {
            revert InsufficientOutput(amountOut, params.amountOutMinimum);
        }

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);
    }

    function _poolKey(address tokenIn, address tokenOut, uint24 fee) private pure returns (bytes32) {
        return keccak256(abi.encode(tokenIn, tokenOut, fee));
    }
}
