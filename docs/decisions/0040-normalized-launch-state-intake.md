# 0040: Normalized launch state intake

- Status: accepted
- Date: 2026-08-28
- Amended by: [0041](0041-launch-config-owned-trade-fees.md), [0042](0042-key-only-shared-launch.md), [0043](0043-versioned-launch-trading-and-atomic-migration.md), [0047](0047-coin-registry-authoritative-supply-mode.md)
- Implements: [0016](0016-unified-creator-cap-claim-and-suins-periphery.md),
  [0019](0019-consuming-creator-authority-and-cap-return.md),
  [0022](0022-dual-asset-fee-ledger-and-claims.md),
  [0024](0024-generated-coin-launch-ticket.md),
  [0025](0025-quote-whitelist-and-migration-targets.md),
  [0027](0027-graduation-economics-and-migration-witnesses.md),
  [0033](0033-meme-liquidity-provision.md), and
  [0039](0039-deterministic-quote-valuations.md)

## Context

The core package has reviewed leaf modules for generated-coin custody, cold
launch policy, supply partitioning, curve arithmetic, and trade-fee accounting.
It does not yet have the state object that consumes those seams. Continuing with
trading or migration first would duplicate their inputs or invent an authority
over balances that no launch owns.

This slice must not settle the remaining lifecycle, pause, version, burn-policy,
route-recovery, or venue questions. It only creates normalized launch custody
from the facts accepted in ADRs 0016 through 0039 and exposes the already
accepted one-time creator claim.

## Decision

### One composable constructor

`launch::new<Meme, Quote, MigrationWitness>` is permissionless. It consumes one
`LaunchTicket<Meme>`, borrows `LaunchConfig` and `RuntimeConfig`, and returns one key-only
`Launch<Meme, Quote>`. It does not accept trade-fee parameters or transfer the
result. Under ADR 0042, the creation PTB consumes the value through the separate
`launch::share` publication function.

The constructor validates in this order:

1. `LaunchConfig` admits the original Quote type and selected migration witness
   and has a configured graduation policy; and
2. the initial Meme balance produces positive curve and destination-pool
   balances under the snapshotted rates.

Under ADR 0041, `LaunchConfig` validates the Quote/Meme trade-fee pair when an
administrator changes it and returns both values in the immutable launch
snapshot. The configuration and partition modules own their errors and guard
precedence.

There is no creation fee, Quote `Currency` input, venue input, initial Quote
payment, or clock. ADR 0043 adds the runtime borrow for the global package gate
and carries the ticket-bound sell-burn rate into launch state. ADR 0047 makes
Coin Registry the only supply-mode authority read at migration.

### Exact initial custody

`Launch<Meme, Quote>` stores:

- immutable virtual Quote, migration target, both LaunchConfig-snapshotted trade-fee
  rates, all three graduation rates, and the selected migration witness's
  original `TypeName`;
- the lifecycle and immutable sell-burn rate added by ADR 0043;
- the partitioned Meme curve reserve, protocol Meme graduation fee, and
  destination-pool Meme provision;
- zero real Quote reserve and zero pending Meme burn;
- one empty embedded `FeeLedger<Meme, Quote>`;
- exactly one unissued `CreatorAuthority<Meme>`; and
- the native `MetadataCap<Meme>` paired with that authority.

The type has `key` as its only ability. It cannot be nested or publicly
transferred, and successful creation ends with top-level shared ownership.

The authority and metadata capability use `Option` only because their accepted
claim removes both linear resources from a borrowed launch. They are never
replaced, and there is no parallel claimed boolean. The object stores no derived
valuation, expected curve release, creator recipient, venue object, application
sequence, or speculative lifecycle control.

The constructor reads the ticket id before consuming the ticket, then emits
`LaunchCreated` after the complete object exists. The event records the launch
and source-ticket ids, original type identities, every immutable economic input,
every named initial balance, the metadata-cap id, and all four zero fee-ledger
totals. Consumers join the source-ticket id to `LaunchTicketCreated` for creator
identity and authoritative supply-mode history instead of duplicating those
facts.

### One launch-level creator claim

`launch::claim_creator_cap` is the sole public claim function. It requires that
the launch still contains both linear resources, removes the
`CreatorAuthority<Meme>`, delegates identity and X-attestation verification to
`creator_authority::claim_creator_cap`, independently removes the native
`MetadataCap<Meme>`, and returns:

```move
(CreatorCap<Meme>, MetadataCap<Meme>)
```

The metadata capability never enters `creator_authority`. A missing authority
or metadata capability raises the new append-only
`creator_authority_unavailable` error, code 66, without adding a claimed flag.

### Deferred boundaries

This record did not add buy, sell, fee-claim, migration, or version functions;
ADR 0043 adds those lifecycle operations. Pause, route recovery, display,
allocation, and vesting remain outside this slice.

## Alternatives considered

**Separate launch-state and trading objects.** Rejected: reserves, pending burn,
and the embedded fee ledger must change atomically during a trade.

**Store derived valuations or expected release.** Rejected: the SDK derives
them exactly from the stored primitive inputs under ADR 0039.

**Read live launch policy during later operations.** Rejected: cold policy is
snapshotted once so administration cannot reprice or retarget an existing
launch.

**Store the ticket's burnable event input.** Rejected by ADR 0047. Hot sells
need the ticket-bound rate, but they do not need supply mode. Migration already
borrows `Currency<Meme>` and reads its authoritative state before disposal.

**Add route preparation now.** Rejected: launch-time reservation and recovery
remain proposed in ADR 0010. The selected migration witness is the smallest
accepted migration primitive.

## Consequences

- Every accepted launch-time primitive has one consensus-critical owner.
- Ticket inventory and authorities move into launch custody without minting or
  capability pass-through.
- Later configuration changes affect only later launches.
- Creator authentication remains composable and one-time.
- Trading and migration can consume reviewed launch state without reopening the
  construction boundary.
- ADRs 0043 and 0045 resolve lifecycle and the single package-version gate; pause remains a
  separate product decision.

## Verification

- Construction tests assert exact balance conservation, immutable snapshots,
  configured fee-rate values, source-ticket linkage, original type names,
  metadata custody, and all zero initial balances.
- Creator-claim integration proves the launch returns the creator and metadata
  capabilities separately and cannot claim twice.
- Configuration failures retain their owning module and guard order.
- Build, warning-as-error lint, full Move tests, and structural boundary checks
  remain required.
