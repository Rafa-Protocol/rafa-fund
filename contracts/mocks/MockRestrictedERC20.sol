// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test token that models paused and address-restricted RWA transfers.
contract MockRestrictedERC20 is ERC20 {
    mapping(address account => bool blocked) public blocked;
    bool public transfersPaused;

    error TransfersPaused();
    error RestrictedAddress(address account);

    constructor() ERC20("Restricted RWA", "rRWA") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function setTransfersPaused(bool paused) external {
        transfersPaused = paused;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (transfersPaused) revert TransfersPaused();
            if (blocked[from]) revert RestrictedAddress(from);
            if (blocked[to]) revert RestrictedAddress(to);
        }
        super._update(from, to, value);
    }
}
