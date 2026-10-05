# Production security operations

This runbook defines the controls to configure before a RAFA fund accepts
mainnet deposits. Placeholder roles must be replaced with named Safe addresses,
owners, backups, and alert destinations in the chain deployment record.

## Authority layout

| Authority | Required production holder | Restrictions |
| --- | --- | --- |
| Registry owner | RAFA protocol Safe, at least 2-of-3 | No trader or guardian signer quorum; hardware-backed signers; two-step ownership transfer. |
| Factory owner | RAFA protocol Safe | Register only bytecode- and parameter-verified funds; may deactivate but not move fund assets. |
| Fund default admin | Dedicated fund Safe, at least 2-of-3 | At least one-day onchain admin-transfer delay; never assigned to the trader key. |
| Trader | Isolated automation signer | Gas only; trader role only; no Safe, registry, adapter-owner, guardian, or admin authority. |
| Guardian | Independent operations Safe or signer | Pause authority only; cannot unpause or trade. |
| Adapter owner | Protocol Safe | Configure only reviewed routes or pools; ownership separate from the trader key. |
| Fee recipient | Treasury Safe | Receives fee shares; no operational role required. |

Every deployment record must contain the chain ID, address, code hash,
constructor arguments, role assignments, Safe threshold, signer custody owners,
and transaction hashes for all ownership transfers.

## Asset admission and policy changes

Before first configuration, record token behavior, decimals, issuer controls,
oracle feed and bounds, update cadence, sequencer dependency, adapter bytecode,
venue liquidity, legal eligibility, exposure cap, and an unwind route.

For an existing asset policy change:

1. disable admission and buying; preserve selling only when the route is safe;
2. submit `proposeAssetReconfiguration` from the registry Safe;
3. independently compare the emitted policy with the approved change ticket;
4. monitor the full 48-hour delay for objections, oracle drift, and code changes;
5. execute from the Safe, verify storage and source, then test a bounded sell;
6. re-enable admission or buying only in a separate approved Safe transaction.

Use `reduceAssetExposureLimit` for emergency reductions. Raising a cap requires
the delayed full-policy path.

## Required alerts

Page the on-call operator immediately for:

- `TradingAutoPaused`, `TradingPauseUpdated`, or `DepositsPauseUpdated`;
- any role grant/revoke or default-admin transfer event;
- registry ownership, adapter ownership, or factory ownership changes;
- `AssetPolicyReconfigurationProposed`, execution, cancellation, or status change;
- oracle data older than the settlement threshold, outside configured price
  bounds, or inconsistent with an independent reference;
- cumulative trade notional above 75% of its 24-hour allowance;
- cumulative oracle-relative loss above 50% of its 24-hour pause threshold;
- failed in-kind delivery, growing pending claims, or unusual dust sweeps;
- fund exposure above 90% of either the fund or protocol limit; and
- deployed bytecode, proxy state, route, pool, or token behavior changing from
  the approved record.

Dashboard views must show idle liquidity, total NAV, price per share, exposures,
oracle age, 24-hour trade notional, 24-hour oracle-relative loss, pause state,
pending claims, and Safe action status for every fund.

## Incident actions

1. Guardian pauses trading and, when investor entry could worsen the event,
   deposits.
2. Registry Safe disables admission and buying for the affected asset. Disable
   selling only if the token or venue is unsafe; otherwise preserve unwind.
3. Revoke the trader role if key compromise is suspected and rotate the signer.
4. Preserve investor access to `redeemInKind`; publish any issuer transfer
   restrictions and the pending-claim process.
5. Reconcile holdings, allowances, pending claims, oracle state, and all trades
   from the start of the incident window.
6. Unpause only after the root cause, loss estimate, replacement configuration,
   independent review, and Safe approvals are recorded. An automatic loss pause
   cannot be cleared before its 24-hour risk window expires.

## Mainnet release evidence

Attach these artifacts to the release tag and deployment record:

- final auditor re-review tied to the exact commit;
- clean production build, tests, typecheck, dependency scan, and bytecode-size check;
- Base and Ethereum mainnet-fork results with exact tokens, feeds, and venues;
- Sepolia rehearsal transaction hashes for deposit, buy, sell, pause, policy
  change, cash exit after delay, stale-oracle block, and in-kind exit;
- verified-source links and constructor arguments;
- completed role and Safe matrix; and
- monitoring screenshots or test notifications proving every required alert.
