import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("FundFactoryV2Module", (m) => {
  const factoryOwner = m.getParameter("factoryOwner");
  const accountingAsset = m.getParameter("accountingAsset");
  const router = m.getParameter("router");
  const maximumPerformanceFeeBps = m.getParameter("maximumPerformanceFeeBps", 2_000n);

  const registry = m.contract("FundFactoryV2", [
    factoryOwner,
    accountingAsset,
    router,
    maximumPerformanceFeeBps,
  ]);

  return { registry };
});
