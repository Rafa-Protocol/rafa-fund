import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("RafaFundV2Module", (m) => {
  const fundName = m.getParameter("fundName");
  const fundSymbol = m.getParameter("fundSymbol");
  const metadataURI = m.getParameter("metadataURI");
  const accountingAsset = m.getParameter("accountingAsset");
  const assetRegistry = m.getParameter("assetRegistry");
  const admin = m.getParameter("admin");
  const trader = m.getParameter("trader");
  const guardian = m.getParameter("guardian");
  const feeRecipient = m.getParameter("feeRecipient");
  const performanceFeeBps = m.getParameter("performanceFeeBps", 2_000n);
  const maxTradeSlippageBps = m.getParameter("maxTradeSlippageBps", 300n);
  const maxTradeValueBps = m.getParameter("maxTradeValueBps", 2_500n);
  const adminTransferDelay = m.getParameter("adminTransferDelay", 86_400n);
  const depositCap = m.getParameter("depositCap");

  const fund = m.contract("RafaFundV2", [
    {
      name: fundName,
      symbol: fundSymbol,
      metadataURI,
      accountingAsset,
      assetRegistry,
      admin,
      trader,
      guardian,
      feeRecipient,
      performanceFeeBps,
      maxTradeSlippageBps,
      maxTradeValueBps,
      adminTransferDelay,
      depositCap,
    },
  ]);

  return { fund };
});
