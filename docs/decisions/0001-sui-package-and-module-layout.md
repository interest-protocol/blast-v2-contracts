# 0001: Sui package and module layout

- Status: proposed
- Date: 2026-08-22
- Amended by: [0020](0020-admin-cap-self-destruction.md), [0028](0028-hot-cold-runtime-configuration.md)

## Sources

| Ref | Full commit | Repository |
| --- | --- | --- |
| `su@a3552af` | `a3552af11a531717378b6337a174f9340d1099dc` | interest-protocol/su-lending |
| `sui@ae60d06` | `ae60d065ed27576d25ac1c94145e5ffe3ddcf89e` | MystenLabs/sui |
| `cetus@ddfbdeb` | `ddfbdeba174319998b012de876ab7ec23c3ab0bc` | CetusProtocol/cetus-contracts |
| `bluefin@91ce930` | `91ce930575b2aa3decab9b7e129b8002deba80c1` | fireflyprotocol/bluefin-spot-contract-interface |
| `turbos@cff6932` | `cff693265bfc41c7de2233afe31c9d7428adc9e1` | turbos-finance/turbos-sui-move-interface |

Naming and style rules are taken from the current
[Move code quality checklist](https://move-book.com/guides/code-quality-checklist/), read 2026-08-22.

## Context

`sui/Move.toml` declares one package, `blast_fun`, edition `2024`, named address `blast_fun = "0x0"`.
`sui/sources/` is empty. The layout must be decided before any module creates a public ABI, because
`../architecture.md` treats public types, signatures, event schemas, and storage layouts as release
commitments, and old Sui package versions remain callable after an upgrade.

Two forces pull in opposite directions:

1. `../architecture.md` starts from **one package per chain** and adds a package only for a real
   security or dependency boundary.
2. Every venue integration available today violates the immutable-dependency rule in `../../AGENTS.md`.
   Cetus pins `rev = "mainnet-v1.3.0"` — a git tag, not a commit
   (`cetus@ddfbdeb:packages/cetus_clmm/Move.toml:7-8`). Bluefin pins `rev = "mainnet-v1.35.2"` and
   ships an interface package whose bodies are `abort 0`
   (`bluefin@91ce930:Move.toml:7-9`, `bluefin@91ce930:sources/pool.move:202`). Turbos pins the Sui
   framework itself to `rev = "testnet"`, a **mutable branch**
   (`turbos@cff6932:clmm/Move.toml:7`).

Pulling any of those into `blast_fun` would make the trusted core unreproducible.

## Decision

### Package set

| Package | Contains | Depends on |
| --- | --- | --- |
| `blast_fun` | all core protocol logic and every neutral shared type | Sui framework only |
| `blast_fun_cetus` | Cetus route preflight and migration adapter | `blast_fun`, Cetus |
| `blast_fun_bluefin` | Bluefin migration adapter | `blast_fun`, Bluefin |
| `blast_fun_turbos` | Turbos migration adapter | `blast_fun`, Turbos |
| `blast_fun_revshare` | epoch settlement and claims | `blast_fun` (types only), Sui framework |
| `blast_fun_template` | generated per-launch coin package | `blast_fun`, Sui framework |

Each adapter is a separate package because it carries a distinct external failure surface and a distinct
dependency-immutability exemption — the boundary test in `../architecture.md`. `blast_fun_revshare` is
separate because it is separately governed and holds funds; it must not be able to touch curve state.

### Modules inside `blast_fun`

Layered, with dependencies pointing only downward:

```text
6  launch          lifecycle, state transitions, entrypoints
5  fees            accrual, split, claim
4  curve           quote and reserve transitions
3  launch_ticket   generated OTW currency creation and pre-launch capability custody
   route           RouteRequest / RouteCommitment / PreparedLaunch
   migration       MigrationPayload handoff type
2  acl             ProtocolAuthority, SuperAdminCap, AdminCap delegation
   runtime_config  shared live X backend key and protocol/creator fee percentage
   launch_config   cold quote, graduation-default, and migrator-witness policy snapshots
   creator_authority address/X claim state and CreatorCap issuance
   display         Display custody and field policy
1  math            pure arithmetic, rounding-named helpers
   events          event structs and emitters
   constants       protocol constants
   errors          package error-code macros and test-only registry aliases
```

`math`, `events`, `constants` and `errors` hold no authority and no storage. `route` and `migration`
define types only; they contain no venue knowledge.

Physically, `constants`, `errors`, `events`, and `events_wrapper` live under `sources/lib/`; domain
modules remain directly under `sources/`. The directory is navigational only and does not change their
`blast_fun::<module>` names or visibility. Further directories require a durable multi-module concern,
not a one-file taxonomy.

### Dependency direction, stated without contradiction

**`blast_fun` imports no venue package, at launch or at migration.** Core *defines* the neutral route
types; every adapter depends **inward** on core. Composition between core and an adapter happens **in
the programmable transaction block, not in core code**: a transaction threads core-defined values
through an adapter call and back into core.

This is the composable-API rule of `../engineering-principles.md` applied literally, and it is why the
launch transaction in [ADR 0002](0002-coin-creation-and-currency-authority.md) can perform venue
preflight without core ever naming Cetus, Bluefin, or Turbos.

### Naming and style

- package-wide protocol values live in `constants.move` behind lower-snake-case
  `macro public(package)` accessors; related values are derived rather than repeated;
- package error macros are lower snake case; their optional `#[test_only]` registry aliases use
  `EPascalCase`; truly test-local fixture constants use `ALL_CAPS`;
- primitive integer bounds and common math/vector operations come from the pinned MoveStdlib; never
  introduce `MAX_U*` literal duplicates or local helpers without checking that source first;
- capabilities suffixed `Cap`, events named as completed facts in past tense;
- `public` or `entry`, never `public entry`;
- parameter order: primary object, capability, domain values, system objects such as `Clock`,
  `TxContext` last;
- a getter requires a concrete onchain production caller; when justified, name
  it after the field and use `_mut` only for mutable access;
- `public(package)` for cross-module internals; `public` only where external composability requires it.

### Public surface inventory

Every `public` item must appear in this table with the composability requirement that forces it. The
table is a release commitment: adding a row is an ABI change, and removing one is impossible once
published.

| Item | Kind | Why it must be public |
| --- | --- | --- |
| `launch::prepare` | function | first command of the launch PTB; its results feed an adapter in another package |
| `launch::finish` | function | last command of the launch PTB; consumes the adapter's sealed commitment |
| `launch::buy`, `launch::sell` | function | must compose inside router PTBs and return owned coins |
| `launch::quote_buy`, `launch::quote_sell` | functions | frontends need authoritative read-only quotes derived from actual launch state rather than caller-supplied reserves and rates ([ADR 0025](0025-quote-whitelist-and-migration-targets.md)) |
| `launch::begin_migration` | function | produces the single-use handoff consumed by an adapter package |
| `launch::settle_migration` | function | consumes the adapter's sealed settlement |
| `route::RouteRequest`, `route::RouteCommitment`, `route::PreparedLaunch` | types | crossed by adapter packages |
| `route::seal_commitment` | function | adapter-witness-gated constructor; the only way to build a commitment |
| `migration::MigrationPayload` | type | crossed by adapter packages |
| `launch::claim_creator_fees`, `launch::claim_protocol_fees` | function | embedded fee state is reached through the launch while both claimed coins are returned for composition ([ADR 0022](0022-dual-asset-fee-ledger-and-claims.md)) |
| `acl::ProtocolAuthority`, `acl::SuperAdminCap`, `acl::AdminCap`, `acl::AdminWitness` | types | shared administration registry, externally held capabilities, and the drop-only transaction proof passed across privileged module boundaries ([ADR 0015](0015-protocol-authority-and-x-signer-state.md)) |
| `acl::add_admin`, `acl::revoke_admin` | functions | root-holder transactions deliberately deliver and immediately revoke routine admin authority |
| `acl::destroy_admin_cap` | function | an admin-cap holder must be able to renounce live membership or delete an already-revoked cap for its storage rebate ([ADR 0020](0020-admin-cap-self-destruction.md)) |
| `acl::sign_in` | function | external PTBs must turn a currently registered `AdminCap` into the drop-only witness accepted by feature setters |
| `acl::begin_super_admin_transfer`, `acl::cancel_super_admin_transfer`, `acl::accept_super_admin_transfer`, `acl::destroy_retired_super_admin_cap` | functions | root rotation is a wallet-driven delayed two-party lifecycle |
| `runtime_config::RuntimeConfig` | type | small shared singleton consumed by public X creator claims and every trade for the dedicated signer and live protocol fee share ([ADR 0028](0028-hot-cold-runtime-configuration.md)) |
| `runtime_config::set_x_claim_signer`, `runtime_config::revoke_x_claim_signer`, `runtime_config::set_protocol_fee_share` | functions | protocol administrators mutate the two live domains with a borrowed `AdminWitness` and typed replay-complete events |
| `launch_config::LaunchConfig` | type | shared bounded cold policy containing quote targets, graduation defaults, and external migrator witness types selected when new launch state snapshots its economics ([ADR 0025](0025-quote-whitelist-and-migration-targets.md), [ADR 0027](0027-graduation-economics-and-migration-witnesses.md)) |
| `launch_config::allow_quote`, `launch_config::set_migration_quote_target`, `launch_config::remove_quote` | functions | protocol administrators curate future launch admission and targets with a borrowed `AdminWitness` and replay-complete events |
| `launch_config::set_graduation_defaults`, `launch_config::allow_migration_witness`, `launch_config::remove_migration_witness` | functions | protocol administrators curate bounded future-launch terminal economics and external migrator code identities without rewriting existing launches |
| `creator_authority::CreatorCap` | type | transferable coin-typed authority consumed by creator fee and migration integrations ([ADR 0014](0014-typed-creator-cap-and-diagnostic-modules.md)) |
| `launch_ticket::LaunchTicket` | type | returned across the generated-package boundary and held by the launcher until registration completes |
| `launch_ticket::new_address`, `launch_ticket::new_x` | functions | called from a generated coin package's `init`; consume its OTW and return the ticket for deliberate delivery ([ADR 0024](0024-generated-coin-launch-ticket.md)) |
| `launch::claim_creator_cap` | function | the single address/X claim seam; consumes the stored authority after validating `TxContext::sender` and returns `CreatorCap` and native `MetadataCap` separately for composition ([ADR 0019](0019-consuming-creator-authority-and-cap-return.md)) |
| `migration::collect_lp_fees` | function | must return owned coins for composition |
| `migration::release_reservation` | function | `AdminCap`-gated venue-state cleanup before a venue switch ([ADR 0010](0010-migration-and-venue-adapters.md)) |

**No `mint` function appears in this table, in any module, at any visibility that an external caller can
reach.** That absence is an invariant with a dedicated test, not a convention — see
[ADR 0003](0003-treasury-cap-lifetime-and-burn.md).

### Display for Blast's own objects

`Display<phantom T>` and its `DisplayKey<T>` are **per concrete type instantiation**
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/display_registry.move:38-50`).
`Launch<Meme, Quote>` and `LpVault<Meme, Quote>` are a *different type for every pair*, so displaying
them means **one `Display` object created and shared per launch**, each with its own `DisplayCap`, its
own storage and gas cost, and its own creation step inside the launch transaction. There is no single
"Display for Launch"; there is one per instantiation.

Options considered:

| Option | Behaviour | Cost | Risk |
| --- | --- | --- | --- |
| D-opt1 | create `Display<Launch<M,Q>>` in the launch transaction | one extra shared object plus one cap **per launch**, forever | stray `DisplayCap` per launch; depends on premise **P12** |
| **D-opt2 (chosen)** | display only non-generic protocol types; give the generic shared objects no `Display` | one `Display` per protocol type, created once at package publish | none; does not depend on P12 |
| D-opt3 | create `Display<LpVault<M,Q>>` only at migration | per-graduated-token cost, amortised | depends on P12 |

**Decision: D-opt2.** Coin presentation already comes from `Currency<Meme>` metadata
([ADR 0002](0002-coin-creation-and-currency-authority.md)) and indexers reconstruct launch presentation
from events ([ADR 0011](0011-event-schema-and-replay.md)). `Launch` and `LpVault` are shared protocol
objects that explorers resolve and wallets do not list, so a per-launch `Display` buys presentation
polish at a permanent per-launch cost. D-opt3 is the upgrade path if product later wants per-token cards.

A `DisplayKey<T>` can be claimed only once per type
(`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/derived_object.move:38-44`,
`EObjectAlreadyExists`), so a failed creation is **not retryable under the same key**. That alone makes
per-launch Display creation a liability inside a launch transaction that may abort.

For each displayed non-generic type:

- **creation** — `display_registry::new_with_publisher<T>` with the package `Publisher`, then `share`
  (`sui@ae60d06:crates/sui-framework/packages/sui-framework/sources/registries/display_registry.move:63-73, 93-96`);
- **authority** — one `DisplayCap<T>` per displayed protocol type, custodied under
  `AdminCap`, never by a creator; generated coin metadata instead follows the
  native `MetadataCap<Meme>` returned separately from `CreatorCap<Meme>` under
  ADR 0023;
- **field template** — `name`, `description`, `image_url`, `project_url`, `link`, `thumbnail_url`;
- **update rules** — `set`/`unset` are `AdminCap`-gated and emit old/new values; `clear` is prohibited
  on a live protocol type;
- **freeze** — no `DisplayCap` destruction path was observed in the module at the pinned commit
  (premise **P8**). Until P8 is closed, "frozen Display" means the cap is held under a documented
  no-update policy or transferred to an immutable holder. This ADR does not claim a capability the
  framework has not been shown to provide.

## Alternatives considered

**One package containing adapters.** Rejected: it would import three external dependencies, none of
which can currently be pinned to an immutable commit, into the trusted core.

**One package per module, mirroring the historical repository.** Rejected by `../architecture.md`:
packages are justified by boundaries, not by symmetry with a prior design.

**Core calls the adapter directly.** Rejected: it inverts the dependency direction and makes core
un-buildable without a venue dependency. PTB-level composition achieves the same transaction-atomicity
with none of the coupling.

**D-opt1 per-launch Display.** Rejected as the default on cost and on the non-retryable derived-key
risk; retained as a documented upgrade path.

## Consequences

- Core stays buildable and reproducible with the Sui framework as its only dependency.
- State modules contain no duplicated protocol constants, and standard-library arithmetic keeps primitive
  bounds out of Blast source.
- An adapter's failure or dependency drift cannot reach core.
- Every cross-package value is a core-defined type, so the adapter surface is inventoried in one place.
- Adding a venue is a new package plus a new approved witness, never a core change.
- Explorer presentation of `Launch` / `LpVault` relies on events and on `Currency<Meme>` metadata rather
  than on per-instantiation `Display`.

## Verification

- Dependency test: `blast_fun` builds with no venue dependency in its manifest.
- Constants test: production protocol values appear only in `constants.move`, and no source duplicates
  primitive `MAX_U*` bounds supplied by MoveStdlib.
- Public-surface test: an inventory test enumerates the package's public functions and fails if any
  function is public without a row in the table above.
- No-mint test: a negative test asserts no public path reaches `coin::mint` for the launch coin type.
- Display test: for each displayed type, every required field resolves to a non-empty string.
- Premise **P12** (generic instantiation accepted by `new_with_publisher`) needs a compile fixture plus a
  localnet creation **only if** D-opt1 or D-opt3 is later adopted; D-opt2 does not depend on it.
- Premise **P8** (Display freeze semantics) needs a module review at the pinned toolchain before any
  "immutable Display" claim is made.
