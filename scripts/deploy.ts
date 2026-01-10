import { ethers } from "hardhat";

async function main() {
  // Base Mainnet Addresses
  const USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
  const AERODROME_ROUTER = "0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43";

  console.log("Deploying FundFactory...");

  const FundFactory = await ethers.getContractFactory("FundFactory");
  const factory = await FundFactory.deploy(USDC_ADDRESS, AERODROME_ROUTER);

  await factory.deployed();

  console.log(`FundFactory deployed to: ${factory.address}`);
  console.log("------------------------------------------------");
  console.log("Run this next to verify:");
  console.log(`npx hardhat verify --network base ${factory.address} ${USDC_ADDRESS} ${AERODROME_ROUTER}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});