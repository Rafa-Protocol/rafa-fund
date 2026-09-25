# RWA asset discovery

Files in this directory are research inputs, not the live protocol allowlist. An
asset becomes usable only after the RAFA Safe configures it in that chain's
`RafaAssetRegistry` with a reviewed oracle, adapter, price-age limits, and
exposure cap.

## Admission checklist

Before setting `admissionEnabled` or `buyEnabled`, operators must verify:

1. the issuer's official token address and current holder eligibility rules;
2. whether the vault and its investors can legally hold and receive the token;
3. transfer restrictions, blocklists, redemption mechanics, and market hours;
4. token decimals and non-standard ERC-20 behavior on a mainnet fork;
5. an independent, total-return-aware oracle and its corporate-action behavior;
6. executable liquidity for the configured adapter and a conservative exposure cap;
7. emergency monitoring that can disable admission/buying while preserving a sell-only unwind.

`base-mainnet-b20.json` records the ten Coinbase B20 stock candidates published
by Base. Their on-chain `decimals()` values were also checked against Base
mainnet on 2026-09-24. The B20 token addresses may have no ordinary bytecode
because they are Base-native precompiles; the registry intentionally validates
their behavior and policy rather than requiring `code.length > 0`.

Ethereum's tokenized-asset set changes too quickly for a hand-maintained claim
of completeness. `sources.json` identifies primary discovery sources, and
`scripts/discover-xstocks.mjs` exports the complete current xStocks API result
for a selected network. Discovery never changes the on-chain allowlist.

Example:

```bash
node scripts/discover-xstocks.mjs --network=Ethereum --output=/tmp/xstocks-ethereum.json
```

