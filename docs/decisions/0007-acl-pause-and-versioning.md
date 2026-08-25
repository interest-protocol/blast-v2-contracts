# 0007: Capability ACL, pause scope, and versioning

- Status: proposed
- Date: 2026-08-22
- Amended by: [0023](0023-generated-coin-supply-and-metadata-custody.md), [0032](0032-admin-authorized-upgrade-cap-custody.md)
- Authority spine settled by: [0015](0015-protocol-authority-and-x-signer-state.md)
- Admin-cap lifecycle settled by: [0020](0020-admin-cap-self-destruction.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `sui@ae60d06` | `ae60d065ed27576d25ac1c94145e5ffe3ddcf89e` | MystenLabs/sui |

## Context

`../../AGENTS.md` requires capabilities rather than address checks, a documented bound and event for every
privileged setter, a precisely defined pause scope, and a version gate that stops old package versions
bypassing a fix. `../architecture.md` adds that old Sui bytecode remains callable after an upgrade, so
the version gate must live in shared state, not in the entrypoint.

## Decision

### Capabilities

| Capability | Held by | Grants |
| --- | --- | --- |
| `SuperAdminCap` | protocol multisig | add/revoke protocol admins; delayed root transfer |
| `AdminCap` | protocol operations | bounded parameter changes, version bump, pause, adapter approval, `DisplayCap` custody, X-claim signer rotation, and—through a live `AdminWitness` while that path remains enabled—interim exact-digest package-upgrade authorization and irreversible policy restriction |
| `CreatorCap` | per launch, creator address | creator fee claim, LP fee collection after migration, metadata update during bonding |

Possession of a `Launch` object grants nothing. Being the address recorded as creator grants nothing on
its own — the `CreatorCap` is the authority, so authority is transferable exactly when the capability is,
and never accidentally.

### Authority matrix

| Operation | `SuperAdminCap` | `AdminCap` | `CreatorCap` | anyone | Bound | Event |
| --- | :---: | :---: | :---: | :---: | --- | --- |
| `launch::prepare` / `finish` | — | — | — | yes | ticket required | `LaunchCreated` |
| `buy` / `sell` | — | — | — | yes | not paused, version current, `Live` | `Bought` / `Sold` |
| `begin_migration` | — | — | — | yes | threshold crossed | `MigrationBegun` |
| `settle_migration` | — | — | — | yes | sealed settlement | `Migrated` |
| claim creator fees | — | — | yes | — | accrued balance only | `CreatorFeesClaimed` |
| collect LP fees | — | — | yes | — | fees only; position stays in `LpVault`; principal liquidity unchanged | `LpFeesCollected` |
| release venue reservation | — | yes | — | — | only while a reservation is held and no settlement exists | `ReservationReleased` |
| claim protocol fees | — | yes | — | — | accrued balance only | `ProtocolFeesClaimed` |
| update coin metadata | — | — | yes | — | bonding only | `MetadataUpdated` |
| choose launch quote/meme fee rates | — | — | — | launcher | fixed at launch; each within its accepted bound | fields in `LaunchCreated` |
| set global protocol fee share | — | yes | — | — | `<= 10_000` bps | `ProtocolFeeShareChanged` |
| set creation fee | — | yes | — | — | `<= CREATION_FEE_CEILING` | `CreationFeeSet` |
| set migration fee | — | yes | — | — | `<= MIGRATION_FEE_CEILING_BPS` | `MigrationFeeSet` |
| approve adapter witness | — | yes | — | — | bounded set size | `AdapterApproved` |
| revoke adapter witness | — | yes | — | — | — | `AdapterRevoked` |
| rotate X-claim signer | — | yes | — | — | different 32-byte key | `XClaimSignerSet` |
| revoke X-claim signer | — | yes | — | — | configured key | `XClaimSignerRevoked` |
| grant / revoke protocol admin | yes | — | — | — | at most 16 active admins | `AdminGranted` / `AdminRevoked` |
| destroy own admin cap | — | cap consumed | — | — | removes membership if active; always deletes cap | `AdminDestroyed` |
| set / unset `Display` field | — | yes | — | — | — | `DisplayFieldSet` |
| pause / unpause a scope | — | yes | — | — | scope enumerated | `Paused` / `Unpaused` |
| bump package version | — | yes | — | — | monotonic | `VersionBumped` |
| authorize / commit package upgrade | — | yes | — | — | exact 32-byte digest; wrapped cap's current policy; matching native receipt | `UpgradeAuthorized` / `UpgradeCommitted` |
| restrict package upgrade policy | — | yes | — | — | strictly more restrictive; additive or dependency-only | `UpgradePolicyRestricted` |

Every ordinary configuration row has a bound and an event. The package-upgrade
row is intentionally stronger: an active routine admin can authorize arbitrary
replacement code allowed by the wrapped cap's current policy and permanently
narrow that policy. ADR 0032 accepts that interim authority explicitly and
defines a package-only one-way governance cutover; it must not be described
operationally as an ordinary parameter update.

### Negative transition matrix

`Configured → Live → MigrationPending → Migrated`, plus `Recovery` reachable only from
`MigrationPending`. Every operation is tested against every source state; the expected abort is named,
never bare.

| Operation | `Configured` | `Live` | `MigrationPending` | `Migrated` | `Recovery` |
| --- | --- | --- | --- | --- | --- |
| `buy` | `ENotLive` | ok | `ENotLive` | `ENotLive` | `ENotLive` |
| `sell` | `ENotLive` | ok | `ENotLive` | `ENotLive` | `ENotLive` |
| `begin_migration` | `ENotLive` | `EThresholdNotReached` until crossed | `EMigrationAlreadyBegun` | `EAlreadyMigrated` | `EInRecovery` |
| `settle_migration` | `ENotMigrating` | `ENotMigrating` | ok | `EAlreadyMigrated` | `ENotMigrating` |
| claim creator fees | `ENothingAccrued` | ok | ok | ok | ok |
| collect LP fees | `ENotMigrated` | `ENotMigrated` | `ENotMigrated` | ok | `ENotMigrated` |
| release venue reservation | `ENoReservation` | ok if held | ok if held | `EAlreadyMigrated` | ok if held |
| update metadata | `ENotLive` | ok | `EMetadataFrozen` | `EMetadataFrozen` | `EMetadataFrozen` |
| enter recovery | `ENotMigrating` | `ENotMigrating` | ok after timeout | `EAlreadyMigrated` | `EInRecovery` |

**Fee claims are not lifecycle-gated.** Accrued fees are a settled obligation, so a claim never aborts
because of the launch's state; in `Configured` there is simply nothing accrued, which is
`ENothingAccrued` and not `ENotLive`. LP fee collection is the one fee-adjacent operation that *is*
state-gated, because the `LpVault` does not exist until migration.

**The protocol fee share is global and live.** Its setter is not launch-lifecycle-gated. Once updated,
every launch uses the new percentage on its next trade; balances accrued before the update retain their
existing creator/protocol ownership.

### Guard precedence

The fixed order, tested through abort precedence:

1. version gate;
2. pause gate;
3. lifecycle state;
4. **authorization of the caller** — the capability the caller presents;
5. **input validation** — including the shape, membership and binding of every value passed in;
6. economic checks including bounds, slippage and deadline.

When two conditions are simultaneously invalid, the earlier guard fires. Each such pair has a test.

**Where the adapter witness check sits, and why.** `launch::finish`
([ADR 0002](0002-coin-creation-and-currency-authority.md)) verifies that a `RouteCommitment`'s sealing
witness type is in the approved-adapter set. That is **step 5, input validation of a passed value — not
step 4 caller authorization.** The commitment is an argument, not a credential: the caller of `finish`
proves nothing by holding it, `finish` itself is permissionless, and an unapproved witness means the
argument is malformed rather than that the caller lacks a right.

This makes ADR 0002's `finish` order a strict refinement of the general order rather than a competing
one. Its checks are all step 5, run in the sequence stated there — supply snapshot, cap identity,
inventory, witness membership, digest binding, single-use — after the version, pause and state gates of
steps 1 to 3. There is exactly one satisfiable ordering, and it is tested in both places against the
same fixture.

### Pause scope

Pause is per scope, never global-by-accident:

| Scope | Blocks | Leaves open |
| --- | --- | --- |
| `PAUSE_LAUNCH` | new launches | all trading, all claims, migration |
| `PAUSE_BUY` | buys | **sells**, claims, migration |
| `PAUSE_SELL` | sells | buys, claims, migration |
| `PAUSE_MIGRATION` | begin and settle migration | trading, claims |

**Pausing buys never strands an exit.** `PAUSE_SELL` does block an exit, so it is reserved for a
demonstrated economic emergency, requires `AdminCap`, and emits a reason code. Fee claims are never
pausable, because accrued fees are already owed.

### Versioning

A `version: u64` lives in the shared `Config`. Every mutating entrypoint asserts it matches the compiled
package constant before any other work. `AdminCap` bumps it monotonically. Old package versions stay
callable forever on Sui, so the shared-state check is the only durable gate; a bump immediately disables
every previously published entrypoint.

ADR 0032's wrapped `UpgradeCap` controls who can publish replacement code; it
does not replace this shared-state cutover. Upgrade custody without the version
gate still leaves old entrypoints callable and is therefore insufficient for a
public release.

## Alternatives considered

**Address-based admin checks.** Rejected by `../../AGENTS.md`: object possession or an address check must
not imply broader authority.

**A single global pause flag.** Rejected: it cannot express "stop new launches but let holders exit".

**Pausable fee claims.** Rejected: accrued fees are a settled obligation.

**Version check in the entrypoint constant only.** Rejected: it does not stop calls into the old package.

**Creator authority by recorded address rather than capability.** Rejected: it conflates identity with
authority and makes delegation impossible without changing the recorded creator.

## Consequences

- Every privileged action is capability-gated, bounded, and evented, so the admin surface is replayable
  from events alone.
- Routine admins can irreversibly renounce membership, and revoked holders retain a storage-rebate path.
- Until a later governance path retires the original authorization function, any
  active routine admin is also compatible-code upgrade authority.
- Guard precedence is observable and therefore a release commitment.
- `PAUSE_SELL` is a deliberate, loud, exceptional action.
- A version bump is a hard cutover with no grace period.

## Verification

- Authority matrix executed as a test table: each role's allowed and forbidden actions, plus rotation and
  revocation.
- Admin-cap destruction tests cover active membership removal and already-revoked object cleanup.
- Trade-fee split tests cover configurable values, both percentage boundaries, a changed share applied
  to an existing launch, protocol-favouring ceiling rounding, and typed creator/protocol claim authority.
- LP-fee tests: collection by a non-`CreatorCap` holder aborts; collection before migration aborts
  `ENotMigrated`; no collection path reduces principal liquidity or removes the position from the vault.
- Reservation-release tests: release without a reservation aborts `ENoReservation`; release naming the
  wrong venue aborts `EWrongVenue`; release after settlement aborts `EAlreadyMigrated`.
- Guard-precedence test for the witness case specifically: a call with a stale version **and** an
  unapproved witness aborts on version, proving witness membership is step 5 and not step 4.
- Negative transition matrix executed as a test table: every illegal source state asserts its exact named
  abort.
- Guard-precedence tests for every pair of simultaneously invalid conditions.
- Pause tests: for each scope, the blocked and the still-open operations.
- Exit-preservation test: with `PAUSE_BUY` set, a sell still succeeds.
- Version test: a call at an old version aborts before any state read.
- Ceiling tests: each bounded setter aborts above its ceiling and emits old/new on success.
