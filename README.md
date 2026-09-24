# RAFA Fund Protocol

RAFA Fund Protocol V2 is a non-custodial, tokenized fund system designed for Base. Investors deposit a single accounting asset such as USDC and receive ERC-20 fund shares. RAFA-operated trading accounts can rebalance each vault only through supported assets and guarded Aerodrome routes.

V2 is implemented alongside the original `BaseETF` and `FundFactory` prototypes. New deployments should use `RafaFundV2`, `FundFactoryV2`, and `ChainlinkPriceOracle`.

> **Audit status:** V2 has automated tests but has not received an independent security audit. Do not accept production deposits before an audit, Base fork testing, verified deployment parameters, and multisig handoff are complete.

## V2 contracts

- `RafaFundV2`: ERC-4626-compatible vault, fund-share token, NAV calculation, risk controls, performance-fee accounting, guarded trading, and in-kind exits.
- `FundFactoryV2`: owner-controlled registry of official RAFA funds. Vaults are deployed directly and registered after their accounting asset, router, and fee limits are verified.
- `ChainlinkPriceOracle`: Chainlink feed adapter with L2 sequencer checks and 18-decimal asset/accounting-asset prices.

## Security properties

- Only the RAFA registry owner can mark a vault as an official fund.
- The vault admin, trader, guardian, and fee recipient are separate roles.
- The trader can only swap between the accounting asset and an allowlisted asset; funds always return to the vault.
- Oracle staleness, maximum trade size, maximum asset exposure, and minimum DEX output are enforced on-chain.
- Deposit caps and independent deposit/trading pauses limit incident impact.
- Standard redemptions use idle accounting-asset liquidity. In-kind redemption remains available if a DEX or oracle is unavailable.
- Performance fees are minted as shares only above the fund's high-water mark.
- Contracts are immutable and do not use proxies.

See [ARCHITECTURE.md](./ARCHITECTURE.md) and [SECURITY.md](./SECURITY.md) for the complete model and operating assumptions.

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

## Deployment

Hardhat Ignition modules live in `ignition/modules`. Copy `ignition/parameters/example.json`, replace every placeholder, and review the resulting file with a second operator.

```bash
npx hardhat ignition deploy --network baseSepolia \
  --parameters ignition/parameters/base-sepolia.json \
  ignition/modules/FundFactoryV2.ts

npx hardhat ignition deploy --network baseSepolia \
  --parameters ignition/parameters/base-sepolia.json \
  ignition/modules/RafaFundV2.ts
```

Deploy one `ChainlinkPriceOracle` per supported asset/accounting-asset feed pair, then add it to the fund from the admin multisig. Mainnet addresses and transaction hashes must be recorded under `deployments/` and verified on BaseScan before the web application consumes them.

The fund module does not register the vault automatically because the registry owner should be the RAFA Safe, not the hot deployment account. After reviewing the deployed bytecode and constructor arguments, submit `registerFund(fundAddress)` from the Safe.

## Legacy contracts

`BaseETF.sol` and `FundFactory.sol` are retained only to preserve the original prototype history. They are not production deployment targets.
