# 0024: Generated coin launch ticket

- Status: accepted
- Date: 2026-08-24
- Implements: [0023](0023-generated-coin-supply-and-metadata-custody.md)
- Amended by: [0035](0035-initializer-finalized-meme-supply.md)

## Context

The generated coin package must use its one-time witness to create the current
unregulated Coin Registry currency. The resulting `TreasuryCap<Meme>` and
`MetadataCap<Meme>` must survive the separate permissionless registration
transaction before Blast can open the launch.

Accepting arbitrary pre-created capabilities would weaken provenance. Passing
the capabilities through unrelated modules would also obscure which module owns
their custody.

## Decision

### Blast consumes the OTW

`launch_ticket::new` is public because the generated coin package calls it from
its `init`. The constructor takes the OTW and the Coin Registry metadata inputs
in the same order as
`coin_registry::new_currency_with_otw`, followed by the creator identity, the
`burnable` choice, and `TxContext`.

The caller obtains a validated `CreatorIdentity` from
`creator_authority::new_address` or `creator_authority::new_x`. The ticket
constructor converts it into one linear `CreatorAuthority<Meme>`, then calls
`new_currency_with_otw` and finalizes the initializer. Blast does not expose a
ticket constructor that accepts an existing `TreasuryCap` or `MetadataCap`.

The constructor returns the ticket. It does not transfer it. The generated
package remains responsible for deliberate delivery from its non-composable
`init` boundary.

### The ticket owns only pre-launch custody

`LaunchTicket<Meme>` has `key, store` and contains:

- its `UID`;
- the empty `TreasuryCap<Meme>`;
- the native `MetadataCap<Meme>`;
- exactly one unissued `CreatorAuthority<Meme>`; and
- the launcher's `burnable` choice.

The choice is a boolean because the external decision is exactly burnable or
not burnable. The launch operation later maps it to Coin Registry `BurnOnly` or
`Fixed`. No second supply-mode argument may override the ticket.

The ticket does not mint, update metadata, claim creator authority, or perform
registration. `into_parts` is package-only and consumes the ticket before it
returns the four stored launch inputs to the future launch module. This is a
storage transition, not unchanged capability pass-through.

### Creation event

`LaunchTicketCreated` uses the package `Event<T>` wrapper and records the ticket,
original meme type, both native cap IDs, launcher, address-or-X creator identity,
and burnable choice. It has no sequence, nonce, schema version, or action tag.

The event tells the Blast worker which transaction created a pending ticket. The
worker reads that transaction's object effects to find the `Currency<Meme>` sent
to the Coin Registry address, then submits permissionless
`finalize_registration<Meme>`.

## Alternatives considered

**Accept existing treasury and metadata caps.** Rejected: the ticket would not
prove that Blast used the generated package's OTW and current unregulated Coin
Registry path.

**Transfer the ticket inside Blast.** Rejected: a reusable public constructor
must return its owned result so the generated package controls delivery.

**Expose separate address and X ticket constructors.** Rejected: identity
selection is composable input; duplicating the OTW currency-creation and custody
path adds interface and implementation without another lifecycle.

**Create a public supply-mode object or enum factory.** Rejected: the external
choice has only two states and does not need another public construction API.

**Pass the metadata cap through creator authority.** Rejected: creator identity
authentication does not validate, transform, consume, or store metadata
authority.

## Consequences

- One ticket is tied to one framework-validated OTW coin type.
- The treasury cap is zero-supply when the ticket is created.
- Address and X creator validation fail before Coin Registry object creation.
- The ticket is transferable before launch and cannot be silently dropped.
- Registration and launch remain separate later transactions.

## Verification

- Address and X tests cover both burnable choices and exact event fields.
- Tests prove both native cap IDs survive ticket custody and treasury supply is
  zero.
- A transfer test proves caller-selected ticket delivery.
- Invalid address and X identities abort before currency creation.
- A non-OTW type is rejected by the pinned Coin Registry implementation.
- Structural checks require one creator-identity OTW constructor and reject
  duplicate identity-specific, regulated, legacy, transfer, and arbitrary-cap
  construction paths.
- Build, strict lint, full tests, coverage, and source-boundary checks remain
  release gates.
