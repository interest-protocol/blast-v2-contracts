# Small-vault recovery within the band

Status: accepted. Date: 2026-10-24.

## Problem and audit alignment

L-3 describes a below-band vault whose smallest whole-lot increase overshoots
its target. Rebalance sizes zero, and the deposit band gate blocks growth.
The audit restatement recommends an early non-actionable diagnostic, a false
keeper hint, helpful deposits and documented operating-size constraints.

Follow that recovery goal, with two refinements. A target is an aim within an
accepted band: permit one lot past target only if it actually finishes inside
that band. If no standalone buy fits, a deposit must fund explicit catch-up
exposure and finish inside the band in the same transaction. A proportional
mint alone preserves or lowers leverage, so just relaxing its initial gate
does not reliably cure the problem. Gradual below-band mint completion would
weaken L1; it remains disallowed. This decision narrows the target-only
increase rule in ADR 0064 only for the one-lot case below.

The auditor's five-lot, 1.67x example now takes the one-lot rebalance path:
its hint is true, rebalance succeeds, and deposits wait for that rebalance.
`a_small_long_or_short_can_buy_one_lot_past_target_inside_the_band` and
`recovery_deposits_do_not_skip_an_available_single_lot_rebalance` pin this
intentional difference. A one-lot position at 1.67x instead exercises the false
hint, early diagnostic and deposit recovery. The source is the project's audit
restatement, not original-auditor sign-off.

## Standalone recovery

Core owns one fee-aware sizing decision used by preparation, every next order,
and the keeper hint. Ordinary increases remain capped, cost-adjusted buys at
or below target. Only if that result is zero and leverage is below the band,
consider one lot. It must fit the ordinary execution-priced cap and its
conservative post-cost leverage must lie inside the full band. A sealed order
records this exception; the actual fill must pass both exact inclusive band
edges. Ordinary orders still cannot cross target. No caller chooses an order
or expands the price allowance. The existing private entry and internal share
boundary remains intact.

If both choices size zero, preparation aborts early with a distinct diagnostic
and the hint returns false. Invalid opening caps, fees, prices and venue state
retain their own errors. A hint is not a promise of funding, liquidity or fills.

## Deposit-funded recovery

Only a below-band, non-flat position with no standalone increase may enter
this branch of the existing mint transaction. Above-band positions and those
with an available standalone increase still must rebalance first. Opening
margin, authenticated prices, market operation and reconciliation remain
mandatory. No new public transaction endpoint or caller-selected flag is added.

The deposit must fund the usual minimum proportional order. Core then sizes a
catch-up buy against pre-mint NAV plus the deposit net of protocol fees, aiming
at target after conservative costs. Total catch-up size is at most one ordinary
order cap and must be at least the proportional amount. Reject a projected
outside-band result before funding. The adapter executes exactly this sealed
size through its ordinary bounded mint order loop and checks each real fill.

Completion prices shares from actual NAV added, capped by the deposit net of
fees. The depositor bears all catch-up execution costs through fewer shares;
their minimum-share setting limits those costs. Existing holders' NAV per share
must not fall. The actual contribution must still fund the minimum proportional
size, the entire sealed order must fill, and the final state must pass both band
edges and the NAV cap using the actual reserve after fees and clamping. An abort
rolls back all effects except network gas. No intermediate below-band deposit
can commit. Favorable excess stays with existing holders under ADR 0084.

## Limits and release evidence

This is conditional recovery, not guaranteed execution. The deposit must be
large enough to support legal whole-lot sizing but small enough for the order
and NAV caps; some configurations admit no such deposit. The admin may need
to adjust caps. Costs, thin books, absent margin, stale prices or reserve changes
can still reject execution. Recovery deliberately does not relax those rules.
Mints may use priority gas: the venue's priority surcharge is an additional
actual cost, not included in the ordinary-taker-fee projection. The depositor's
minimum shares and final band check remain authoritative.

Without costs, requiring at least roughly `L / (T - B)` position lots avoids
the target-only rounding dead zone (current leverage L, target T, lower edge B).
The band-landing exception reduces that dead zone. This estimate is not a fixed
protocol minimum: live lot value, fees, price bounds, reserves and caps also
matter. Deposits retain the calibrated product minimum from L1.

Use fresh first-party publications under ADR 0115. Core plan layouts and helper
signatures change; the adapter's transaction signatures stay the same. Local
Move tests and external ABI checks cannot establish real Aftermath trading.
Before release, exercise long/short one-lot and deposit recovery with real
fills, costs, margin admission, caps, failed fills and transaction rollback.
