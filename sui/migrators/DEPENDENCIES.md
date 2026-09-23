# Migrator dependencies and release gates

This is the reproducible package-id and dependency matrix for the one aggregate
`blast_fun_migrators` package. It records what the adapters link to, how that is
re-verified against mainnet, and which gates must pass before release.

## Package boundary

Cetus and Bluefin are the only venues (ADR 0088), as modules in one
independently deployed package. The launchpad core never imports this package;
each venue module depends inward on the narrow core interface, owns one sealed
`Witness() has drop`, and redeems the core's linear `Migration` value in the same
Move call. Aftermath, MMT, and Turbos were removed before publication together
with their witnesses, local interfaces, and dependency pins.

- **Release adapter matrix.** An adapter reaches the launchpad seams (ticket
  binding, the treasury-capability borrow, `begin_migration`,
  `complete_migration`, `fee_router::collect`, and `settle_and_update_routes`)
  only by constructing its own witness. The matrix is therefore exactly
  `cetus::Witness` and `bluefin::Witness`, each completing into sealed `LpVault`
  custody. `scripts/check_source_boundaries.sh` fails when any other module
  declares a witness or calls a seam, when a completion does not prepare, attach,
  and share its vault, or when a local venue interface other than Cetus's exists.
  A future adapter is separate work: it first defines and tests its pinned-tier
  rule, its ticket binding with any venue preparation, permanent `LpVault`
  custody, its atomic route, collection, settled route update, and event
  conformance, and then extends that gate. There is no generic plug-in
  constructor.
- **One aggregate package.** Cetus and Bluefin ship together, so the release
  gate, dependency graph, and `UpgradeCap` lifecycle are shared.
- **Shared per-launch vault.** `vault::LpVault<Meme, Quote>` is one shared vault
  *type*, not one global object. Every migrated launch shares its own vault, so
  unrelated fee collections never contend on the same Sui object. The venue
  position is one dynamic **object** field under the sealed
  `vault::PositionKey<Venue>` name, with no removal, transfer, or immutable
  borrow path.
- **Protocol residual custody.** Every venue residual stays in its per-launch
  vault and is claimed only by the existing admin-gated protocol claim. No
  adapter stores a payout address, burns a nonzero residual, or sends one to
  `0x0`.
- **Router-only LP fees.** The vault holds no LP fees, fee ledger, fee
  capability, or fee policy. An adapter collects its bound position and hands
  both balances to `blast_fun::fee_router::collect`, or to
  `settle_and_update_routes` with a route change, in the same transaction; the
  router splits them by the share pair frozen at activation and pays every
  destination at once (ADR 0088).
- **Sealed venue tiers.** `venue_config::VenueConfig` is one shared singleton
  holding one `(tick_spacing, fee_rate)` entry per venue as a dynamic field
  keyed by `TierKey<Venue>`, so an upgrade-added venue module can register its
  own tier without touching the frozen struct layout. Migration is
  permissionless, so routes read the effective tier instead of trusting caller
  parameters. Only Cetus compiles a default, used while no pin exists; Bluefin
  has none, so its migration aborts until a pin exists. Only the venue module's
  sealed marker can write its entry, behind this package's own current
  generation and a live `AdminWitness<BLAST_FUN_DOMAIN>` from the shared
  Launchpad authority. A pin affects only later migrations, and for Cetus only
  later bindings: a bound Cetus ticket migrates at the tier it reserved.
- **Cetus pool-creation reservation.** Any Meme holder could pre-create the
  Cetus pool for a pair and tick spacing, so `cetus::bind` reserves creation
  before any Meme leaves the ticket: it mints the Meme type's single
  `factory::PoolCreationCap` from the lent treasury capability and registers the
  bound Quote at the effective tick spacing (compiled default 200 at 1%, the tier
  Cetus admits for permissioned SUI and USDC pairs on 2026-09-22). The
  capability is a dynamic object field of `VenueConfig`, so it keeps its ID, and
  each reserved tick spacing is a dynamic field; only `cetus` constructs either
  key, and nothing extracts the capability or unregisters a pair. Migration
  creates the pool with that capability at the reserved tick spacing and never
  adopts an existing pool. Cetus's pool-manager role can also create a reserved
  pair's pool without the capability. That is a trust assumption on the venue
  operator: such a pool makes the pair's migration abort, and recovering the
  launch would need a migrators upgrade.
- **Direct events, no wrapper.** `blast_events.move` owns the typed payloads
  and is the only module that calls `sui::event::emit`.
  This package deliberately does **not** use the core `blast_events::Event<T>`
  envelope: it is a separate package, so native payload filtering stays direct
  and the core event ABI is unchanged. Payloads carry no application sequence,
  revision, nonce, schema version, or action tag.

## Live ABI verifier

```bash
node scripts/check_mainnet_abi.mjs
```

Node built-ins only, no JSON-RPC. It POSTs to the official Sui mainnet GraphQL
endpoint `https://graphql.mainnet.sui.io/graphql`, and first asserts
`chainIdentifier` is the mainnet genesis checkpoint digest
`4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S` (`35834a8a`). For Bluefin Spot
and Cetus CLMM it then:

1. resolves the original package id to its current revision, because
   `package(address:)` returns the tip of a lineage;
2. re-reads the pinned revision through `package(address:, version:)` and fails
   when `packageVersionsAfter` reports any newer tip, naming that tip instead of
   silently adopting it;
3. asserts the expected current package id, version, whole-package object digest,
   and previous transaction on both the resolved tip and the pinned revision;
4. asserts every consumed struct's exact `typeOrigins` defining id — normally
   the original package id, with Cetus `PoolCreationCap` pinned to revision 8
   (`0x157468379cfe5616c063ae39a889dd184ad48350d3e08f8d9b4ade22b8e3fb61`), where
   it was introduced;
5. decodes each consumed module's on-chain bytes, checks the `0xa11ceb0b` Move
   magic, and asserts the committed SHA-256 fingerprint; and
6. asserts the normalized public ABI of every consumed Bluefin Spot and Cetus
   CLMM function and struct.

The `integer_mate` signed-integer helpers that Bluefin's full-range tick
alignment calls are outside this ABI check: that package is pinned by commit in
`Move.toml` and `Move.lock`, and its linkage entry is recorded under
[Transitive interface packages](#transitive-interface-packages).

### Response validation

The GraphQL response is untrusted input to a release gate, so every field is
validated before it is rendered. Each function and struct object must carry
exactly the requested fields; each list must be a real list; `isEntry` and
`isPhantom` must be real booleans; visibility, abilities, constraints, primitive
type names, reference kinds, and type-body shapes must each be a known value with
no duplicates. A null, absent, partial, or novel response is a failure, never a
value that normalizes into something an expectation happens to match. The live
schema omits `signature.ref` for a by-value type, so absence is the by-value
shape and any present `ref` — including an explicit null — must be `&` or
`&mut`. Type origins are built one entry at a time and reject a repeated
`module::struct` key, so a wrong defining id cannot be overwritten by a later
expected one; an exact repeat of the same defining id fails too.

The ABI comparison then uses the structured `OpenMoveTypeSignature`, not display
prose. Each entry renders reference mutability, every parameter in order,
type-parameter constraints, phantom markers, abilities, visibility, `entry`, and
the full return tuple. `@self` is the package's own original address, `@sui` and
`@std` are the framework addresses, and every other address is compared
literally, so a venue that re-points a helper type to a different package fails.
Missing or extra parameters, `&` versus `&mut`, visibility drift, ability drift,
phantom drift, and return drift each fail the run.

### Local pin validation

The same run parses `Move.toml`, the Cetus local interface manifest, and
`Move.lock` with a strict reader for exactly the record shapes those files use.
Comments are removed before any comparison, so commented-out text can never
satisfy an expectation, and a duplicate key, a duplicate table, an escape, a
nested inline table, or any unrecognized value form is itself a failure.

Each file is then bound to an exact expectation:

- every `[dependencies]` name set must match, and each record must match
  key-for-key and value-for-value — repository, subdirectory, local path,
  revision, and `override` rule included;
- every Git record in every checked manifest and in both lock environments must
  carry an immutable 40-hex `rev` and must not carry `branch` or `tag`, whatever
  the expectation says;
- `[package]` may declare only known keys, `published-at` must equal the current
  package id, `[addresses]` must equal the original package id, and no table
  outside `package`, `dependencies`, and `addresses` may appear;
- `Move.lock` must declare format version 4, exactly the 15 expected pinned nodes
  in each of the `mainnet` and `testnet` environments, each node's exact `source`
  record and exact resolved `deps` edges, and nothing else; every node's
  `manifest_digest` must be a string of 64 uppercase hex digits, the shape the
  Move CLI generates; and
- the local normalized interface must resolve its named `Sui` edge to a node
  whose source is `MystenLabs/sui` at
  `crates/sui-framework/packages/sui-framework` and
  `06734f6ff0af45d8632a14a4dc4b100197f6b1a2`.

### Failure behaviour

The run fails closed. Each request has a 30-second whole-request deadline
covering both the connection and the body read; transport errors, timeouts, and
HTTP 5xx retry three times, and the body is read inside that retry boundary. A
GraphQL `errors` payload, a non-JSON body, any other non-2xx status, a missing
package, a missing module, and a missing function are immediate failures.
`--emit` prints the observed facts as a paste-ready expectation block; it never
relaxes an assertion.

### Offline self-test

```bash
node scripts/check_mainnet_abi.mjs --self-test
```

Makes no network request and mutates no file. It renders a well-formed function
and struct fixture, validates the committed manifests and lock, and then asserts
that 57 mutated inputs are rejected — null lists, a missing or null `isEntry`,
unknown and duplicate abilities and constraints, unknown visibility, novel type
bodies and reference kinds, an explicit null `signature.ref`, extra response
fields, duplicate type origins with conflicting and with identical defining ids,
a commented-out dependency, a missing `rev`, `branch` and `tag` selectors, a
wrong-but-40-hex Sui revision, wrong repositories and subdirectories, added and
dropped `override` rules, duplicate keys and tables, extra and missing lock
nodes, rebound `deps` edges, boolean, malformed, and lowercase
`manifest_digest` values, and a struct pinned to its introducing revision
resolved against the original package. Six positive fixtures pin the accepted
shapes, including a by-value parameter with `ref` absent and that revision pin.
Every case that a live run cannot reach without a real venue upgrade is covered
here instead.

## Published venue packages

Re-verified on mainnet on 2026-09-02; Cetus CLMM re-pinned to revision 15 and
re-verified on 2026-09-22.

| Venue | Named address | Original package id | Current package id | Version | Package digest | Previous transaction |
| --- | --- | --- | --- | --- | --- | --- |
| Bluefin Spot | `bluefin_spot` | `0x3492c874c1e3b3e2984e8c41b589e642d4d0a5d6459e5a9cfc2d52fd7c89c267` | `0xd075338d105482f1527cbfd363d6413558f184dec36d9138a70261e87f486e9c` | 17 | `4tyboYqrPbZzN6V5Lh2TccW8j9nbH65mJeQFynoQGxut` | `CShZDVqJQrXm4SYiCgDe49kKnFzadwhFV5viqHLgRfaX` |
| Cetus CLMM | `cetus_clmm` | `0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb` | `0x260693ec785a6e6c9d81d58c7d2ff72f1288ae0fa6a9725abe05a6478b11f084` | 15 | `9rZP5D79m4Yfq9fvtPujtpvU5rhfiYm1JS6LaxcMZVSu` | `5sSoTfTiti8kXjJhZeYuFWFcxxvjbZpFQ96rZ3dzeQbC` |

## Committed module fingerprints

SHA-256 of each module's decoded on-chain bytecode at the current revision above.
Only modules that declare an adapter-consumed type or function are fingerprinted.

| Package | Module | SHA-256 of decoded on-chain bytecode |
| --- | --- | --- |
| `bluefin_spot` | `config` | `e896bcbdab23bf5c04eb38b12306f8d6ced8bb9194c789cd1f7f09c78e595cab` |
| `bluefin_spot` | `pool` | `d1436b0837eab8912797b91ed68755ad6e4228243f188a43c42ea040e844e97c` |
| `bluefin_spot` | `position` | `ea83d3b9a65c7f62579dd0a902ddad8ade46cec277e5781ab9e52783c48caaec` |
| `cetus_clmm` | `config` | `d0575fcd8fa5e6d63a779a19fbc1ee276459d151d8045bc7e7a9f5f380adfad5` |
| `cetus_clmm` | `factory` | `4cd33aca821e17cccb0004e3c78ec6033b7fec0360fdf17c03393e976efa5e9b` |
| `cetus_clmm` | `pool` | `059cbeeb4502c7e54b1a9ada73709505f9572f4c80c441c1c31fbee64c32c7a1` |
| `cetus_clmm` | `pool_creator` | `23c78096ed45feda5349e098d9827f37cee0fce662544e98ea28de5f6e8c57b6` |
| `cetus_clmm` | `position` | `78f71fd13a5ab6528509d1a2ceb279e4d6616cd8e6877baf4a5ee25627789cc3` |

## Normalized ABI coverage

| Venue | Modules | Functions | Structs | Type origins |
| --- | --- | --- | --- | --- |
| Bluefin Spot | 3 | 8 | 3 | 3 |
| Cetus CLMM | 5 | 9 | 5 | 5 |
| **Total** | **8** | **17** | **8** | **8** |

The list contains only Bluefin Spot and Cetus CLMM functions and structs the
adapters actually reference.

## Source pins

Every direct and overridden Git dependency in `Move.toml` is a full commit.

| Manifest dependency | Kind | Pin |
| --- | --- | --- |
| `blast_admin` | local | `../admin` |
| `blast_fun` | local | `../launchpad` |
| `BluefinSpot` | git `fireflyprotocol/bluefin-spot-contract-interface` | `91ce930575b2aa3decab9b7e129b8002deba80c1` |
| `CetusClmm` | local `interfaces/cetus` | normalized from mainnet revision 15 |
| `Sui` (override) | git `MystenLabs/sui`, subdir `crates/sui-framework/packages/sui-framework` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` |
| `IntegerMate` (override) | git `CetusProtocol/integer-mate` | `09a12d9b171122883d9350039d4ed6e8400033b9` |
| `IntegerLibrary` (override) | git `fireflyprotocol/integer-library` | `8a534bd1c0b334cd3937c27987f3147a06ba6a18` |

Cetus's reviewed source manifest carries no `published-at`, so Cetus ships as a
minimal local normalized interface. It preserves the venue's original type
address and sets `published-at` to the current mainnet revision. Its bodies are
`abort 0` link stubs; they exist only to type-check and to bind the runtime
package id.

Upstream `BluefinSpot/Move.toml` itself declares mutable revisions
(`Sui = mainnet-v1.35.2`, `IntegerMate = sui-v1.1.2`, `IntegerLibrary = v1.0.1`).
The aggregate manifest overrides all three with full commits, and `Move.lock`
resolves every node — including transitive ones — to a 40-hex commit, so the
built graph contains no mutable revision.

## Resolved graph

`sui move build` for both the `mainnet` and `testnet` environments compiles
exactly nine dependency nodes:

```text
BluefinSpot  CetusClmm  IntegerLibrary  IntegerMate_1  MoveSTL  MoveStdlib_2
Sui_2  blast_admin  blast_fun
```

`IntegerMate_1` is the single `09a12d9b…` integer package; Bluefin's older
`sui-v1.1.2` node is overridden away and never compiled. `MoveStdlib_2` and
`Sui_2` are the one `06734f6f…` framework pair, which the Cetus local interface
also binds in both lock environments; the lock's other framework nodes are the
upstream pins of Bluefin and its integer libraries, likewise overridden away.

Only eight addresses are referenced by the aggregate package's own bytecode, so
only those enter the published linkage table:

| Address | Referenced by `blast_fun_migrators` modules |
| --- | --- |
| `blast_admin`, `blast_fun`, and `blast_fun_migrators` | yes |
| `0x1` MoveStdlib, `0x2` Sui framework | yes |
| `bluefin_spot`, `cetus_clmm` | yes |
| `integer_mate` `0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57` | yes, Bluefin full-range tick math |
| `integer_library` `0x03637b7b60978ef4389124f7683456f0050ab015a0590d52b6e6cadb342af34a` | no, compile-only transitive |
| `move_stl` `0xbe21a06129308e0495431d12286127897aff07a8ade3970495a4404d97f9eaaa` | no, compile-only transitive |

`bluefin_spot::config::get_tick_range` returns
`0x714a63a0…::i32::I32`. Both integer-mate revisions in the graph declare that
same original address, so the overridden pin keeps one consistent `I32` type
across the Bluefin call and the adapter's own tick arithmetic.

### Transitive interface packages

| Named address | Original id | Current mainnet revision | Version | Pinned `published-at` |
| --- | --- | --- | --- | --- |
| `integer_mate` | `0x714a63a0dba6da4f017b42d5d0fb78867f18bcde904868e51d951a5a6f5b7f57` | `0xdfaadf86be9af246900d1e3f3b996cf549e7948e662a9977bdd7646d8fa3a778` | 7 | `0xdfaadf86…` — current |
| `integer_library` | `0x03637b7b60978ef4389124f7683456f0050ab015a0590d52b6e6cadb342af34a` | `0xab5e63352d0f05881bdfa1631cc0f7fc1669175a00d608828a924df481a9e4bd` | 3 | `0xab5e6335…` — current |

Both pinned interfaces already target the current mainnet revision, so the
`integer_mate` linkage entry needs no change before publication.

## Local gate

Run from this directory:

```bash
node scripts/check_mainnet_abi.mjs --self-test
node scripts/check_mainnet_abi.mjs
sui move build
sui move lint --warnings-are-errors
sui move test --lint
sui move build -e mainnet
bash scripts/check_source_boundaries.sh
```

A local build proves type compatibility only. The interface bodies are `abort 0`
stubs, so no venue call executes in the Move tests under `tests/`; venue
behaviour is exercised only by the dev-inspect matrix below.

## Mainnet dev-inspect matrix

The release matrix is Cetus and Bluefin. Each row below is one dev-inspect
fixture against the published venue packages above, in the orientation named by
the route. No route may be skipped, and a skipped row is a release blocker, not
a documentation footnote. Vault claim: `vault::claim_protocol_fees` pays the
protocol migration residuals under `AdminWitness<BLAST_FUN_DOMAIN>` and this
package's current generation. It touches neither the venue nor the position.

Cetus's compiled default tier is active from publication, and a Cetus fixture
that overrides it must record that Cetus registers the pinned
`(tick_spacing, fee_rate)`. Bluefin has no default, so its migration fixture
runs after a tier pin.

Each migration fixture must show:

- the balance-derived `sqrt_price_x64` matches the exact Q64.64 target for that
  orientation, with no caller-supplied price and no display-decimal scaling;
- full-range ticks come from the venue's pinned tick helpers and align inward to
  the selected tick spacing; and
- the returned position belongs to the new pool, has positive liquidity, and
  enters the vault as its one sealed dynamic object field.

Each router-bound collection fixture must show venue liquidity is identical
immediately before and after collection, the vault, pool, and position ids match
the router's settlement binding, and the collected balances reach the router
unchanged.

One venue-semantics row was already **proven against published mainnet
bytecode on 2026-08-30** by disassembling the live module (fetched through the
official GraphQL endpoint, disassembled with the pinned `sui move
disassemble`); the dev-inspect fixtures re-confirm it end to end:

- **Bluefin order acceptance.** The current `bluefin_spot::pool` module
  contains no type-name comparison at all, so no canonical-order check exists
  to reject the hard-coded Meme-as-coin-A order for any Quote.

### Cetus revision-3 rows

| Route | Orientation and authority |
| --- | --- |
| `bind` | Binds a launch ticket in `Quote` through the core and reserves the pair's Cetus pool creation; aborts unless `LaunchConfig` admits `cetus::Witness` |
| `migrate_meme_a`, `migrate_meme_b` | Permissionless; the route matching the pair's Cetus coin order |
| `collect_fees_meme_a`, `collect_fees_meme_b` | Permissionless; pays the router's current routes |
| `settle_and_update_routes_meme_a`, `settle_and_update_routes_meme_b` | Under the launch's `RouterConfigCap`; pays the current routes, then commits the proposed ones |

Each Cetus fixture must show:

- `bind` mints the Meme type's single `PoolCreationCap` from the lent treasury
  capability on its first binding only and keeps it as a `VenueConfig` dynamic
  object field, registers the Quote at the effective tick spacing, aborts with
  `ETierMismatch` unless Cetus registers that tick spacing at the effective fee
  rate, and emits `CetusPoolReserved`; a Quote already reserved keeps its
  reservation;
- each migration route aborts with `EInvalidCoinOrder` unless Cetus's own
  `factory::is_right_order` agrees with it, and creates the pool only with the
  reserved `PoolCreationCap` at the reserved tick spacing, never adopting one;
- liquidity is seeded with the exact handed-off balances; whatever the venue does
  not take stays in the vault as protocol residuals, and supplied principal plus
  residual reconciles exactly with the hand-off;
- the position enters the vault under `PositionKey<cetus::Venue>`, the vault is
  shared, the router is bound to the vault, pool, and position IDs, and the
  caller receives no object; and
- collection and the settled update collect only that position on its own pool
  (another pool aborts with `EPositionPoolMismatch`), leave its liquidity
  unchanged, and pay through the router, the update under the old routes first.

### Bluefin revision-3 rows

| Route | Orientation and authority |
| --- | --- |
| `bind` | Binds a launch ticket in `Quote` through the core; aborts unless `LaunchConfig` admits `bluefin::Witness` |
| `migrate` | Permissionless; creates `Pool<Meme, Quote>` with Meme as coin A |
| `collect_fees` | Permissionless; pays the router's current routes |
| `settle_and_update_routes` | Under the launch's `RouterConfigCap`; pays the current routes, then commits the proposed ones |

Each Bluefin fixture must show:

- `migrate` aborts until `bluefin::set_tier` pins a pair (there is no compiled
  default), and Bluefin's own pool creation bounds that pair: tick spacing at
  most 400 (`pool` aborts 1026) and fee rate at most 20,000 (1027), so an
  above-bound pin leaves the launch MigrationReady until a valid pin;
- the pool is created with `create_pool_and_get_object<Meme, Quote, SUI>` at the
  balance-derived `sqrt_price_x64`, full-range ticks aligned inward to the pinned
  spacing, and the caller's whole `Coin<SUI>` as the creation fee, which Bluefin
  accepts only at exactly its configured SUI amount (1038 for an unsupported fee
  coin, 1039 for any other amount); the Quote's shared `Currency` supplies coin
  B's symbol, decimals, and icon;
- liquidity is seeded with the exact handed-off balances, fixing Meme when its
  atoms are at least the Quote atoms and Quote otherwise; whatever the venue does
  not take stays in the vault as protocol residuals, with no utilization bound,
  and supplied principal plus residual reconciles exactly with the hand-off;
- the position enters the vault under `PositionKey<bluefin::Venue>`, the vault and
  the pool are shared, the router is bound to their IDs and the position's, and
  the caller receives no object; and
- collection and the settled update collect only that position on its own pool
  (another `Pool<Meme, Quote>` aborts with `EPositionPoolMismatch`), leave its
  liquidity unchanged, and pay through the router, the update under the old
  routes first.

## Release gate

The package stays upgradeable (ADR 0088): venues gate callers by package
version, so adapters must be able to relink after a venue upgrade, and its
`UpgradeCap` is never destroyed. Every migrators upgrade uses the compatible
policy, which no path narrows, and must bump both generation constants in
`package_version.move`: `commit_upgrade_and_advance` always advances the stored
generation, so a build that keeps the old constants fails every generation
check, `authorize_upgrade` included, and freezes the package. Source omission
does not make principal custody permanent while the package has an
`UpgradeCap`: a compatible upgrade could add an extraction function. The correct
public statement is therefore that principal is held by an upgradeable package
with no exposed withdrawal path, never that it is permanently locked. Do not add
a migrator admin capability as an alternative.

Before release, in order:

1. `node scripts/check_mainnet_abi.mjs --self-test` and
   `node scripts/check_mainnet_abi.mjs` both pass, the latter against live
   mainnet;
2. the local build, lint, test, and source-boundary gates pass;
3. every row of the replacement Cetus and Bluefin dev-inspect matrix passes,
   including each migration, collection, and settled route-update route in every
   orientation; and
4. the deployment runbook admits exactly `cetus::Witness` and
   `bluefin::Witness` in the Launchpad `LaunchConfig` with
   `launch_config::allow_migration_witness`, each only after that adapter's
   binding, migration routes, collection, and settled update are reviewed and
   its dev-inspect rows pass, and `bluefin::Witness` only after
   `bluefin::set_tier` has pinned the Bluefin tier. No other migration witness
   exists in this package, and none is admitted.

After release, before `launch_config::allow_meme_decimals` admits a new Meme
precision, rerun the migration extremes at that precision (the smallest and
largest LP Meme and LP Quote hand-offs, in each coin order) against real venue
bytecode on each admitted venue.
