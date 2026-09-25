import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("RafaAssetRegistryModule", (m) => {
  const registryOwner = m.getParameter("registryOwner");
  const accountingAsset = m.getParameter("accountingAsset");

  const assetRegistry = m.contract("RafaAssetRegistry", [registryOwner, accountingAsset]);

  return { assetRegistry };
});
