# 0033: Meme liquidity provision for destination pools

- Status: accepted
- Date: 2026-08-25
- Amends: [0025](0025-quote-whitelist-and-migration-targets.md),
  [0027](0027-graduation-economics-and-migration-witnesses.md)

> Amended by [ADR 0039](0039-deterministic-quote-valuations.md): the snapshot
> additionally returns per-Quote virtual liquidity before the target and the
> off-chain SDK derives the exact curve endpoint and native-Quote previews.

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| Memez.Fun migration liquidity selection | `00596fdac4dd11f427c7bc594e566ce36160db93` | [`interest-protocol/memez-gg`](https://github.com/interest-protocol/memez-gg/tree/00596fdac4dd11f427c7bc594e566ce36160db93) |

The pinned handoff pattern is traced in
[`docs/research/memez-fun-migration-pattern.md`](../research/memez-fun-migration-pattern.md):
core selects the Meme liquidity balance before constructing the single-use
migration payload
(`fun/sources/pump.move:L194-L217`). The full partition comparison, including
every Memez.Fun bucket this ADR deliberately does not adopt, is
[`docs/research/memez-fun-migration-meme-partition.md`](../research/memez-fun-migration-meme-partition.md).

Memez.Fun keeps four economically distinct lines: the per-launch
`liquidity_provision` (destination-pool Meme principal), a configured
stakeholder Meme `allocation` distributed only after migration, a
Quote-denominated `migration` fee deducted before the handoff, and
adapter-owned XPump policy (migration caller reward, residual treasury, and
LP-fee routing). Blast adopts only the first of these as this provision. The
protocol Meme graduation allocation and the Quote migration fee remain the two
separate protocol-revenue lines fixed by ADR 0027 — Blast's Meme allocation is
protocol revenue, not a Memez-style stakeholder distribution — Blast grants no
creator or stakeholder supply allocation (ADR 0012), and any venue-side
reward, treasury, or LP-fee policy belongs to the future external migrator
package, never to core (ADRs 0010 and 0027).

Blast also rejects two Memez.Fun behaviors: the overloaded sentinel in which a
zero liquidity value means "provide the complete terminal curve inventory" —
in Blast, zero is exclusively the unconfigured state and can never be
snapshotted into a launch — and the terminal `@0x0` transfer that fakes a
burn. How the non-migrated terminal remainder is disposed of — genuinely
destroyed through the Coin Registry for a `BurnOnly` launch, or returned
through an explicitly accounted residual path for a `Fixed` launch — is
decided by the future migration ADR, not here.

## Context

ADR 0027 fixed two graduation accounting lines: the Quote migration fee
(protocol revenue) and the protocol Meme graduation allocation (protocol
revenue in Meme units). Neither line answers how much initial Meme supply is
reserved as the destination pool's Meme principal at migration. Without an
explicit rate, the future migration module would have to invent one — either
by migrating the entire terminal curve remainder or by reading a live value,
both of which ADR 0025/0027 forbid for cold launch policy.

The provision competes with the protocol allocation for the same initial
supply: whatever both reserve must still leave a positive share for curve
inventory, or bonding could never begin.

## Decision

### A third cold graduation rate

`LaunchConfig` gains one field and keeps its concern boundary:

```move
public struct LaunchConfig has key {
    id: UID,
    quotes: VecMap<TypeName, u64>,
    quote_migration_fee_bps: u64,
    meme_graduation_allocation_bps: u64,
    meme_liquidity_provision_bps: u64,
    migration_witnesses: VecSet<TypeName>,
}
```

`meme_liquidity_provision_bps` is the percentage of initial Meme supply, in
basis points, reserved before curve inventory as the destination pool's Meme
principal. This ADR fixes only that reservation policy and formula; the later
launch/migration ADRs define the actual `Balance<Meme>` custody and venue
handoff (see Deferred custody below). The reservation is never protocol
revenue, never a creator allocation, and never joins trade fees, pending burn,
or claims.

### Bounds and the unconfigured sentinel

- The configured range is **1 through 9,999 basis points** inclusive
  (`constants::max_meme_liquidity_provision_bps!()` = 9,999).
- Initialization writes **0**, which means only "not configured yet". A zero
  provision must never be interpreted as "migrate all terminal curve
  inventory"; that overloaded sentinel is rejected by design.
- The supply partition must keep curve inventory nonempty:
  `meme_graduation_allocation_bps + meme_liquidity_provision_bps < 10_000`.
- The Quote migration fee and protocol Meme allocation stay independently
  zero-safe under their existing 500 and 1,000 bps ceilings.

### One setter for the complete triple

`set_graduation_defaults` now updates the Quote migration fee, the protocol
Meme graduation allocation, and the Meme liquidity provision together, under
a borrowed `AdminWitness`, with this guard order:

1. Quote migration fee above its ceiling
   (`invalid_quote_migration_fee_bps`, code 47);
2. Meme graduation allocation above its ceiling
   (`invalid_meme_graduation_allocation_bps`, code 48);
3. Meme liquidity provision zero or above 9,999
   (`invalid_meme_liquidity_provision_bps`, code 59);
4. allocation plus provision leaving no curve inventory
   (`invalid_meme_supply_partition_bps`, code 60);
5. unchanged triple (`graduation_defaults_unchanged`, code 49).

Because the setter validates the provision as configured policy, it can never
store zero; the sentinel survives only from initialization until the first
successful configuration.

### Snapshot atomicity

The package-only `snapshot_for_launch<Quote, MigrationWitness>` returns the
complete cold policy in one read:

```move
(migration_quote_target, quote_migration_fee_bps,
 meme_graduation_allocation_bps, meme_liquidity_provision_bps,
 migration_witness_type_name)
```

Guard order: quote not admitted (`quote_not_allowed`, code 45), migration
witness not admitted (`migration_witness_not_allowed`, code 52), then
unconfigured provision (`invalid_meme_liquidity_provision_bps`, code 59). A
launch can therefore never snapshot a zero provision, and the five values a
launch stores are read from one consistent config state.

### Arithmetic, rounding, and conservation

The reserved pool principal is computed from the snapshotted rate as:

```text
meme_liquidity_provision
  = floor(initial_meme_supply * meme_liquidity_provision_bps / 10_000)
```

The product widens before division. Rounding is **floor**: the provision is
pool inventory rather than a protocol obligation, so the indivisible
remainder stays in curve inventory, where bonding buyers can reach it. This
deliberately differs from the two ceiling-rounded protocol obligations of
ADR 0027; value moved by rounding must never silently favor the protocol
here.

Supply conservation gains one named bucket:

```text
initial_meme_supply
  = curve_inventory
  + meme_graduation_allocation   (ceil, protocol revenue after migration)
  + meme_liquidity_provision     (floor, destination-pool principal)
  + every_other_approved_meme_bucket
```

Boundary behavior: the floor means a positive configured rate can still
reserve zero atomic units — the provision is zero whenever
`initial_meme_supply * meme_liquidity_provision_bps < 10_000` (at 1 bps, any
atomic supply below 10,000 units). The setter validates policy, not per-launch
supplies, and the BPS-level partition bounds alone do not guarantee a positive
rounded curve inventory for every small atomic supply once the ceiling-rounded
protocol allocation is applied. The future launch design must therefore
enforce both a positive atomic provision and a positive atomic curve
inventory — or an explicit minimum initial supply — after rounding. At 9,999
bps with a zero allocation the identity is exact:

```text
curve_inventory
  = initial_meme_supply - floor(initial_meme_supply * 9_999 / 10_000)
  = ceil(initial_meme_supply / 10_000)
```

The floor remainder is already inside that ceiling, not additional to it. The
partition guard makes 10,000 bps combined unreachable.

A snapshotted percentage makes the pool's Meme principal predictable and
reservable before bonding, but it does not by itself preserve the terminal
curve price at the destination venue: virtual Quote never migrates, the Quote
migration fee reduces the real Quote side, and a concentrated-liquidity venue
takes its opening price as an explicit input. The opening-price rule, venue
seeding formula, orientation, and residual handling are decided by the future
migration ADR; the partition research note derives the price-continuity
formula those decisions must confront.

### Deferred custody

No `Balance<Meme>` custody, launch bucket, or destination-pool call is
implemented by this ADR. This decision fixes only the reservation policy: cold
storage, bounds, guards, event schema, and the formula. The later
launch/migration ADRs define the actual `Balance` custody and the venue
handoff. Adding pool custody or a venue call before those ADRs are accepted
would violate the layering in `docs/architecture.md`.

### Event schema

`LaunchConfigCreated` gains `meme_liquidity_provision_bps` (initially 0) and
`GraduationDefaultsChanged` carries the complete old/new triple. Both remain
wrapped in the package `Event<T>` envelope with no application sequence,
schema version, action tag, or nonce. A replay consumer reconstructs the
effective policy of every launch from creation plus mutation facts alone.

## Alternatives considered

**Reuse zero as "migrate everything".** Rejected: one field would encode two
unrelated meanings, an unconfigured deployment would silently select the most
aggressive policy, and the historical sentinel is exactly the ambiguity this
ADR removes.

**Derive the provision from the terminal curve remainder.** Rejected: the
pool principal would then depend on trade history rather than snapshotted
policy, making launch economics unpredictable and unreplayable from
configuration facts.

**A separate setter for the provision.** Rejected: the three graduation
rates are validated against each other (the partition guard) and snapshotted
together; independent setters would allow transiently inconsistent triples
and double the privileged surface.

**Ceiling rounding like the protocol obligations.** Rejected: the provision
is not owed to the protocol. Flooring keeps the indivisible remainder in
curve inventory, preserving the rule that rounding favors the protocol only
for protocol obligations.

**Store the provision per quote entry.** Rejected: the provision partitions
Meme supply and is independent of the quote asset; per-quote copies would
multiply administration without adding policy expressiveness.

## Consequences

- `LaunchConfig` storage layout, `snapshot_for_launch` arity, and both event
  payloads change before any public release; no published ABI is broken.
- Launch creation gains a hard precondition: administrators must configure
  the graduation triple before the first launch can snapshot policy.
- Existing error codes keep their meanings; codes 59 and 60 are appended to
  the registry.
- Launch creation receives every economic rate it needs in one atomic
  snapshot read, preserving ADR 0025/0027 cold-policy semantics; which
  component holds the snapshotted state is defined by the later launch ADR.

## Verification

- Setter boundary tests: ceilings, ceiling-plus-one, zero and 9,999-plus-one
  provision, the exact partition boundary, and independent zero fee and
  allocation values.
- Guard-precedence tests: each simultaneously-invalid input pair asserts
  which of codes 47, 48, 59, 60, and 49 fires first.
- Snapshot tests: rejection of the unconfigured provision after quote and
  witness admission, and the atomic five-value return.
- Replay tests: creation and mutation events reconstruct the complete triple
  without reading state.
- Structural checks: `check_source_boundaries.sh` pins the exact struct
  layout, the setter and snapshot signatures, the 9,999 constant, and the
  zero-initialized defaults.
