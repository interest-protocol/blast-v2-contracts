# 0011: Event schema, replay, and the operation-to-rule checklist

- Status: proposed
- Date: 2026-08-22
- Amended by: [0019](0019-consuming-creator-authority-and-cap-return.md), [0020](0020-admin-cap-self-destruction.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@ae60d06` | `ae60d065ed27576d25ac1c94145e5ffe3ddcf89e` | MystenLabs/sui |
| `su@a3552af` | `a3552af11a531717378b6337a174f9340d1099dc` | interest-protocol/su-lending |

## Context

`../../AGENTS.md` requires that a consumer starting at deployment and replaying events in order can
reconstruct lifecycle, balances, configuration, fee state, allocation state, and migrations **without
reading mutable state**, and that mutation events carry stable identity, old/new or delta values, final
totals, and a sequence number where order is otherwise ambiguous.

Two Blast-specific facts raise the bar. During bonding the Coin Registry reports no supply, because
`total_supply` returns `none` while the state is `Unknown`
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/coin_registry.move:630-638`),
so **events are the only source of live supply**. And the quote risk snapshot is a launch-time reading
that can go stale ([ADR 0005](0005-quote-asset-generalisation.md)), so the event must say what was true
and when.

## Decision

### One generic Move envelope

Every Sui payload `T` is emitted as
`blast_fun::events_wrapper::Event<T>` through one package-only emitter, following
the current Su package
(`su@a3552af:packages/su/sources/lib/events_wrapper.move:1-17`). Indexers can
follow one stable Blast event family across package upgrades and discriminate
the inner payload type. The outer wrapper is indexing ABI; it does not remove
the need to version reducers when an inner payload schema changes.

The domain scopes below describe ordering and replay fields inside `T`; they are
not competing Move event types that bypass the generic wrapper.

### Three sequenced domain scopes and one meme-scoped fact

Not every event belongs to a launch. Global ACL, configuration and Display events are protocol-wide,
settlement events belong to an epoch in a separately governed package, and the one-time
`CreatorCapClaimed` fact follows the unique meme type into integrations beyond the launch lifecycle.
Forcing one sequenced domain scope on all payloads would require fabricated or redundant identifiers and make a
single sequence counter a global write contention point. Each mutable domain therefore has its own
**independently gapless, monotonic** sequence; the at-most-once meme fact needs no counter.

| Domain scope | Fields | Sequence scope | Emitted by |
| --- | --- | --- | --- |
| **per-launch** | `launch_id`, `meme_type`, `quote_type`, `launch_seq`, `timestamp_ms` | strictly increasing and gapless **per launch**, starting at 0 on `LaunchCreated` | `blast_fun` launch, curve, fee, migration paths |
| **global** | `config_id`, `global_seq`, `timestamp_ms` | strictly increasing and gapless **per shared `Config` object** | `blast_fun` ACL, configuration, Display, adapter-approval, X-claim signer paths |
| **epoch** | `epoch_id`, `quote_type`, `epoch_seq`, `timestamp_ms` | strictly increasing and gapless **per epoch** | `blast_fun_revshare` |
| **per-meme fact** | original meme `TypeName` | no sequence; at most one claim fact per generated meme type | `blast_fun` creator authority |

The three sequences are independent. A consumer orders **within** a scope by its sequence and **across**
scopes by transaction digest and checkpoint, never by comparing a `launch_seq` with a `global_seq`.

ADR 0018 further separates global administration from X signer configuration. ACL payloads use the
`ProtocolAuthority` identity, while X signer payloads use the `XClaimConfig` identity; each shared object
has its own replay scope and neither creation payload pretends the objects share storage.

Two payloads deliberately carry fields from more than one domain scope because they genuinely belong to two domains:

- `CreatorFeeSplitSet` carries the per-launch envelope (it changes one launch's fee routing) and repeats
  the `config_id` bound that constrained it;
- `EpochFunded` carries the epoch envelope and repeats `launch_ids`, the set it settles for, when the
  epoch is launch-scoped rather than protocol-wide.

### Event catalogue

Domain column: **L** per-launch, **G** global, **E** epoch, **M** per-meme fact.

| Event | Env | Key fields beyond the envelope |
| --- | :---: | --- |
| `LaunchCreated` | L | creator-identity kind and either creator address or `x_identity_hash`, `V`, `T`, `M0`, total supply, `meme_decimals`, `quote_decimals`, full quote risk snapshot (regulated **tri-state**, deny cap id, supply state, quote total supply, treasury/metadata cap state, symbol and name hashes), fee configuration, route params, reservation id if any |
| `Bought` | L | `quote_in_gross`, `quote_fee`, `quote_in_net`, `meme_out`, `M'`, `Q'`, `crossed_threshold` |
| `Sold` | L | `meme_in`, `progress_bps`, `burn_bps`, `meme_burned`, `meme_in_effective`, `quote_out_gross`, `quote_fee`, `quote_out_net`, `M'`, `Q'` |
| `MemeBurnedOnCurve` | L | `amount`, `burn_bps`, `progress_bps`, `total_supply_after` |
| `MemeBurnedAtMigration` | L | `amount`, `total_supply_after` |
| `SupplyStateChanged` | L | `old_state`, `new_state`, `final_total_supply` |
| `FeesAccrued` | L | `protocol_delta`, `creator_delta`, `protocol_total`, `creator_total` |
| `CreatorFeesClaimed` / `ProtocolFeesClaimed` | L | `amount`, `remaining_total`, recipient |
| `CreatorFeeSplitSet` | L | `recipients` (bounded vector), `shares_bps`, `old_recipients`, `old_shares_bps`, `remainder_beneficiary`, `max_recipients_bound`, `config_id` |
| `LpFeesCollected` | L | `venue`, `pool_id`, `position_id`, `lp_vault_id`, `meme_collected`, `quote_collected`, `creator_share`, `protocol_share`, `principal_liquidity_before`, `principal_liquidity_after` |
| `CreatorContributed` | L | `quote_amount`, `meme_received`, `Q'` — distinguishes creator-supplied progress from market progress |
| `ContributionClaimRecorded` | L | contributor, asset, amount, claim owner, withdrawal conditions |
| `MetadataUpdated` | L | field, `old_value`, `new_value` |
| `MetadataFrozen` | L | metadata cap id |
| `CreatorCapClaimed` | M | creator address, optional X identity commitment, optional X expiry |
| `ProtocolAuthorityCreated` | G | authority id, initial root-cap id and recipient, admin bound, root-transfer delay |
| `AdminAdded` | G | authority id, admin-cap id, recipient |
| `AdminRevoked` | G | authority id and admin-cap id; membership removed while the cap object may remain |
| `AdminDestroyed` | G | authority id, admin-cap id, `was_active`; cap deleted and membership absent afterward |
| `XClaimConfigCreated` | G | disabled shared signer configuration id |
| `RouteSelected` | L | route A/B/C, venue, tick spacing, fee rate, orientation, target sqrt price, `reservation_id` |
| `ReservationReleased` | L | `venue`, `reservation_id`, `tick_spacing`, `orientation`, reason |
| `MigrationBegun` | L | payload id, `M`, `Q` at handoff |
| `MigrationAborted` | L | reason code, route attempted, retry window remaining, `reservation_still_held` |
| `Migrated` | L | venue, pool id, position id, `LpVault` id, amounts deployed, residuals returned, migration fee, final sqrt price |
| `RecoveryEntered` | L | reason, governing policy id |
| `DisplayFieldSet` | G | type name, key, `old_value`, `new_value` |
| `ConfigChanged` | G | parameter, `old_value`, `new_value`, ceiling |
| `Paused` / `Unpaused` | G | scope, reason code |
| `VersionBumped` | G | `old_version`, `new_version` |
| `AdapterApproved` / `AdapterRevoked` | G | witness type name |
| `XClaimSignerSet` / `XClaimSignerRevoked` | G | previous public key and, for set/rotation, current public key; no key id or active flag |
| `EpochOpened` | E | quote type, `MAX_EPOCH_LEAVES`, `MAX_EPOCH_FUNDED`, dust policy, `scope` (`protocol` or `launch_scoped`), `launch_ids` (empty when `scope` is `protocol`) |
| `EpochFunded` | E | `funded_delta`, `funded_total`, `launch_ids` (the launch-scoped set this epoch settles for; empty when the epoch scope is `protocol`) |
| `RootPublished` | E | root, `leaf_count`, `claimable_cap`, challenge window end, root-commitment kind |
| `RootReplaced` | E | `old_root`, `new_root` |
| `Claimed` | E | `leaf_index`, recipient, amount, `cumulative_claimed`, `funded_total` |
| `EpochSwept` | E | `swept_amount`, destination, `cumulative_claimed`, `funded_total` |

### Rules the catalogue enforces

- Events are named as **completed facts in past tense** and emitted **after** the final state is known.
- An X identity commitment appears only in `LaunchCreated` and
  `CreatorCapClaimed`. No economic path reads a handle, and no raw X credential
  enters state or events ([ADR 0013](0013-creator-fee-authority-and-x-claims.md)).
- Each event carries exactly one primary envelope; the two dual-domain events above repeat the secondary
  identifier as an ordinary field, never as a second sequence. The meme fact is keyed by original
  `TypeName` and has no launch id or sequence because it can be emitted only once.
- The quote risk snapshot is emitted once, at `LaunchCreated`, and is explicitly a launch-time reading;
  an indexer wanting current risk must additionally watch the live `Currency<Quote>`.
- Every burn is a named term with the resulting total supply, so supply is reconstructable during bonding
  when the registry reports none.
- Field changes are schema migrations and require a replay test
  (`../../AGENTS.md`).

### Reconstructable state

A reducer over the stream must reproduce, without reading any object:

`M`, `Q`, total supply, cumulative burned by moment, accrued and claimed fees per recipient, the current
creator fee split and its remainder beneficiary, cumulative LP fees collected and their split, lifecycle
state, pause and version state, configuration and its ceilings, creator authority, contribution claims,
route, reservation and reservation-release state, migration settlement, and per-epoch RevShare funding,
claims, and sweeps.

Sequence reconstruction is per scope: `launch_seq` gapless within each launch, `global_seq` gapless per
`Config`, `epoch_seq` gapless per epoch. A reducer that assumes one global ordering across the three is
wrong by construction. `CreatorCapClaimed` is reduced as one immutable fact keyed by meme type.

### Operation-to-rule checklist

| Operation | Validate before mutate | Replay-complete | Immutable deps | Bounded state | Composable | Exact failures |
| --- | --- | --- | --- | --- | --- | --- |
| `prepare` | guard order test | `LaunchCreated` | core has no venue dep | ticket consumed, no growth | returns values | named aborts per field |
| `reserve` (adapter) | cap-id and digest checks | `RouteSelected` | vendored SHA pin | no new collection | returns values | named aborts |
| `finish` | supply, cap, inventory, witness, digest | `LaunchCreated` | core has no venue dep | one `Launch` per ticket | returns `Launch` | named aborts per check |
| `buy` | version, pause, state, slippage, non-zero out | `Bought` | none | none | returns `Coin<Meme>` | `EZeroOutput`, slippage, deadline |
| `sell` | version, pause, state, burn, slippage, non-zero out | `Sold`, `MemeBurnedOnCurve` | none | none | returns `Coin<Quote>` | `EZeroOutput`, slippage, deadline |
| claim fees | capability, accrued only | `*FeesClaimed` | none | none | returns coin | `ENotAuthorized`, `ENothingAccrued` |
| set creator fee split | capability, recipient count, share sum | `CreatorFeeSplitSet` | none | fixed `MAX_FEE_RECIPIENTS` | n/a | `ETooManyRecipients`, `ESharesNotWhole` |
| collect LP fees | capability, vault-locked position | `LpFeesCollected` | vendored SHA pin | none | returns coins | `ENotAuthorized`, `EPositionNotInVault` |
| release reservation | capability, reservation exists | `ReservationReleased` | vendored SHA pin | frees the reservation slot | n/a | `ENoReservation`, `EWrongVenue` |
| metadata update | capability, bonding only | `MetadataUpdated` | none | none | n/a | `EMetadataFrozen` |
| creator-cap claim | consume `CreatorAuthority`; address equality with no attestation, or X backend signature/domain/expiry/active signer | `CreatorCapClaimed` | none | removes one authority | returns `CreatorCap` | address/X branch and structural consumption tests |
| destroy admin cap | owned cap; membership lookup cannot block deletion | `AdminDestroyed` | none | removes one membership if present and deletes cap | n/a | active and already-revoked branches |
| `begin_migration` | state, threshold, single-use | `MigrationBegun` | core has no venue dep | one payload | returns payload | `EMigrationAlreadyBegun` |
| adapter settle | acceptance band, orientation, range | `RouteSelected` | vendored SHA pin | none | returns settlement | band and range aborts |
| `settle_migration` | witness, single-use, ordering | `Migrated`, `MemeBurnedAtMigration`, `SupplyStateChanged`, `MetadataFrozen` | core has no venue dep | one settlement | returns `LpVault` | `EAlreadyMigrated` |
| admin setters | capability, ceiling | `ConfigChanged` | none | none | n/a | `EAboveCeiling` |
| pause / version | capability | `Paused`, `VersionBumped` | none | none | n/a | `ENotAuthorized` |
| revshare publish | cap, leaf and funding bounds, claimable cap | `RootPublished` | none | fixed bitmap | n/a | `ETooManyLeaves`, `EEpochOverfunded` |
| revshare claim | root final, index range, bitmap | `Claimed` | none | fixed bitmap | returns coin | `EAlreadyClaimed`, `ELeafIndexOutOfRange` |
| revshare sweep | expiry, not swept | `EpochSwept` | none | frees a slot | n/a | `ENotExpired`, `EAlreadySwept` |

## Alternatives considered

**Emit deltas only.** Rejected: an indexer joining late, or one that drops a message, cannot recover.
Final totals make each event self-reconciling.

**Store social handles on-chain for indexer convenience.** Rejected: mutable identity in economic state
([ADR 0008](0008-creator-identity-and-claims.md)). Discovery events serve the same purpose.

**Rely on the Coin Registry for supply.** Rejected: it reports `none` during bonding, exactly when a
launch is most actively indexed.

**One combined trade event.** Rejected: buy and sell have different fields and different burn semantics,
and a shared shape would carry unused fields in half the stream.

**A single envelope with one global sequence.** Rejected on two grounds. A protocol-wide configuration
change has no `launch_id`, so the field would have to be fabricated; and a single monotonic counter
across all launches would make every trade contend on one shared field, which is a throughput cost paid
for nothing an indexer needs.

## Consequences

- Indexers can rebuild everything from events; object reads become an optimisation, not a requirement.
- Adding or changing any field above is a schema migration requiring a replay test.
- The event stream is wide; that cost is accepted because `../engineering-principles.md` treats events as
  the accounting interface rather than as notifications.

## Verification

- Reducer replay test: reconstruct final state from events alone and compare field-by-field with object
  state, for a sequence covering launch, many trades, both burn moments, threshold crossing, a creator
  fee-split change, a failed migration with retry **including reservation release on venue switch**, a
  successful migration, LP fee collection, and a full RevShare epoch.
- Field-level assertions on every event in the catalogue.
- Sequence tests, one per scope: `launch_seq` strictly increasing and gapless within a launch,
  `global_seq` within a `Config`, `epoch_seq` within an epoch; plus a negative test asserting the reducer
  does not order across scopes by sequence.
- Fee-split reducer test: after a `CreatorFeeSplitSet`, replayed per-recipient entitlements equal object
  state, and the remainder beneficiary receives exactly the rounding residue.
- LP-fee reducer test: cumulative `LpFeesCollected` reconciles with the vault balances, and
  `principal_liquidity_before == principal_liquidity_after` in every collection.
- Supply-reconstruction test: cumulative burns from events equal the final registry `total_supply` after
  the supply state becomes `BurnOnly`.
- Schema-migration test: a changed field fails the replay test until the reducer is updated.
