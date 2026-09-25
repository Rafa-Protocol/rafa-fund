# Security policy and deployment gates

## Current status

RAFA Fund Protocol V2 is pre-audit software. Automated tests and compiler checks
are not substitutes for an independent review. Do not enable production
deposits on Base or Ethereum until all gates below are complete.

1. Independent Solidity audit with all critical and high findings resolved.
2. Mainnet-fork tests using exact accounting assets, tokens, feeds, adapters,
   pools/routes, and issuer restrictions selected for each chain.
3. Base Sepolia and Ethereum Sepolia rehearsals covering deployment, registry
   setup, deposit, buy, sell, fee, pause, policy reduction, cash redemption, and
   stale-oracle in-kind redemption.
4. Verified source and constructor arguments for every deployed contract.
5. Registry, adapter, factory, and fund ownership assigned to approved RAFA Safe addresses.
6. Trader funded only for gas with no admin, guardian, or registry authority.
7. Guardian and sell-only unwind runbooks exercised by independent operators.
8. Legal/eligibility review for every regulated or permissioned RWA and intended investor jurisdiction.
9. Conservative deposit, trade-size, exposure, freshness, and slippage limits approved per asset.
10. Monitoring for issuer/B20 pauses, stale feeds, sequencer outages, transfer failures,
    role/policy changes, concentration, NAV anomalies, and failed transactions.
11. Addresses, parameters, feeds, routes, hashes, audit commit, and Safe transactions recorded under `deployments/`.

## Trust assumptions

- The registry owner controls the protocol-wide asset policy and is trusted to
  choose valid oracles/adapters. It must be a secured multisig.
- A fund admin can choose only centrally admitted assets and can only make
  exposure limits stricter than the registry. Initially it is also the RAFA Safe.
- The trader can rebalance within configured limits but cannot select arbitrary
  assets, venues, or recipients.
- A registry-approved adapter can pull a fund's exact trade input. Adapter code,
  ownership, route configuration, and external venue must therefore be audited.
- Chainlink, sequencer feeds, accounting assets, DEX venues, B20, and RWA issuers
  are external dependencies and may pause, block, upgrade, or restrict transfers.
- Technical token compatibility does not establish investor eligibility or a
  legal right to hold, trade, redeem, or receive an RWA during in-kind exit.

## Emergency behavior

- Registry owner can disable admission and buying while preserving sells, or
  disable both directions if transfers or the venue are unsafe.
- Fund guardian can pause deposits and trading; only fund admin can unpause.
- Price-dependent settlement stops on stale data.
- In-kind redemption is intentionally not pausable and does not depend on live
  oracles or liquidity, though issuer transfer controls can still reject a recipient.
- Unsupported tokens can be recovered by fund admin; the accounting asset and
  supported holdings cannot be recovered through that function.

## Reporting

Do not disclose a suspected vulnerability publicly. Contact the RAFA protocol
team through the private security channel established before mainnet launch.
Add the final security contact and disclosure SLA here before deployment.
