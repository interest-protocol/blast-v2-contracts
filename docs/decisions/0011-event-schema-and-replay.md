# 0011: Event schema, replay, and the operation-to-rule checklist

- Status: proposed
- Date: 2026-08-22
- Amended by: [0019](0019-consuming-creator-authority-and-cap-return.md), [0020](0020-admin-cap-self-destruction.md), [0022](0022-dual-asset-fee-ledger-and-claims.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@ae60d06` | `ae60d065ed27576d25ac1c94145e5ffe3ddcf89e` | MystenLabs/sui |
| `sui@06734f6` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` | MystenLabs/sui |
| `su@a3552af` | `a3552af11a531717378b6337a174f9340d1099dc` | interest-protocol/su-lending |

## Context

`../../AGENTS.md` requires that a consumer starting at deployment and replaying events in order can
reconstruct lifecycle, balances, configuration, fee state, allocation state, and migrations **without
reading mutable state**, and that mutation events carry stable identity, old/new or delta values, final
totals, and a sequence number where order is otherwise ambiguous.

Blast's generated currency enters core only after its supply is irreversibly
`Fixed` or `BurnOnly` under ADR 0023. Events still carry initial and final supply
facts so indexers can reconcile every burn without reading mutable state.

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

### Native Sui order and four replay scopes

Not every event belongs to a launch. Global ACL, configuration and Display events are protocol-wide,
settlement events belong to an epoch in a separately governed package, and the one-time
`CreatorCapClaimed` fact follows the unique meme type into integrations beyond the launch lifecycle.
Sui already identifies an event by transaction digest plus its per-transaction event index at the pinned
revision, while current event delivery additionally exposes checkpoint and transaction position. A
protocol payload must not duplicate that native ordering with a stored counter merely for pagination,
gap detection, or replay. See
[`../research/sui-event-ordering-and-domain-sequences.md`](../research/sui-event-ordering-and-domain-sequences.md).

| Domain scope | Identity and replay fields | Ordering | Emitted by |
| --- | --- | --- | --- |
| **per-launch** | original meme and quote `TypeName`, plus timestamp when the domain needs it | native checkpoint, transaction, and event position | `blast_fun` launch, curve, claim, migration paths |
| **global** | concern-owning shared object id | native checkpoint, transaction, and event position | `blast_fun` ACL, configuration, Display, adapter-approval, X-claim signer paths |
| **epoch** | `epoch_id` and quote type | native checkpoint, transaction, and event position | `blast_fun_revshare` |
| **per-meme fact** | original meme `TypeName` | native position; at most one claim fact per generated meme type | `blast_fun` creator authority |

Replay continuity comes from stable entity identity together with old/new values, exact deltas, or final
snapshots. A domain counter is added only if it is itself business state or native position cannot order
the relevant transitions; that exception requires an explicit ADR.

ADR 0018 further separates global administration from X signer configuration. ACL payloads use the
`ProtocolAuthority` identity, while X signer payloads use the `XClaimConfig` identity; each shared object
has its own replay scope and neither creation payload pretends the objects share storage.

One payload deliberately carries fields from more than one domain scope because it genuinely belongs to two domains:

- `EpochFunded` carries the epoch envelope and repeats `meme_types`, the launch set it settles for, when the
  epoch is launch-scoped rather than protocol-wide.

### Event catalogue

Domain column: **L** per-launch, **G** global, **E** epoch, **M** per-meme fact.

| Event | Env | Key fields beyond the envelope |
| --- | :---: | --- |
| `LaunchCreated` | L | creator-identity kind and either creator address or `x_identity_hash`, `V`, `T`, `M0`, total supply, fixed/burnable supply mode, `meme_decimals`, `quote_decimals`, fixed `quote_fee_bps` and `meme_fee_bps`, all four initial fee-ledger totals, route params, reservation id if any |
| `Bought` | L | `quote_in_gross`, `quote_fee`, `quote_in_net`, `meme_out_gross`, `meme_fee`, `meme_out_net`, applied `protocol_fee_share_bps`, meme/quote `protocol_fee_delta` and `creator_fee_delta`, all four final fee-ledger totals, `M'`, `Q'`, `crossed_threshold` |
| `Sold` | L | `meme_in_gross`, `meme_fee`, `meme_in_after_fee`, `progress_bps`, `burn_bps`, `pending_burn_delta`, `pending_burn_total`, `meme_in_effective`, `quote_out_gross`, `quote_fee`, `quote_out_net`, applied `protocol_fee_share_bps`, meme/quote `protocol_fee_delta` and `creator_fee_delta`, all four final fee-ledger totals, `M'`, `Q'` |
| `MemeBurnedAtMigration` | L | `amount`, `total_supply_after` |
| `SupplyStateChanged` | L | `old_state`, `new_state`, `final_total_supply` |
| `CreatorFeesClaimed` / `ProtocolFeesClaimed` | L | both claimed amounts, both affected remaining totals, claimant |
| `LpFeesCollected` | L | `venue`, `pool_id`, `position_id`, `lp_vault_id`, `meme_collected`, `quote_collected`, `creator_share`, `protocol_share`, `principal_liquidity_before`, `principal_liquidity_after` |
| `CreatorContributed` | L | `quote_amount`, `meme_received`, `Q'` — distinguishes creator-supplied progress from market progress |
| `ContributionClaimRecorded` | L | contributor, asset, amount, claim owner, withdrawal conditions |
| `MetadataUpdated` | L | field, `old_value`, `new_value` |
| `MetadataFrozen` | L | metadata cap id |
| `CreatorCapClaimed` | M | creator address, optional X identity commitment, optional X expiry |
| `LaunchTicketCreated` | M | ticket id, original meme type, treasury-cap id, metadata-cap id, launcher, address-or-X creator identity, burnable selection |
| `ProtocolAuthorityCreated` | G | authority id, initial root-cap id and recipient, admin bound, root-transfer delay |
| `AdminAdded` | G | authority id, admin-cap id, recipient |
| `AdminRevoked` | G | authority id and admin-cap id; membership removed while the cap object may remain |
| `AdminDestroyed` | G | authority id, admin-cap id, `was_active`; cap deleted and membership absent afterward |
| `XClaimConfigCreated` | G | disabled shared signer configuration id |
| `TradeFeeConfigCreated` | G | shared fee-config id and initial `protocol_fee_share_bps` |
| `ProtocolFeeShareChanged` | G | shared fee-config id and old/new `protocol_fee_share_bps` |
| `LaunchConfigCreated` | G | shared launch-config id, quote and migration-witness bounds, and zero-safe initial graduation defaults |
| `QuoteAllowed` | G | shared config id, original quote type, initial migration quote target |
| `QuoteMigrationTargetChanged` | G | shared config id, original quote type, old/new migration quote target |
| `QuoteRemoved` | G | shared config id, original quote type, previous migration quote target |
| `GraduationDefaultsChanged` | G | shared config id and complete old/new Quote-fee and Meme-allocation pairs |
| `MigrationWitnessAllowed` | G | shared config id and admitted external migrator witness original type |
| `MigrationWitnessRemoved` | G | shared config id and removed external migrator witness original type |
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
| `EpochOpened` | E | quote type, `MAX_EPOCH_LEAVES`, `MAX_EPOCH_FUNDED`, dust policy, `scope` (`protocol` or `launch_scoped`), `meme_types` (empty when `scope` is `protocol`) |
| `EpochFunded` | E | `funded_delta`, `funded_total`, `meme_types` (the launch-scoped set this epoch settles for; empty when the epoch scope is `protocol`) |
| `RootPublished` | E | root, `leaf_count`, `claimable_cap`, challenge window end, root-commitment kind |
| `RootReplaced` | E | `old_root`, `new_root` |
| `Claimed` | E | `leaf_index`, recipient, amount, `cumulative_claimed`, `funded_total` |
| `EpochSwept` | E | `swept_amount`, destination, `cumulative_claimed`, `funded_total` |

### Rules the catalogue enforces

- Events are named as **completed facts in past tense** and emitted **after** the final state is known.
- An X identity commitment appears only in `LaunchTicketCreated`, `LaunchCreated`, and
  `CreatorCapClaimed`. No economic path reads a handle, and no raw X credential
  enters state or events ([ADR 0013](0013-creator-fee-authority-and-x-claims.md)).
- Each event carries exactly one primary envelope; the two dual-domain events above repeat the secondary
  identifier as an ordinary field. Payloads do not duplicate Sui's native event position. The meme fact
  is keyed by original `TypeName` and can be emitted only once.
- During bonding, `Sold` records pending-burn custody rather than claiming that
  supply decreased. The one terminal burn is a named fact with resulting total
  supply; fixed launches have neither pending burn nor a burn event.
- `Bought` and `Sold` are the sole fee-accrual facts. Each contains the split deltas and post-accrual
  totals plus the live global percentage applied; no second event describes the same mutation.
- The fee-share configuration has its own global replay scope. Its update affects the next accrual of
  every launch, while already-accrued balances remain unchanged.
- Claim events identify the claimant but not a payout recipient because the claimed coins are returned.
  Final coin routing and current `CreatorCap<Meme>` custody are native transaction/object-ownership
  facts, not protocol event state.
- Field changes are schema migrations and require a replay test
  (`../../AGENTS.md`).

### Reconstructable state

A reducer over the stream must reproduce, without reading any object:

`M`, `Q`, pending burn, total supply, terminal burn, accrued and claimed
creator/protocol fees in both assets, the current global protocol fee share,
the active quote whitelist and targets, cumulative LP fees collected and their
split, lifecycle state, pause and version state, configuration and its ceilings,
creator-authority issuance, contribution claims, route, reservation and
reservation-release state, migration settlement, and per-epoch RevShare
funding, claims, and sweeps.

Two deliberately non-indexable custody facts remain outside the protocol event reducer: the current
owner of a transferable `CreatorCap<Meme>` and the final recipients of coins returned by a claim. Both
are available from native Sui object ownership and transaction effects. The protocol stream records
cap issuance, claimant identity, claimed amounts, and the resulting accounting state.

Reducers process native Sui event order and partition state by the stable identity carried in each
payload. Old/new continuity and final snapshots expose dropped or misapplied domain transitions without
adding counters to protocol storage. `CreatorCapClaimed` is reduced as one immutable fact keyed by meme
type.

### Operation-to-rule checklist

| Operation | Validate before mutate | Replay-complete | Immutable deps | Bounded state | Composable | Exact failures |
| --- | --- | --- | --- | --- | --- | --- |
| `prepare` | guard order test | `LaunchCreated` | core has no venue dep | ticket consumed, no growth | returns values | named aborts per field |
| `reserve` (adapter) | cap-id and digest checks | `RouteSelected` | vendored SHA pin | no new collection | returns values | named aborts |
| `finish` | supply, cap, inventory, witness, digest | `LaunchCreated` | core has no venue dep | one `Launch` per ticket | returns `Launch` | named aborts per check |
| `buy` | version, pause, state, slippage, non-zero out | `Bought` | none | none | returns `Coin<Meme>` | `EZeroOutput`, slippage, deadline |
| `sell` | version, pause, state, pending-burn allocation, slippage, non-zero out | `Sold` | none | one embedded pending-burn balance | returns `Coin<Quote>` | `EZeroOutput`, slippage, deadline |
| claim fees | capability, accrued only | `*FeesClaimed` | none | none | returns coin | `ENotAuthorized`, `ENothingAccrued` |
| set protocol fee share | admin witness, `<= 10_000` | `ProtocolFeeShareChanged` | none | one scalar | n/a | `EInvalidProtocolFeeShareBps` |
| mutate quote whitelist | admin witness, target, membership, capacity | `QuoteAllowed`, `QuoteMigrationTargetChanged`, or `QuoteRemoved` | none | at most 16 entries | n/a | exact errors 42–46 |
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
change has no `meme_type`, so the field would have to be fabricated; and a single monotonic counter
across all launches would make every trade contend on one shared field, which is a throughput cost paid
for nothing an indexer needs. Separate application counters are also rejected when native Sui event
position already provides the required order.

## Consequences

- Indexers can rebuild all protocol accounting and lifecycle state from events; native object reads and
  transaction effects remain authoritative for the two explicitly documented custody facts.
- Adding or changing any field above is a schema migration requiring a replay test.
- The event stream is wide; that cost is accepted because `../engineering-principles.md` treats events as
  the accounting interface rather than as notifications.

## Verification

- Reducer replay test: reconstruct final state from events alone and compare field-by-field with object
  state, for a sequence covering launch, many trades, both burn moments, threshold crossing, both fee
  claims, a failed migration with retry **including reservation release on venue switch**, a
  successful migration, LP fee collection, and a full RevShare epoch.
- Field-level assertions on every event in the catalogue.
- Native-order replay test: checkpoint, transaction, and event positions produce the same per-entity
  state as direct transaction-order replay, including multiple Blast events in one transaction.
- Schema tests reject application-level counters that merely duplicate native Sui event ordering.
- Fee-ledger reducer test: replayed creator/protocol totals in both assets equal object state after each
  accrual and claim across global percentage updates; each trade records its applied percentage, and
  ceiling rounding assigns any indivisible residue to the protocol.
- LP-fee reducer test: cumulative `LpFeesCollected` reconciles with the vault balances, and
  `principal_liquidity_before == principal_liquidity_after` in every collection.
- Supply-reconstruction test: cumulative burns from events equal the final registry `total_supply` after
  the supply state becomes `BurnOnly`.
- Schema-migration test: a changed field fails the replay test until the reducer is updated.
