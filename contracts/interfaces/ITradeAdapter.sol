// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Executes an exact-input swap for a RAFA fund.
/// @dev The caller approves exactly `amountIn`. An adapter must pull no more
///      than that amount and deliver the output directly to `recipient`.
interface ITradeAdapter {
    function accountingAsset() external view returns (address);

    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minimumAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);
}
