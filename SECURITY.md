# Security policy and deployment gates

## Current status

RAFA Fund Protocol V2 is pre-audit software. Automated tests and compiler checks are not substitutes for an independent review.

Do not enable production deposits until all of the following are complete:

1. Independent Solidity audit with all critical and high findings resolved.
2. Base mainnet-fork tests using the exact USDC, Aerodrome router and Chainlink feeds selected for deployment.
3. Base Sepolia deployment and complete deposit, trade, fee, pause, redemption and in-kind redemption rehearsal.
4. Verification of every contract on BaseScan.
5. Factory owner and vault admin assigned to the approved RAFA Safe.
6. Trader funded only for gas and granted no admin or guardian authority.
7. Guardian runbook tested by an operator who is not using the trader key.
8. Conservative deposit, trade-size, exposure and slippage limits reviewed for each initial fund.
9. Monitoring for stale prices, paused state, role changes, NAV changes and failed transactions.
10. Deployment addresses, constructor arguments, feed addresses and transaction hashes committed under `deployments/`.

## Trust assumptions

- The default admin can change supported assets, price adapters, caps, metadata, fee recipient and operational roles. It must be a secured multisig.
- The registry owner decides which funds are official RAFA funds. It must be a secured multisig.
- The trader can rebalance within configured limits but cannot send assets outside the fund.
- Chainlink feeds, the Base sequencer feed, USDC and Aerodrome are external dependencies.
- In-kind redemption transfers the tokens the vault actually owns; recipients must be able to hold and manage those assets.

## Emergency behavior

- The guardian may pause deposits and trading independently.
- Only the default admin may unpause.
- In-kind redemption is intentionally not pausable and does not depend on live oracles.
- Unsupported tokens sent to a vault can be recovered by the admin; supported assets and the accounting asset cannot be recovered through that function.

## Reporting

Do not disclose a suspected vulnerability publicly. Contact the RAFA protocol team through the private security channel established before mainnet launch. Add the final security contact and disclosure SLA here before deployment.
