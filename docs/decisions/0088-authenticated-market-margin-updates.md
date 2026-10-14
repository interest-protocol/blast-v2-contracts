# 0088: Venue policy read live from the bound clearing house

- Status: accepted
- Date: 2026-10-14
- Amends: [0074](0074-aftermath-vault-activation-and-health.md)

## Context

The live NVDA vault rejected an ordinary Aftermath margin-ratio update as
account drift: the stored checkpoint carried the old market IMR/MMR, every
synchronization classified the new values as `Unexpected`, and mint and redeem
stayed blocked until the adapter changed. The same construction pinned every
other market-wide setting Aftermath's admin can change without touching a
Boosts account, and bound the two oracle storages and feed origins by object
id, so a lot-size change, a pause, a freeze or a re-pointed oracle would have
stranded the vault the same way, the oracle case including shutdown.

## Decision

Everything the venue's admin can change for the whole market is venue policy,
read from the vault's authenticated clearing house, never an account fact the
stored checkpoint must reproduce:

- The stored-to-current preexisting classifier adopts the lot size, pause mode,
  frozen flag and both market margin ratios the bound clearing house shows now
  (`set_core_params`, `pause_market`, `resume_market`, `freeze_clearing_house`,
  `unfreeze_clearing_house`, `commit_margin_ratios_proposal`). It still requires
  exact free and allocated collateral, position, order, funding-snapshot and
  position-margin fields, and the one funding-settlement shape it recognized
  before. A policy update never explains an account change, and an interval the
  classifier cannot explain is still reported as drift.
- The binding authenticates the account, the registry and the clearing house.
  The price-feed storages are checked on every capture and every venue mutation
  against the clearing house's current storage ids, and the feed is the one the
  market reads at its current source id (`set_base_oracle_params`,
  `set_collateral_oracle_params`). The venue's named price functions repeat the
  storage check and the feed's raw price must still equal them.
- Checks around an atomic venue mutation stay exact in every field: nothing but
  the adapter's own call runs between its before and after reads.
- Live venue gates are unchanged. Every priced operation synchronizes first and
  evaluates the venue's current margin, pause, freeze, oracle freshness,
  leverage, slippage and deadline gates, so a stricter margin or a pause blocks
  trading for its real reason. The adapter carries no hardcoded venue setting.

The adapter is published fresh at generation 1 after audit rather than upgraded
in place; the deployed package keeps its stranded vault until then.

## Consequences

- An interval in which only venue policy or the market's cumulative rates moved
  reconciles as `Unchanged`; the accepted checkpoint carries the new policy and
  `FundingSettled` records the previous and accepted checkpoints with a zero
  delta, so replay sees the policy change. Identical retries remain quiet.
- A re-pointed oracle no longer halts the vault; the capture values with
  whatever feed the venue trades at, under the venue's own staleness check.
- `Binding` and `VaultInitialized.binding` lose the four oracle ids; the
  activation evidence scripts check the storages the activation was called with
  against the market, not against the event.
- What remains outside this decision: an Aftermath package upgrade that raises
  the clearing house or registry version, a change to the market's collateral
  scale (not settable after creation), and anything that moves the account
  itself (liquidation, ADL, socialized losses). The first aborts inside the
  venue until the adapter is relinked; the last is drift by design.
