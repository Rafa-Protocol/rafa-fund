import { readFile } from "node:fs/promises";

const limits = {
  runtime: 24_576,
  init: 49_152,
};

const artifacts = [
  "artifacts/contracts/RafaFundV2.sol/RafaFundV2.json",
  "artifacts/contracts/FundFactoryV2.sol/FundFactoryV2.json",
  "artifacts/contracts/RafaAssetRegistry.sol/RafaAssetRegistry.json",
  "artifacts/contracts/adapters/AerodromeAdapter.sol/AerodromeAdapter.json",
  "artifacts/contracts/adapters/UniswapV3Adapter.sol/UniswapV3Adapter.json",
  "artifacts/contracts/oracles/ChainlinkPriceOracle.sol/ChainlinkPriceOracle.json",
];

let failed = false;

for (const artifactPath of artifacts) {
  const artifact = JSON.parse(await readFile(artifactPath, "utf8"));
  const runtimeBytes = (artifact.deployedBytecode.length - 2) / 2;
  const initBytes = (artifact.bytecode.length - 2) / 2;

  console.log(`${artifact.contractName}: runtime=${runtimeBytes} bytes, init=${initBytes} bytes`);

  if (runtimeBytes > limits.runtime || initBytes > limits.init) {
    failed = true;
    console.error(`${artifact.contractName} exceeds an EVM deployment-size limit.`);
  }
}

if (failed) process.exitCode = 1;
