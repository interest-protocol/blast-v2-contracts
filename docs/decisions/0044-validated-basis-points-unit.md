# 0044: Validated basis-points unit

- Status: accepted
- Date: 2026-08-28
- Amends: [0021](0021-pure-constant-product-curve-quotes.md),
  [0022](0022-dual-asset-fee-ledger-and-claims.md),
  [0026](0026-deferred-sell-burn.md),
  [0027](0027-graduation-economics-and-migration-witnesses.md),
  [0028](0028-hot-cold-runtime-configuration.md),
  [0041](0041-launch-config-owned-trade-fees.md), and
  [0043](0043-versioned-launch-trading-and-atomic-migration.md)
- Amended by: [0081](0081-separate-lp-fee-share-policy.md), which makes the raw
  value read public

## Context

Blast stores seven basis-points rates across runtime configuration, launch
configuration, launch tickets, and launches. Raw `u64` storage lets invalid
values exist unless every constructor and future migration repeats the same
10,000-basis-point guard. Fee and partition modules also repeat the same
multiply-divide rounding formulas.

The base range invariant is cross-cutting, but stricter policy remains local:
launch trade fees are capped at 1,000 basis points, migration fees at 500,
protocol Meme graduation fees at 1,000, and the combined Meme partition must
leave positive curve inventory.

## Decision

Add one reusable `bps` library module. `Bps` is a copyable, storable wrapper
around `u64`; `bps::new` accepts the inclusive range `0..=10_000` and aborts for
larger values. It exposes the raw value for event and ABI boundaries, downward
and upward rounded application to a `u64` amount, and the exact complement to
10,000 basis points. The arithmetic uses the standard widened `u64`
multiply-divide methods, so every valid result remains at most its input.

All `Bps` operations are `public(package)`. Move does not support package-visible
struct declarations, so the opaque type declaration is public to let sibling
Blast modules name it; its field is private and external packages cannot
construct or inspect a value.

Runtime configuration, launch configuration, launch tickets, and launches store
rates as `Bps`. Package-only curve, fee-ledger, and graduation seams consume
`Bps`, preventing unvalidated rates from reaching protocol arithmetic. Public
setters and the launch-ticket constructor continue to accept raw `u64` for a
simple transaction ABI. `bps::new` is the only owner of the inclusive
`0..=10_000` invariant. Owner modules keep only stricter domain ceilings,
nonzero requirements, and cross-field policy, then construct `Bps`. Package
seams pass already validated `Bps` values directly instead of unwrapping and
revalidating them. Events continue to contain raw `u64` primitive facts so
indexers do not depend on the storage wrapper.

`Bps` does not expose generic addition or subtraction. Combined-rate policy and
its error precedence stay in the owning module. This is a pre-publication
storage-layout refinement, so the initial package version does not advance. A
deployed package would require an explicit upgrade and migration design.

## Alternatives considered

- Keep raw `u64` storage and use helper functions only. This centralizes
  arithmetic but does not make the range invariant structural.
- Put basis-points helpers in `constants` or `fees`. `constants` must remain a
  value registry, while basis points are also used by curve, graduation, burn,
  and runtime policy.
- Add one module per fee domain. The base unit and arithmetic are identical;
  domain-specific ceilings remain clearer in their existing owner modules.

## Consequences

The Sui package grows from 15 to 16 source modules. The added module has one
cohesive responsibility and removes repeated validation assumptions at stored
state and arithmetic boundaries. Serialized config, ticket, and launch layouts
change even though each wrapped value still contains one `u64`. Public setter
inputs and replay event schemas do not change.

## Verification

- Unit tests cover both range boundaries, the first invalid value, downward and
  upward rounding, maximum-`u64` identity, complements, and remainder
  conservation.
- Ticket and runtime setter tests prove invalid raw inputs abort in `bps::new`;
  retired domain-specific codes 32 and 40 are not reused.
- Existing curve, fee, graduation, config, ticket, launch, event, and upgrade
  tests must continue to pass.
- Source-boundary checks enforce `Bps` storage, raw event payloads, owner-local
  policy ceilings, the package-visible `bps` API, and single ownership of the
  inclusive range check.
