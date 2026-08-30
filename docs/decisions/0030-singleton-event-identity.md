# 0030: Singleton event identity without repeated object ids

- Status: accepted
- Date: 2026-08-25
- Amends: [0011](0011-event-schema-and-replay.md), [0015](0015-protocol-authority-and-x-signer-state.md), [0020](0020-admin-cap-self-destruction.md), [0028](0028-hot-cold-runtime-configuration.md)
- Amended by: [0039](0039-deterministic-quote-valuations.md), [0058](0058-eventless-package-initialization.md), [0059](0059-no-sender-or-unchanged-state-in-event-payloads.md)

> Amended by [ADR 0039](0039-deterministic-quote-valuations.md): the pre-release
> `QuoteMigrationTargetChanged` event is replaced by the replay-complete
> `QuoteParametersChanged` event for the virtual/terminal pair.

> Amended by [ADR 0058](0058-eventless-package-initialization.md): the
> "Creation events retain singleton discovery ids" decision below is reversed.
> `ProtocolAuthorityCreated`, `RuntimeConfigCreated`, and `LaunchConfigCreated`
> are removed entirely, because every field they carried is either recorded by
> the publish transaction's native effects or compiled into the published
> bytecode. The rest of this record — no repeated owner id on typed singleton
> mutations, and changed state only on root-transfer facts — stands unchanged.

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| — | No external ABI fact introduced | — |

This record simplifies Blast-owned pre-publication event schemas without changing
protocol state, authorization, or replay behavior.

## Context

Blast production initializes exactly one `ProtocolAuthority`, one
`RuntimeConfig`, and one `LaunchConfig`. Their creation events publish the three
shared-object ids, but every later mutation payload also repeats its owning
singleton id.

The repeated ids came from a general event-replay rule: mutation events should
carry stable entity identity so reducers can partition independently changing
instances. That rule is necessary for launches, tickets, capabilities, quote
entries, meme types, and any other domain where several entities can exist. It
does not add information when production can create only one instance of the
payload's typed singleton domain.

The repository contains no committed Sui publication, deployment record,
indexer, or SDK consumer. This is therefore a pre-publication schema correction.
If a deployment exists outside the repository, its existing event payload types
remain published indexing ABI and require a separate compatibility decision.

## Decision

### Creation events retain singleton discovery ids

`ProtocolAuthorityCreated.authority_id`,
`RuntimeConfigCreated.runtime_config_id`, and
`LaunchConfigCreated.config_id` remain. Each creation event announces the shared
object that clients must discover and establishes the initial event-replay
state.

### Typed singleton mutations do not repeat their owner id

The following mutation payloads remove their repeated owning singleton id:

- ACL: `AdminGranted`, `AdminRevoked`, `AdminDestroyed`,
  `SuperAdminTransferStarted`, `SuperAdminTransferCancelled`, and
  `SuperAdminTransferred` remove `authority_id`;
- live settings: `XClaimSignerSet`, `XClaimSignerRevoked`, and
  `ProtocolFeeShareChanged` remove `runtime_config_id`; and
- cold launch policy: `QuoteAllowed`, `QuoteMigrationTargetChanged`,
  `QuoteDisallowed`, `GraduationDefaultsChanged`,
  `MigrationWitnessAllowed`, and `MigrationWitnessDisallowed` remove
  `config_id`.

The fully qualified wrapped payload type identifies the package deployment and
the singleton concern. Native Sui event position orders mutations. Starting at
deployment, the creation fact plus typed old/new, delta, or final fields remains
sufficient to replay each singleton without reading mutable state.

This rule applies only while production has exactly one instance of the type.
Introducing replacement or multiple same-typed shared objects is a protocol and
event-schema change that must add explicit identity to its new mutation facts.
Test-only constructors do not expand production indexing ABI.

### Root-transfer facts retain only changed state

`SuperAdminTransferStarted` and `SuperAdminTransferCancelled` also remove
`current_super_admin_cap_id`. Those operations do not mutate the current root
cap id; a reducer already knows it from `ProtocolAuthorityCreated` and the most
recent `SuperAdminTransferred` event.

`SuperAdminTransferred` retains both `previous_super_admin_cap_id` and
`new_super_admin_cap_id` because that transition changes the recognized root.
The old/new pair supplies continuity and the new id is required to reconstruct
the final authority state.

All varying entity identities remain, including admin-cap ids, quote and
migration-witness type names, meme types, ticket and native capability ids, and
creator addresses. All old/new values and final snapshots remain.

## Alternatives considered

**Repeat every singleton id for self-contained mutation rows.** Rejected: it
optimizes consumers that intentionally skip the creation stream while making
every event payload and reducer schema carry a value that cannot vary. Blast's
replay contract starts at deployment.

**Remove ids from singleton creation events too.** Rejected: those facts are the
event-driven discovery boundary for shared objects used by clients and
deployment tooling.

**Keep current root-cap ids on transfer start and cancellation as actor fields.**
Rejected: they are unchanged state, derivable from the preceding authority
stream, and the native transaction inputs remain available for forensic input
inspection.

**Retain ids for a hypothetical future replacement singleton.** Rejected: a
replacement changes today's production singleton invariant and needs an
explicit migration plus new replay facts rather than speculative fields in the
first schema.

## Consequences

- Fifteen mutation payload types lose one repeated 32-byte singleton id.
- Transfer start and cancellation each lose one additional unchanged 32-byte
  root-cap id.
- Creation-event discovery and full event-only replay remain intact.
- Event tests become simpler and focus on changing entity identity and state.
- Any future multi-instance or replacement-singleton design must restore entity
  identity in its new event payloads.

## Verification

- Field-level tests cover all twenty implemented payload types, including admin
  revocation and all root-transfer transitions.
- Replacement of a pending root transfer proves both cancellation and start
  facts without relying on singleton ids; source boundaries preserve their
  emission order.
- Runtime- and launch-config event tests replay old/new values and varying entry
  identities without owner ids.
- Build, warning-as-error lint, complete tests, 100% Move coverage, source
  boundaries, and `git diff --check` pass under the pinned toolchain.
