# 0027: Graduation economics and migration witnesses

- Status: accepted
- Date: 2026-08-24
- Amends: [0006](0006-fees-and-launch-paths.md), [0010](0010-migration-and-venue-adapters.md), [0011](0011-event-schema-and-replay.md), [0022](0022-dual-asset-fee-ledger-and-claims.md), [0025](0025-quote-whitelist-and-migration-targets.md)
- Preserved by: [0028](0028-hot-cold-runtime-configuration.md)

> Amended by [ADR 0033](0033-meme-liquidity-provision.md): `LaunchConfig` gains a
> third cold rate, the nonzero destination-pool
> `meme_liquidity_provision_bps`. The graduation setter updates the complete
> triple and rejects an unchanged triple, the package-only snapshot returns
> five values, and the exact struct layout and snapshot list quoted below are
> the pre-0033 forms.
> Amended by [ADR 0039](0039-deterministic-quote-valuations.md): the per-Quote
> virtual reserve joins the launch snapshot, while an off-chain SDK derives
> exact-target release and Quote-denominated valuation previews.
> Amended by [ADR 0043](0043-versioned-launch-trading-and-atomic-migration.md):
> `launch::migrate` now implements the selected-witness core handoff and the
> two supply-mode disposal paths; venue adapters remain separate packages.
> The exact quote registry representation is amended by
> [ADR 0062](0062-table-backed-quote-registry.md): quotes use an uncapped
> `Table`, while migration witnesses retain their independent 16-entry bound.
> Amended by
> [ADR 0046](0046-witness-authorized-migration-redemption.md): any caller may
> create the type-bound handoff, while redemption requires the selected sealed
> witness value.

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| Memez.Fun migration authorization | `00596fdac4dd11f427c7bc594e566ce36160db93` | [`interest-protocol/memez-gg`](https://github.com/interest-protocol/memez-gg/tree/00596fdac4dd11f427c7bc594e566ce36160db93) |

The pinned pattern is traced in
[`docs/research/memez-fun-migration-pattern.md`](../research/memez-fun-migration-pattern.md).
It confirms that core can allowlist an external package's sealed witness type,
snapshot exactly one selected `TypeName` into each launch, and later require a
value of that type to unlock a linear migration payload. The DEX migrator is a
separate package depending inward on core.

## Context

Graduation needs two independent protocol policies: how much terminal Quote
becomes Blast revenue and how much initial Meme supply is reserved for Blast.
They are cold settings selected when a launch is created, unlike the live trade
fee split read on every trade.

Core also needs to know which external migration implementations may receive a
launch's assets without importing any DEX. A caller address is not sufficient:
authorization belongs to the adapter code that knows how to complete a specific
venue integration.

DEX pool-opening charges are not part of the Blast product. A venue requiring a
separate creation payment will not be integrated. Consequently core has no
venue-cost amount, fee-asset type, third coin, external payer, reimbursement, or
refund lifecycle.

## Decision

### Two graduation accounting lines

1. **Quote migration fee.** A percentage of gross real terminal `Quote`, stored
   as protocol revenue only after successful migration. It is SUI only when
   `Quote` is SUI. Zero disables it.
2. **Protocol Meme graduation fee.** A percentage of initial `Meme` supply,
   separated before curve inventory is established. It is initially protocol
   owned and becomes claimable only after successful migration. Zero disables
   it.

No event, balance, getter, or claim may relabel one line as another. Neither line
is a DEX cost or part of the four-balance trade-fee ledger.

### One cold launch-policy object

`LaunchConfig` remains concern-specific and must not absorb ACL membership, the
X signer, live trade-fee state, launch balances, DEX objects, or adapter state.
It stores exactly:

```move
public struct LaunchConfig has key {
    id: UID,
    quotes: Table<TypeName, u64>,
    quote_migration_fee_bps: u64,
    protocol_meme_graduation_fee_bps: u64,
    migration_witnesses: VecSet<TypeName>,
}
```

The quote Table has no protocol cardinality cap, while the migration-witness
set retains its independent limit of 16 entries. Quote entries map an original
quote type to its nonzero migration target. Migration-witness entries contain
original type identities only; they contain no amount, route
configuration, DEX object, or address.

All public mutations borrow `AdminWitness`. Graduation defaults update together,
reject either value above its hard ceiling, reject an unchanged pair, and allow
zero independently. Witness admission rejects duplicates and capacity overflow;
disallowing rejects a missing type. Every successful mutation emits a wrapped
typed event.

### One migrator selected per launch

Launch creation is generic over `Quote` and `MigrationWitness`. The package-only
snapshot function:

1. verifies that `Quote` is admitted;
2. verifies that the selected migration witness type is admitted;
3. returns the quote target, both graduation rates, and the witness's original
   `TypeName`.

The launch stores those four values. It never reads `LaunchConfig` again.
Disallowing a witness prevents future launches from selecting it but does not
rewrite or strand launches that already selected it. This is intentional cold
policy, matching the pinned Memez.Fun pattern.

The witness type must have `drop`. A supported external migrator module owns a
sealed `public struct Witness() has drop` and exposes no public constructor.
Move's module-private construction rule makes a witness value proof that the
selected adapter code is executing; it is not proof about the transaction
sender.

### Core and migrator package boundary

The future core migration module owns a non-copyable, non-droppable, non-storable
handoff containing only core identity and the Meme/Quote migration balances. At
graduation it creates that handoff with the launch's selected witness `TypeName`.
The handoff can be consumed only by supplying a droppable witness value whose
original type matches the stored type.

Every DEX migrator is a separate Move package:

```text
DEX package
    ^ dependency
external migrator package  ------>  Blast core
  owns sealed Witness                owns TypeName whitelist
  owns DEX calls                     owns linear asset handoff
```

The external package depends on Blast core and its DEX interface. Blast core
never depends on either. Anyone may drive a permissionless migration transaction,
but only the selected adapter module can construct the witness required to
release the handoff.

### No pool-opening fee policy

Supported DEXs must permit pool creation without a protocol-level pool-opening
charge. Ordinary transaction gas is paid through the normal Sui transaction gas
budget and is not launch accounting.

Core and adapters must not introduce:

- venue-cost policies or maximum-cost fields;
- a DEX fee coin or third asset;
- an external fee payer;
- reimbursement or refund state; or
- a deduction from terminal Quote presented as a DEX cost.

If a future venue requires any such payment, that venue is unsupported unless a
new explicit product decision replaces this one.

### Launch snapshot and custody

`Launch<Meme, Quote>` stores immutable copies of:

- `migration_quote_target`;
- `quote_migration_fee_bps`;
- `protocol_meme_graduation_fee_bps`; and
- selected migration-witness original `TypeName`.

At launch, the complete initial Meme supply is divided into explicitly named
buckets. The protocol Meme graduation fee is calculated before curve construction and
held in its own `Balance<Meme>`. It never enters curve inventory, pending burn,
trade fees, migration inventory, or creator claims. Launch creation rejects a
configuration that leaves zero valid curve inventory after all approved supply
buckets.

### Arithmetic and rounding

The approved formulas are:

```text
protocol_meme_graduation_fee
  = ceil(initial_meme_supply * protocol_meme_graduation_fee_bps / 10_000)

quote_migration_fee
  = ceil(gross_terminal_quote * quote_migration_fee_bps / 10_000)
```

Both products widen before division. Ceiling rounding assigns an indivisible
unit to the protocol obligation, consistent with ADR 0022. Zero rates produce
zero without a special mode.

### Migration ordering and exactly-once charging

One migration attempt uses the single-use core handoff. The atomic transaction
performs these conceptual steps:

1. validate lifecycle and the selected witness type;
2. derive the Blast Quote fee from gross terminal Quote;
3. isolate net Quote and the distinct protocol-revenue balance;
4. burn accumulated pending Meme for `BurnOnly` launches;
5. redeem the handoff with the selected external migrator's sealed witness;
6. create the venue pool and seed it with net Meme and Quote;
7. return every named residual and settlement identity to core;
8. commit protocol revenue and `Migrated` state; and
9. emit final replay-complete facts.

An adapter abort rolls back the entire transaction. The Blast fee does not become
claimable, pending burn is not destroyed, and no second migration right is
created. The Quote migration fee is committed exactly once, on the successful
transition to `Migrated`.

### Claims

The initial ownership policy is protocol-only. After successful migration, one
public launch function borrows `AdminWitness`, drains the source-specific
protocol Meme graduation fee and Quote migration revenue, and returns
`(Coin<Meme>, Coin<Quote>)`. It accepts no recipient and performs no transfer.
Claiming before `Migrated`, or while both balances are empty, aborts with a named
error.

### Required event accounting

Configuration events expose config identity, complete old/new graduation
defaults, and allowed or disallowed migration witness types. `LaunchCreated`
exposes all immutable effective snapshots. Successful migration events expose at
least:

- original Meme, Quote, and migration-witness types;
- gross terminal Meme and Quote balances;
- Quote migration fee and final protocol-claimable Quote total;
- reserved Protocol Meme graduation fee and final protocol-claimable Meme total;
- pending Meme burned and resulting supply;
- net Meme and Quote seeded;
- named Meme and Quote residuals; and
- venue pool, position, and LP-vault identities.

Native Sui event position supplies ordering. No application sequence, schema
version, action tag, or nonce is added.

### Conservation

Every successful launch and migration satisfies separate asset identities:

```text
gross_terminal_quote - quote_migration_fee
  = quote_seeded + quote_residual

initial_meme_supply
  = curve_inventory
  + protocol_meme_graduation_fee
  + meme_outstanding
  + meme_trade_fees
  + pending_burn
  + every_other_approved_meme_bucket

gross_terminal_migration_meme
  = meme_seeded + pending_burn_destroyed + meme_residual
```

The event-only reducer must reproduce every term without reading mutable state.

## Accepted settings

| Decision | Accepted behavior |
| --- | --- |
| Quote migration-fee ceiling | **500 bps (5%)** |
| Protocol Meme graduation-fee ceiling | **1,000 bps (10%)** |
| Initial defaults | **zero/zero** |
| Initial ownership | **protocol-only**; creator/community ownership and vesting remain deferred |
| Rounding | **ceiling** for both protocol obligations |
| Migration authorization | at most 16 external witness types; each launch selects exactly one |
| Witness update scope | future launches only; selected types are immutable per launch |
| DEX pool-opening cost | **unsupported**; no core or adapter fee field |

## Alternatives considered

**A separate shared `GraduationConfig`.** Rejected: graduation defaults are
co-read with quote and migrator admission only at launch.

**Put graduation defaults in `TradeFeeConfig`.** Rejected: graduation values are
snapshotted once, while the protocol/creator trade split is read live on every
trade.

**Whitelist migrator addresses.** Rejected: caller identity does not prove which
adapter code receives and settles the assets. A sealed witness authorizes module
code identity.

**Import DEX packages into core.** Rejected: it couples the core upgrade and
dependency graph to every venue. External packages depend inward instead.

**Store all allowed routes in every launch.** Rejected: a launch selects one
implementation from the current whitelist, matching the reference pattern and
keeping launch state bounded to one `TypeName`.

**Add a venue-cost or third-asset field.** Rejected: supported DEXs do not charge
to open pools. A fee-charging venue will not be used.

## Consequences

- Existing launches cannot be repriced or retargeted by later admin updates.
- Migrator removal is not an emergency revocation mechanism for existing
  launches; an explicit recovery design would require a separate decision.
- Protocol graduation revenue remains capability-claimed and composable.
- Core stays free of DEX dependencies, DEX costs, and third assets.
- Core migration is implemented as the launch-owned linear handoff. External
  migrator packages remain separate audit slices, one venue at a time.

## Verification

Implementation proceeds one seam at a time:

1. `LaunchConfig`: zero/one/both graduation defaults, both ceilings and ceiling
   plus one, unchanged setters, Table-backed quote growth, bounded witnesses, duplicate
   and missing types, future-only removal, original type names, complete wrapped
   events, and exact guards.
2. Pure graduation arithmetic and custody: one-unit and maximum-width rounding,
   zero remaining inventory, four enablement combinations, and independent
   conservation.
3. Launch integration: protocol Meme graduation fee reserved before curve
   inventory, immutable quote/fee/witness snapshots, native supply-mode event
   history, and complete `LaunchCreated` facts.
4. Core migration handoff: selected-witness mismatch, linear consumption,
   atomic retry, no double charging, terminal burn, residuals, and event-only
   reconstruction.
5. One external migrator package: sealed witness, permissionless driver, no
   pool-opening payment, pool/position/LP-vault identities, orientation, and
   dependency release gate from ADR 0010.

Every slice must pass build, warning-as-error lint, complete Move tests, 100%
coverage, structural boundaries, shared vectors, and `git diff --check` before
review.
