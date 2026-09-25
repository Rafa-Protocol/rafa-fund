import { network } from "hardhat";

const BASE_SEPOLIA_CHAIN_ID = 84_532n;
const WAD = 10n ** 18n;
const USDC = 10n ** 6n;

const { ethers } = await network.create();
const chain = await ethers.provider.getNetwork();
if (chain.chainId !== BASE_SEPOLIA_CHAIN_ID) {
  throw new Error(`Refusing to deploy test fixtures to chain ${chain.chainId}; expected Base Sepolia (84532).`);
}

const [deployer] = await ethers.getSigners();
const deployerAddress = await deployer.getAddress();
const deployerBalance = await ethers.provider.getBalance(deployerAddress);
const deploymentBlock = await ethers.provider.getBlockNumber();
if (deployerBalance === 0n) {
  throw new Error(`Testnet deployer ${deployerAddress} has no Base Sepolia ETH.`);
}

async function deploy(name: string, args: unknown[] = []) {
  const contract = await ethers.deployContract(name, args);
  await contract.waitForDeployment();
  const deploymentTransaction = contract.deploymentTransaction();
  if (deploymentTransaction) await deploymentTransaction.wait(2);

  const address = await contract.getAddress();
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if ((await ethers.provider.getCode(address)) !== "0x") break;
    if (attempt === 19) throw new Error(`Deployment bytecode for ${name} was not visible at ${address}.`);
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }

  console.log(`${name}: ${address}`);
  return contract;
}

async function confirm(transaction: Promise<{ wait(confirmations?: number): Promise<unknown> }>) {
  await (await transaction).wait(2);
}

function fundParams(
  name: string,
  symbol: string,
  accountingAsset: string,
  assetRegistry: string,
) {
  return {
    name,
    symbol,
    metadataURI: "https://rafa.ai/docs",
    accountingAsset,
    assetRegistry,
    admin: deployerAddress,
    trader: deployerAddress,
    guardian: deployerAddress,
    feeRecipient: deployerAddress,
    performanceFeeBps: 0,
    maxTradeSlippageBps: 500,
    maxTradeValueBps: 5_000,
    adminTransferDelay: 0,
    depositCap: 1_000_000n * USDC,
  };
}

console.log(`Deploying from ${deployerAddress} with ${ethers.formatEther(deployerBalance)} Base Sepolia ETH`);

const testUsdc = await deploy("MockERC20", ["RAFA Test USD", "tUSDC", 6]);
const testWeth = await deploy("MockERC20", ["RAFA Test Wrapped Ether", "tWETH", 18]);
const router = await deploy("MockAerodromeRouter");
const adapter = await deploy("AerodromeAdapter", [
  deployerAddress,
  await testUsdc.getAddress(),
  await router.getAddress(),
]);
const assetRegistry = await deploy("RafaAssetRegistry", [deployerAddress, await testUsdc.getAddress()]);
const testWethOracle = await deploy("TestnetPriceOracle", [2_000n * WAD]);

await confirm(adapter.configureRoute(await testWeth.getAddress(), false, ethers.ZeroAddress));
await confirm(
  assetRegistry.configureAsset(
    await testWeth.getAddress(),
    18,
    await testWethOracle.getAddress(),
    7 * 24 * 60 * 60,
    7 * 24 * 60 * 60,
    7_000,
    await adapter.getAddress(),
    ethers.encodeBytes32String("TEST_CRYPTO"),
    ethers.encodeBytes32String("RAFA_TEST"),
  ),
);

const cashFund = await deploy("RafaFundV2", [
  fundParams("RAFA Testnet Cash", "rCASH", await testUsdc.getAddress(), await assetRegistry.getAddress()),
]);
const balancedFund = await deploy("RafaFundV2", [
  fundParams("RAFA Testnet Balanced", "rBAL", await testUsdc.getAddress(), await assetRegistry.getAddress()),
]);
const conservativeFund = await deploy("RafaFundV2", [
  fundParams("RAFA Testnet Conservative", "rSAFE", await testUsdc.getAddress(), await assetRegistry.getAddress()),
]);
const growthFund = await deploy("RafaFundV2", [
  fundParams("RAFA Testnet Growth", "rGROW", await testUsdc.getAddress(), await assetRegistry.getAddress()),
]);
await confirm(balancedFund.addAsset(await testWeth.getAddress(), 7_000));
await confirm(conservativeFund.addAsset(await testWeth.getAddress(), 3_000));
await confirm(growthFund.addAsset(await testWeth.getAddress(), 7_000));

const factory = await deploy("FundFactoryV2", [
  deployerAddress,
  await testUsdc.getAddress(),
  await assetRegistry.getAddress(),
  2_000,
]);
await confirm(factory.registerFund(await cashFund.getAddress()));
await confirm(factory.registerFund(await conservativeFund.getAddress()));
await confirm(factory.registerFund(await balancedFund.getAddress()));
await confirm(factory.registerFund(await growthFund.getAddress()));

await confirm(testUsdc.mint(deployerAddress, 20_000n * USDC));
await confirm(testUsdc.mint(await router.getAddress(), 2_000_000n * USDC));
await confirm(testWeth.mint(await router.getAddress(), 1_000n * WAD));
await confirm(
  router.setRate(
    await testUsdc.getAddress(),
    await testWeth.getAddress(),
    false,
    WAD,
    2_000n * USDC,
  ),
);
await confirm(
  router.setRate(
    await testWeth.getAddress(),
    await testUsdc.getAddress(),
    false,
    2_000n * USDC,
    WAD,
  ),
);

await confirm(testUsdc.approve(await cashFund.getAddress(), 1_000n * USDC));
await confirm(cashFund.depositWithSlippage(1_000n * USDC, deployerAddress, 1_000n * WAD));
await confirm(cashFund.redeemWithSlippage(100n * WAD, deployerAddress, deployerAddress, 99n * USDC));

await confirm(testUsdc.approve(await balancedFund.getAddress(), 2_000n * USDC));
await confirm(balancedFund.depositWithSlippage(2_000n * USDC, deployerAddress, 2_000n * WAD));
await confirm(testUsdc.approve(await conservativeFund.getAddress(), 2_500n * USDC));
await confirm(conservativeFund.depositWithSlippage(2_500n * USDC, deployerAddress, 2_500n * WAD));
await confirm(testUsdc.approve(await growthFund.getAddress(), 3_000n * USDC));
await confirm(growthFund.depositWithSlippage(3_000n * USDC, deployerAddress, 3_000n * WAD));
const latestBlock = await ethers.provider.getBlock("latest");
if (!latestBlock) throw new Error("Unable to read the Base Sepolia head block.");
await confirm(
  balancedFund.trade(
    await testUsdc.getAddress(),
    await testWeth.getAddress(),
    400n * USDC,
    19n * WAD / 100n,
    latestBlock.timestamp + 600,
  ),
);
await confirm(
  conservativeFund.trade(
    await testUsdc.getAddress(),
    await testWeth.getAddress(),
    250n * USDC,
    12n * WAD / 100n,
    latestBlock.timestamp + 600,
  ),
);
await confirm(
  growthFund.trade(
    await testUsdc.getAddress(),
    await testWeth.getAddress(),
    1_500n * USDC,
    72n * WAD / 100n,
    latestBlock.timestamp + 600,
  ),
);
await confirm(
  growthFund.trade(
    await testUsdc.getAddress(),
    await testWeth.getAddress(),
    300n * USDC,
    145n * WAD / 1_000n,
    latestBlock.timestamp + 600,
  ),
);

const deployment = {
  schemaVersion: 1,
  network: "Base Sepolia",
  chainId: Number(BASE_SEPOLIA_CHAIN_ID),
  explorerUrl: "https://sepolia.basescan.org",
  deploymentBlock,
  deployedAt: new Date().toISOString(),
  deployer: deployerAddress,
  contracts: {
    testUsdc: await testUsdc.getAddress(),
    testWeth: await testWeth.getAddress(),
    mockRouter: await router.getAddress(),
    aerodromeAdapter: await adapter.getAddress(),
    assetRegistry: await assetRegistry.getAddress(),
    testWethOracle: await testWethOracle.getAddress(),
    cashFund: await cashFund.getAddress(),
    conservativeFund: await conservativeFund.getAddress(),
    balancedFund: await balancedFund.getAddress(),
    growthFund: await growthFund.getAddress(),
    fundFactory: await factory.getAddress(),
  },
  checks: {
    factoryFunds: Number(await factory.fundsLength()),
    cashFundTotalAssets: (await cashFund.totalAssets()).toString(),
    conservativeFundTotalAssets: (await conservativeFund.totalAssets()).toString(),
    conservativeFundTestWethBalance: (await testWeth.balanceOf(await conservativeFund.getAddress())).toString(),
    balancedFundTotalAssets: (await balancedFund.totalAssets()).toString(),
    balancedFundTestWethBalance: (await testWeth.balanceOf(await balancedFund.getAddress())).toString(),
    growthFundTotalAssets: (await growthFund.totalAssets()).toString(),
    growthFundTestWethBalance: (await testWeth.balanceOf(await growthFund.getAddress())).toString(),
  },
  warning: "Testnet-only deployment using unrestricted mock tokens, a mock router, and a fixed-price oracle.",
};

console.log(`RAFA_DEPLOYMENT_JSON=${JSON.stringify(deployment)}`);
