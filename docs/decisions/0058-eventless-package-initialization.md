# 0058 — Eventless package initialization

- Status: **accepted**
- Date: 2026-08-30
- Amends: [0011](0011-event-schema-and-replay.md), [0018](0018-authority-module-separation.md), [0022](0022-dual-asset-fee-ledger-and-claims.md), [0028](0028-hot-cold-runtime-configuration.md), [0030](0030-singleton-event-identity.md), [0033](0033-meme-liquidity-provision.md), [0049](0049-audit-hardened-package-version-and-launch-intake.md)
- Amended by: [0062](0062-table-backed-quote-registry.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| — | No external ABI fact introduced | — |

This record removes Blast-owned pre-publication creation payloads. It changes no
protocol state, authority, storage layout, or replay outcome.

## Context

ADR 0030 removed the repeated singleton id from every typed *mutation* payload
but deliberately kept the *creation* payloads, reasoning that they are "the
event-driven discovery boundary for shared objects used by clients and deployment
tooling."

The aggregate migrators package then shipped the same discovery fact and dropped
it again: `VenueConfigCreated` carried nothing but `config_id`, and Sui
transaction effects already record the shared object and its type at publication
(ADR 0057, commit `3509780`). That leaves the launchpad and blastSUI packages
holding six creation payloads whose fields fall entirely into two derivable
classes.

**Class 1 — native publication effects.** The publish transaction's effects
record every created object with its id, type, and owner, and the transaction
records its sender. That covers `authority_id`, `super_admin_cap_id`,
`package_version_id`, `runtime_config_id`, `config_id`, the delivered root cap's
`super_admin_recipient`.

**Class 2 — compiled invariants of the bytecode being published.** `init` runs
only at the original publish, never on upgrade, so every remaining field is the
constant compiled into the package the indexer is already reading:
`PACKAGE_VERSION` is `1`; `max_admins`, `max_migration_witnesses`, and
`super_admin_transfer_delay_ms` are `constants` macros;
and all six initial rates — `protocol_fee_share_bps`, `quote_fee_bps`,
`meme_fee_bps`, `quote_migration_fee_bps`,
`protocol_meme_graduation_fee_bps`, and `meme_liquidity_provision_bps` — are
literal zero.

No creation payload carried a single value that could vary between two
deployments of the same bytecode.

## Decision

### Package initialization emits no events

The following payload types, their emit helpers, and their test-only field
getters are removed:

- `blast_fun`: `ProtocolAuthorityCreated`, `PackageVersionCreated`,
  `RuntimeConfigCreated`, `LaunchConfigCreated`;
- `blast_sui`: `ProtocolAuthorityCreated`, `PackageVersionCreated`.

Every `init` now only constructs and shares or delivers its objects. Native
publication effects are the discovery fact, exactly as ADR 0057 already
established for `VenueConfig`.

This applies to production singletons initialized from compiled constants. A
creation fact that commits a value the deployer or a caller supplies is a
different case and keeps its event: `PackageAdminCreated` reads the `policy` and
version of a *user-supplied* `UpgradeCap` at wrap time, and `VaultCreated`
records the owner seed split, validator, and opening custody. Both are emitted
by ordinary public functions, not `init`.

### Replay stays complete

Each removed initial value is either read from publication effects or re-supplied
by the first mutation that changes it. ADR 0079 later removed redundant old
values from launchpad mutation events; their resulting values remain enough
when replay begins at deployment:

| Removed initial value | Recovered from |
| --- | --- |
| every singleton object id | publish transaction effects |
| `super_admin_cap_id`, `super_admin_recipient` | publish effects; then `SuperAdminTransferred.previous_super_admin_cap_id` / `new_super_admin_cap_id` |
| `protocol_fee_share_bps` | compiled zero; then `ProtocolFeeShareChanged` |
| `version` | compiled `PACKAGE_VERSION`; then `PackageVersionAdvanced.previous_version` |
| `quote_fee_bps`, `meme_fee_bps` | compiled zero; then `LaunchTradeFeesChanged` |
| `quote_migration_fee_bps`, `protocol_meme_graduation_fee_bps`, `meme_liquidity_provision_bps` | compiled zero; then `GraduationDefaultsChanged` |
| `max_admins`, `max_migration_witnesses`, `super_admin_transfer_delay_ms` | `constants` macros in the published bytecode; never mutable |

A reducer starting at deployment therefore still reconstructs lifecycle,
accounting, configuration, fee state, allocation state, and migrations without
reading mutable state.

### The rule is mechanically gated

`sui/launchpad/scripts/check_source_boundaries.sh` fails if any `init` under
`sources/` calls an `events::` helper, or if any of the four removed launchpad
payload names reappears in `sources` or `tests`.

## Alternatives considered

**Keep the creation events as an indexer convenience.** Rejected: it publishes
six payload types and their reducer schemas to carry values that cannot vary,
and it contradicts the decision already taken for `VenueConfig`. An indexer that
declines to read the publish transaction it is bootstrapping from is not a case
the ABI should widen for.

**Keep only the ids and drop the constant fields.** Rejected: the id is the one
field publication effects most directly record, so the remainder would be the
half worth keeping — and it is compiled into the package.

**Keep `ProtocolAuthorityCreated` alone, as ADR 0030's baseline for the root-cap
chain.** Rejected: the initial `SuperAdminCap` is the single capability object
created and transferred by the publish transaction, so the chain that
`SuperAdminTransferred` continues is anchored by effects rather than by a
payload.

## Consequences

- Six payload types, six emit helpers, and six test-only getters are removed;
  `blast_fun` emits 30 payload types and `blast_sui` 20.
- Publication of either package now emits zero Move events.
- An indexer bootstraps singleton ids, the root-cap holder, and the treasury
  from the publish transaction rather than from a payload.
- Introducing a replacement or multi-instance singleton, or an initializer that
  commits a caller-supplied value, requires a creation fact again and a new ADR.

## Verification

- `blast_fun`: 221 tests pass, including
  `package_initialization_shares_singletons_without_events`, which runs all four
  production initializers, asserts `event::num_events() == 0`, and then takes
  each shared singleton; and `package_init_delivers_only_root`, which asserts
  zero user events with the root cap delivered and no admin cap.
- `blast_sui`: 146 tests pass at 100% module coverage for `events`,
  `events_wrapper`, `acl`, and `package_version`, including
  `init_shares_the_authority_and_delivers_the_root_cap_without_events`.
- The eventless-`init` boundary gate was confirmed to fail on a reintroduced
  emission before being restored.
- Build under both build environments, warning-as-error lint, complete tests,
  source boundaries, and coverage pass under the pinned toolchain.
