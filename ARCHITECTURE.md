# RAFA Fund Protocol architecture

## System model

```mermaid
flowchart LR
    Investor[Investor wallet] -->|Deposit accounting asset| Fund[RafaFundV2]
    Fund -->|Mint ERC-20 shares| Investor
    Investor -->|Cash or in-kind redemption| Fund
    Trader[Restricted RAFA trader] -->|Guarded rebalance| Fund
    Safe[RAFA Safe] --> Registry[RafaAssetRegistry]
    Safe -->|Fund roles and stricter caps| Fund
    Guardian[Independent guardian] -->|Pause deposits or trading| Fund
    Registry -->|Asset policy| Fund
    Oracle[Reviewed price oracle] --> Registry
    Registry --> Adapter[Chain-specific trade adapter]
    Adapter --> Venue[Aerodrome or Uniswap V3]
    Factory[FundFactoryV2] -->|Official fund list| Fund
```

## Chain-local asset registry

Base and Ethereum each receive an independent `RafaAssetRegistry`, owned by the
RAFA Safe. A configured policy binds one token to:

- admission, buy, and sell status flags;
- immutable-at-read token decimals;
- separate NAV and settlement price-age limits;
- a protocol-wide maximum exposure;
- an `IPriceOracle` implementation and `ITradeAdapter` implementation; and
- machine-readable asset-class and issuer identifiers.

The split status flags support incident response. RAFA can prevent new funds
from adding an asset, stop further buying, and keep selling enabled for an
orderly unwind. Existing funds read the registry on each trade and valuation,
so a protocol policy or exposure reduction applies without redeploying them.

First-time asset configuration validates an ERC-20 token's reported decimals
when bytecode is available. Replacing an existing oracle, adapter, decimals,
freshness setting, exposure cap, class, or issuer requires this sequence:

1. disable admission and buying while optionally preserving sells;
2. publish the proposed policy onchain;
3. wait at least 48 hours;
4. execute while the asset remains disabled; and
5. re-enable admission or buying in a separate transaction after verification.

A protocol exposure cap can be reduced immediately but cannot be raised through
that fast path.

Discovery is explicitly off-chain. Catalog files do not configure the registry,
and no discovery script has a Safe key or an automatic admission path.

## Base B20 compatibility

Coinbase B20 assets are native Base precompiles and may expose ERC-20 behavior
without normal EVM bytecode. `RafaAssetRegistry` therefore does not require
token bytecode, while it does require code at the configured oracle and adapter.
Operational review must call token methods on a mainnet fork before admission.

B20 prices incorporate a multiplier for dividends and stock splits. RAFA must
use the official total-return-aware feed, not a generic spot-equity quote. A
corporate-action or market-hours freeze stops `updatedAt` from advancing; the
strict settlement age then blocks deposits, cash exits, fees, and trades. The
RAFA monitor should disable admission/buys immediately when an issuer pause is
detected. In-kind exits remain available.

## Execution adapters

The fund never calls a DEX directly. The registry selects a reviewed adapter for
each asset, and the fund approves only the exact input amount for one call.

- Base uses `AerodromeAdapter`, whose owner enables a direct stable or volatile
  route between the accounting asset and one candidate asset.
- Ethereum uses `UniswapV3Adapter`, whose owner enables a direct pool fee tier.

Both adapters return output directly to the fund. The fund checks actual input
spent, actual output received, deadline, oracle-relative slippage, per-trade NAV
limit, rolling 24-hour notional, cumulative oracle-relative loss, and post-buy
exposure. Official funds accept at most 2% oracle-relative slippage, can trade at
most 100% of NAV in aggregate per 24-hour window, and auto-pause after more than
1% of NAV in cumulative oracle-relative loss. Adding another venue requires a
new adapter that implements `ITradeAdapter`; fund bytecode does not change.

## Deployment and official funds

Each vault is an immutable `RafaFundV2`. `FundFactoryV2` is an official-fund
registry instead of a bytecode factory, keeping contracts below EVM size limits
and avoiding upgrade authority. Registration checks the canonical implementation
marker, expected accounting asset, expected asset registry, and maximum
performance fee. Registration also rejects funds configured above 2% slippage
or below a one-day default-admin transfer delay. The Safe must still verify
bytecode and constructor arguments; the marker alone is not proof of identity.

## Roles

| Role | Initial holder | Authority |
| --- | --- | --- |
| Asset registry owner | RAFA Safe | Protocol asset admission/status, oracle, adapter, freshness, and global cap. |
| Fund default admin | RAFA Safe | Select permitted assets, stricter caps, roles, metadata, and unsupported-token recovery. |
| Trader | Restricted RAFA automation key | Swap only between accounting asset and permitted assets within on-chain limits. |
| Guardian | Independent operations key or Safe | Pause deposits and fund trading; only admin unpauses. |
| Factory owner | RAFA Safe | Register and deactivate official funds. |
| Fee recipient | RAFA treasury/Safe | Receive newly minted performance-fee shares. |

Initially RAFA operates every fund and the Safe retains centralized policy
control. The RAFA token is not required for deposits, manager permissions, or
asset admission in this phase; governance can be introduced later without
making it a tradable portfolio asset by default.

## NAV, settlement, and exits

`totalAssets` values idle accounting tokens plus each active holding using the
policy's NAV age. `settlementTotalAssets` uses the stricter trade age and is
required before deposits, cash exits, fee crystallization, and trades. Invalid
or stale data reverts instead of valuing an asset at zero.

Standard ERC-4626 withdrawals use idle accounting-asset liquidity. `redeemInKind`
burns shares and transfers a proportional slice of every held token without a
DEX or oracle, including during price, venue, or pause incidents. Recipients may
still be subject to issuer transfer restrictions.

Shares minted by a deposit, mint, or performance-fee accrual cannot be used for
a cash exit or transferred for six hours. This reduces stale-NAV deposit/exit
arbitrage while preserving immediate proportional in-kind exits. The delay is
share-based: previously unlocked shares remain usable when an account receives
newly minted locked shares.

Performance fees mint shares only on profit above a per-share high-water mark.
They accrue before standard entry/exit and can be called permissionlessly. If
pricing is unavailable, in-kind redemption skips fee accrual and emits an event
rather than trapping investors.

## Indexing

The investor application should index factory registration/status, ERC-4626
deposits/withdrawals, fund-share transfers, trades, in-kind redemptions, fees,
and registry policy/status events. Historical performance must use price per
share rather than TVL so flows are not mistaken for returns.
