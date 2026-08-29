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

- **One aggregate package.** Bluefin, MMT, Cetus, Turbos, and Full Sail ship
  together, so the release gate, dependency graph, and `UpgradeCap` lifecycle are
  shared. One custody and claim surface is worth one all-venues release gate.
- **Shared per-launch vault.** `vault::LpVault<Meme, Quote>` is one shared vault
  *type*, not one global object. Every migrated launch shares its own vault, so
  unrelated fee collections never contend on the same Sui object. The venue
  position is one dynamic **object** field under the sealed
  `vault::PositionKey<Venue>` name, with no removal, transfer, or immutable
  borrow path.
- **Live treasury.** Every venue residual is transferred to the
  `runtime_config::protocol_treasury` address read during that migration. No
  adapter stores its own treasury and none burns or sends residuals to `0x0`.
- **Same live protocol fee share.** `vault::accrue_fees` reads
  `runtime_config::protocol_fee_share_bps` at each collection and splits new fees
  through the same core `FeeLedger` used by bonding-curve trade fees. Protocol
  amounts round up, creators receive the exact remainder, and already accrued
  ownership never changes.
- **Direct events, no wrapper.** `events.move` owns the five typed payloads
  (`VaultCreated`, `MigrationCompleted`, `LpFeesCollected`, `CreatorFeesClaimed`,
  `ProtocolFeesClaimed`) and is the only module that calls `sui::event::emit`.
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
Cetus, Turbos, Full Sail, and Full Sail's separate IntegerMate package it then:

1. resolves the original package id to its current revision, because
   `package(address:)` returns the tip of a lineage;
2. re-reads the pinned revision through `package(address:, version:)` and fails
   when `packageVersionsAfter` reports any newer tip, naming that tip instead of
   silently adopting it;
3. asserts the expected current package id, version, whole-package object digest,
   and previous transaction on both the resolved tip and the pinned revision;
4. asserts every consumed struct's `typeOrigins` defining id is still the
   original package id;
5. decodes each consumed module's on-chain bytes, checks the `0xa11ceb0b` Move
   magic, and asserts the committed SHA-256 fingerprint; and
6. asserts the normalized public ABI of every consumed function and struct.

The ABI comparison uses the structured `OpenMoveTypeSignature` from GraphQL, not
display prose. Each entry renders reference mutability, every parameter in order,
type-parameter constraints, phantom markers, abilities, visibility, `entry`, and
the full return tuple. `@self` is the package's own original address, `@sui` and
`@std` are the framework addresses, and every other address is compared
literally, so a venue that re-points a helper type to a different package fails.
Missing or extra parameters, `&` versus `&mut`, visibility drift, ability drift,
phantom drift, and return drift each fail the run.

The same run cross-checks the committed local pins: each local normalized
interface manifest's `published-at` and original named address, its Sui framework
revision, the root manifest's dependency edges, and — in **both** the `mainnet`
and `testnet` lock graphs — that every local normalized interface resolves its
`Sui` edge to `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` under
`crates/sui-framework/packages/sui-framework`. Every Git revision in `Move.toml`
and `Move.lock` must be an immutable 40-hex commit.

The run fails closed. GraphQL transport errors retry three times; a GraphQL
`errors` payload, a missing package, a missing module, or a missing function is
an immediate failure. `--emit` prints the observed facts as a paste-ready
expectation block; it never relaxes an assertion.

## Published venue packages

Re-verified on mainnet on 2026-08-29.

| Venue | Named address | Original package id | Current package id | Version | Package digest | Previous transaction |
| --- | --- | --- | --- | --- | --- | --- |
| Bluefin Spot | `bluefin_spot` | `0x3492c874c1e3b3e2984e8c41b589e642d4d0a5d6459e5a9cfc2d52fd7c89c267` | `0xd075338d105482f1527cbfd363d6413558f184dec36d9138a70261e87f486e9c` | 17 | `4tyboYqrPbZzN6V5Lh2TccW8j9nbH65mJeQFynoQGxut` | `CShZDVqJQrXm4SYiCgDe49kKnFzadwhFV5viqHLgRfaX` |
| MMT V3 | `mmt_v3` | `0x70285592c97965e811e0c6f98dccc3a9c2b4ad854b3594faab9597ada267b860` | `0xcf60a40f45d46fc1e828871a647c1e25a0915dec860d2662eb10fdb382c3c1d1` | 5 | `3muHEfy71LYEbjYSuvJ1i8y2XcFJPzctyaTFCkatfEqd` | `9ugrBxCA9yLJ4qrRDFoMnHSLbk1bP3N1A7cZ4DKvos5L` |
| Cetus CLMM | `cetus_clmm` | `0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb` | `0x25ebb9a7c50eb17b3fa9c5a30fb8b5ad8f97caaf4928943acbcff7153dfee5e3` | 14 | `FEdn2yRh28atu7tANr6gCWQ3gtDSD2EZmyEeryTuokoi` | `9feeN5tyxKLPPt1nRERtddp8xzxMVefNufkhxWAT1Jja` |
| Turbos CLMM | `turbos_clmm` | `0x91bfbc386a41afcfd9b2533058d7e915a1d3829089cc268ff4333d54d6339ca1` | `0xa5a0c25c79e428eba04fb98b3fb2a34db45ab26d4c8faf0d7e39d66a63891e64` | 22 | `FxTpAy2BbjFLWXF2Ddd4pmiBizrU27us4CwNHo9DtzVn` | `4iZ5nMJbgU6VtoDXg8TsuAEg6K6y4zovDgcMqxNn4diS` |
| Full Sail CLMM | `clmm_pool` | `0xe74104c66dd9f16b3096db2cc00300e556aa92edc871be4bc052b5dfb80db239` | `0x497a144ba3d93ae44d9fd23d4ff4761c329d87a505136d2269c743b2297fa881` | 4 | `CWkTsBks7SsYsvDQ9QQxkHqgDAKdvuDkh4DAd9DHo3nF` | `3rbk2g4FuuqFGKBLyNYLkqJjv2XKvgnSans6EpPaRCSd` |
| Full Sail IntegerMate | `fullsail_integer_mate` | `0x6b904ae739b2baad330aae14991abcd3b7354d3dc3db72507ed8dabeeb7a36de` | `0x6b904ae739b2baad330aae14991abcd3b7354d3dc3db72507ed8dabeeb7a36de` | 1 | `sJBBNfgrAEwYvUxzbM8y7yHYdHTE5no2Urg4B3eJR1s` | `CWQ5cMDkAGu6o8nCWDix25KGpnBXRLt2bZdVchacjRVN` |

Full Sail has never published Move sources; revision 4 is confirmed by mainnet
lineage and `@fullsailfinance/sdk@11.0.0`, while the official contracts page
still lists revision 3. Full Sail IntegerMate has never been upgraded, so its
original and current ids are the same object.

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
| `clmm_pool` | `config` | `fa727813c54f77a7c16c4a76d334a5f5477bd785685b3d6539de85fde49de5be` |
| `clmm_pool` | `factory` | `b13f70d07a91f192045152a367a073b06b520cc71458e3e78ce7b2e82e5f2906` |
| `clmm_pool` | `pool` | `3332e1a5db68034668dd36acf3b63dd0545d0fc193f251af192842d91b91be59` |
| `clmm_pool` | `position` | `4d61ff120ba2988afc2dc8c1729ccccb0541adf7e0b0864da09e227ce8301f99` |
| `clmm_pool` | `rewarder` | `8aec3da2ff2194faf69df8e2e033505dc5a464601514a790075c43ee0aedfe07` |
| `clmm_pool` | `tick_math` | `25c2ea22ad657e05c8949c5767efcc7b6b8b33e014f2f5999d185d70a7ebaad4` |
| `fullsail_integer_mate` | `i32` | `9be3bdeba386cf882d90603fa8decbe8a477e5a5d39341bbc940577b4393412f` |

## Normalized ABI coverage

| Venue | Modules | Functions | Structs | Type origins |
| --- | --- | --- | --- | --- |
| Bluefin Spot | 3 | 6 | 3 | 3 |
| MMT V3 | 9 | 14 | 5 | 5 |
| Cetus CLMM | 5 | 15 | 5 | 5 |
| Turbos CLMM | 7 | 14 | 7 | 7 |
| Full Sail CLMM | 6 | 15 | 6 | 6 |
| Full Sail IntegerMate | 1 | 3 | 1 | 1 |
| **Total** | **31** | **67** | **27** | **27** |

`clmm_pool::factory::new_pool_key` is included even though the adapter never
calls it: `fullsail::assert_coin_order` replicates that ordering rule with
`type_name::with_defining_ids`, so a change to the venue helper's signature must
still fail the gate.

## Source pins

Every direct and overridden Git dependency in `Move.toml` is a full commit.

| Manifest dependency | Kind | Pin |
| --- | --- | --- |
| `blast_fun` | local | `../launchpad` |
| `BluefinSpot` | git `fireflyprotocol/bluefin-spot-contract-interface` | `91ce930575b2aa3decab9b7e129b8002deba80c1` |
| `mmt_v3` | git `mmt-finance/mmt-contract-interface`, subdir `mmt_v3` | `e27d14caed53e1b7c4e1c12ea89b2ff87c58ee82` |
| `CetusClmm` | local `interfaces/cetus` | normalized from mainnet revision 14 |
| `TurbosCLMM` | local `interfaces/turbos` | normalized from `turbos-finance/turbos-sui-move-interface@cff693265bfc41c7de2233afe31c9d7428adc9e1` |
| `FullSailCLMM` | local `interfaces/fullsail` | normalized from mainnet revision 4 |
| `FullSailIntegerMate` | local `interfaces/fullsail_integer_mate` | normalized from mainnet revision 1 |
| `Sui` (override) | git `MystenLabs/sui`, subdir `crates/sui-framework/packages/sui-framework` | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` |
| `IntegerMate` (override) | git `CetusProtocol/integer-mate` | `09a12d9b171122883d9350039d4ed6e8400033b9` |
| `IntegerLibrary` (override) | git `fireflyprotocol/integer-library` | `8a534bd1c0b334cd3937c27987f3147a06ba6a18` |

Cetus's reviewed source manifest carries no `published-at`, Turbos's upstream
manifest pins a mutable `Sui = testnet` reference, and Full Sail publishes no
sources at all, so those three plus Full Sail IntegerMate ship as minimal local
normalized interfaces. Each one preserves the venue's original type address and
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
BluefinSpot  CetusClmm  FullSailCLMM  FullSailIntegerMate  IntegerLibrary
IntegerMate_1  MoveSTL  MoveStdlib_2  Sui_2  TurbosCLMM  blast_fun  mmt_v3
```

`IntegerMate_1` is the single `09a12d9b…` integer package; Bluefin's older
`sui-v1.1.2` node is overridden away and never compiled. `MoveStdlib_2` and
`Sui_2` are the one `06734f6f…` framework pair, which every local normalized
interface also binds in both lock environments.

Only ten addresses are referenced by the aggregate package's own bytecode, so
only those enter the published linkage table:

| Address | Referenced by `blast_fun_migrators` modules |
| --- | --- |
| `blast_fun` and `blast_fun_migrators` | yes |
| `0x1` MoveStdlib, `0x2` Sui framework | yes |
| `bluefin_spot`, `mmt_v3`, `cetus_clmm`, `turbos_clmm`, `clmm_pool` | yes |
| `fullsail_integer_mate` | yes |
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
node scripts/check_mainnet_abi.mjs
sui move build
sui move lint --warnings-are-errors
sui move build -e mainnet
bash scripts/check_source_boundaries.sh
bash scripts/check_turbos_dependency_pin.sh
bash scripts/check_fullsail_dependency_pin.sh
```

A local build proves type compatibility only. The interface bodies are `abort 0`
stubs, so nothing about venue behaviour is exercised until the mainnet gate runs.

## Mainnet dev-inspect matrix

The aggregate package exposes 24 venue routes plus 2 vault claims. Each row is
one dev-inspect fixture against the published venue packages above, in the
orientation named by the route. No route may be skipped, and a skipped row is a
release blocker, not a documentation footnote.

| Venue | Migration routes | Fee-collection routes |
| --- | --- | --- |
| Bluefin | `migrate` — Meme is always coin A, Quote always coin B | `collect_fees` |
| MMT | `migrate_meme_x`, `migrate_meme_y` | `collect_fees_meme_x`, `collect_fees_meme_y` |
| Cetus | `migrate_new_meme_a`, `migrate_new_meme_b`, `migrate_existing_meme_a`, `migrate_existing_meme_b` | `collect_fees_meme_a`, `collect_fees_meme_b` |
| Turbos | `migrate_new_meme_a`, `migrate_new_meme_b`, `migrate_existing_meme_a`, `migrate_existing_meme_b` | `collect_fees_meme_a`, `collect_fees_meme_b` |
| Full Sail | `migrate_new_meme_a`, `migrate_new_meme_b`, `migrate_existing_meme_a`, `migrate_existing_meme_b` | `collect_fees_meme_a`, `collect_fees_meme_b` |

Vault claims: `vault::claim_creator_fees` under `CreatorCap<Meme>` and
`vault::claim_protocol_fees` under `AdminWitness`. Neither touches the venue or
the position.

Each migration fixture must show:

- the balance-derived `sqrt_price_x64` matches the exact Q64.64 target for that
  orientation, with no caller-supplied price and no display-decimal scaling;
- Bluefin `config::get_pool_creation_fee_amount<Quote>` reports supported and
  exactly zero, and the adapter supplies `balance::zero<Quote>()`;
- the venue's own canonical-order helper agrees with the selected route;
- full-range ticks come from the venue's pinned tick helpers and align inward to
  the selected tick spacing;
- adopted Cetus, Turbos, and Full Sail pools pass the 50-bps deviation check
  immediately before liquidity is added;
- both assets are at least 99.99% utilized and each residual is at most one basis
  point, with both residuals transferred to the live `protocol_treasury`; and
- the returned position belongs to the new pool, has positive liquidity, and
  enters the vault as its one sealed dynamic object field.

Each fee-collection fixture must show venue liquidity is identical immediately
before and after collection, the vault, pool, and position ids match on both
sides of the call, and the split uses the live `protocol_fee_share_bps` read
during that collection.

## Immutable-release gate

Source omission does not make principal custody permanent while this package
still has an `UpgradeCap`: a compatible upgrade could add an extraction function.

The principal of a migrated launch may be described as **permanently locked only
after** all of the following, in order:

1. `node scripts/check_mainnet_abi.mjs` passes against live mainnet;
2. the local build, lint, source-boundary, and dependency-pin gates pass;
3. every route and orientation in the dev-inspect matrix above passes, including
   all fee-collection routes and both vault claims; and
4. the aggregate package's single `UpgradeCap` is destroyed and the resulting
   immutable-package evidence is recorded under
   `deployments/sui/mainnet/`.

Until step 4 is recorded, the correct public statement is that principal is held
by an upgradeable package with no exposed withdrawal path — not that it is
permanently locked. Do not add a migrator admin capability as an alternative.
