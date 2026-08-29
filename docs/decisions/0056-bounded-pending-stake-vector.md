# 0056: Bounded pending-stake vector in custody ledgers

- Status: accepted
- Date: 2026-08-29

## Context

Each custody ledger previously held at most one pending `StakedSui` in an
`Option`. Native `StakedSui.join` requires equal activation epochs, and a new
request always activates at `epoch + 1`, so `stake_idle` skipped delegation
whenever the held receipt came from an earlier epoch. That deferral occurred
in exactly one production state: fun custody retains an activated receipt
while its conversion floor loss would breach the funSUI exit buffer, and new
fun deposits then stayed liquid — fully counted at face value but unstaked —
until the retained receipt resolved, costing roughly one epoch of staking
yield on that idle slice.

Sui native staking, unlike systems without fungible conversion, drains
multi-receipt states by construction: `convert_to_fungible_staked_sui` makes
every receipt mergeable into the single active `FungibleStakedSui` position
one epoch after creation, and `refresh` performs that drain at the first
current-rate epoch. Receipts are therefore transient, never accumulating.

## Decision

`Custody` stores `pending_stakes: vector<StakedSui>` ordered by strictly
increasing activation epoch, bounded by `constants::max_pending_stakes!()`
(three). `stake_idle` joins a same-epoch request into the newest receipt,
otherwise pushes into a free slot, and skips delegation — leaving the excess
liquid — when the ledger is full and the newest receipt cannot join. Skip,
never abort: a full ledger costs deferred yield only, and must not fail the
user operation carrying the sweep.

`refresh` resolves fun receipts oldest-first, rechecking the exit buffer per
receipt so each conversion budgets one floor-loss bound. `withdraw_exact`
drains pending principal newest-first, so the oldest, soonest-earning
receipts stay delegated; the one-SUI native minimum split rule applies per
receipt. `unwind` realizes every receipt.

### Bound argument

Receipts enter only through `stake_idle`, which the vault gates on a
current-epoch exchange rate, and all same-epoch requests join one receipt, so
inflow is at most one receipt per current-rate epoch. In that same
transaction, `refresh` has already converted or realized every receipt whose
activation epoch arrived, except a fun receipt activated this epoch that the
buffer guard retains — and that retained receipt is realized or converted at
the next current-rate epoch. Safe mode freezes inflow and drain together, so
the population cannot grow while it cannot shrink, and idle epochs only defer
drain that then completes before the next inflow. The reachable maximum is
two concurrent receipts (one buffer-deferred, one current-epoch); three
carries one slot of slack so an unforeseen state degrades to the old deferral
behavior instead of aborting.

## Rejected alternatives

- `Table<u64, StakedSui>` keyed by epoch: dynamic-field gas on every user
  operation, no native iteration, and oversized for a population of two.
- Chunked big-vector structures: solve an object-size problem three orders of
  magnitude away; justified only where the staking system lacks fungible
  consolidation (for example Walrus `StakedWal`), which Sui provides.
- Force-resolving the retained fun receipt before staking: spends exit-buffer
  backing or forfeits rewards to stake a few hours earlier, overriding the
  protections that create the deferral.
- Abort at the cap: turns an unreachable bookkeeping state into a
  user-facing outage on mint, redeem, and donate.
