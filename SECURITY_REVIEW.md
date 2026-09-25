# RAFA Fund V2 security review

Date: 2026-09-24

Status: pre-deployment engineering review. This is not a substitute for an
independent professional audit before production funds are accepted.

## Scope

- `RafaFundV2`
- `RafaAssetRegistry`
- `FundFactoryV2`
- Aerodrome and Uniswap V3 adapters
- Chainlink price adapter
- Base Sepolia deployment rehearsal

Legacy `BaseETF` and `FundFactory` contracts are not deployment candidates and
were excluded from the V2 security scope.

## Findings fixed

### RF-01: a restricted RWA could block every asset in an in-kind exit

Severity: High (availability)

The original in-kind redemption transferred every token atomically. A paused,
blacklisted, or permissioned RWA token could revert its transfer and roll back
delivery of USDC and every other asset.

The vault now isolates each delivery with a bounded-gas external self-call. A
failed asset becomes a reserved claim for the intended receiver, while other
assets are delivered. The claimant can retry to any eligible address with
`claimPending`. Reserved balances are excluded from NAV, liquidity, exposure,
and trading calculations so they cannot be counted or spent twice.

### RF-02: direct token transfers could bypass buy-time exposure enforcement

Severity: Medium (risk control)

ERC-20 transfers cannot be prevented, so an outside account could send an
approved asset directly to a fund and push it over its fund or protocol
exposure limit without using `trade`.

The vault now reports `exposuresCompliant()` and returns zero from `maxDeposit`
whenever any current holding exceeds its effective limit. New deposits remain
blocked until an authorized sell restores compliance. Sell-side rebalancing and
in-kind exits remain available.

## Verification results

- 26 Hardhat tests pass.
- A deterministic 64-operation, two-investor state sequence preserves asset and
  share-supply invariants.
- A four-fund catalog rehearsal passes for Cash, Conservative, Balanced, and
  Growth funds, including deposits and 0%, 10%, 20%, and 60% test-WETH
  allocations.
- `RafaFundV2` coverage: 88.52% lines and 90.16% statements.
- `ChainlinkPriceOracle` coverage: 87.10% lines and 90.24% statements.
- ERC-4626 interface and event conformance passes Slither's checker.
- Slither high-impact scan reports zero unsuppressed findings. The one reviewed
  balance-delta warning is documented inline: the private trade helper is only
  reached through a `nonReentrant` entry point, and adversarial reentry is
  tested.
- Production dependency audit reports zero known vulnerabilities.
- `RafaFundV2` runtime bytecode is 22,151 bytes, below the 24,576-byte EVM
  runtime limit.

The suite exercises allowlist administration, role separation, deposit caps,
pauses, oracle freshness and malformed rounds, sequencer downtime, slippage,
trade-size limits, exposure limits, performance fees, first-depositor donation
attacks, delegated exits, malicious adapters, stale-oracle emergency exits,
restricted-token claims, and multi-fund registration.

## Residual risks and production requirements

1. Registry, adapter, and trader authority is intentionally centralized for the
   initial launch. Production ownership should use separate multisigs, a
   non-zero admin-transfer delay, and an independently held guardian key.
2. Base Sepolia uses unrestricted mock tokens, a mock router, and a fixed-price
   oracle. None is production-safe.
3. Only non-rebasing, non-fee-on-transfer tokens with reviewed transfer and
   compliance behavior should be admitted. A pending RWA claim can remain
   unavailable until the token accepts an eligible receiver.
4. Performance fees crystallize from oracle NAV. Production oracle selection,
   deviation monitoring, and a circuit-breaker procedure remain operational
   requirements.
5. Exposure checks cannot stop unsolicited token transfers; they stop new
   deposits and manager buys while allowing an orderly sell-side unwind.
6. The legacy V1 contracts remain in the repository for reference and must not
   be deployed as V2 funds.
7. Commission an independent audit and run a time-boxed public testnet/bounty
   period before accepting real user assets.
