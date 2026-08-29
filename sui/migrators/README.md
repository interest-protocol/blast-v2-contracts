# Blast migration adapters

This directory is one aggregate Move package for all supported liquidity
venues. Venue modules depend on the launchpad core; the launchpad core never
imports this package. A launch selects a venue's sealed migration witness.

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

Creator and protocol fee claims are defined once in `vault`. Venue modules pass
completed fee balances through the witness-gated `vault::accrue_fees` function;
they cannot borrow the common fee ledger directly.

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

## Replayable events

The dedicated `events` module owns five strongly typed payloads and their
package-only emit helpers. Only that module calls `sui::event::emit`; state
modules call its typed helpers.

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

`Move.toml` pins every direct or overridden Git dependency to a complete
commit:

| Package | Commit |
| --- | --- |
| Bluefin Spot interface | `91ce930575b2aa3decab9b7e129b8002deba80c1` |
| MMT V3 interface | `e27d14caed53e1b7c4e1c12ea89b2ff87c58ee82` |
| Cetus IntegerMate | `09a12d9b171122883d9350039d4ed6e8400033b9` |
| Cetus MoveSTL | `0681fec63a310ae753d03a06f7c05d3e2925bb09` |
| Turbos CLMM interface | `cff693265bfc41c7de2233afe31c9d7428adc9e1` |
| Sui | `06734f6ff0af45d8632a14a4dc4b100197f6b1a2` |
| IntegerMate | `09a12d9b171122883d9350039d4ed6e8400033b9` |
| IntegerLibrary | `8a534bd1c0b334cd3937c27987f3147a06ba6a18` |

The current IntegerMate package is at its repository root. The aggregate
package overrides Bluefin's older transitive revision with this same pin so
future Cetus integration can use one integer package.

The pinned Bluefin interface declares original package
`0x3492c874c1e3b3e2984e8c41b589e642d4d0a5d6459e5a9cfc2d52fd7c89c267`.
Mainnet revision 17 is
`0xd075338d105482f1527cbfd363d6413558f184dec36d9138a70261e87f486e9c`,
with digest `4tyboYqrPbZzN6V5Lh2TccW8j9nbH65mJeQFynoQGxut`. Its normalized targets used
by the adapter match the pinned interface signatures.

The pinned MMT interface declares original package
`0x70285592c97965e811e0c6f98dccc3a9c2b4ad854b3594faab9597ada267b860`.
Mainnet revision 5 is
`0xcf60a40f45d46fc1e828871a647c1e25a0915dec860d2662eb10fdb382c3c1d1`.
The adapter uses the pinned revision's canonical-order, pool, position,
liquidity, collection, and tick-helper interfaces.

The local Cetus interface preserves original package
`0x1eabed72c53feb3805120a081dc15963c204dc8d091542592abaf7a35689b2fb` and
sets `published-at` to mainnet revision 14 at
`0x25ebb9a7c50eb17b3fa9c5a30fb8b5ad8f97caaf4928943acbcff7153dfee5e3`.
That immutable package has digest `FEdn2yRh28atu7tANr6gCWQ3gtDSD2EZmyEeryTuokoi`.
The normalized interface includes only the public Cetus types and functions
used by this adapter.

The pinned Turbos interface declares original package
`0x91bfbc386a41afcfd9b2533058d7e915a1d3829089cc268ff4333d54d6339ca1` and
sets `published-at` to mainnet latest package
`0xa5a0c25c79e428eba04fb98b3fb2a34db45ab26d4c8faf0d7e39d66a63891e64`.
At the pinned source, the adapter consumes exactly
`pool_factory::deploy_pool_and_mint_with_return_`,
`position_manager::mint_with_return_`,
`position_manager::collect_with_return_`,
`position_manager::get_position_info`, the `pool::get_pool_*` getters, and
the signed full-range `math_tick` helpers. The aggregate package overrides the
upstream mutable `Sui = testnet` reference with its pinned
`06734f6ff0af45d8632a14a4dc4b100197f6b1a2` framework dependency.

## Verification and immutable-release gate

Run from this directory:

```bash
sui move build
sui move lint --warnings-are-errors
sui move build -e mainnet
bash scripts/check_source_boundaries.sh
```

The Bluefin, MMT, Cetus, and Turbos interface dependencies contain `abort 0` link
stubs. A local build proves type compatibility only. Before production release,
verify published-package lineage and normalized ABI. Then run mainnet
dev-inspect fixtures for every creation and adoption orientation, exact
balance-derived initialization, 50-bps Cetus and Turbos adoption checks,
one-basis-point residual limits, and fee collection without a liquidity change.

Source omission does not make principal custody permanent while this package
has an `UpgradeCap`. After the release checks pass, destroy the package
`UpgradeCap` and record the immutable-package evidence. Do not add a migrator
admin capability. No production claim that LP principal is permanently locked
is valid before this irreversible step.

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

## Vault errors

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | `EWrongVenue` | The supplied venue witness does not match the vault's attached position marker. |
