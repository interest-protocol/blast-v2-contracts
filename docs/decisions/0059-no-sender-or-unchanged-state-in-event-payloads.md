# 0059 — No transaction sender or unchanged state in event payloads

- Status: **accepted**
- Date: 2026-08-30
- Amends: [0011](0011-event-schema-and-replay.md), [0022](0022-dual-asset-fee-ledger-and-claims.md), [0030](0030-singleton-event-identity.md)
- Extends: [0058](0058-eventless-package-initialization.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| — | No external ABI fact introduced | — |

This record removes Blast-owned pre-publication payload fields. It changes no
protocol state, authorization, arithmetic, or replay outcome.

## Context

ADR 0058 removed six creation payloads whose every field was already recorded by
the publish transaction's native effects or compiled into the published
bytecode. Applying the same test field-by-field across all four packages finds
two remaining classes.

**The transaction sender, restated under an actor name.** Twenty-one payload
fields are populated with exactly `ctx.sender()`, which is the transaction
sender that every consumer already receives with the event envelope. ADR 0011
kept the claimant while dropping the payout recipient, reasoning that the
claimant is the protocol-validated actor; that reasoning distinguishes the
*actor* from the *recipient*, but the actor is the sender, so the field is a
copy rather than a distinct fact.

**Unchanged state on a non-mutating authorization fact.**
`UpgradeAuthorized.package_id`, `.package_version`/`.cap_version`, and `.policy`
in both administered packages are reads of the wrapped cap taken immediately
before `authorize`. `authorize_upgrade` mutates nothing, and all three values are
already replayed from `PackageAdminCreated` plus the `UpgradeCommitted` and
`UpgradePolicyRestricted` streams. Only the digest is new information, and it is
the fact the event exists to record.

## Decision

### Payloads do not restate the transaction sender

The following fields are removed:

- `blast_fun`: `LaunchTicketCreated.launcher`, `LaunchCreated.launcher`,
  `Bought.buyer`, `Sold.seller`, `Migrated.migrator`,
  `CreatorFeesClaimed.claimant`, `ProtocolFeesClaimed.claimant`, and
  `CreatorCapClaimed.creator`;
- `blast_fun_migrators`: `LpFeesCollected.collector`,
  `CreatorFeesClaimed.claimant`, and `ProtocolFeesClaimed.claimant`;
- `blast_fun_vesting`: `VestingCreated.funder` and the `caller` on
  `VestingClaimed`, `VestingCanceled`, and `VestingClosed`, in both the linear
  and checkpoint modules.

`LaunchTicketCreated.creator` and `CreatorCapClaimed`'s X identity commitment
stay: they are the declared or attested creator identity, which the deployer or
the backend supplies and which need not equal the sender. `VestingCreated`
retains `beneficiary` and `refund_recipient`, and `VestingCanceled` retains
both, for the same reason.

### `UpgradeAuthorized` carries only the authorized digest

`UpgradeAuthorized` keeps `digest` alone in both `blast_fun` and `blast_sui`. Its
test-only accessor becomes `upgrade_authorized_digest`.

`accrue_fees` in the migrators vault and `close_irrevocable` in both vesting
modules no longer read the context. `accrue_fees` is package-private and drops
the parameter; the three public venue entry points and `close_irrevocable` keep
their uniform signatures with the repository's `_`-prefixed unused-parameter
convention, which costs callers nothing because Sui supplies `TxContext` from
the runtime rather than from the transaction's argument list.

### What deliberate redundancy stays

This decision does **not** touch two kinds of intentional duplication, and
future audits must not remove them:

- **Delta plus final total.** `Bought`, `Sold`, and `LpFeesCollected` carry both
  per-transition deltas and the resulting ledger totals, and every blastSUI
  vault event carries a complete `VaultCustody` snapshot. ADR 0011 explicitly
  rejected emitting deltas alone so that a consumer joining late, or dropping a
  message, can still reconcile. Each event stays self-reconciling.
- **Old/new pairs on mutations.** Required by ADR 0030 and load-bearing for ADR
  0058: they are what lets a reducer recover an initial value that no creation
  event states any more.

Fields that record the *final state at removal* also stay —
`QuoteDisallowed.previous_*`, `XClaimSignerRevoked.previous_public_key`,
`SuperAdminTransferCancelled.recipient`, `SuperAdminTransferred.recipient`, and
`AdminGranted.recipient`. They are the identity of what was removed or
delivered, and keeping them holds removals to the same self-contained standard
as accruals.

### The rule is mechanically gated

Each package's `check_source_boundaries.sh` fails if an event payload declares a
field named for an actor (`buyer`, `seller`, `claimant`, `launcher`, `migrator`,
`collector`, `caller`, `funder`), and the `blast_fun` and migrator gates also
fail if any `events::` call site passes `ctx.sender()`.

## Alternatives considered

**Keep the actor fields so an event row is self-contained.** Rejected: the
envelope that delivers the payload already carries the sender, so the field is
duplicated in the same message rather than saving a lookup.

**Keep `LpFeesCollected.collector` to avoid touching venue signatures.**
Rejected, but it is why `accrue_fees` lost a parameter: the alternative was an
inconsistent adapter surface where three venues declare a context they never
read while two use it.

**Also drop the previous-value-at-removal fields.** Rejected: unlike the sender,
they are not carried by the envelope, and reconstructing them requires the full
prior stream, which is exactly the late-join case ADR 0011 protects.

## Consequences

- Twenty-one actor fields and six unchanged-state fields are removed;
  `blast_fun` emits 30 payload types, `blast_sui` 20, the migrators 6, and
  vesting 4 per module, all with narrower schemas.
- A consumer reading an actor now reads the transaction sender from the event
  envelope instead of the payload.
- `UpgradeAuthorized` is a single-field fact; its package id, cap version, and
  policy come from the surrounding administration stream.
- Any future payload that must record an actor who is *not* the sender — a
  sponsored or delegated action, or a recipient — must name that field for the
  role it plays and record the necessity in an ADR, because the boundary gate
  denies the actor names above.

## Verification

- `blast_fun` 221 tests, `blast_sui` 146, migrators 15, vesting 41 — all pass
  under warning-as-error lint in both build environments.
- Every boundary gate passes, and both new gates were confirmed to fail on a
  reintroduced actor field before being restored.
- `blast_sui` coverage holds at 100% for every gated module; `blast_fun` holds
  100% on every module this record touches.
