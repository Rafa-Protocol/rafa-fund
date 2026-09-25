import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("FundFactoryV2Module", (m) => {
  const factoryOwner = m.getParameter("factoryOwner");
  const accountingAsset = m.getParameter("accountingAsset");
  const assetRegistry = m.getParameter("assetRegistry");
  const maximumPerformanceFeeBps = m.getParameter("maximumPerformanceFeeBps", 2_000n);

  const factory = m.contract("FundFactoryV2", [
    factoryOwner,
    accountingAsset,
    assetRegistry,
    maximumPerformanceFeeBps,
  ]);

  return { factory };
});
