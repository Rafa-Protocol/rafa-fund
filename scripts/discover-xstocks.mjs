import { writeFile } from "node:fs/promises";

const API = "https://api.xstocks.fi/api/v2/public/assets";
const network = argument("network") ?? "Ethereum";
const output = argument("output");

const assets = [];
let page = 0;
let hasNextPage = true;

while (hasNextPage) {
  const response = await fetch(`${API}?page=${page}`);
  if (!response.ok) throw new Error(`xStocks API returned HTTP ${response.status} for page ${page}`);

  const body = await response.json();
  for (const asset of body.nodes ?? []) {
    for (const deployment of asset.deployments ?? []) {
      if (deployment.network !== network) continue;
      assets.push({
        name: asset.name,
        symbol: asset.symbol,
        underlyingSymbol: asset.underlyingSymbol,
        isin: asset.isin,
        isTradingHalted: asset.isTradingHalted,
        token: deployment.address,
        wrapper: deployment.wrapperAddressV2 ?? null,
        supportsAtomicSwaps: deployment.supportsAtomicSwaps,
      });
    }
  }

  hasNextPage = Boolean(body.page?.hasNextPage);
  page += 1;
}

assets.sort((left, right) => left.symbol.localeCompare(right.symbol));
const catalog = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  source: API,
  network,
  status: "discovery-only",
  count: assets.length,
  assets,
};
const encoded = `${JSON.stringify(catalog, null, 2)}\n`;

if (output) {
  await writeFile(output, encoded);
  console.error(`Wrote ${assets.length} ${network} deployments to ${output}`);
} else {
  process.stdout.write(encoded);
}

function argument(name) {
  const prefix = `--${name}=`;
  return process.argv.find((value) => value.startsWith(prefix))?.slice(prefix.length);
}

