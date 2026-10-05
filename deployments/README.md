# Verified deployments

- `base-sepolia.json` — historical public testnet rehearsal at commit
  `00cff8a`, using unrestricted mocks and a fixed-price oracle. It predates the
  October 2026 audit remediations and must not be treated as the current
  implementation or reused for production. A new rehearsal record will be
  added after the independent re-review.

For every deployment, add a chain-specific JSON file containing:

- chain ID and network name;
- Git commit SHA;
- deployer and transaction hash;
- contract address and constructor arguments;
- block-explorer verification URL;
- Safe owner/admin addresses;
- accounting asset, asset registry, and execution adapters;
- every approved asset policy, route/pool, price adapter, and underlying feed;
- fund risk parameters; and
- independent audit commit or report hash; and
- asset eligibility and operational review references.

The investor web application must consume only addresses listed here and registered by `FundFactoryV2`.
