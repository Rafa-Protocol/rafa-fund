// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    // @notice Swaps `amountIn` of one token for as many possible of another token
    // @param amountIn The amount of tokens to send
    // @param amountOutMin The minimum amount of tokens to receive (slippage protection)
    // @param routes The array of structs defining the hop-by-hop path
    // @param to The recipient of the output tokens
    // @param deadline Unix timestamp after which the transaction will revert
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    // @notice Calculates the expected output amount for a given input
    // @param amountIn The amount of input tokens
    // @param routes The trading path
    function getAmountsOut(uint256 amountIn, Route[] memory routes) external view returns (uint256[] memory amounts);

    // @notice Returns the address of the default factory used for route creation
    function defaultFactory() external view returns (address);
}
