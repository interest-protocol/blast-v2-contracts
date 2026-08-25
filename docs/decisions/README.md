# Architecture decision records

Use ADRs for decisions that create durable protocol, authority, storage, ABI, upgrade, dependency,
deployment, or cross-chain commitments.

Name files `NNNN-short-title.md` and use this template:

```markdown
# NNNN: Title

- Status: proposed | accepted | superseded
- Date: YYYY-MM-DD

## Context

What decision is required, including threats, invariants, and constraints.

## Decision

The precise behavior, bounds, authority, and chain-specific mapping.

## Alternatives considered

The serious alternatives and why they were not selected.

## Consequences

Security, composability, operations, upgrades, indexing, and testing impact.

## Verification

Tests, shared vectors, deployment checks, and review evidence required.
```

An ADR records a decision; it does not replace executable invariants or tests.

## Citation rule

Every ADR must cite external ABI facts as `repo@commit:path:line`, resolvable through the pin table in
[../reference-review.md](../reference-review.md). A claim about an external package that cannot be cited
that way must be written as a **named premise with a falsification test**, never as an assertion.

Each ADR carries a `## Sources` table mapping the short refs it uses to full commit hashes.

## Index

| ADR | Title | Status |
| --- | --- | --- |
| [0001](0001-sui-package-and-module-layout.md) | Sui package and module layout | proposed |
| [0002](0002-coin-creation-and-currency-authority.md) | Coin creation, currency authority, and the launch transaction sequence | proposed |
| [0003](0003-treasury-cap-lifetime-and-burn.md) | TreasuryCap lifetime and the two burn moments | superseded by 0023 and 0026 |
| [0004](0004-bonding-curve.md) | Constant-product bonding curve | proposed |
| [0005](0005-quote-asset-generalisation.md) | Generic, permissionless quote asset | superseded by 0025 |
| [0006](0006-fees-and-launch-paths.md) | Asset provenance, seed mode, and creator fees | proposed |
| [0007](0007-acl-pause-and-versioning.md) | Capability ACL, pause scope, and versioning | proposed |
| [0008](0008-creator-identity-and-claims.md) | Creator assignment, social claims, and replay-safe signatures | superseded by 0013 |
| [0009](0009-referrals-and-revshare.md) | Referral attribution and weekly RevShare settlement | proposed |
| [0010](0010-migration-and-venue-adapters.md) | Migration routes and venue adapters | proposed |
| [0011](0011-event-schema-and-replay.md) | Event schema, replay, and the operation-to-rule checklist | proposed |
| [0012](0012-flywheel-features.md) | Flywheel feature dispositions | proposed |
| [0013](0013-creator-fee-authority-and-x-claims.md) | Creator fee authority and X account claims | **accepted** |
| [0014](0014-typed-creator-cap-and-diagnostic-modules.md) | Coin-typed creator authority and diagnostic modules | **accepted** |
| [0015](0015-protocol-authority-and-x-signer-state.md) | Protocol authority and minimal X signer state | **accepted** |
| [0016](0016-unified-creator-cap-claim-and-suins-periphery.md) | Unified CreatorCap claim and SuiNS periphery | **accepted** |
| [0017](0017-coin-type-domain-for-x-creator-claims.md) | Coin-type domain for X creator claims | **accepted** |
| [0018](0018-authority-module-separation.md) | Separate protocol ACL, X signer configuration, and creator authority | **accepted** |
| [0019](0019-consuming-creator-authority-and-cap-return.md) | Consuming creator authority and returning CreatorCap | **accepted** |
| [0020](0020-admin-cap-self-destruction.md) | Admin-cap self-destruction and voluntary renunciation | **accepted** |
| [0021](0021-pure-constant-product-curve-quotes.md) | Pure constant-product curve quotes | **accepted** |
| [0022](0022-dual-asset-fee-ledger-and-claims.md) | Dual-asset fee ledger and capability claims | **accepted** |
| [0023](0023-generated-coin-supply-and-metadata-custody.md) | Generated coin supply and metadata custody | **accepted** |
| [0024](0024-generated-coin-launch-ticket.md) | Generated coin launch ticket | **accepted** |
| [0025](0025-quote-whitelist-and-migration-targets.md) | Quote whitelist and migration targets | **accepted** |
| [0026](0026-deferred-sell-burn.md) | Deferred sell burn custody | **accepted** |
| [0027](0027-graduation-economics-and-migration-witnesses.md) | Graduation economics and migration witnesses | **accepted** |
| [0028](0028-hot-cold-runtime-configuration.md) | Hot/cold runtime configuration consolidation | **accepted** |
| [0029](0029-composable-creator-identity.md) | Composable creator identity and protected linear authority | **accepted** |
| [0030](0030-singleton-event-identity.md) | Singleton event identity without repeated object ids | **accepted** |
| [0031](0031-package-witness-and-publisher-custody.md) | Package witness and Publisher custody | **accepted** |
| [0032](0032-admin-authorized-upgrade-cap-custody.md) | Package administration custody and admin-authorized upgrades | **accepted** |

Only ADRs 0013–0032 are accepted. ADR 0021 accepts the pure curve formulas and
package boundary, while ADR 0022 accepts the trade-fee ceiling, live global split
semantics, embedded ledger, and claim boundary. ADR 0023 accepts the generated-coin
supply modes, one-billion ceiling, and separate native metadata-cap return. ADR
0024 accepts the generated-coin launch-ticket boundary, ADR 0025 the bounded
quote whitelist and immutable per-launch target snapshot, and ADR 0026 the
deferred terminal sell-burn lifecycle. Other deployment constants, public ABI,
and storage commitments still await approval.

ADR 0027 accepts the graduation economics, launch-policy consolidation,
bounded migration-witness admission, external migrator package boundary, and
the exclusion of DEX pool-opening fees.

ADR 0028 consolidates the dedicated X signer and live protocol fee share into
one small `RuntimeConfig`, while preserving separate `ProtocolAuthority` and
cold `LaunchConfig` shared objects.

ADR 0030 keeps shared-object discovery ids on singleton creation events while
removing repeated owner ids from typed singleton mutation payloads.

ADR 0031 moves the package OTW out of ACL into a minimal `blast` module, uses it
to claim and retain the framework `Publisher`, and keeps all state-module
initializers context-only unless they genuinely consume an OTW.

ADR 0032 validates and wraps the package `Publisher` and `UpgradeCap` in one
shared package-administration object, lets a live `AdminWitness` authorize exact
upgrade digests and irreversibly narrow policy, and provides the one-way
package-only cutover that later governance must use to retire routine admins.

## Open premises

These ADRs depend on facts that require either a pinned Sui toolchain or a live
external-integration check. Each is named in the ADR that depends on it, with a
falsification test.

| Premise | Question | Owning ADR |
| --- | --- | --- |
| P1 | Can a transaction pass a type argument naming a package published in the same transaction? | [0002](0002-coin-creation-and-currency-authority.md) |
| P2 | Is `&mut Currency<T>` obtainable only as a shared input? | [0003](0003-treasury-cap-lifetime-and-burn.md) |
| P3 | Which direction is the Cetus canonical pair ordering? | [0010](0010-migration-and-venue-adapters.md) |
| P4 | Do Bluefin or Turbos expose a reservation primitive, and how do they order pairs? | [0010](0010-migration-and-venue-adapters.md) |
| P5 | Which quote assets does Cetus currently admit to `allowed_pair_config`? | [0005](0005-quote-asset-generalisation.md), [0010](0010-migration-and-venue-adapters.md) |
| P6 | May an `init` call a dependency package to construct and return an object? | [0002](0002-coin-creation-and-currency-authority.md) |
| P7 | What is Bluefin's exact protocol fee share on creator-created pools? | [0006](0006-fees-and-launch-paths.md) |
| P8 | Does `display_registry` expose any `DisplayCap` destruction path? | [0001](0001-sui-package-and-module-layout.md) |
| P9 | Can an adapter determine pair support before consuming the migration payload? | [0005](0005-quote-asset-generalisation.md), [0010](0010-migration-and-venue-adapters.md) |
| P10 | Can a no-ability struct be threaded through a call in another package within one transaction? | [0002](0002-coin-creation-and-currency-authority.md) |
| P11 | Can `TreasuryCap<T>` be passed by value across a transaction command boundary? | [0002](0002-coin-creation-and-currency-authority.md) |
| P12 | Does `display_registry::new_with_publisher<T>` accept a generic instantiation? | [0001](0001-sui-package-and-module-layout.md) |
| P13 | Can a module's `init` accept a shared object such as `&mut CoinRegistry`? | [0002](0002-coin-creation-and-currency-authority.md) |
| P14 | Can a transaction command result be a Move reference? | [0002](0002-coin-creation-and-currency-authority.md) |
| P15 | Does the configured X user-context authentication return the stable id of the currently authenticated user while app-only credentials fail the claim path? | [0013](0013-creator-fee-authority-and-x-claims.md) |

**Load-bearing premises.** P10, P11, P13 and P14 together carry the launch transaction composition:
P13 forces currency creation into `init` and therefore the OTW path; P14 forces the `TreasuryCap` to move
by value rather than by reference; P10 and P11 make the core-adapter-core threading expressible. Each has
a stated fallback — reservation in its own transaction with a persisted single-use record — so a failure
costs a transaction, not the architecture. They are the **first four compile fixtures** of the
implementation stage, ordered in [../testing.md](../testing.md) gate 0.

None is treated as established until its named compile, localnet, or integration
test passes, and none is asserted as a cited fact in the records.
