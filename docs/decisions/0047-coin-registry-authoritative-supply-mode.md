# 0047: Coin Registry authoritative supply mode

- Status: accepted
- Date: 2026-08-29
- Amends: [0024](0024-generated-coin-launch-ticket.md),
  [0035](0035-initializer-finalized-meme-supply.md),
  [0037](0037-remove-redundant-ticket-burn-mode.md),
  [0040](0040-normalized-launch-state-intake.md), and
  [0043](0043-versioned-launch-trading-and-atomic-migration.md)

## Context

`launch_ticket::new` uses the owner's `burnable` input to consume the unique
`TreasuryCap<Meme>`. It changes the native `Currency<Meme>` state to `Fixed` or
`BurnOnly` before it finalizes the initializer. Coin Registry does not permit
either final state to change into the other state.

The current ticket stores the same input. `launch::new` copies it into the
Launch object. At migration, core compares that cached Boolean with the native
state. No current public path can create a mismatch because both facts come from
the same constructor input and neither fact can change.

Selling needs `sell_burn_bps`, but it does not need the native supply mode.
Migration already borrows `Currency<Meme>` for native burning and total-supply
accounting.

## Decision

Coin Registry is the only onchain authority for the generated coin supply mode.

`LaunchTicket<Meme>` stores its linear resources and `sell_burn_bps`. It does
not store `burnable`. Its constructor still accepts `burnable`, applies the
corresponding irreversible initializer transition, and records the selection in
`LaunchTicketCreated`.

`Launch<Meme, Quote>` stores `sell_burn_bps` but does not store `burnable`.
`LaunchCreated` records `sell_burn_bps` and its source ticket id. Event reducers
obtain the original supply-mode selection from the linked
`LaunchTicketCreated` fact.

The sealed `LaunchTicket<Meme>` is also the construction proof consumed by
`launch::new`. The ticket constructor always changes the native supply state to
exactly `Fixed` or `BurnOnly` before it returns the ticket. An external caller
cannot construct a ticket with `Unknown` supply.

At migration, core reads `Currency<Meme>` once:

- `BurnOnly` destroys terminal disposal through Coin Registry;
- otherwise, the construction invariant means `Fixed`, so core sends terminal
  disposal to `0x0`.

`Migrated.native_supply_burned` records which terminal action completed. The
event does not also repeat that fact as `burnable`.

## Alternatives considered

**Keep the cached Boolean and revalidate it.** Rejected. The comparison protects
against an unreachable mismatch that exists only because Blast stores duplicate
state.

**Borrow and revalidate `Currency<Meme>` when the launch is created.** Rejected.
The sealed ticket already proves that its constructor finalized the mode. A
second check would add a shared-object dependency without strengthening the
invariant.

**Use the sell-burn rate as the supply mode.** Rejected. Fixed and BurnOnly
launches can use any valid sell-burn rate, including zero.

## Consequences

- Ticket and Launch storage each lose one duplicate Boolean.
- Migration selects its terminal action from current authoritative native state.
- Supply-mode validity is established before `LaunchTicket` construction
  completes, so migration cannot strand assets behind a late validation.
- Launch intake remains independent of the shared Currency object.
- Replay remains complete through the ticket id, `LaunchTicketCreated`, and
  `Migrated.native_supply_burned`.
- No module, capability, setter, or new error code is added.

## Verification

- Fixed and BurnOnly ticket tests inspect native `Currency<Meme>` state.
- Launch tests prove that `sell_burn_bps` survives ticket redemption without a
  cached supply mode.
- Migration tests prove Fixed `0x0` disposal and BurnOnly native destruction
  with both empty and nonempty accumulated sell-burn escrow.
- Guard-order tests cover stale package versions, invalid lifecycle, invalid
  migration witness, and repeated migration.
- Launch-ticket tests cover sell-burn rates at zero, 50%, and the first invalid
  value above 100%.
- Structural checks reject `burnable` storage in LaunchTicket and Launch.
- Build, lint, full tests, coverage, source-boundary checks, and diff checks pass.
