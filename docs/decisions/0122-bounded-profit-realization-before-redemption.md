# Bounded profit realization before redemption

Status: proposed. Date: 2026-10-24.

## Problem and audit recommendation

M-2 in the repository's Asymptotic audit restatement describes a cash mismatch:
share pricing includes positive unrealized PnL, whereas Aftermath's withdrawal
budget excludes it. An ordinary proportional close can leave insufficient cash
at every partial redemption size. The minimum recommendation is an exact cash
check and a named error. The stronger recommendation is to realize enough profit
and leave margin headroom; limiting the payout is an alternative that changes
holder economics.

We adopt the cash check and profit-realization recommendation. We do not cap the
holder's payout at available cash. Our refinement is a separate maintenance
transaction before redemption is quoted: changing the redemption's exact
proportional close would alter the remaining holders' exposure and cost allocation.
The source is a project restatement, not the original auditor's report; this
decision is not original-auditor approval.

## Decision

Anyone may request profit realization, but the contract selects every economic
term from authenticated venue facts and existing policy. It runs only when
cash, including free account cash, cannot cover the venue's current initial
margin requirement without positive unrealized gains. The venue's effective IMR,
collateral price and haircut are live inputs. Positive oracle PnL determines
what can be realized; neither it nor the cash budget replaces shareholder NAV.

One transaction closes a bounded portion and reopens exactly that portion.
Both immediate-or-cancel orders must fill in full, under the existing ordinary
price limits and execution-notional cap. There is no minimum-lot cap exemption
because the second leg opens risk. Each fill retains the standard raw checkpoint
proof. Two orders, no persistent recovery state, no new role or caller reward.
If either leg fails, all effects roll back.

The core sizes toward the cash shortfall, with a conservative rounding minimum
that makes the step economical, and caps the result at one opening order.
Larger deficits require multiple transactions. Before trading, the complete
shortfall plus rounding headroom must fit within total profit minus a
full-position cost allowance. At fixed prices, each call consumes the initial
slack between those quantities by its actual cost. A later code 65 means the
sequence has stalled under the worst-case allowance, even if better execution
could clear the gap. New collateral, an appropriate risk-reducing operation or a
price move is then needed. Raising the cap can avoid repeated costs before a
stall but does not remove this guard. Each call is checked anew; completion of a
sequence is not promised.
Worst-case costs include both
legs' price movement and live taker fees, plus two collateral atoms for
normalization. Estimated realized gains must exceed twice that cost allowance.
Completion proves the same base, side, lot and oracle pair, positive holder NAV,
leverage at or below the hard cap, bounded actual equity loss, a strictly smaller
cash shortfall, and an actual allocated-cash increase larger than the equity loss.
A mark-price change alone cannot establish recovery progress.

This is ordinary maintenance: transaction gas price cannot exceed reference gas
price. A private entry function takes the ClearingHouse directly and shares it
internally, preserving ADR 0118's transaction-composition restriction. It cannot
accept a market returned by a preceding by-value trading session or return one
for subsequent use. Earlier reference-only mutations remain possible under
ADR 0118; this is not a ban on every earlier market command.

Funding is settled and reconciled first using the existing exact-once path.
Realization then changes no share supply, maintenance reserve, uncovered funding
deficit, admin cash, fees or lifecycle. All holders bear actual trading costs in
the updated share value. A later redemption quotes that updated value, preserves
the exact proportional close and the user's minimum payout, and checks the
venue's own releasable-cash result before deallocation. Insufficient cash returns
`redemption_exceeds_releasable`; it never silently discounts the payout or burns
shares without paying.

`ProfitRealized` records vault identity, before/after equity, realized base,
before/after shortfall and raw checkpoints. Existing order events describe each
fill. Native transaction ordering and these events reconstruct recovery without
a duplicate stored counter or balance.

## Limits and related decisions

- M-5 and L-5 remain separate: this operation reopens risk and therefore requires
  healthy opening margin. It does not authorize an unsafe reopen, choose a new
  activation IMR or bypass emergency deleveraging. Existing policy must leave
  enough margin for the round trip; the hard leverage cap is enforced afterward.
  If even fully realized equity after the haircut cannot support the unchanged
  position, this route cannot restore withdrawals: deleveraging, new collateral
  or shutdown is needed. Realizing profit does not create equity.
- Adequate two-sided depth, fresh accepted prices, an operational venue and an
  economical amount of profit are required. A small live cap may require several
  transactions or an administrator's cap update. Recovery and redemption are
  separate transactions; prices and funding may move between them.
- Price limits, the cash-benefit test, the gas cap and the private-entry boundary
  bound permissionless costs. They do not eliminate cross-transaction adverse
  execution or market-making profit. Launch price-bound calibration remains a gate.
- Negative allocated collateral produces a conservatively overstated shortfall
  because the venue does not haircut negative collateral. A recovery trade may
  change book prices and the mark, causing the cash-progress check to refuse it.
  Deallocation refreshes venue TWAPs and funding again; at the boundary the venue
  may still return its own insufficient-cash error after the adapter precheck.
- A completed recovery does not promise every later withdrawal succeeds. Prices,
  cash requirements, execution costs and venue rules are checked again.
- Local venue interfaces prove types; fixture tests replace external reads and
  fills. Live ABI/bytecode inspection is not execution. A controlled mainnet
  close/reopen followed by redemption, both directions, partial-fill rollback,
  fees and haircut changes remains required before deployment. This is a new
  package lineage, not an upgrade to the live NVDA vault.
