// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAerodromeRouter} from "../interfaces/IAerodromeRouter.sol";

contract MockAerodromeRouter is IAerodromeRouter {
    using SafeERC20 for IERC20;

    struct Rate {
        uint256 numerator;
        uint256 denominator;
    }

    address public immutable override defaultFactory;
    mapping(bytes32 routeKey => Rate rate) public rates;

    error InvalidRate();
    error InvalidRoute();
    error DeadlineExpired();
    error InsufficientOutput(uint256 actualAmountOut, uint256 minimumAmountOut);

    constructor() {
        defaultFactory = address(0xFACADE);
    }

    function setRate(address from, address to, bool stable, uint256 numerator, uint256 denominator) external {
        if (numerator == 0 || denominator == 0) revert InvalidRate();
        rates[_routeKey(from, to, stable)] = Rate(numerator, denominator);
    }

    function getAmountsOut(uint256 amountIn, Route[] memory routes) public view returns (uint256[] memory amounts) {
        if (routes.length == 0) revert InvalidRoute();
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;

        for (uint256 i; i < routes.length; ++i) {
            Rate memory rate = rates[_routeKey(routes[i].from, routes[i].to, routes[i].stable)];
            if (rate.denominator == 0) revert InvalidRoute();
            amounts[i + 1] = Math.mulDiv(amounts[i], rate.numerator, rate.denominator);
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (routes.length == 0) revert InvalidRoute();

        Route[] memory routeCopy = routes;
        amounts = getAmountsOut(amountIn, routeCopy);
        uint256 amountOut = amounts[amounts.length - 1];
        if (amountOut < amountOutMin) revert InsufficientOutput(amountOut, amountOutMin);

        IERC20(routes[0].from).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(routes[routes.length - 1].to).safeTransfer(to, amountOut);
    }

    function _routeKey(address from, address to, bool stable) private pure returns (bytes32) {
        return keccak256(abi.encode(from, to, stable));
    }
}
