// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITradeAdapter} from "../interfaces/ITradeAdapter.sol";

/// @notice Security-test adapter that attempts to over-pull or fake output.
contract AdversarialTradeAdapter is ITradeAdapter {
    using SafeERC20 for IERC20;

    enum Attack {
        Overpull,
        FakeOutput,
        ReenterThenSwap
    }

    address public immutable override accountingAsset;
    Attack public attack;

    constructor(address accountingAsset_) {
        accountingAsset = accountingAsset_;
    }

    function setAttack(Attack attack_) external {
        attack = attack_;
    }

    function swapExactInput(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minimumAmountOut,
        address recipient,
        uint256
    ) external returns (uint256 amountOut) {
        if (attack == Attack.ReenterThenSwap) {
            (bool reentered,) = msg.sender.call(abi.encodeWithSignature("accruePerformanceFee()"));
            require(!reentered, "reentrancy succeeded");
        }

        uint256 amountToPull = attack == Attack.Overpull ? amountIn + 1 : amountIn;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountToPull);
        if (attack == Attack.ReenterThenSwap) IERC20(tokenOut).safeTransfer(recipient, minimumAmountOut);
        return minimumAmountOut;
    }
}
