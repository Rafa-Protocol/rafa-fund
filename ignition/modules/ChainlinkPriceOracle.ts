import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("ChainlinkPriceOracleModule", (m) => {
  const assetUsdFeed = m.getParameter("assetUsdFeed");
  const accountingAssetUsdFeed = m.getParameter("accountingAssetUsdFeed");
  const sequencerUptimeFeed = m.getParameter("sequencerUptimeFeed");
  const sequencerGracePeriod = m.getParameter("sequencerGracePeriod", 3_600n);

  const oracle = m.contract("ChainlinkPriceOracle", [
    assetUsdFeed,
    accountingAssetUsdFeed,
    sequencerUptimeFeed,
    sequencerGracePeriod,
  ]);

  return { oracle };
});
