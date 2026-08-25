# 0037: Remove redundant supply mode from launch-ticket custody

- Status: accepted
- Date: 2026-08-25
- Amends: [0024](0024-generated-coin-launch-ticket.md), [0035](0035-initializer-finalized-meme-supply.md)

## Context

`launch_ticket::new` uses its `burnable` input to consume the unique
`TreasuryCap<Meme>` through either `make_supply_fixed` or
`make_supply_burn_only`. After initializer finalization, the Coin Registry's
`Currency<Meme>` is the authoritative and irreversible supply-mode record.

Storing the same boolean in `LaunchTicket<Meme>` does not enforce that state.
Its only implemented uses were to repeat the constructor input in
`LaunchTicketCreated` and return it from `into_parts` to a launch module that does
not yet exist.

## Decision

`LaunchTicket<Meme>` stores only its UID and the three linear resources that
must cross the generated-package boundary:

- the complete `Balance<Meme>`;
- `MetadataCap<Meme>`; and
- `CreatorAuthority<Meme>`.

The constructor retains `burnable` as an input because it must select the native
initializer transition. It passes that input directly to `LaunchTicketCreated`
without storing it. `into_parts` returns only the three stored resources.

The future launch implementation must define how it obtains and validates the
authoritative supply mode when burn policy becomes executable. It must not rely
on an unverified caller boolean or reintroduce a cached mode before that consumer
and its invariant are implemented.

## Consequences

- Ticket storage contains no duplicate of native Coin Registry state.
- Event indexing still records the launcher's selected mode.
- The launch-ticket ABI and tests are smaller.
- A future launch-mode design may inspect `Currency<Meme>` or introduce another
  proof boundary, but that decision belongs with the consuming launch module.

## Verification

- Fixed and burn-only tests inspect `Currency<Meme>` for authoritative mode and
  assert the creation-event fact.
- Structural checks reject a `burnable` field in `LaunchTicket<Meme>` and require
  its three-resource custody shape.
- Build, warnings-as-errors lint, full tests, and source-boundary checks remain
  release gates.
