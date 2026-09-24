# RAFA Fund Protocol

RAFA Fund Protocol V2 is a non-custodial, tokenized fund system for Base and
Ethereum. Investors deposit one accounting asset, such as USDC, and receive
ERC-20 fund shares. RAFA-operated traders can rebalance a fund only through
assets, price oracles, risk limits, and execution adapters approved by the
chain-local protocol registry.

V2 lives alongside the original `BaseETF` and `FundFactory` prototypes. New
deployments use `RafaFundV2`, `RafaAssetRegistry`, `FundFactoryV2`, and one
reviewed trade adapter per venue.

> **Audit status:** V2 has automated tests but has not received an independent
> security audit. Do not accept production deposits before the gates in
> [SECURITY.md](./SECURITY.md) are complete.

## V2 contracts

- `RafaFundV2`: ERC-4626-compatible vault, NAV calculation, performance fees,
  guarded trading, fund-level exposure limits, and oracle-independent in-kind exits.
- `RafaAssetRegistry`: RAFA Safe-controlled protocol allowlist. Each asset has
  independent admission, buy, and sell switches plus a chain-specific oracle,
  adapter, price-age limits, protocol exposure cap, asset class, and issuer ID.
- `FundFactoryV2`: RAFA's registry of official funds. It accepts only funds that
  use the expected accounting asset and protocol asset registry.
- `AerodromeAdapter`: approved direct accounting-asset routes for Base.
- `UniswapV3Adapter`: approved direct accounting-asset pools for Ethereum.
- `ChainlinkPriceOracle`: asset/accounting-asset pricing with optional L2
  sequencer checks.

## Key controls

- Only the RAFA registry Safe can make an asset eligible protocol-wide.
- Each fund admin chooses a subset and may set a stricter exposure limit.
- The protocol can stop new admissions and buys while leaving sells enabled for
  an orderly unwind.
- Managers can swap only between the accounting asset and an approved holding;
  output always returns to the vault.
- Deposits, cash exits, fees, and trades use a strict price-freshness window.
  Read-only NAV can use a longer window, while in-kind exits need no oracle.
- Base B20 native tokens are supported even when `code.length` is zero. They
  still require reviewed ERC-20 behavior, an official total-return-aware feed,
  legal eligibility, and executable liquidity before approval.
- Discovery data under [assets](./assets/README.md) never grants on-chain approval.
- Contracts are immutable and do not use proxies.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the complete model.

## Development

Use Node.js 22.

```bash
npm install
npm run check
```

Useful commands:

```bash
npm run compile
npm test
npm run build
npm run check:size
npm run typecheck
```

### Base Sepolia rehearsal

The testnet deployment script creates unrestricted mock `tUSDC` and `tWETH`,
a fixed-price test oracle, four sample funds, and an official-fund registry. It
also seeds deposits, one redemption, and one managed-asset trade so the web
application has real onchain state to display.

```bash
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org \
DEPLOYER_PRIVATE_KEY=<funded-test-key> \
npm run deploy:base-sepolia
```

The script refuses to run anywhere except chain ID `84532`. Its contracts and
tokens are test fixtures only and must never be reused for a mainnet launch.

## Deployment sequence

Use separate Base and Ethereum deployments. The same Safe may own both, but
each chain has its own registry, adapters, oracles, factory, and funds.

1. Deploy the trade adapter and `RafaAssetRegistry` for the chain.
2. Configure only reviewed routes or pools on the adapter.
3. Deploy and verify one price-oracle adapter per candidate asset.
4. Have the RAFA Safe configure asset policies in `RafaAssetRegistry`.
5. Deploy `RafaFundV2` with that registry and add a permitted subset of assets.
6. Deploy `FundFactoryV2`, verify all bytecode and parameters, then register the fund from the Safe.
7. Record verified addresses and transaction hashes under `deployments/` before the web application consumes them.

Hardhat Ignition modules are in `ignition/modules`; copy
`ignition/parameters/example.json` and replace every placeholder. Mainnet
deployment remains blocked until the independent audit and testnet rehearsals
in [SECURITY.md](./SECURITY.md) are complete.

## Legacy contracts

`BaseETF.sol` and `FundFactory.sol` are retained only to preserve prototype
history. They are not production deployment targets.
