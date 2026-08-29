# Blast migration adapters

This directory is one aggregate Move package for all supported liquidity
venues. Venue modules depend on the launchpad core; the launchpad core never
imports this package. A launch selects a venue's sealed migration witness.

Bluefin, MMT, Cetus, Turbos, and Full Sail ship together in this one package, so
they share one custody surface, one claim surface, one dependency graph, one
release gate, and one `UpgradeCap`. [DEPENDENCIES.md](DEPENDENCIES.md) owns the
package-id and dependency matrix, the committed module fingerprints, the
dev-inspect matrix, and the immutable-release gate.

## Common vault

Every completed migration creates one shared `vault::LpVault<Meme, Quote>`.
The vault stores the pool ID and the common `FeeLedger<Meme, Quote>`. Its one
venue position is a child object under the sealed
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

Every venue residual goes to the live `runtime_config::protocol_treasury`
address read during that migration. No adapter stores its own treasury address,
and no adapter burns a residual or sends one to `0x0`.

## Bluefin route

`bluefin::migrate` supports one deterministic orientation: Meme is coin A and
Quote is coin B. It calls guarded `launch::migrate`, redeems the typed payload
with `bluefin::Witness` in the same transaction, and derives the Q64.64
Quote-per-Meme price from the actual payload balances. Display decimals do not
affect the price. Bluefin event metadata comes from the supplied Coin Registry
`Currency<Meme>` and `Currency<Quote>` objects.

The caller selects tick spacing and fee rate. The adapter gets the live range
from `config::get_tick_range`, aligns both endpoints inward, and validates the
pinned Bluefin initialization-price bounds. It queries the Quote-denominated
creation fee, requires a supported Quote type and an exact zero amount, and
constructs only `balance::zero<Quote>()`.

Each Meme or Quote residual must be at most one basis point of its migration
input. Both residual balances go to the live protocol treasury. The returned
position must belong to the new pool and have positive liquidity before it is
attached to the common vault.

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
and Quote balances. They create and initialize a new pool, derive full-range
friendly ticks through the pinned MMT helpers, open the position, and require
at least 99.99% use of both balances while adding liquidity. The position enters
the common vault before the new MMT pool is shared. Both residual coins go to
the live protocol treasury.

MMT fee collection has one typed route for each pool orientation. Each route
requires the sealed MMT venue value, verifies the vault, pool, and position
identities, and requires unchanged positive position liquidity. Coin X/Y fees
are normalized to Meme/Quote before they enter the common fee ledger.

## Cetus routes

Cetus has new-pool and adopted-pool routes for both canonical type orders.
`migrate_new_meme_a` and `migrate_existing_meme_a` require Meme as coin A.
`migrate_new_meme_b` and `migrate_existing_meme_b` require Meme as coin B.
Each route checks the Cetus canonical order and its pool-key rule. The caller
does not supply an orientation or a price.

New routes derive the Q64.64 price from redeemed atomic balances. They use
`pool_creator::full_range_tick_range` and create unpermissioned pools through
`create_pool_v3`. The adapter gets the fee rate from the live Cetus fee tier.
It requires at least 99.99% use and at most one-basis-point residual for both
assets. Residual Meme and Quote coins go to the live runtime treasury.

Existing routes redeem the core payload before the balance-derived target exists.
They immediately compare that target with `pool::current_sqrt_price` at 50 bps,
before opening a position or adding liquidity. They use Cetus's fixed-coin
receipt, payment, and repayment flow, then check the created position belongs
to the supplied pool. Atomic failure restores the core launch transition.

`collect_fees_meme_a` and `collect_fees_meme_b` require a real private Cetus
venue value. They check vault, pool, and position IDs and positive liquidity.
They call `pool::collect_fee(..., true)` and require unchanged liquidity.
The Meme-B route reverses Cetus A/B fee balances before common Meme/Quote
accrual.

## Turbos routes

Turbos has new-pool and adopted-pool routes for both type orders. The
`migrate_*_meme_a` routes use Meme as coin A. The `migrate_*_meme_b` routes use
Meme as coin B. New-pool callers provide one concrete `Fee<FeeType>` object;
the selected `FeeType` fixes the Turbos fee tier and tick spacing. Existing
routes take a pool with that same `FeeType`. Callers do not provide a price or
an orientation flag.

Each route derives its Q64.64 price from the redeemed atomic Meme and Quote
balances. The adapter derives full-range signed ticks from
`math_tick::get_min_tick` and `math_tick::get_max_tick`. New routes call
`pool_factory::deploy_pool_and_mint_with_return_`. Existing routes redeem the
payload, compare the balance-derived price with the live pool price at exactly
50 bps, then call `position_manager::mint_with_return_`. All liquidity calls
use caller-provided deadlines and one-basis-point minimum amounts.

The returned `TurbosPositionNFT` enters the common vault as its dynamic object
field. The adapter rejects a mismatched pool ID, requires at least 99.99% use
of both inputs, and sends each residual to the live runtime treasury. Both fee
routes call `collect_with_return_`, read `get_position_info` before and after,
and require unchanged positive liquidity. The Meme-B route reverses Turbos A/B
fee coins before shared Meme/Quote accrual.

## Full Sail routes

Full Sail has new-pool and adopted-pool routes for both canonical type orders.
Its canonical order is descending lexical order of coin type names, which
`clmm_pool::factory::new_pool_key` enforces through the deprecated
`type_name::get`. That helper returns defining IDs, so the adapter compares
defining IDs to reproduce the pinned venue rule exactly. Each route verifies
that order on chain before it redeems the migration payload. Callers do not
supply an orientation or an economic price.

New routes derive the Q64.64 price from the actual Meme and Quote balances and
call revision 4 `factory::create_pool_with_liquidity`. They pass both source
amounts, an empty URI, zero feed IDs, and `false` for automatic volume
calculation. Thus an arbitrary Meme does not claim an oracle or stable-asset
feed. The adapter derives both full-range ticks from Full Sail `tick_math`,
aligns them inward to the selected tick spacing, and uses the live global
configuration, rewarder vault, and pool registry.

Adopted routes redeem the payload and immediately compare the balance-derived
price with `pool::current_sqrt_price` at exactly 50 bps. Only then do they use
Full Sail's open, fixed-coin add, payment, and repayment receipt flow. Every
route requires at least 99.99% use of both assets and sends both residuals to
the live runtime treasury.

The returned `Position` enters the common vault as its sealed dynamic object
field. Both fee routes call `pool::collect_fee(..., true)`, verify pool and
position identities before and after collection, and require unchanged
positive liquidity. The Meme-B route reverses Full Sail A/B fees before common
Meme/Quote accrual.

## Replayable events

The dedicated `events` module owns five strongly typed payloads and their
package-only emit helpers. Only that module calls `sui::event::emit`; state
modules call its typed helpers.

These are direct Sui events. This independently deployed package deliberately
does **not** wrap them in the core `events_wrapper::Event<T>` envelope: wrapping
would add nothing here, it would hide the payload type from native event
filters, and it would pull a second package into the core event ABI. Consumers
filter on the five payload types below.

- `VaultCreated` records vault, pool, and position IDs plus venue, Meme, and
  Quote type names.
- `MigrationCompleted` records launch, vault, and pool IDs; source, used, and
  residual amounts for both assets; residual treasury; balance-derived price;
  and the exact tick and fee inputs.
- `LpFeesCollected` records vault, pool, and position IDs; the venue and asset
  types; collector; gross fees; applied protocol share; creator/protocol deltas
  and final totals for both assets; and principal liquidity before and after.
- `CreatorFeesClaimed` and `ProtocolFeesClaimed` record the vault, claimant,
  drained amounts, asset types, and all four post-claim ledger totals.

The payloads are completed facts and use native Sui event ordering. They contain
no application sequence, revision, nonce, schema version, or action tag.

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
sui move build -e mainnet
bash scripts/check_source_boundaries.sh
bash scripts/check_turbos_dependency_pin.sh
bash scripts/check_fullsail_dependency_pin.sh
```

`scripts/check_mainnet_abi.mjs` uses Node built-ins only and the official Sui
mainnet GraphQL endpoint. For Bluefin, MMT, Cetus, Turbos, Full Sail, and Full
Sail's separate IntegerMate package it resolves the original package id to its
current revision, fails when any revision exists beyond the pinned tip, and
asserts the package id, version, whole-package digest, previous transaction, and
original type origins. It then asserts a committed SHA-256 over each consumed
module's decoded on-chain bytecode and the normalized public ABI of every
consumed function and struct, comparing structured signatures rather than
display prose so that a missing or extra parameter, `&` versus `&mut`,
visibility drift, ability drift, phantom drift, or return drift all fail.

Every GraphQL field is shape-validated before it is rendered, so a null,
partial, or novel response fails instead of normalizing into a passing value.
The same run parses the root manifest, the four local interface manifests, and
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
all 15 migration routes, all 9 fee-collection routes, and both vault claims,
covering exact balance-derived initialization, zero Bluefin creation fee, venue
canonical order, full-range tick bounds, the 50-bps Cetus, Turbos, and Full Sail
adoption checks, one-basis-point residual limits with treasury delivery, and fee
collection with unchanged principal liquidity.

Source omission does not make principal custody permanent while this package has
an `UpgradeCap`: a compatible upgrade could add an extraction function. LP
principal may be described as permanently locked **only after** the self-test and
every live ABI gate above pass, every local gate passes, every dev-inspect row passes, and the
aggregate package's single `UpgradeCap` is destroyed and that immutable-package
evidence is recorded. Until then the accurate statement is that principal is held
by an upgradeable package with no exposed withdrawal path. Do not add a migrator
admin capability as an alternative.

## Bluefin errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EInvalidTickSpacing` | Tick spacing is zero. |
| 1 | `EUnsupportedCreationFee` | Quote is not a supported Bluefin creation-fee type. |
| 2 | `ENonzeroCreationFee` | Bluefin requires a nonzero Quote pool-opening fee. |
| 3 | `EInvalidSqrtPrice` | The balance-derived price is outside pinned Bluefin bounds. |
| 4 | `EPositionPoolMismatch` | The pool, vault, and position IDs do not match. |
| 5 | `EZeroPositionLiquidity` | The created or collected position has no principal liquidity. |
| 6 | `EPositionLiquidityChanged` | Bluefin fee collection changed position principal. |

## MMT errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EInvalidCoinOrder` | The selected MMT route does not match the unique canonical type order. |
| 1 | `EPositionPoolMismatch` | The pool, vault, and position IDs do not match. |
| 2 | `EZeroPositionLiquidity` | The created or collected position has no principal liquidity. |
| 3 | `EPositionLiquidityChanged` | MMT fee collection changed position principal. |

## Cetus errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EInvalidCoinOrder` | The selected Cetus route does not match canonical order. |
| 1 | `EPositionPoolMismatch` | The vault, pool, and position IDs do not match. |
| 2 | `EZeroPositionLiquidity` | The created or collected position has no principal liquidity. |
| 3 | `EPositionLiquidityChanged` | Cetus fee collection changed position principal. |
| 4 | `EPaymentExceedsBalance` | Cetus requested more than the redeemed balance. |
| 5 | `EInsufficientUtilization` | Cetus used less than 99.99%, or left more than a 1-bps residual. |

## Turbos errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EInvalidTickSpacing` | The selected Turbos fee tier or pool has zero tick spacing. |
| 1 | `EPositionPoolMismatch` | The vault, Turbos NFT, and pool IDs do not match. |
| 2 | `EZeroPositionLiquidity` | The created or collected Turbos position has no principal liquidity. |
| 3 | `EPositionLiquidityChanged` | Turbos fee collection changed position principal. |
| 4 | `EInsufficientUtilization` | Turbos used less than 99.99%, or left more than a 1-bps residual. |

## Full Sail errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EInvalidCoinOrder` | The selected Full Sail route does not match canonical order. |
| 1 | `EInvalidTickSpacing` | The selected Full Sail tick spacing is zero. |
| 2 | `EPositionPoolMismatch` | The vault, pool, and Full Sail position IDs do not match. |
| 3 | `EZeroPositionLiquidity` | The created or collected Full Sail position has no principal liquidity. |
| 4 | `EPositionLiquidityChanged` | Full Sail fee collection changed position principal. |
| 5 | `EPaymentExceedsBalance` | Full Sail requested more than the redeemed balance. |
| 6 | `EInsufficientUtilization` | Full Sail used less than 99.99%, or left more than a 1-bps residual. |

## Vault errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EWrongVenue` | The supplied venue witness does not match the vault's attached position marker. |
