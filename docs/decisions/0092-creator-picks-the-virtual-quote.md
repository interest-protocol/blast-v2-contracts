# 0092: The creator picks the virtual Quote reserve; launch config only admits Quotes

- Status: accepted
- Date: 2026-09-25
- Amends: [0090](0090-minimal-launchpad-surface.md)

## Context

`LaunchConfig` held `virtual_quotes: Table<TypeName, u64>`: an administrator set
one virtual Quote reserve per Quote type, zero disallowing it, and every launch
on that Quote started from it. The founder ruled on 2026-09-25 that the deployer
picks the virtual reserve and the configuration only checks that the Quote is
whitelisted.

## Decision

**Configuration.** `LaunchConfig.quotes` is a `Table<TypeName, bool>` of
admitted original Quote types, so the whitelist grows without bounding the
object; a key's presence admits it and its value is always `true`.
`set_quote_allowed<Quote>(allowed)` replaces `set_quote`: it adds or removes the
key, so re-admitting an admitted Quote or removing an unlisted one aborts with
the table's own error. `QuoteSet` records `allowed` instead of `virtual_quote`.
`snapshot_for_launch` aborts with `quote_not_allowed` for a Quote that is
not admitted and returns only the trade fees.

**Launch.** `LaunchInitializer` gains `set_virtual_quote`, which the creator
calls like `set_graduation_target`; `finalize` requires it and aborts with
`invalid_virtual_quote` when it is zero. A zero reserve would price the
curve's first purchase at nothing and let it take the whole curve reserve.
`LaunchCreated` already records the launch's virtual Quote, so replay is
unchanged.

## Consequences

- Each launch's starting price and curve shape are the creator's choice. Blast
  no longer sets a floor under them; an unusual reserve affects only that launch.
- Disallowing a Quote stops new launches on it; live launches keep trading.
- Adapters are unchanged: the creator's PTB calls `set_virtual_quote` on the
  initializer the adapter returns, before `finalize`.
