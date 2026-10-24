# 0120: Priority gas for emergency reductions and unwind

- Status: accepted
- Date: 2026-10-24
- Amends: [0074](0074-aftermath-vault-activation-and-health.md), [0118](0118-limit-priced-vault-orders-and-a-widening-unwind-bound.md)
- Source: [Asymptotic M-9](../reviews/boosts-asymptotic-2026-10.md), founder decision

## Context

Capping maintenance transactions at the reference gas price avoids Aftermath's
priority trading surcharge but prevents them competing with higher-priced
traffic on the same shared objects. Shutdown can then make no closing progress.
The auditor recommended exempting unwind while keeping ordinary rebalances
capped. The accepted extension also exempts rebalances at emergency leverage.

## Decision

Unwind accepts any transaction gas price, including for venue settlement.
Rebalance first synchronizes and authenticates the position, prepares the core
plan, then checks its fixed emergency classification before any order. Only
starting leverage strictly above the hard cap permits a higher gas price.
Starting exactly at the cap, an ordinary reduction or an increase does not.
A plan's own fills cannot promote it into an emergency.

The core owns this classification. Emergency plans remain close-only, stop
once leverage is no longer above the hard cap, and never continue toward the
ordinary target at priority gas. A later transaction is classified again.
The private entry boundaries, internal clearing-house sharing, execution-price
limits, minimum-lot exception, work bound and actual-progress checks remain.

The caller pays network gas. Holders pay the configured venue priority trading
surcharge in addition to ordinary trading fees on admitted priority fills.
The venue rate is activated by bidding above reference; it does not increase
with the gas bid. No new fee ceiling, caller reimbursement or privileged
exception is introduced. The ordinary fee estimate sizes only increases,
which remain gas-capped. Emergency reductions size the next step and prove
progress against actual post-fill equity, including the extra trading cost.

Invalid observations or an inside-band position can now fail before the
rebalance gas check, because the exemption requires an authenticated plan.
Existing numeric error identities and entry signatures are unchanged; the
core exposes its already-stored plan classification without adding state.

## Limits and verification

Ordinary rebalances can still be delayed by congestion. Higher bids improve
the ability to compete, not guaranteed execution. Someone must submit and pay
for the calls; shutdown still needs its existing administrator authorization.
Venue priority support, fresh prices, liquidity, margin, venue availability,
and the existing progress checks still apply. Excessive fees can defeat
leverage improvement and correctly cause a rebalance to abort. M-5 and the
other unresolved audit findings remain separate.

Tests cover reference-price ordinary calls, priority ordinary rejection,
the exact hard-cap boundary, emergency calls on both sides, and immutable
classification as fills change leverage. The production entry wiring is
checked separately because the local venue interfaces are ABI stubs. Existing
state tests exercise costs in subsequent emergency sizing and stopping when
the hard cap is restored. Live priority execution remains a release gate.
