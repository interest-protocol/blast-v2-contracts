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
| [0033](0033-meme-liquidity-provision.md) | Meme liquidity provision for destination pools | **accepted** |
| [0034](0034-remove-premature-governance-cutover.md) | Remove the premature governance cutover | **accepted** |
| [0035](0035-initializer-finalized-meme-supply.md) | Finalize generated Meme supply during initialization | **accepted** |
| [0036](0036-fixed-nine-decimal-generated-memes.md) | Fix generated Meme precision at nine decimals | **accepted** |
| [0037](0037-remove-redundant-ticket-burn-mode.md) | Remove redundant supply mode from launch-ticket custody | superseded by 0043 |
| [0038](0038-standard-method-names.md) | Standard method names for reads, conversions, and wrapper destruction | **accepted** |
| [0039](0039-deterministic-quote-valuations.md) | Deterministic Quote-denominated launch valuations | **accepted** |
| [0040](0040-normalized-launch-state-intake.md) | Normalized launch state intake | **accepted** |
| [0041](0041-launch-config-owned-trade-fees.md) | LaunchConfig-owned trade fees | **accepted** |
| [0042](0042-key-only-shared-launch.md) | Key-only shared launch publication | **accepted** |
| [0043](0043-versioned-launch-trading-and-atomic-migration.md) | Versioned launch trading and atomic migration | **accepted** |
| [0044](0044-validated-basis-points-unit.md) | Validated basis-points unit | **accepted** |
| [0045](0045-single-package-version.md) | Single package version | **accepted** |
| [0046](0046-witness-authorized-migration-redemption.md) | Witness-authorized migration redemption | **accepted** |
| [0047](0047-coin-registry-authoritative-supply-mode.md) | Coin Registry authoritative supply mode | **accepted** |
| [0048](0048-sui-package-workspace.md) | Sui package workspace | **accepted** |
| [0049](0049-audit-hardened-package-version-and-launch-intake.md) | Audit-hardened package cutover and launch intake | **accepted** |
| [0050](0050-module-local-package-version-constant.md) | Module-local package-version constant | **accepted** |

ADRs 0013–0036 and 0038–0050 are accepted; ADR 0037 is superseded by 0043. ADR 0021 accepts the pure curve formulas and
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

ADR 0041 places the bounded Quote/Meme total trade-fee pair in cold
`LaunchConfig`. Admins update the pair atomically, each future launch snapshots it,
and launch callers cannot supply rates.

ADR 0042 removes `store` from `Launch`, keeps `key` as its only ability, and
adds one consuming publication function that shares each constructed launch as
top-level state.

ADR 0030 keeps shared-object discovery ids on singleton creation events while
removing repeated owner ids from typed singleton mutation payloads.

ADR 0031 moves the package OTW out of ACL into a minimal `blast` module, uses it
to claim and retain the framework `Publisher`, and keeps all state-module
initializers context-only unless they genuinely consume an OTW.

ADR 0032 validates and wraps the package `Publisher` and `UpgradeCap` in one
shared package-administration object and lets a live `AdminWitness` authorize
exact upgrade digests and irreversibly narrow policy.

ADR 0033 adds an independent, nonzero Meme liquidity-provision rate to the cold
launch snapshot. It reserves destination-pool principal separately from protocol
Meme revenue and forbids Memez.Fun's overloaded zero-means-all sentinel.

ADR 0034 removes ADR 0032's speculative governance cutover — the durable
enabled flag, package-only disable path, its event, and error codes 55/58 —
because no governance design exists to call it. A future governance ADR retires
the routine-admin package path through the mandatory shared-object version gate.

ADR 0035 mints the exact one-billion-coin Meme inventory during OTW currency
initialization, immediately consumes mint authority into `Fixed` or `BurnOnly`,
and stores only the resulting balance in `LaunchTicket`.

ADR 0036 removes caller-selected precision from `launch_ticket::new`. Every
generated Meme has nine decimals and exactly
`1_000_000_000__000_000_000` atomic units.

ADR 0037's removal of ticket supply-mode custody was superseded by ADR 0043.
ADR 0047 restores Coin Registry as the only supply-mode authority. The ticket
and Launch bind only the sell-burn rate, while migration reads native mode.

ADR 0038 replaces generic projection and decomposition verbs with one naming
rule: field-named reads, destination-named `into_*` conversions, and `destroy`
for consuming wrappers that delete themselves and release their contents.

ADR 0039 stores the virtual and terminal Quote reserves as one per-Quote policy
pair and assigns curve-release and native-Quote forecasts to an off-chain SDK
function derived from immutable launch inputs rather than independent caps.

ADR 0040 consumes the reviewed ticket, policy, graduation, and fee-ledger seams
into one normalized `Launch<Meme, Quote>`, emits its complete initial state, and
exposes the unified creator-cap plus native metadata-cap claim. Trading,
migration, pause, and version transitions remain deferred.

ADR 0042 makes that normalized launch key-only and requires the creation PTB to
consume it through `launch::share`, preventing public transfer or nesting.

ADR 0043 adds the global runtime package cutover, ticket-bound sell-burn policy,
public buy/sell and fee claims, and an atomic
witness-typed migration payload. Fixed terminal disposal goes to `0x0` without
reducing total supply; BurnOnly disposal uses the native registry burn.

ADR 0044 adds one validated `Bps` unit for stored rates and package arithmetic.
Domain modules retain stricter ceilings and combined-rate policy, while public
setter inputs and replay event fields remain raw `u64` values.

ADR 0045 removes the redundant per-Launch version. Runtime config now holds the
only operational package version for Launch and package-administration cutover.

ADR 0046 moves the sealed external adapter witness from permissionless
`launch::migrate` to `launch::redeem_migration`. The migration caller selects
the snapshotted witness type, while only that witness's owner can open the
non-droppable payload in the same transaction.

ADR 0047 makes native Coin Registry state the only supply-mode authority. The
ticket and Launch retain `sell_burn_bps` but no cached `burnable` Boolean, and
migration selects Fixed or BurnOnly disposal directly from `Currency<Meme>`.

ADR 0048 turns `sui/` into a package workspace. The current `blast_fun` package
lives in `sui/launchpad/`; future venue adapters and vesting packages live below
`sui/migrators/` and `sui/vesting/` with independent manifests and lockfiles.

ADR 0049 moves the one operational package version into a dedicated singleton
so every mutable shared object can use the same gate without a module cycle. It
separates native upgrade commit from checked bytecode activation, hardens launch
and migration-witness intake, and removes a migration-time recheck of immutable
launch policy.

ADR 0050 keeps the compiled package generation as a private constant beside the
`PackageVersion` initializer and guards. The package constants registry no
longer exposes a value that no other module consumes.

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
