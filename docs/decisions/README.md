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

Every ADR must cite external ABI facts at an immutable repository revision and
path. A claim that cannot be pinned must be a **named premise with a
falsification test**, never an assertion.

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
| [0051](0051-generated-meme-package-template.md) | Generated Meme package template | **accepted** |
| [0052](0052-stepped-linear-vesting.md) | Fully funded stepped-linear vesting | **accepted** |
| [0053](0053-single-validator-funsui-and-blastsui.md) | Single-validator `funSUI` and `blastSUI` | **accepted** |
| [0054](0054-v3-dex-migrators-and-locked-lp-fees.md) | V3 DEX migrators, exact seed pricing, and locked LP fees | **accepted** |
| [0055](0055-global-vesting-package-and-checkpoints.md) | Global vesting package and checkpoint schedules | **accepted** |
| [0056](0056-bounded-pending-stake-vector.md) | Bounded pending-stake vector in custody ledgers | **accepted** |
| [0057](0057-admin-pinned-venue-tiers.md) | Admin-pinned venue tiers for permissionless migration | **accepted** |
| [0058](0058-eventless-package-initialization.md) | Eventless package initialization | **accepted** |
| [0059](0059-production-launchpad-abi-and-sdk-parity.md) | Production launchpad ABI and first SDK parity boundary | **accepted** |
| [0060](0060-blastsui-metadata-cap-custody.md) | Retain currency and receipt update capabilities in package-admin custody | **accepted** |
| [0061](0061-blastsui-routine-admin-and-composable-package-custody.md) | Routine administration and composable package custody for blastSUI | **accepted** |
| [0062](0062-table-backed-quote-registry.md) | Table-backed quote registry without a protocol cardinality cap | **accepted** |
| [0063](0063-aftermath-weighted-pool-migrator.md) | Aftermath weighted-pool migration with permanently locked LP tokens | **accepted** |
| [0064](0064-aftermath-backed-leverage-coins.md) | Aftermath-backed `SUI2L` and `SUI2S` leverage coins | proposed |
| [0065](0065-discoverable-blastsui-treasury-caps.md) | Discoverable blastSUI treasury-cap custody | **accepted** |
| [0066](0066-aftermath-dao-fee-pool.md) | Aftermath DAO-fee wrapper and claimable launch revenue | **accepted** |
| [0067](0067-retire-full-sail-migrator.md) | Retire the Full Sail migrator before release | **accepted** |
| [0068](0068-compact-lp-fee-principal-snapshot.md) | Compact the LP-fee principal snapshot before release | **accepted** |
| [0069](0069-consolidate-launch-graduation-and-move-migration-math.md) | Consolidate launch graduation and move migration math into migrators | **accepted** |
| [0070](0070-series-one-versioning-and-role-administration.md) | Series1 operational version and role administration | **superseded** |
| [0071](0071-series-one-vault-issuance.md) | Series1 Vault and dynamic share-currency issuance | **superseded** |
| [0072](0072-series-one-package-capability-custody.md) | Series1 package-capability custody | **superseded** |
| [0073](0073-series-one-adapter-owned-vaults.md) | Series1 core with adapter-owned product Vaults | **accepted** |
| [0074](0074-aftermath-vault-activation-and-health.md) | Aftermath Vault activation and health evidence | **accepted for dependency and raw-field normalization** |
| [0075](0075-independent-holder-fee-distributor.md) | Independent holder fee distributor | **accepted; live release gates remain** |
| [0076](0076-native-v2-and-auto-lp.md) | Native V2 and automatic liquidity deposits | **accepted; packages parked in `scratch-sui/` pending redesign ([0083](0083-migrators-own-lp-fee-policy-and-authority.md))** |
| [0077](0077-fixed-creator-selected-sell-burn.md) | Fixed creator-selected sell burn | **accepted** |
| [0078](0078-explicit-curve-invariant-primitives.md) | Explicit curve invariant primitives | **accepted** |
| [0079](0079-compact-launch-state-and-events.md) | Compact launch state and events before publication | **accepted** |
| [0080](0080-provider-independent-creator-recipient.md) | Provider-independent creator recipients | **accepted** |
| [0081](0081-separate-lp-fee-share-policy.md) | Separate LP-fee share policy with per-project pins | **accepted** |
| [0082](0082-revocable-creator-and-lp-fee-capabilities.md) | Revocable curve-fee, metadata, and LP-fee capabilities | **accepted** |
| [0083](0083-migrators-own-lp-fee-policy-and-authority.md) | Migrators own LP-fee policy and migration-born LP-fee authority | **accepted** |
| [0085](0085-explorer-visible-type-naming.md) | Explorer-visible type naming: every on-chain type names Blast | **accepted** |
| [0086](0086-maintenance-reserve-ceiling.md) | Maintenance reserve ceiling: `max_reserve_bps` of notional, clamped credits, priced-after-release, no admin release | **accepted** |
| [0087](0087-vault-issuance-activated-in-one-transaction.md) | Vault issuance activated in one transaction: `issue` returns a hot-potato issuance, `initialize` returns the Vault, no optional activation fields | **accepted** |
| [0088](0088-authenticated-market-margin-updates.md) | Authenticated market margin updates: live venue policy with exact account checkpoints | **accepted** |

ADRs 0013–0036, 0038–0063, 0065–0069, 0073, 0077–0083, and 0085–0088 are accepted; ADR 0074 accepts the Aftermath dependency and raw-field normalization while retaining its live evidence gate; ADR 0037 is superseded by 0043, and ADRs 0070–0072 are superseded by 0073. ADR 0021 accepts the pure curve formulas and
package boundary, while ADR 0022 accepts the trade-fee ceiling, live global split
semantics, embedded ledger, and claim boundary. ADR 0023 accepts the generated-coin
supply modes, one-billion ceiling, and separate native metadata-cap return. ADR
0024 accepts the generated-coin launch-ticket boundary, ADR 0025 the
administrator-curated quote whitelist and immutable per-launch target snapshot,
ADR 0062 moves that whitelist to a Table without a protocol cardinality cap, and ADR 0026 the
deferred terminal sell-burn lifecycle. Other deployment constants, public ABI,
and storage commitments still await approval.

ADR 0027 accepts the graduation economics, launch-policy consolidation,
bounded migration-witness admission, external migrator package boundary, and
the exclusion of DEX pool-opening fees.

ADR 0055 consolidates vesting under one package and adds exact irregular
checkpoint schedules. A linear builder stores up to 256 entries in an inline
vector; claims use binary search and retain ADR 0052's fixed-beneficiary and
fair-cancellation policy.

ADR 0028 consolidates the dedicated creator-claim signer and live protocol fee share into
one small `RuntimeConfig`, while preserving separate `ProtocolAuthority` and
cold `LaunchConfig` shared objects.
ADR 0081 keeps that share for bonding-curve trades only and moves LP-fee splits
to a separate `LpFeePolicy` with Meme-keyed partner pins.

ADR 0080 separates the launcher from the designated creator recipient and
replaces provider-specific social identity with an opaque Blast account
commitment. Securely linked login methods remain off chain, so new providers do
not change the contract ABI.

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

ADR 0051 adds the buildable generated Meme package template. Its initializer
calls the Blast launch-ticket constructor and sends the returned ticket to the
publisher, converting P6 into compile evidence.

ADR 0052 adds a framework-only Sui vesting package with fully funded,
fixed-beneficiary stepped-linear schedules. Cancellation is opt-in through a
schedule-bound capability and can return only unvested value.

ADR 0053 accepts the independent `blast_sui` package: a 1:1 `funSUI` ledger
and a `blastSUI` share ledger with separate native positions on one immutable
validator, a yield sweep from fun to blast custody behind a fixed rounding
reserve, a seed `blastSUI` supply locked at `@0x0` so every redemption is a
fee-paying partial exit, a bounded redemption fee, and one package-local
package-local authority boundary for fee changes and upgrades, as amended by
ADR 0061.

ADR 0054 accepts isolated V3 adapter packages, real-balance seed pricing, locked
LP principal, and the operational recommended SUI lane. Its Memez, Raydium,
Pump, and Hop comparisons are context only; they do not set an on-chain USD
oracle or immutable global default.

ADR 0057 amends 0054: permissionless migration reads its venue fee tier from
one admin-pinned shared `VenueConfig` singleton instead of caller parameters,
failing closed until each venue is pinned.

ADR 0058 amends 0011 and reverses 0030's creation-event exception: no `init`
emits an event in any package, because every field those payloads carried is
either recorded by the publish transaction's native effects or compiled into the
published bytecode.

ADR 0059 freezes the production launchpad, generated Meme, and aggregate
migrator ABI at contract commit `a5ed34ad49c6c001af2db5b9cbcb206075704412`.
It fixes current-package call targets, original-package type identity,
shared-object mutability, complete event decoding, and the first SDK migration,
LP-vault, and replay parity boundary.

ADR 0060 amends 0053 before the first blastSUI deployment. Both currency
initializers retain their unique native metadata capabilities, the receipt
Display creator returns its unique update capability, and the deployment flow
moves all three into the shared `PackageAdmin`.

ADR 0061 narrows the blastSUI `SuperAdminCap` to routine-admin membership and
root rotation. Live `AdminCap` sign-in produces the witness for routine fee and
package operations. Package custody now uses the composable
construct–attach–finalize lifecycle, with exact-type dynamic object fields for
current and future child capabilities.

ADR 0063 adds an Aftermath weighted-pool migrator. It creates a zero-flatness
pool with admin-pinned role weights, reconciles the complete
source balances and LP supply, and permanently locks every liquid LP token.
ADR 0066 wraps it with Aftermath's DAO-fee pool, fixes the unavoidable base fee
at 0.01%, sends a 2% default DAO fee to the vault address, and locks the DAO
owner cap beside the LP. Admins can change the DAO rate for future or existing
pools without changing the recipient. Permissionless typed receive paths accrue
DAO fee coins through the common creator/protocol ledger without touching LP
principal.

ADR 0064 proposes standalone `SUI2L` and `SUI2S` fungible coins backed by
separate, capability-controlled Aftermath SUI-USDC accounts. A sealed adapter
keeps venue authority outside core share math. Actual post-execution NAV prices
mint and redemption. Retained USDC fees enter a funding-only maintenance reserve
that is excluded from shareholder NAV but improves venue margin. Liquidation
reduces NAV without deleting wallet-held coins. The decision remains proposed
until its venue, valuation, liquidation, and liveness premises pass live tests.

ADR 0065 amends 0053 before the first blastSUI deployment. Both treasury caps
enter permanent, type-keyed dynamic object field custody under the vault, so
standard Sui infrastructure can read their canonical supplies without exposing
mint or burn authority outside vault transitions.

ADR 0067 retires Full Sail before the aggregate migrators package's first
recorded production release. It removes the adapter, both local interface
packages, all six routes, the venue-tier default, release checks, and SDK APIs.
The remaining five venues expose 13 migration routes and eight fee-accrual or
collection routes.

ADR 0068 compacts the pre-release `LpFeesCollected` event. Venue adapters still
read principal before and after collection and abort unless it is unchanged,
but the completed event records only the verified final `principal_liquidity`
snapshot. The SDK reducer consumes that one canonical value.

ADR 0069 removes the separate graduation helper module and puts its private
balance partitions in `launch`. It also moves all seed-price, deviation,
utilization, and residual arithmetic into the aggregate migrators package with
package-only visibility and migrator-local error codes.

ADR 0073 supersedes ADRs 0070 through 0072. Series1 owns one global multi-role
administrator registry plus venue-neutral policy, lifecycle, accounting, and
`State<Product>`. Each adapter owns its version, upgrade custody, outer
`Vault<Product>`, currency capabilities, risk-module selection, and venue
state. Runtime product witnesses let one adapter package issue several distinct
currencies without an adapter root or generic handoff.

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
| P7 | What is Bluefin's exact protocol fee share on creator-created pools? | [0006](0006-fees-and-launch-paths.md) |
| P8 | Does `display_registry` expose any `DisplayCap` destruction path? | [0001](0001-sui-package-and-module-layout.md) |
| P9 | Can an adapter determine pair support before consuming the migration payload? | [0005](0005-quote-asset-generalisation.md), [0010](0010-migration-and-venue-adapters.md) |
| P10 | Can a no-ability struct be threaded through a call in another package within one transaction? | [0002](0002-coin-creation-and-currency-authority.md) |
| P11 | Can `TreasuryCap<T>` be passed by value across a transaction command boundary? | [0002](0002-coin-creation-and-currency-authority.md) |
| P12 | Does `display_registry::new_with_publisher<T>` accept a generic instantiation? | [0001](0001-sui-package-and-module-layout.md) |
| P13 | Can a module's `init` accept a shared object such as `&mut CoinRegistry`? | [0002](0002-coin-creation-and-currency-authority.md) |
| P14 | Can a transaction command result be a Move reference? | [0002](0002-coin-creation-and-currency-authority.md) |
| P15 | Can every supported login return an immutable provider subject that the backend securely maps to exactly one Blast account without email-based auto-linking? | [0080](0080-provider-independent-creator-recipient.md) |
| P16 | Does the deployed Aftermath ABI support the complete same-transaction account, cap-custody, and session flow? | [0064](0064-aftermath-backed-leverage-coins.md) |
| P17 | Can the adapter reproduce Aftermath equity, signed fixed-point rounding, and each exact funding settlement in atomic USDC? | [0064](0064-aftermath-backed-leverage-coins.md) |
| P18 | Does the custom position IMR remain an effective floor through market changes and liquidation? | [0064](0064-aftermath-backed-leverage-coins.md) |
| P19 | Does the minimum external checkpoint detect every material liquidation, ADL, settlement, order, and collateral mutation? | [0064](0064-aftermath-backed-leverage-coins.md) |
| P20 | Which risk-reduction and settlement operations remain live in every Aftermath pause, freeze, stale-oracle, and settlement mode? | [0064](0064-aftermath-backed-leverage-coins.md) |

**Load-bearing premises.** P10, P11, P13 and P14 together carry the launch transaction composition:
P13 forces currency creation into `init` and therefore the OTW path; P14 forces the `TreasuryCap` to move
by value rather than by reference; P10 and P11 make the core-adapter-core threading expressible. Each has
a stated fallback — reservation in its own transaction with a persisted single-use record — so a failure
costs a transaction, not the architecture. Their owning ADRs define the
required compile fixtures.

None is treated as established until its named compile, localnet, or integration
test passes, and none is asserted as a cited fact in the records.
