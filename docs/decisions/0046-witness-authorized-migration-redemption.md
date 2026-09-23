# 0046: Witness-authorized migration redemption

- Status: accepted; amended by [0088](0088-reusable-launch-accounting-and-atomic-migration.md)
- Date: 2026-08-28
- Amends: [0010](0010-migration-and-venue-adapters.md),
  [0027](0027-graduation-economics-and-migration-witnesses.md), and
  [0043](0043-versioned-launch-trading-and-atomic-migration.md)

> ADR 0088 replaces the concrete `MigrationPayload` and
> `redeem_migration` shape with one no-ability `Migration` value that
> `begin_migration` returns with the liquidity balances and
> `complete_migration` consumes under the launch's stored adapter witness in
> the same transaction. This ADR remains authoritative only for
> permissionless initiation, sealed witness authorization, linear handoff, and
> transaction rollback.

## Context

Migration is permissionless. Any transaction sender must be able to start the
terminal launch transition. The selected external adapter must still be the only
code that can open the terminal asset handoff.

Passing the sealed adapter witness into `launch::migrate` combines these two
separate concerns. The witness then authorizes payload creation, although its
security purpose is to authorize payload redemption by the selected adapter.

## Decision

`launch::migrate<Meme, Quote, MigrationWitness>` takes no witness value. Any
caller can invoke it with a witness type. Core checks that the type's original
`TypeName` equals the immutable migration witness selected by the launch. It
then returns a non-copyable and non-droppable
`MigrationPayload<Meme, Quote, MigrationWitness>`.

`launch::redeem_migration` consumes that payload and a value of its exact
`MigrationWitness` type. A supported external adapter owns the sealed witness
constructor and supplies the witness when it opens the payload.

The payload has no abilities. Therefore, a transaction cannot complete after
`migrate` unless code with the selected witness consumes the payload. If
redemption or later adapter work aborts, Sui rolls back the migration transition
and all asset movement in the transaction.

This change adds no storage, event, error, module, or privileged operation.

## Alternatives considered

**Supply the witness to `migrate`.** Rejected. It makes a permissionless state
transition appear adapter-authorized and checks code authority one function too
early.

**Remove the witness type from `migrate`.** Rejected. Core must type the linear
payload and compare the caller-selected type with the launch snapshot before it
moves terminal assets.

**Make the payload droppable.** Rejected. A caller could complete migration
without the selected adapter and discard its asset handoff.

## Consequences

- Any sender can pay gas and start migration.
- Only the selected adapter can open the returned payload.
- The public ABI places the sealed witness on `redeem_migration`, where code
  authority is required.
- Existing migration events and error codes do not change.

## Verification

- A selected witness type can create a payload without a witness value.
- Redemption succeeds only when it consumes a value of the payload's exact
  witness type.
- A non-selected witness type aborts before terminal asset mutation.
- Lifecycle and package-version checks keep their existing precedence.
- Build, lint, full tests, coverage, and source-boundary checks pass.
