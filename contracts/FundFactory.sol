// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./BaseETF.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract FundFactory is Ownable {
    event FundCreated(address indexed fundAddress, address indexed manager, string name, string symbol);

    address public immutable USDC;
    address public immutable AERODROME_ROUTER;
    
    address[] public allFunds;
    mapping(address => bool) public isFund;

    constructor(address _usdc, address _router) Ownable() {
        USDC = _usdc;
        AERODROME_ROUTER = _router;
    }

    function createFund(string memory _name, string memory _symbol, address _manager) external returns (address) {
        BaseETF newFund = new BaseETF(_name, _symbol, USDC, AERODROME_ROUTER);

        // Grant Manager Role to the specified user
        newFund.grantRole(newFund.DEFAULT_ADMIN_ROLE(), msg.sender);
        newFund.grantRole(newFund.MANAGER_ROLE(), _manager);
        
        // Optional: Revoke Factory's rights if desired, keeping only for now for easy management
        // newFund.renounceRole(newFund.MANAGER_ROLE(), address(this));

        address fundAddr = address(newFund);
        allFunds.push(fundAddr);
        isFund[fundAddr] = true;

        emit FundCreated(fundAddr, _manager, _name, _symbol);
        return fundAddr;
    }

    function getFundsCount() external view returns (uint256) {
        return allFunds.length;
    }
}