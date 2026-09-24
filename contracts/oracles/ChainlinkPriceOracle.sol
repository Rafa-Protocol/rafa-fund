// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/// @title ChainlinkPriceOracle
/// @notice Converts an asset/USD feed and accounting-asset/USD feed into an
///         18-decimal asset/accounting-asset price.
/// @dev On L2s, pass the Chainlink sequencer uptime feed and a grace period.
///      On chains without a sequencer feed, pass address(0) and zero.
contract ChainlinkPriceOracle is IPriceOracle {
    uint8 private constant WAD_DECIMALS = 18;

    IAggregatorV3 public immutable assetUsdFeed;
    IAggregatorV3 public immutable accountingAssetUsdFeed;
    IAggregatorV3 public immutable sequencerUptimeFeed;
    uint256 public immutable sequencerGracePeriod;

    uint8 public immutable assetFeedDecimals;
    uint8 public immutable accountingAssetFeedDecimals;

    error InvalidAddress();
    error UnsupportedFeedDecimals(uint8 decimals);
    error InvalidOracleAnswer(address feed, int256 answer);
    error InvalidOracleTimestamp(address feed, uint256 updatedAt);
    error IncompleteOracleRound(address feed, uint80 roundId, uint80 answeredInRound);
    error SequencerDown();
    error SequencerGracePeriodActive(uint256 startedAt, uint256 gracePeriod);

    constructor(
        address assetUsdFeed_,
        address accountingAssetUsdFeed_,
        address sequencerUptimeFeed_,
        uint256 sequencerGracePeriod_
    ) {
        if (assetUsdFeed_ == address(0) || accountingAssetUsdFeed_ == address(0)) revert InvalidAddress();
        if (assetUsdFeed_.code.length == 0 || accountingAssetUsdFeed_.code.length == 0) revert InvalidAddress();
        if (sequencerUptimeFeed_ != address(0) && sequencerUptimeFeed_.code.length == 0) revert InvalidAddress();

        assetUsdFeed = IAggregatorV3(assetUsdFeed_);
        accountingAssetUsdFeed = IAggregatorV3(accountingAssetUsdFeed_);
        sequencerUptimeFeed = IAggregatorV3(sequencerUptimeFeed_);
        sequencerGracePeriod = sequencerGracePeriod_;

        uint8 assetDecimals = IAggregatorV3(assetUsdFeed_).decimals();
        uint8 accountingDecimals = IAggregatorV3(accountingAssetUsdFeed_).decimals();
        if (assetDecimals > WAD_DECIMALS) revert UnsupportedFeedDecimals(assetDecimals);
        if (accountingDecimals > WAD_DECIMALS) revert UnsupportedFeedDecimals(accountingDecimals);

        assetFeedDecimals = assetDecimals;
        accountingAssetFeedDecimals = accountingDecimals;
    }

    function latestPrice() external view returns (uint256 priceWad, uint256 updatedAt) {
        _checkSequencer();

        (uint256 assetUsdWad, uint256 assetUpdatedAt) = _readFeed(assetUsdFeed, assetFeedDecimals);
        (uint256 accountingUsdWad, uint256 accountingUpdatedAt) =
            _readFeed(accountingAssetUsdFeed, accountingAssetFeedDecimals);

        priceWad = Math.mulDiv(assetUsdWad, 1e18, accountingUsdWad);
        updatedAt = Math.min(assetUpdatedAt, accountingUpdatedAt);
    }

    function _checkSequencer() private view {
        if (address(sequencerUptimeFeed) == address(0)) return;

        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (startedAt == 0 || block.timestamp <= startedAt + sequencerGracePeriod) {
            revert SequencerGracePeriodActive(startedAt, sequencerGracePeriod);
        }
    }

    function _readFeed(IAggregatorV3 feed, uint8 feedDecimals)
        private
        view
        returns (uint256 answerWad, uint256 updatedAt)
    {
        (uint80 roundId, int256 answer,, uint256 feedUpdatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0 || feedUpdatedAt == 0) revert InvalidOracleAnswer(address(feed), answer);
        if (feedUpdatedAt > block.timestamp) revert InvalidOracleTimestamp(address(feed), feedUpdatedAt);
        if (answeredInRound < roundId) {
            revert IncompleteOracleRound(address(feed), roundId, answeredInRound);
        }

        answerWad = uint256(answer) * (10 ** (WAD_DECIMALS - feedDecimals));
        updatedAt = feedUpdatedAt;
    }
}
