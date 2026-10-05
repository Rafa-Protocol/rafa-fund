# DatSon360 remediation engineering review

Date: 2026-10-05

Status: implemented and internally validated; independent DatSon360 re-review
pending. This document is RAFA's engineering record, not an auditor attestation.
The original PDF and the immutable remediation commit link are published in
[Rafa-Protocol/security-audits](https://github.com/Rafa-Protocol/security-audits).

## Reference scope

DatSon360's draft v0.1 reviewed commit `2ddd1c3` and covered:

- `RafaFundV2`
- `RafaAssetRegistry`
- `FundFactoryV2`
- Aerodrome and Uniswap V3 adapters
- Chainlink price adapter
- interfaces, tests, and deployment tooling

The draft listed 1 High, 2 Medium, 5 Low, and 4 Informational findings. The
dispositions below describe RAFA's changes after the report; the auditor must
confirm final severity and closure status.

## Finding dispositions

| Finding | RAFA disposition | Implementation and verification |
| --- | --- | --- |
| HIGH-01: repeated max-slippage trades | Mitigated; auditor verification pending | Protocol maximum reduced to 5%; official-fund maximum reduced to 2%; rolling 24-hour notional capped at 100% of NAV; trading auto-pauses above 1% of NAV in cumulative oracle-relative loss; trade-value limit can only decrease. Tests reproduce cumulative adverse fills and verify the pause and delayed reset. |
| MED-01: NAV arbitrage from oracle latency | Mitigated; auditor verification pending | Newly minted shares cannot transfer or use cash exits for six hours. Deposits and cash exits always require settlement-fresh prices, including zero-fee funds. Immediate proportional in-kind exit remains available. |
| MED-02: instant registry oracle/adapter replacement | Fixed in code; auditor verification pending | Existing policies require admission and buying to be disabled, an onchain proposal, a 48-hour delay, and execution while still disabled. Execution preserves the disabled state; re-enabling is separate. Emergency exposure reductions remain immediate. |
| LOW-01: settlement freshness depended on fee accrual | Fixed in code; auditor verification pending | Deposit, mint, withdraw, redeem, and slippage variants explicitly call `settlementTotalAssets` before fee logic. A zero-performance-fee stale-oracle cash-exit test now reverts. |
| LOW-02: dust donation blocked asset removal | Fixed in code; auditor verification pending | Removal blocks outstanding claims and significant balances, but a disabled asset with no pending claims may sweep at most $0.01-equivalent dust to the fee recipient before removal. Both dust and above-threshold cases are tested. |
| LOW-03: in-kind exit can skip fees during oracle outage | Acknowledged design; auditor verification pending | The emergency exit remains oracle-independent to avoid trapping investors. NatSpec and the emitted skip event explicitly disclose that an exiting holder may avoid otherwise-accrued fees during an outage. |
| LOW-04: registry did not verify token decimals | Fixed in code; auditor verification pending | First configuration and reconfiguration compare configured decimals with `IERC20Metadata.decimals()` whenever token bytecode exists. The zero-code exception remains only for Base-native B20 compatibility. |
| LOW-05: factory omitted slippage and admin-delay checks | Fixed in code; auditor verification pending | Official registration rejects slippage above 2% and default-admin transfer delay below one day. Both rejection paths are tested. |
| INFO-01: floating Solidity pragma | Fixed | All project contracts and interfaces pin Solidity `0.8.34`; production and test builds use the same compiler. |
| INFO-02: Chainlink clamping and deprecated `answeredInRound` check | Fixed in code; auditor verification pending | Each oracle now requires immutable minimum and maximum price bounds. The deprecated `answeredInRound` completeness check was removed; answer validity and timestamp checks remain. |
| INFO-03: deposit exposure error reused cap error | Fixed | Exposure noncompliance now reverts with `ExposureLimitsBreached`. |
| INFO-04: `FundCreated` event naming drift | Fixed | The registry event is now `FundRegistered`. |

## Validation results

- Production compile: Solidity `0.8.34`, Cancun target, optimizer enabled with 200 runs.
- Full project check passes: production build, bytecode-size gate, tests, and TypeScript typecheck.
- Production dependency advisory scan reports zero known vulnerabilities.
- Focused Slither high-impact scan reports no high-impact findings. The broader
  scan's medium warnings were reviewed as intentional zero/sentinel comparisons,
  exact-balance verification that deliberately ignores adapter return values,
  mock-only payable behavior, or external calls protected by `nonReentrant` and
  role checks; these still require auditor confirmation.
- 30 Hardhat tests pass.
- `RafaFundV2` runtime bytecode is 23,287 bytes, below the 24,576-byte EVM limit by 1,289 bytes.
- Other runtime sizes: `RafaAssetRegistry` 7,545 bytes, `FundFactoryV2` 4,181 bytes,
  `AerodromeAdapter` 3,603 bytes, `UniswapV3Adapter` 2,775 bytes, and
  `ChainlinkPriceOracle` 2,311 bytes.
- The deterministic 64-operation, two-investor sequence preserves NAV and
  share-supply invariants.
- Attack-path coverage includes malicious adapters, repeated adverse fills,
  rolling notional exhaustion, stale settlement prices with zero fees, delayed
  registry changes, decimals mismatch, direct-donation exposure breaches,
  restricted-token claims, dust griefing, first-depositor donation attacks,
  and cash-exit locks.

## Residual risks and release blockers

1. DatSon360 must re-review the exact remediation commit and issue a final report.
2. The 1% cumulative-loss threshold limits but does not eliminate damage from a
   compromised trader; monitoring and rapid role revocation remain mandatory.
3. In-kind exit intentionally remains immediately available and may bypass fee
   crystallization or the cash-exit delay during an oracle incident.
4. First-time registry configuration and status changes are immediate Safe
   actions. Safe security, review procedures, and alerting remain trust assumptions.
5. Oracle bounds limit extreme values but do not prove economic correctness.
   Independent reference monitoring and feed-specific configuration are required.
6. Base Sepolia fixtures are not production assets, feeds, or venues. Exact-asset
   mainnet-fork tests and both Sepolia rehearsals remain release gates.
7. Production role addresses, Safe thresholds, alert destinations, and security
   contact must be recorded before deposits are enabled.

See [OPERATIONS.md](./OPERATIONS.md) for the required role topology, policy-change
procedure, alerts, incident response, and mainnet release evidence.
