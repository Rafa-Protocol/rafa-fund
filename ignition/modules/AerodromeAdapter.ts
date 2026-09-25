import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("AerodromeAdapterModule", (m) => {
  const adapterOwner = m.getParameter("adapterOwner");
  const accountingAsset = m.getParameter("accountingAsset");
  const aerodromeRouter = m.getParameter("aerodromeRouter");

  const adapter = m.contract("AerodromeAdapter", [adapterOwner, accountingAsset, aerodromeRouter]);

  return { adapter };
});
