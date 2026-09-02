# Blast migration adapters

This directory is one aggregate Move package for all supported liquidity
venues. Venue modules depend on the launchpad core; the launchpad core never
imports this package. A launch selects a venue's sealed migration witness.

Bluefin, MMT, Cetus, Turbos, Full Sail, and Aftermath ship together in this one package, so
they share one custody surface, one claim surface, one dependency graph, one
release gate, and one `UpgradeCap`. [DEPENDENCIES.md](DEPENDENCIES.md) owns the
package-id and dependency matrix, the committed module fingerprints, the
dev-inspect matrix, and the immutable-release gate.

## Common vault

Every completed migration creates one shared `vault::LpVault<Meme, Quote>`.
The vault stores the pool ID, protocol-owned migration residual balances, and
the common `FeeLedger<Meme, Quote>`. Its one venue position is a child object under the sealed
`vault::PositionKey<Venue>` dynamic-object-field name.

Only package functions can construct a vault or mutably borrow its typed
position. Construction consumes an ephemeral venue witness, and position
access requires a reference to one. Each venue marker has a private constructor
in its venue module, so another module in the aggregate package cannot forge the
witness needed to access that position. There is no immutable position borrow,
dynamic-object-field removal function, or public position borrow.

This is one shared vault *type*, not one global vault object. Every migrated
launch gets its own shared `LpVault<Meme, Quote>`, so unrelated fee collections
never contend on the same Sui object.

Creator and protocol fee claims are defined once in `vault`. Venue modules pass
completed fee balances through the witness-gated `vault::accrue_fees` function;
they cannot borrow the common fee ledger directly. That function reads the live
`runtime_config::protocol_fee_share_bps` during each collection and splits new
fees through the same core `FeeLedger` as bonding-curve trade fees, so protocol
amounts round up, creators receive the exact remainder, and a later share change
never rewrites already accrued ownership.

Every venue residual stays in its per-launch vault as protocol-owned custody.
The existing admin-gated protocol claim drains those residuals together with
accrued protocol LP fees. No adapter stores a payout address, burns a nonzero
residual, or sends one to `0x0`.

## Pinned venue tiers

`launch::migrate` is deliberately permissionless, so no migration caller may
choose the venue fee tier or tick spacing of the pool that permanently
custodies the launch principal. The shared `venue_config::VenueConfig`
singleton holds one sealed tier entry per venue as a dynamic field keyed by
`TierKey<Venue>`, so an upgrade-added venue module can register its own tier
without touching the singleton's frozen struct layout. Only a venue module can
write its own entry — the package-only write consumes that venue's sealed
witness — and each module's public `set_tier` additionally requires a live
core `AdminWitness`. Every mutation emits an old/new `VenueTierUpdated` fact;
zero old values mean the compiled default was still active.

Each venue module compiles its researched default, so every route works from
publication with no setup transaction. Meme pools take the venue's highest
tier; the defaults below were read from live mainnet registries on 2026-08-30:

| Venue | Default `(tick_spacing, fee_rate)` | Source |
| --- | --- | --- |
| Bluefin | `(200, 10_000)` — 1% | no venue registry; dominant production meme tier across live pools |
| Cetus | `(260, 40_000)` — 4% | highest of 16 tiers in the `GlobalConfig` fee-tier registry |
| Full Sail | `(20, 10_000)` — 1% | highest of 5 tiers in the `GlobalConfig` fee-tier registry |
| MMT | `(400, 20_000)` — 2% | highest of 10 entries in the `fee_amount_tick_spacing` table |
| Turbos | `(800, 40_000)` — 4% | highest registered `Fee` tier object (`FEE40000BPS`) |

- Bluefin routes use the effective `(tick_spacing, fee_rate)` pair directly.
- Cetus and Full Sail new routes use the effective tick spacing and require
  the venue's registered fee for that spacing to equal the effective fee.
- Cetus adopted pools must match the effective pair. Full Sail adjusts live
  pool fees dynamically, so its adopted pools match on tick spacing alone.
- MMT routes use the effective fee rate and require the venue-derived tick
  spacing of the created pool to equal the effective spacing.
- Turbos routes require the supplied `Fee<FeeType>` object or adopted pool to
  match the effective pair exactly.

Because tier policy lives in a shared object rather than package constants, it
stays correctable on mainnet without a package upgrade, including after the
`UpgradeCap` is destroyed; changes affect only later migrations.

Aftermath has no tick-spacing dimension. Its module-owned `AftermathPolicy`
stores role-based Meme and Quote weights plus the DAO fee under a sealed
`aftermath::PolicyKey`. The compiled default is 50/50 with a 200-bps (2%) DAO
fee. Admin pins for future migrations require each weight to be at least 1%,
the weights to sum exactly to 100%, and the DAO fee to stay within 0–10,000
bps. Aftermath's base pool rejects a zero swap-in fee, so every Blast pool uses
the minimum 0.01% base fee and zero swap-out, deposit, and withdrawal fees.

## Aftermath routes

`aftermath::migrate_meme_first` and `migrate_meme_second` create a fresh
two-coin weighted pool through Aftermath's V2 capability API. The selected
route must match Aftermath's defining-ID lexicographic type order before the
core payload is redeemed. The LP type must also be absent from the live pool
registry.

Both routes use the effective role-based weights and DAO fee while fixing zero
flatness, the 0.01% base swap-in fee, and zero swap-out, deposit, and withdrawal
fees. The Meme-first and Meme-second routes reorder the policy weights into
Aftermath's canonical type order. They send both source coins in full. Before
wrapping the pool, the adapter checks both exact reserves, every curve and fee
parameter, nine LP decimals, positive liquid LP, and Aftermath's exact
1,000-unit illiquid LP reserve.

Operators must first publish a fresh nine-decimal LP currency and create its
`CreatePoolCapV2` with Aftermath's LP-creation flow. That preparation is a
separate transaction; the cap is then consumed by the atomic Blast migration.

The adapter prepares the vault first and passes its object address as the DAO
fee recipient to Aftermath's DAO wrapper. The outer `DaoFeePool<Lp>` is the
shared pool; it owns the reconciled base pool. The vault position owns every
liquid `Coin<Lp>` and the wrapper `OwnerCap<Lp>`, with no LP burn or withdrawal
route. The cap never leaves custody. A live `AdminWitness` can use it by
reference to increase or decrease that existing pool's DAO fee while the
recipient remains fixed to the vault.

DAO swaps, deposits, and withdrawals transfer Meme or Quote fee coins to the
vault address. `accrue_fees` receives separate typed Meme and Quote vectors
containing 1 through 100 total child-address coins. Either vector can be empty.
It deletes the coin wrappers while merging both balances and performs one
common fee-ledger accrual. It requires the locked LP amount to remain
unchanged. Creator and protocol claims then use the same live split and claim
paths as every other venue. The base 0.01% fee still compounds into the locked
LP and is never represented as claimable revenue.

## Bluefin route

`bluefin::migrate` supports one deterministic orientation: Meme is coin A and
Quote is coin B. It calls guarded `launch::migrate`, redeems the typed payload
with `bluefin::Witness` in the same transaction, and derives the Q64.64
Quote-per-Meme price from the actual payload balances. Display decimals do not
affect the price. Bluefin event metadata comes from the supplied Coin Registry
`Currency<Meme>` and `Currency<Quote>` objects.

The tick spacing and fee rate come from the effective venue tier. The
adapter gets the live range from `config::get_tick_range`, aligns both
endpoints inward, and validates the pinned Bluefin initialization-price bounds.
It queries the Quote-denominated creation fee, requires a supported Quote type
and an exact zero amount, and constructs only `balance::zero<Quote>()`.

The full Meme balance is the fixed liquidity side. At the balance-derived
opening price a full-range seed leaves its rounding residual on the Quote
requirement, so fixing Meme is the only order the venue can satisfy from the
migrated balances. That holds exactly while the Meme atom balance is at least
the Quote atom balance, and every fixed-side route rejects the perverse
opposite configuration with a named guard.

Each Meme or Quote residual must be at most one basis point of its migration
input, the venue-reported used amounts must reconcile exactly against
`source − residual`, and both residual balances enter protocol-owned vault
custody. The returned position must belong to the new pool and have positive
liquidity before it is attached to that vault.

`bluefin::collect_fees` verifies the vault pool ID, position pool ID, and
positive liquidity before collection. It verifies both IDs again and requires
unchanged position liquidity afterward. The Meme and Quote fee balances then
enter `FeeLedger::accrue_from_runtime`, which reads the live protocol share for
that collection.

## MMT routes

MMT requires canonical type order. `mmt::migrate_meme_x` is valid only when
Meme sorts as coin X, and `mmt::migrate_meme_y` is valid only when Meme sorts
as coin Y. Each route checks both possible orders and requires exactly one
canonical result before it redeems the migration payload.

Both routes derive the atomic Q64.64 initialization price from the actual Meme
and Quote balances and read the effective MMT fee rate. They create and
initialize a new pool, derive full-range friendly ticks through the pinned MMT
helpers, open the position, and require at least 99.99% use of both balances
while adding liquidity. The position enters the common vault before the new MMT
pool is shared. Both residual coins enter the same protocol-owned vault custody.

MMT fee collection has one typed route for each pool orientation. Each route
requires the sealed MMT venue value, verifies the vault, pool, and position
identities, and requires unchanged positive position liquidity. Coin X/Y fees
are normalized to Meme/Quote before they enter the common fee ledger.

## Cetus routes

Cetus has new-pool and adopted-pool routes for both canonical type orders.
`migrate_new_meme_a` and `migrate_existing_meme_a` require Meme as coin A.
`migrate_new_meme_b` and `migrate_existing_meme_b` require Meme as coin B.
Every route checks the Cetus canonical order, and the new-pool routes also
derive the venue pool key. The caller does not supply an orientation, a price,
or a tier.

New routes derive the Q64.64 price from redeemed atomic balances and the tick
spacing from the admin-pinned tier. They use
`pool_creator::full_range_tick_range` and create unpermissioned pools through
`create_pool_v3` with Meme as the fixed liquidity side, so the rounding
residual lands on the Quote requirement. They require at most a one-basis-point
residual for both assets, which is the same bound as 99.99% utilization.
Residual Meme and Quote coins enter protocol-owned custody in the LP vault.

Existing routes require the adopted pool to match the pinned tick spacing and
its venue-registered fee, then redeem the core payload and immediately compare
the balance-derived target with `pool::current_sqrt_price` at 50 bps, before
opening a position or adding liquidity. The one-basis-point residual rule binds
far tighter than that coarse gate, so adoption succeeds only when the pool
price is within about one basis point of the seed ratio. The fixed liquidity
side follows the adopted price — Meme when the pool is at or below the derived
price, Quote above it — so outside a boundary sliver of roughly 4e-8 relative
price around the derived value, the affordable side is the fixed one. They use
Cetus's fixed-coin receipt, payment, and repayment flow, then check the created
position belongs to the supplied pool. Atomic failure restores the core launch
transition.

`collect_fees_meme_a` and `collect_fees_meme_b` require a real private Cetus
venue value. They check vault, pool, and position IDs and positive liquidity.
They call `pool::collect_fee(..., true)` and require unchanged liquidity.
The Meme-B route reverses Cetus A/B fee balances before common Meme/Quote
accrual.

## Turbos routes

Turbos pools are keyed by their exact `(CoinA, CoinB, FeeType)` order and the
venue registers no canonical pair order, so both type orders are genuine
routes. The `migrate_*_meme_a` routes use Meme as coin A. The
`migrate_*_meme_b` routes use Meme as coin B. New-pool callers provide one
concrete `Fee<FeeType>` object, and existing routes take a pool with that same
`FeeType`; both must match the admin-pinned `(tick_spacing, fee_rate)` pair, so
the tier is deterministic. Callers do not provide a price, an orientation flag,
or a tier.

Each route derives its Q64.64 price from the redeemed atomic Meme and Quote
balances. The adapter derives full-range magnitude-and-sign ticks from
`math_tick::get_min_tick` and `math_tick::get_max_tick` for the venue calls and
re-encodes them as two's-complement bits for the migration event, so the event
schema carries one tick encoding across every venue. New routes call
`pool_factory::deploy_pool_and_mint_with_return_`. Existing routes redeem the
payload, compare the balance-derived price with the live pool price at exactly
50 bps, then call `position_manager::mint_with_return_`. All liquidity calls
use caller-provided deadlines and one-basis-point minimum amounts.

The returned `TurbosPositionNFT` enters the common vault as its dynamic object
field. The adapter rejects a mismatched pool ID, bounds each residual at one
basis point of its input, and keeps both residuals in protocol-owned vault
custody. Both fee routes call `collect_with_return_`, read
`get_position_info` before and after, and require unchanged positive liquidity.
The Meme-B route reverses Turbos A/B fee coins before shared Meme/Quote
accrual.

## Full Sail routes

Full Sail has new-pool and adopted-pool routes for both canonical type orders.
Its canonical order is descending lexical order of coin type names, which
`clmm_pool::factory::new_pool_key` enforces through the deprecated
`type_name::get`. That helper returns defining IDs, so the adapter compares
defining IDs to reproduce the pinned venue rule exactly. Each route verifies
that order on chain before it redeems the migration payload. Callers do not
supply an orientation or an economic price.

New routes derive the Q64.64 price from the actual Meme and Quote balances,
the tick spacing from the effective tier, and call revision 4
`factory::create_pool_with_liquidity` with Meme as the fixed liquidity side so
the rounding residual lands on the Quote requirement. They pass both source
amounts, an empty URI, zero feed IDs, and `false` for automatic volume
calculation. Thus an arbitrary Meme does not claim an oracle or stable-asset
feed. The adapter derives both full-range ticks from Full Sail `tick_math`,
aligns them inward to the pinned tick spacing, and uses the live global
configuration, rewarder vault, and pool registry.

Adopted routes require the pool to match the pinned tick spacing and its
venue-registered fee, then redeem the payload and immediately compare the
balance-derived price with `pool::current_sqrt_price` at exactly 50 bps. The
one-basis-point residual rule binds far tighter than that coarse gate. The
fixed liquidity side follows the adopted price — Meme at or above the derived
price in this orientation-dependent sense, Quote otherwise — so outside a
boundary sliver of roughly 4e-8 relative price around the derived value, the
affordable side is the fixed one. Only then do they use Full Sail's open,
fixed-coin add, payment, and repayment receipt flow. Every route bounds both
residuals at one basis point and keeps them in protocol-owned vault custody.

The returned `Position` enters the common vault as its sealed dynamic object
field. Both fee routes call `pool::collect_fee(..., true)`, verify pool and
position identities before and after collection, and require unchanged
positive liquidity. The Meme-B route reverses Full Sail A/B fees before common
Meme/Quote accrual.

## Replayable events

The dedicated `events` module owns six strongly typed payloads and their
package-only emit helpers. Only that module calls `sui::event::emit`; state
modules call its typed helpers.

These are direct Sui events. This independently deployed package deliberately
does **not** wrap them in the core `events_wrapper::Event<T>` envelope: wrapping
would add nothing here, it would hide the payload type from native event
filters, and it would pull a second package into the core event ABI. Consumers
filter on the payload types below.

- `VenueTierUpdated` records one sealed venue tier pin replacing the previous
  values, carrying the venue witness type name; zero old values mean the venue
  module's compiled default was active before the pin. The singleton itself
  needs no creation event: Sui transaction effects natively record the shared
  object and its type at publication.
- `VaultCreated` records vault, pool, and position IDs plus venue, Meme, and
  Quote type names.
- `MigrationCompleted` records launch, vault, and pool IDs; source, used, and
  residual amounts for both assets; the pool's sqrt price at
  seeding — balance-derived on new-pool routes, the adopted pool's live price
  on adoption routes; and the tick and fee inputs, with both tick fields as
  two's-complement `i32` bits on every venue.
- `LpFeesCollected` records vault, pool, and position IDs; the venue and asset
  types; gross fees; applied protocol share; creator/protocol deltas and final
  totals for both assets; and principal liquidity before and after.
- `CreatorFeesClaimed` and `ProtocolFeesClaimed` record the vault, drained
  amounts, asset types, and all four post-claim ledger totals.

The payloads are completed facts and use native Sui event ordering. They contain
no application sequence, revision, nonce, schema version, or action tag, and no
field restating the transaction sender: the collector and both claimants are the
event envelope's sender under ADR 0059.

## Pinned dependencies

`Move.toml` pins every direct or overridden Git dependency to a complete commit:

| Package | Commit |
| --- | --- |
| Bluefin Spot interface | `91ce930575b2aa3decab9b7e129b8002deba80c1` |
| MMT V3 interface | `e27d14caed53e1b7c4e1c12ea89b2ff87c58ee82` |
| Turbos CLMM interface source | `cff693265bfc41c7de2233afe31c9d7428adc9e1` |
| Sui framework | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` |
| IntegerMate | `09a12d9b171122883d9350039d4ed6e8400033b9` |
| IntegerLibrary | `8a534bd1c0b334cd3937c27987f3147a06ba6a18` |
| Cetus MoveSTL | `0681fec63a310ae753d03a06f7c05d3e2925bb09` |

Cetus, Turbos, Full Sail, and Full Sail's separate IntegerMate ship as minimal
local normalized interfaces under `interfaces/`, because Cetus's reviewed source
manifest has no `published-at`, Turbos's upstream manifest pins a mutable
`Sui = testnet` reference, and Full Sail publishes no Move sources. Each local
interface preserves the venue's original type address, sets `published-at` to the
current mainnet revision, and binds the one Sui framework revision above in both
lock environments. Their bodies are `abort 0` link stubs.

[DEPENDENCIES.md](DEPENDENCIES.md) is the single owner of the resulting
package-id matrix: original and current package ids, versions, whole-package
digests, upgrade transactions, per-module bytecode fingerprints, the compiled
dependency set, and which addresses actually enter the published linkage table.

## Verification and immutable-release gate

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
bash scripts/check_fullsail_dependency_pin.sh
```

`tests/` covers what executes locally: the shared vault's custody and
live-share fee accounting, the sealed venue-key guards, the pinned tier
policy's set/read/fail-closed paths, the Turbos two's-complement event
encoding, and the Full Sail canonical-order comparison. Venue calls remain
`abort 0` link stubs, so everything venue-facing belongs to the dev-inspect
matrix.

`scripts/check_mainnet_abi.mjs` uses Node built-ins only and the official Sui
mainnet GraphQL endpoint. For Bluefin, MMT, Cetus, Turbos, Full Sail, Aftermath
AMM, Aftermath DAO Fee, and Full Sail's separate IntegerMate package it resolves
the original package id to its
current revision, fails when any revision exists beyond the pinned tip, and
asserts the package id, version, whole-package digest, previous transaction, and
exact type origins, including Aftermath's revision-3 capability origin. It then asserts a committed SHA-256 over each consumed
module's decoded on-chain bytecode and the normalized public ABI of every
consumed function and struct, comparing structured signatures rather than
display prose so that a missing or extra parameter, `&` versus `&mut`,
visibility drift, ability drift, phantom drift, or return drift all fail.

Every GraphQL field is shape-validated before it is rendered, so a null,
partial, or novel response fails instead of normalizing into a passing value.
The same run parses the root manifest, the six local interface manifests, and
both lock environments with a strict reader and binds every dependency name to
its exact source, subdirectory, local path, revision, and `override` rule;
comments are stripped before comparison, and `branch`, `tag`, a missing `rev`, a
duplicate key or table, an unexpected record, and a rebound edge all fail.

It fails closed: a GraphQL error, a missing package, a missing module, or a
missing function ends the run non-zero. `--self-test` runs the response,
manifest, and lock validators against in-memory fixtures with no network request
and no file change, so every fail-closed path stays covered between venue
upgrades.

The interface dependencies contain `abort 0` link stubs, so a local build proves
type compatibility only. Before production release, run the mainnet dev-inspect
matrix in [DEPENDENCIES.md](DEPENDENCIES.md) for every route and orientation:
all 17 migration routes, all 10 fee-accrual or collection routes, the Aftermath
per-pool DAO-fee update, and both vault claims,
covering exact balance-derived initialization, zero Bluefin creation fee, venue
canonical order, full-range tick bounds, the 50-bps Cetus, Turbos, and Full Sail
adoption checks, one-basis-point residual limits with vault custody, and fee
collection with unchanged principal liquidity. The matrix must additionally
prove, against published venue bytecode: that Turbos `collect_with_return_`
returns the complete collected fee and transfers nothing to its `recipient`
argument — the adapter passes its own vault address there for event attribution;
that Bluefin accepts the hard-coded Meme-as-coin-A order for every
allowlisted Quote; that MMT `get_friendly_ticks` at the venue's extreme sqrt
prices yields ticks its `open_position` accepts; and that every pinned venue
tier in `VenueConfig` matches a registered venue tier.

Source omission does not make principal custody permanent while this package has
an `UpgradeCap`: a compatible upgrade could add an extraction function. LP
principal may be described as permanently locked **only after** the self-test and
every live ABI gate above pass, every local gate passes, every dev-inspect row passes, and the
aggregate package's single `UpgradeCap` is destroyed and that immutable-package
evidence is recorded. Until then the accurate statement is that principal is held
by an upgradeable package with no exposed withdrawal path. Do not add a migrator
admin capability as an alternative.

No vault or collection entry point carries a package-version gate. That is a
deliberate consequence of this release design: destroying the `UpgradeCap` is
the retirement mechanism, so exactly one package version can ever exist and
there is no old bytecode to fence off. The shared `VenueConfig` stays mutable
under the core `AdminWitness` after immutability; it governs only future
migrations and can never touch custodied principal or accrued ownership.

## Bluefin errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EInvalidTickSpacing` | Tick spacing is zero. |
| 1 | `EUnsupportedCreationFee` | Quote is not a supported Bluefin creation-fee type. |
| 2 | `ENonzeroCreationFee` | Bluefin reported a nonzero Quote pool-opening fee. |
| 3 | `EInvalidSqrtPrice` | The balance-derived price is outside pinned Bluefin bounds. |
| 4 | `EPositionPoolMismatch` | The pool, vault, and position IDs do not match. |
| 5 | `EZeroPositionLiquidity` | The created or collected position has no principal liquidity. |
| 6 | `EPositionLiquidityChanged` | Bluefin fee collection changed position principal. |
| 7 | `EVenueAmountMismatch` | Bluefin-reported used amounts disagree with source minus residual. |
| 8 | `EMemeBelowQuote` | The Meme atom balance is below the Quote atom balance, so a Meme-fixed full-range seed cannot succeed. |

## MMT errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EInvalidCoinOrder` | The selected MMT route does not match the unique canonical type order. |
| 1 | `EPositionPoolMismatch` | The pool, vault, and position IDs do not match. |
| 2 | `EZeroPositionLiquidity` | The created or collected position has no principal liquidity. |
| 3 | `EPositionLiquidityChanged` | MMT fee collection changed position principal. |
| 4 | `ETierMismatch` | The venue-derived tick spacing of the created pool does not match the effective tier. |

## Cetus errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EInvalidCoinOrder` | The selected Cetus route does not match canonical order. |
| 1 | `EPositionPoolMismatch` | The vault, pool, and position IDs do not match. |
| 2 | `EZeroPositionLiquidity` | The created or collected position has no principal liquidity. |
| 3 | `EPositionLiquidityChanged` | Cetus fee collection changed position principal. |
| 4 | `EPaymentExceedsBalance` | Cetus requested more than the redeemed balance. |
| 5 | `EInsufficientUtilization` | An adopted Cetus pool consumed less than 99.99% of either balance. |
| 6 | `ETierMismatch` | The pool or venue-registered fee does not match the effective tier. |
| 7 | `EMemeBelowQuote` | The Meme atom balance is below the Quote atom balance, so a Meme-fixed full-range seed cannot succeed. |

## Turbos errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EInvalidTickSpacing` | The selected Turbos fee tier or pool has zero tick spacing. |
| 1 | `EPositionPoolMismatch` | The vault, Turbos NFT, and pool IDs do not match. |
| 2 | `EZeroPositionLiquidity` | The created or collected Turbos position has no principal liquidity. |
| 3 | `EPositionLiquidityChanged` | Turbos fee collection changed position principal. |
| 4 | — | Retired before publication; never reuse. |
| 5 | `ETierMismatch` | The Turbos fee object or adopted pool does not match the effective tier. |
| 6 | `EInvalidFeeRate` | A Turbos tier pin exceeds the venue's `u32` fee width. |

## Full Sail errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EInvalidCoinOrder` | The selected Full Sail route does not match canonical order. |
| 1 | `EInvalidTickSpacing` | The selected Full Sail tick spacing is zero. |
| 2 | `EPositionPoolMismatch` | The vault, pool, and Full Sail position IDs do not match. |
| 3 | `EZeroPositionLiquidity` | The created or collected Full Sail position has no principal liquidity. |
| 4 | `EPositionLiquidityChanged` | Full Sail fee collection changed position principal. |
| 5 | `EPaymentExceedsBalance` | Full Sail requested more than the redeemed balance. |
| 6 | `EInsufficientUtilization` | An adopted Full Sail pool consumed less than 99.99% of either balance. |
| 7 | `ETierMismatch` | The tick spacing does not match the effective tier, or the registered fee disagrees with the effective fee on a new pool. |
| 8 | `EMemeBelowQuote` | The Meme atom balance is below the Quote atom balance, so a Meme-fixed full-range seed cannot succeed. |

## Aftermath errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EInvalidCoinOrder` | The selected route does not match Aftermath's canonical type order. |
| 1 | `ELpTypeAlreadyRegistered` | The supplied LP type already identifies an active pool. |
| 2 | — | Retired before publication; never reuse. |
| 3 | `EPoolInvariantMismatch` | The pool, registry, weights, curve, or fee policy differs from the requested policy. |
| 4 | `EBalanceMismatch` | The pool does not hold every source Meme and Quote unit. |
| 5 | `ELpSupplyMismatch` | LP decimals, liquid supply, or the illiquid reserve differs from policy. |
| 6 | `EInvalidWeight` | Either weight is below 1% or the pair does not sum to 100%. |
| 7 | `EUnchangedPolicy` | A policy pin repeated the currently effective weights and fee. |
| 8 | `EInvalidDaoFee` | The DAO fee exceeds 10,000 basis points. |
| 9 | `EDaoPoolInvariantMismatch` | The wrapper, vault, recipient, or updated rate does not match. |
| 10 | `EUnchangedDaoFee` | An existing pool update repeated its current DAO fee. |
| 11 | `ELpPrincipalChanged` | DAO-fee receipt changed the locked LP amount. |

## Vault errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EWrongVenue` | The supplied venue witness does not match the vault's attached position marker. |
| 1 | `ENothingClaimable` | No protocol fee balance or migration residual is available to claim. |
| 2 | `EVaultAlreadyInitialized` | A prepared vault already has a pool before finalization. |
| 3 | `EInvalidReceivingCoinBatch` | Both receiving vectors are empty or contain more than 100 total coin objects. |

## Venue config errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EInvalidTickSpacing` | A tier pin supplied a zero tick spacing. |
| 1 | `EInvalidFeeRate` | A tier pin supplied a zero fee rate. |
| 2 | `EUnchangedTier` | A tier pin repeated the currently pinned values. |
| 3 | `EVenueTierUnset` | A pinned-tier read found no pin; routes never hit this because they fall back to the compiled default. |
