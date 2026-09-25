import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("UniswapV3AdapterModule", (m) => {
  const adapterOwner = m.getParameter("adapterOwner");
  const accountingAsset = m.getParameter("accountingAsset");
  const uniswapV3Router = m.getParameter("uniswapV3Router");

  const adapter = m.contract("UniswapV3Adapter", [adapterOwner, accountingAsset, uniswapV3Router]);

  return { adapter };
});
