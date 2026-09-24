// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RafaFundV2} from "./RafaFundV2.sol";

/// @title FundFactoryV2
/// @notice RAFA-controlled registry for official funds.
/// @dev Vaults are deployed directly and then registered. Keeping deployment
///      bytecode out of the registry keeps this contract below EVM code-size
///      limits without introducing upgradeable proxies.
contract FundFactoryV2 is Ownable2Step {
    bytes32 public constant EXPECTED_FUND_IMPLEMENTATION_ID = keccak256("RAFA_FUND_V2");
    uint16 public constant ABSOLUTE_MAX_PERFORMANCE_FEE_BPS = 3_000;

    uint16 public immutable maximumPerformanceFeeBps;
    address public immutable accountingAsset;
    address public immutable router;

    address[] private _funds;
    mapping(address fund => bool registered) public isFund;
    mapping(address fund => bool active) public isActiveFund;

    error InvalidAddress();
    error InvalidMaximumPerformanceFee(uint256 feeBps);
    error PerformanceFeeAboveMaximum(uint256 requestedFeeBps, uint256 maximumFeeBps);
    error UnknownFund(address fund);
    error FundAlreadyRegistered(address fund);
    error InvalidFundConfiguration(address fund);

    event FundCreated(
        uint256 indexed fundId,
        address indexed fund,
        address indexed admin,
        string name,
        string symbol,
        string metadataURI
    );
    event FundStatusUpdated(address indexed fund, bool active);

    constructor(address initialOwner, address accountingAsset_, address router_, uint16 maximumPerformanceFeeBps_)
        Ownable(initialOwner)
    {
        if (initialOwner == address(0) || accountingAsset_ == address(0) || router_ == address(0)) {
            revert InvalidAddress();
        }
        if (accountingAsset_.code.length == 0 || router_.code.length == 0) revert InvalidAddress();
        if (maximumPerformanceFeeBps_ > ABSOLUTE_MAX_PERFORMANCE_FEE_BPS) {
            revert InvalidMaximumPerformanceFee(maximumPerformanceFeeBps_);
        }

        accountingAsset = accountingAsset_;
        router = router_;
        maximumPerformanceFeeBps = maximumPerformanceFeeBps_;
    }

    function registerFund(address fund) external onlyOwner {
        if (fund == address(0) || fund.code.length == 0) revert InvalidAddress();
        if (isFund[fund]) revert FundAlreadyRegistered(fund);

        RafaFundV2 candidate = RafaFundV2(fund);
        if (
            candidate.IMPLEMENTATION_ID() != EXPECTED_FUND_IMPLEMENTATION_ID || candidate.asset() != accountingAsset
                || address(candidate.router()) != router
        ) {
            revert InvalidFundConfiguration(fund);
        }

        uint256 fundPerformanceFeeBps = candidate.performanceFeeBps();
        if (fundPerformanceFeeBps > maximumPerformanceFeeBps) {
            revert PerformanceFeeAboveMaximum(fundPerformanceFeeBps, maximumPerformanceFeeBps);
        }

        uint256 fundId = _funds.length;
        _funds.push(fund);
        isFund[fund] = true;
        isActiveFund[fund] = true;

        emit FundCreated(
            fundId, fund, candidate.defaultAdmin(), candidate.name(), candidate.symbol(), candidate.metadataURI()
        );
    }

    function setFundActive(address fund, bool active) external onlyOwner {
        if (!isFund[fund]) revert UnknownFund(fund);
        isActiveFund[fund] = active;
        emit FundStatusUpdated(fund, active);
    }

    function fundsLength() external view returns (uint256) {
        return _funds.length;
    }

    function fundAt(uint256 index) external view returns (address) {
        return _funds[index];
    }

    function getFunds(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 length = _funds.length;
        if (offset >= length || limit == 0) return new address[](0);

        uint256 pageLength = Math.min(limit, length - offset);
        page = new address[](pageLength);
        for (uint256 i = offset; i < offset + pageLength; ++i) {
            page[i - offset] = _funds[i];
        }
    }
}
