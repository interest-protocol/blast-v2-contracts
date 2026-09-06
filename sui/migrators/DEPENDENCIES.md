# Migrator dependencies and release gates

This is the reproducible package-id and dependency matrix for the one aggregate
`blast_fun_migrators` package. It records what the adapters link to, how that is
re-verified against mainnet, and which gates must pass before any deployment may
be described as permanently locked.

## Package boundary

All five venues are modules in one independently deployed package. The launchpad
core never imports this package; each venue module depends inward on the narrow
core interface, owns one sealed `Witness() has drop`, and redeems the core
migration payload in the same Move call.

- **One aggregate package.** Bluefin, MMT, Cetus, Turbos, and Aftermath ship
  together, so the release gate, dependency graph, and `UpgradeCap` lifecycle are
  shared. One custody and claim surface is worth one all-venues release gate.
- **Shared per-launch vault.** `vault::LpVault<Meme, Quote>` is one shared vault
  *type*, not one global object. Every migrated launch shares its own vault, so
  unrelated fee collections never contend on the same Sui object. The venue
  position is one dynamic **object** field under the sealed
  `vault::PositionKey<Venue>` name, with no removal, transfer, or immutable
  borrow path.
- **Protocol residual custody.** Every venue residual stays in its per-launch
  vault and is drained only by the existing admin-gated protocol claim. No
  adapter stores a payout address, burns a nonzero residual, or sends one to
  `0x0`.
- **Same live protocol fee share.** `vault::accrue_fees` reads
  `runtime_config::protocol_fee_share_bps` at each collection and splits new fees
  through the same core `FeeLedger` used by bonding-curve trade fees. Protocol
  amounts round up, creators receive the exact remainder, and already accrued
  ownership never changes.
- **Sealed venue tiers with compiled defaults.** `venue_config::VenueConfig`
  is one shared singleton holding one `(tick_spacing, fee_rate)` entry per
  venue as a dynamic field keyed by `TierKey<Venue>`, so an upgrade-added
  venue module can register its own tier without touching the frozen struct
  layout. Migration is permissionless, so routes read the effective tier
  instead of trusting caller parameters. Each venue module compiles a
  researched highest-tier default (see the README table, sourced from live
  mainnet registries on 2026-08-30) and falls back to it while no pin exists;
  only that module's sealed witness can write its entry, behind this package's
  own current generation and a live `AdminWitness<LAUNCHPAD_DOMAIN>` from the
  shared Launchpad authority. The singleton stays adjustable after the package
  `UpgradeCap` is destroyed and affects only later migrations.
- **Direct events, no wrapper.** `events.move` owns nine typed payloads,
  including `AftermathPolicyUpdated`, `AftermathMigrationCompleted`, and
  `AftermathDaoFeeUpdated`, and is the only module that calls
  `sui::event::emit`.
  This package deliberately does **not** use the core `events_wrapper::Event<T>`
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
`4btiuiMPvEENsttpZC7CZ53DruC3MAgfznDbASZ7DR6S` (`35834a8a`). For Bluefin, MMT,
Cetus, Turbos, Aftermath AMM, and Aftermath DAO Fee it then:

1. resolves the original package id to its current revision, because
   `package(address:)` returns the tip of a lineage;
2. re-reads the pinned revision through `package(address:, version:)` and fails
   when `packageVersionsAfter` reports any newer tip, naming that tip instead of
   silently adopting it;
3. asserts the expected current package id, version, whole-package object digest,
   and previous transaction on both the resolved tip and the pinned revision;
4. asserts every consumed struct's exact `typeOrigins` defining id — normally
   the original package id, with Aftermath `CreatePoolCapV2` pinned to revision
   3 where it was introduced;
5. decodes each consumed module's on-chain bytes, checks the `0xa11ceb0b` Move
   magic, and asserts the committed SHA-256 fingerprint; and
6. asserts the normalized public ABI of every consumed function and struct.

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

The same run parses `Move.toml`, the four local interface manifests, and
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
- `Move.lock` must declare format version 4, exactly the 19 expected pinned nodes
  in each of the `mainnet` and `testnet` environments, each node's exact `source`
  record and exact resolved `deps` edges, and nothing else; every node's
  `manifest_digest` must be a string of 64 uppercase hex digits, the shape the
  Move CLI generates; and
- each local normalized interface must resolve its named `Sui` edge to a node
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
that 56 mutated inputs are rejected — null lists, a missing or null `isEntry`,
unknown and duplicate abilities and constraints, unknown visibility, novel type
bodies and reference kinds, an explicit null `signature.ref`, extra response
fields, duplicate type origins with conflicting and with identical defining ids,
a commented-out dependency, a missing `rev`, `branch` and `tag` selectors, a
wrong-but-40-hex Sui revision, wrong repositories and subdirectories, added and
dropped `override` rules, duplicate keys and tables, extra and missing lock
nodes, rebound `deps` edges, and boolean, malformed, and lowercase
`manifest_digest` values. Five positive fixtures pin the accepted shapes,
including a by-value parameter with `ref` absent. Every case that a live run
cannot reach without a real venue upgrade is covered here instead.

## Published venue packages

Re-verified on mainnet on 2026-09-02.

| Venue | Named address | Original package id | Current package id | Version | Package digest | Previous transaction |
| --- | --- | --- | --- | --- | --- | --- |
| Bluefin Spot | `bluefin_spot` | `0x3492c874c1e3b3e2984e8c41b589e642d4d0a5d6459e5a9cfc2d52fd7c89c267` | `0xd075338d105482f1527cbfd363d6413558f184dec36d9138a70261e87f486e9c` | 17 | `4tyboYqrPbZzN6V5Lh2TccW8j9nbH65mJeQFynoQGxut` | `CShZDVqJQrXm4SYiCgDe49kKnFzadwhFV5viqHLgRfaX` |
| MMT V3 | `mmt_v3` | `0x70285592c97965e811e0c6f98dccc3a9c2b4ad854b3594faab9597ada267b860` | `0xcf60a40f45d46fc1e828871a647c1e25a0915dec860d2662eb10fdb382c3c1d1` | 5 | `3muHEfy71LYEbjYSuvJ1i8y2XcFJPzctyaTFCkatfEqd` | `9ugrBxCA9yLJ4qrRDFoMnHSLbk1bP3N1A7cZ4DKvos5L` |
| Cetus CLMM | `cetus_clmm` | `0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb` | `0x25ebb9a7c50eb17b3fa9c5a30fb8b5ad8f97caaf4928943acbcff7153dfee5e3` | 14 | `FEdn2yRh28atu7tANr6gCWQ3gtDSD2EZmyEeryTuokoi` | `9feeN5tyxKLPPt1nRERtddp8xzxMVefNufkhxWAT1Jja` |
| Turbos CLMM | `turbos_clmm` | `0x91bfbc386a41afcfd9b2533058d7e915a1d3829089cc268ff4333d54d6339ca1` | `0xa5a0c25c79e428eba04fb98b3fb2a34db45ab26d4c8faf0d7e39d66a63891e64` | 22 | `FxTpAy2BbjFLWXF2Ddd4pmiBizrU27us4CwNHo9DtzVn` | `4iZ5nMJbgU6VtoDXg8TsuAEg6K6y4zovDgcMqxNn4diS` |
| Aftermath AMM | `amm` | `0xefe170ec0be4d762196bedecd7a065816576198a6527c99282a2551aaa7da38c` | `0xf948935b111990c2b604900c9b2eeb8f24dcf9868a45d1ea1653a5f282c10e29` | 3 | `Gxia3EZSdQeCXGPkmhXRzXWfmV6bnw7oRvSXNxNLQ9T1` | `7qeJhR15a6jqo7xujZMMe5Bcm11vR7cSBiFHypW3VQ3J` |
| Aftermath DAO Fee | `dao_fee_amm` | `0x6f60a091637054e23915b8745c0c0d47b1d49618ee3435b5f68eccf6a44fb53d` | `0x5ad6890968efcf3d20899e0cec735214f1067b96e77e77d86408989998468bb2` | 2 | `AeSpba79KZ8Ge8nGk2Li2c2tkLy7eC93wTGhgjEVHVpZ` | `9eMeoFRPGDW1TUvbhtstVu2bAaWCCM7VCgbgkEkCUR4c` |

## Committed module fingerprints

SHA-256 of each module's decoded on-chain bytecode at the current revision above.
Only modules that declare an adapter-consumed type or function are fingerprinted.

| Package | Module | SHA-256 of decoded on-chain bytecode |
| --- | --- | --- |
| `bluefin_spot` | `config` | `e896bcbdab23bf5c04eb38b12306f8d6ced8bb9194c789cd1f7f09c78e595cab` |
| `bluefin_spot` | `pool` | `d1436b0837eab8912797b91ed68755ad6e4228243f188a43c42ea040e844e97c` |
| `bluefin_spot` | `position` | `ea83d3b9a65c7f62579dd0a902ddad8ade46cec277e5781ab9e52783c48caaec` |
| `mmt_v3` | `collect` | `90e1f0a43280d678fef070be10afd190808cd24330af061d5e291fc51eb62647` |
| `mmt_v3` | `create_pool` | `1e2d7986ba2c67db9916faf028b65376db99e5f956dc735ed432b1661572f1ad` |
| `mmt_v3` | `global_config` | `7d017415c735d25cdca6c3ba3c0351a047a9d25bcb6dc6fe0bab80b3971619b6` |
| `mmt_v3` | `i32` | `a497795e96c4eeff5558b945926b2a97229d691d30452340f989d441128ded72` |
| `mmt_v3` | `liquidity` | `3c9b457444c43b8ebea2f1ba3daf9a370400d9ad3149654ea11123d3e9447bdb` |
| `mmt_v3` | `pool` | `0b1a2e676c909d3cac300d644c05b470418bd7b630ff57e14fab23afe15f002a` |
| `mmt_v3` | `position` | `7cceacd04adbe6a9955df17b2ca1738a77b27e9a4a681f5ce3621d1a92083a24` |
| `mmt_v3` | `tick_math` | `cb44cb32351dc86766ad76c433faad6a4fd20e97ce51c6bb5a1c68502ac59939` |
| `mmt_v3` | `version` | `65ee05b54cbd66c35a20498b758990ba0c154ac1dd489037a6af81eea82ffba1` |
| `cetus_clmm` | `config` | `8a1610d8e4f02ae48dcf0594f3553f26a6503721c00c3b775c9a1d7bdfa26016` |
| `cetus_clmm` | `factory` | `324c4e4ef1fdd079f22b2088cabe8cae86772ceae87c5873b3d636a92fe06e68` |
| `cetus_clmm` | `pool` | `aba0e2edaa3769e752a44acf314e8ac10850129e1cc7732ed93a6d4e2b9f35b5` |
| `cetus_clmm` | `pool_creator` | `bd52696c635f93ef334818763a1c7f4a4cefc77851e18af3e8b1bf463041d38c` |
| `cetus_clmm` | `position` | `3719452b1462b1b8dd59877eed3bb188bd3d154a10def3026ad3252f660947da` |
| `turbos_clmm` | `fee` | `0113ca7935faf508e936f6d74dfa6fa62c967f8f414572a9327b44c887a65141` |
| `turbos_clmm` | `i32` | `c2b649feed67ef880be3ae6fac1c729d7e65f9bcc03be74e1d2243968d968680` |
| `turbos_clmm` | `math_tick` | `78a692af161feb4dedc3e0bd281f9fb792b83e022d5a1cc06a92168585263bcb` |
| `turbos_clmm` | `pool` | `4a44d2dc2f0920d1253a20c5cd1471d5f3a0d03c1812781b816d372789728d36` |
| `turbos_clmm` | `pool_factory` | `ea8ef02d0fd0700daa020ba37360ad6a8f8dc8067af3ee99052b530494a53fef` |
| `turbos_clmm` | `position_manager` | `badc1be2ee1ba12fb56eb8332f412a58ba279b80f85144862656ceea6c0fa5fe` |
| `turbos_clmm` | `position_nft` | `1c9264b0145915da01c3a072876ffbd753d5697b56d5f2bedb79d92136d3cbea` |
| `amm` | `pool` | `f952884b3e6ea275911ae488e9d1e3f4b2a4409cdd30e8bed69e98fd7d0f7d78` |
| `amm` | `pool_factory` | `e2601c8181d142cb10bf10bbbe90adbd9545688238cbc3ba8b1bf9cf0809b17d` |
| `amm` | `pool_registry` | `9d4f76ef56e619111d94b41bac54641f2012d16a7e796a83436479b319dc6a62` |
| `dao_fee_amm` | `pool` | `029b3e6e0a11a249147cdd0b7b3ea78556d399e03228cae9424529a06cd58f3e` |
| `dao_fee_amm` | `version` | `6fbb4c1b78af3fa68654af6eb29be6fdbc945e9d715a46ac1ca9bc3f3f8920f2` |

## Normalized ABI coverage

| Venue | Modules | Functions | Structs | Type origins |
| --- | --- | --- | --- | --- |
| Bluefin Spot | 3 | 6 | 3 | 3 |
| MMT V3 | 9 | 14 | 5 | 5 |
| Cetus CLMM | 5 | 15 | 5 | 5 |
| Turbos CLMM | 7 | 14 | 7 | 7 |
| Aftermath AMM | 3 | 14 | 3 | 3 |
| Aftermath DAO Fee | 2 | 4 | 3 | 3 |
| **Total** | **29** | **67** | **26** | **26** |

The list contains only functions and structs the adapters actually reference.

## Source pins

Every direct and overridden Git dependency in `Move.toml` is a full commit.

| Manifest dependency | Kind | Pin |
| --- | --- | --- |
| `blast_fun` | local | `../launchpad` |
| `BluefinSpot` | git `fireflyprotocol/bluefin-spot-contract-interface` | `91ce930575b2aa3decab9b7e129b8002deba80c1` |
| `mmt_v3` | git `mmt-finance/mmt-contract-interface`, subdir `mmt_v3` | `e27d14caed53e1b7c4e1c12ea89b2ff87c58ee82` |
| `CetusClmm` | local `interfaces/cetus` | normalized from mainnet revision 14 |
| `TurbosCLMM` | local `interfaces/turbos` | normalized from `turbos-finance/turbos-sui-move-interface@cff693265bfc41c7de2233afe31c9d7428adc9e1` |
| `AftermathAmm` | local `interfaces/aftermath` | normalized from mainnet revision 3; the ABI gate pins the revision-3 `CreatePoolCapV2` origin separately from original AMM types |
| `AftermathDaoFeePools` | local `interfaces/aftermath_dao_fee` | normalized from mainnet revision 2; the live `Version` object is `0xb4bfb0f917f12ad2a772bea9b4f22431f6f5f9653162c3ae6fae5b99b21392b7`, initial shared version `293243902` |
| `Sui` (override) | git `MystenLabs/sui`, subdir `crates/sui-framework/packages/sui-framework` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` |
| `IntegerMate` (override) | git `CetusProtocol/integer-mate` | `09a12d9b171122883d9350039d4ed6e8400033b9` |
| `IntegerLibrary` (override) | git `fireflyprotocol/integer-library` | `8a534bd1c0b334cd3937c27987f3147a06ba6a18` |

Cetus's reviewed source manifest carries no `published-at`, and Turbos's
upstream manifest pins a mutable `Sui = testnet` reference. Cetus, Turbos,
Aftermath AMM, and Aftermath DAO Fee ship as minimal local normalized
interfaces. Each one preserves the venue's original type address and
sets `published-at` to the current mainnet revision. Their bodies are `abort 0`
link stubs; they exist only to type-check and to bind the runtime package id.

Upstream `BluefinSpot/Move.toml` itself declares mutable revisions
(`Sui = mainnet-v1.35.2`, `IntegerMate = sui-v1.1.2`, `IntegerLibrary = v1.0.1`).
The aggregate manifest overrides all three with full commits, and `Move.lock`
resolves every node — including transitive ones — to a 40-hex commit, so the
built graph contains no mutable revision.

## Resolved graph

`sui move build` for both the `mainnet` and `testnet` environments compiles
exactly twelve dependency nodes:

```text
AftermathAmm  AftermathDaoFeePools  BluefinSpot  CetusClmm  IntegerLibrary
IntegerMate_1  MoveSTL  MoveStdlib  Sui  TurbosCLMM  blast_fun  mmt_v3
```

`IntegerMate_1` is the single `09a12d9b…` integer package; Bluefin's older
`sui-v1.1.2` node is overridden away and never compiled. `MoveStdlib` and
`Sui` are the one `06734f6f…` framework pair, which every local normalized
interface also binds in both lock environments.

Only eleven addresses are referenced by the aggregate package's own bytecode, so
only those enter the published linkage table:

| Address | Referenced by `blast_fun_migrators` modules |
| --- | --- |
| `blast_fun` and `blast_fun_migrators` | yes |
| `0x1` MoveStdlib, `0x2` Sui framework | yes |
| `bluefin_spot`, `mmt_v3`, `cetus_clmm`, `turbos_clmm`, `amm`, `dao_fee_amm` | yes |
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
bash scripts/check_turbos_dependency_pin.sh
```

A local build proves type compatibility only. The interface bodies are `abort 0`
stubs, so nothing about venue behaviour is exercised until the mainnet gate runs.
The Move test suite under `tests/` covers what does execute locally: vault
custody and live-share fee accounting, the sealed venue-key guards, the pinned
tier policy's set/read/fail-closed paths, the Turbos two's-complement event
encoding, and the Aftermath canonical-order comparison.

## Mainnet dev-inspect matrix

The aggregate package exposes 13 migration routes, eight fee-accrual or collection
routes, one Aftermath per-pool DAO-fee update, and 2 vault claims. Each row is
one dev-inspect fixture against the published venue packages above, in the
orientation named by the route. No route may be skipped, and a skipped row is a
release blocker, not a documentation footnote.

| Venue | Migration routes | Fee-accrual or collection routes |
| --- | --- | --- |
| Bluefin | `migrate` — Meme is always coin A, Quote always coin B | `collect_fees` |
| MMT | `migrate_meme_x`, `migrate_meme_y` | `collect_fees_meme_x`, `collect_fees_meme_y` |
| Cetus | `migrate_new_meme_a`, `migrate_new_meme_b`, `migrate_existing_meme_a`, `migrate_existing_meme_b` | `collect_fees_meme_a`, `collect_fees_meme_b` |
| Turbos | `migrate_new_meme_a`, `migrate_new_meme_b`, `migrate_existing_meme_a`, `migrate_existing_meme_b` | `collect_fees_meme_a`, `collect_fees_meme_b` |
| Aftermath | `migrate_meme_first`, `migrate_meme_second` | `accrue_dao_fees`; also dev-inspect `update_dao_fee` separately |

Vault claims: `vault::claim_creator_fees` under `CreatorCap<Meme>` and
`vault::claim_protocol_fees` under `AdminWitness<LAUNCHPAD_DOMAIN>`. Both also
require this package's current generation. Neither touches the venue or the
position.

The compiled defaults are active from publication, so no tier setup
transaction is required before the fixtures run; a fixture that overrides a
tier must record that the pinned `(tick_spacing, fee_rate)` matches a tier the
venue actually registers.

Each migration fixture must show:

- the balance-derived `sqrt_price_x64` matches the exact Q64.64 target for that
  orientation, with no caller-supplied price and no display-decimal scaling;
- Bluefin `config::get_pool_creation_fee_amount<Quote>` reports supported and
  exactly zero, and the adapter supplies `balance::zero<Quote>()`;
- the venue's own canonical-order helper agrees with the selected route;
- full-range ticks come from the venue's pinned tick helpers and align inward to
  the selected tick spacing;
- adopted Cetus and Turbos pools pass the 50-bps deviation check
  immediately before liquidity is added;
- both assets are at least 99.99% utilized and each residual is at most one basis
  point, with both residuals held in the per-launch vault; and
- the returned position belongs to the new pool, has positive liquidity, and
  enters the vault as its one sealed dynamic object field;
- the route's venue tier equals the effective `VenueConfig` values, and a
  mismatched `Fee` object or adopted pool aborts with the tier-mismatch code.
- Aftermath consumes exact source balances into a pool using the effective
  role-based weights, 0.01% base swap-in fee, and zero other base fees;
  reconciles the 1,000-unit illiquid LP reserve; prepares the vault; wraps the
  base pool with the effective DAO fee and vault recipient; locks the complete
  returned LP amount as `Balance<Lp>` with the `OwnerCap<Lp>`; and shares only
  the outer wrapper.
- The Aftermath accrual route receives separate Meme and Quote vectors and
  merges 1 through 100 total DAO-transferred coins through the vault address.
  Either vector can be empty. It preserves the complete LP principal amount and
  commits one aggregate live creator/protocol split. The admin update must
  change the wrapper rate, preserve its vault recipient, and reject an unchanged
  rate.

Three venue-semantics rows were already **proven against published mainnet
bytecode on 2026-08-30** by disassembling the live modules (fetched through the
official GraphQL endpoint, disassembled with the pinned `sui move
disassemble`):

- **Bluefin order acceptance.** The current `bluefin_spot::pool` module
  contains no type-name comparison at all, so no canonical-order check exists
  to reject the hard-coded Meme-as-coin-A order for any Quote.
- **MMT friendly ticks.** `tick_math::get_tick_at_sqrt_price` bounds its input
  with an inclusive `Le` against exactly `max_sqrt_price()`, and `i32::mod` is
  sign-following, so the `tick - (tick mod spacing)` alignment always moves
  both bounds toward zero — inside the venue range that `open_position`
  accepts.
- **Turbos collection recipient.** See the fee-collection paragraph below.

The dev-inspect fixtures re-confirm these facts end to end but they are no
longer open questions.

Each fee-collection fixture must show venue liquidity is identical immediately
before and after collection, the vault, pool, and position ids match on both
sides of the call, and the split uses the live `protocol_fee_share_bps` read
during that collection. The Turbos `recipient` question is already proven
against the published v22 bytecode (2026-08-30): inside
`position_manager::collect_with_return_` the recipient address flows only into
`pool::collect_v2`, whose body uses it solely in `event::emit<CollectEventV2>`;
the fee coins come from `pool::split_out_and_return_` and are returned to the
caller, and no `transfer::` call exists anywhere in that chain. The adapter
passes its own vault address as `recipient`, so the venue event attributes the
vault that receives and accounts for the returned fees.

## Immutable-release gate

Source omission does not make principal custody permanent while this package
still has an `UpgradeCap`: a compatible upgrade could add an extraction function.

The principal of a migrated launch may be described as **permanently locked only
after** all of the following, in order:

1. `node scripts/check_mainnet_abi.mjs --self-test` and
   `node scripts/check_mainnet_abi.mjs` both pass, the latter against live
   mainnet;
2. the local build, lint, source-boundary, and dependency-pin gates pass;
3. every route and orientation in the dev-inspect matrix above passes, including
   all fee-collection routes and both vault claims; and
4. the aggregate package's single `UpgradeCap` is destroyed and the resulting
   immutable-package evidence is recorded under
   `deployments/sui/mainnet/`.

Until step 4 is recorded, the correct public statement is that principal is held
by an upgradeable package with no exposed withdrawal path — not that it is
permanently locked. Do not add a migrator admin capability as an alternative.
