/// Bluefin migration with custodied concentrated-liquidity principal.
///
/// Bluefin pools are keyed by their exact type-parameter order, so this module
/// always creates `Pool<Meme, Quote>` with Meme as coin A. The release gate
/// must prove against published bytecode that the venue accepts this order for
/// every allowlisted Quote.
module blast_fun_migrators::bluefin;

use blast_fun::{
    acl::AdminWitness,
    launch::Launch,
    package_version::PackageVersion,
    runtime_config::RuntimeConfig,
};
use blast_fun_migrators::{
    events,
    migration_math,
    vault::{Self, LpVault},
    venue_config::VenueConfig,
};
use bluefin_spot::{
    config::{Self, GlobalConfig},
    pool::{Self, Pool},
    position::Position,
};
use integer_mate::i32;
use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin_registry::Currency,
};

use fun config::get_tick_range as GlobalConfig.tick_range;
use fun config::get_pool_creation_fee_amount as GlobalConfig.pool_creation_fee_amount;

// === Constants ===

/// Venue rounding can return at most one basis point of either source balance.
const MAX_RESIDUAL_BPS: u64 = 1;

/// Bluefin registers no fee-tier table, so the default is the venue's dominant
/// production meme tier — spacing 200 at a 1% fee (1e6 denominator), observed
/// across live mainnet `bluefin_spot::pool::Pool` objects on 2026-08-30.
const DEFAULT_TICK_SPACING: u32 = 200;
const DEFAULT_FEE_RATE: u64 = 10_000;

/// Bluefin's inclusive lower Q64.64 initialization bound at the pinned package.
const MIN_SQRT_PRICE_X64: u128 = 4_295_048_016;

/// Bluefin rejects initialization at or above this exclusive Q64.64 bound.
const MAX_SQRT_PRICE_X64: u128 = 79_226_673_515_401_279_992_447_579_055;

// === Errors ===

#[error(code = 0)]
const EInvalidTickSpacing: vector<u8> = b"Bluefin tick spacing must be greater than zero.";
#[error(code = 1)]
const EUnsupportedCreationFee: vector<u8> = b"Bluefin pool creation fee configuration is unsupported.";
#[error(code = 2)]
const ENonzeroCreationFee: vector<u8> = b"Bluefin pool creation fee must be zero.";
#[error(code = 3)]
const EInvalidSqrtPrice: vector<u8> = b"Bluefin initial square-root price is outside the supported range.";
#[error(code = 4)]
const EPositionPoolMismatch: vector<u8> = b"Bluefin position does not belong to the selected pool.";
#[error(code = 5)]
const EZeroPositionLiquidity: vector<u8> = b"Bluefin position liquidity must be greater than zero.";
#[error(code = 6)]
const EPositionLiquidityChanged: vector<u8> = b"Bluefin fee collection must not change position liquidity.";
#[error(code = 7)]
const EVenueAmountMismatch: vector<u8> = b"Bluefin reported amounts do not match the consumed balances.";
#[error(code = 8)]
const EMemeBelowQuote: vector<u8> = b"Migration Meme balance must be at least the Quote balance.";

// === Public Structs ===

/// Sealed adapter identity selected by a Blast launch.
public struct Witness() has drop;

/// Sealed marker for the Bluefin position attached to the common vault.
public struct Venue() has drop;

// === Public Functions ===

/// Migrates with Meme as Bluefin coin A at the admin-pinned venue tier.
///
/// The full Meme balance is the fixed liquidity side: at the balance-derived
/// opening price a full-range seed leaves its rounding residual on the Quote
/// side, so fixing Meme is the only order the venue can satisfy from the
/// migrated balances.
public fun migrate<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    quote_currency: &Currency<Quote>,
    bluefin_config: &mut GlobalConfig,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let launch_id = object::id(launch);
    let (tick_spacing, fee_rate) = effective_tier(venue_config);
    let (lower_tick_bits, upper_tick_bits) =
        full_range_ticks(bluefin_config, tick_spacing);
    let pool_name = pool_name(meme_currency, quote_currency);
    let meme_icon_url = meme_currency.icon_url().into_bytes();
    let coin_a_symbol = meme_currency.symbol().into_bytes();
    let coin_a_decimals = meme_currency.decimals();
    let coin_b_symbol = quote_currency.symbol().into_bytes();
    let coin_b_decimals = quote_currency.decimals();
    let coin_b_url = quote_currency.icon_url().into_bytes();
    let creation_fee = zero_creation_fee<Quote>(bluefin_config);

    let payload = launch.migrate<Meme, Quote, Witness>(
        package_version,
        meme_currency,
        ctx,
    );
    let (meme, quote) = payload.redeem_migration(Witness());
    let source_meme_amount = meme.value();
    let source_quote_amount = quote.value();
    // A full-range seed with Meme fixed is feasible only while the Meme atom
    // balance is at least the Quote atom balance; reject the perverse
    // configuration with a named guard instead of a venue abort.
    assert!(source_meme_amount >= source_quote_amount, EMemeBelowQuote);
    let sqrt_price_x64 = migration_math::sqrt_price_x64(
        source_meme_amount,
        source_quote_amount,
        true,
    );
    assert_valid_sqrt_price(sqrt_price_x64);

    let (
        pool_id,
        position,
        used_meme_amount,
        used_quote_amount,
        residual_meme,
        residual_quote,
    ) = pool::create_pool_with_liquidity<Meme, Quote, Quote>(
        clock,
        bluefin_config,
        pool_name,
        meme_icon_url,
        coin_a_symbol,
        coin_a_decimals,
        meme_icon_url,
        coin_b_symbol,
        coin_b_decimals,
        coin_b_url,
        tick_spacing,
        fee_rate,
        sqrt_price_x64,
        creation_fee,
        lower_tick_bits,
        upper_tick_bits,
        meme,
        quote,
        source_meme_amount,
        true,
        ctx,
    );

    lock_and_share(
        launch_id,
        pool_id,
        position,
        source_meme_amount,
        source_quote_amount,
        used_meme_amount,
        used_quote_amount,
        residual_meme,
        residual_quote,
        sqrt_price_x64,
        lower_tick_bits,
        upper_tick_bits,
        tick_spacing,
        fee_rate,
        ctx,
    );
}

/// Collects Meme and Quote fees without changing the position principal.
public fun collect_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    runtime_config: &RuntimeConfig,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let pool_id = object::id(pool);
    assert!(self.pool_id() == pool_id, EPositionPoolMismatch);

    let venue = Venue();
    let position =
        self.position_mut<Meme, Quote, Venue, Position>(&venue);
    let position_id = object::id(position);
    assert!(position.pool_id() == pool_id, EPositionPoolMismatch);
    let liquidity_before = position.liquidity();
    assert!(liquidity_before > 0, EZeroPositionLiquidity);

    let (_, _, meme_fee, quote_fee) = pool::collect_fee(
        clock,
        bluefin_config,
        pool,
        position,
    );

    assert!(position.pool_id() == pool_id, EPositionPoolMismatch);
    let liquidity_after = position.liquidity();
    assert!(liquidity_after == liquidity_before, EPositionLiquidityChanged);
    assert!(self.pool_id() == pool_id, EPositionPoolMismatch);

    self.accrue_fees(
        &venue,
        position_id,
        meme_fee,
        quote_fee,
        liquidity_before,
        liquidity_after,
        runtime_config,
        ctx,
    );
}

/// Pins the Bluefin tier under a live core admin witness, replacing the default.
public fun set_tier(
    venue_config: &mut VenueConfig,
    _: &AdminWitness,
    tick_spacing: u32,
    fee_rate: u64,
) {
    venue_config.set_tier(Venue(), tick_spacing, fee_rate);
}

// === Private Functions ===

fun effective_tier(venue_config: &VenueConfig): (u32, u64) {
    if (venue_config.has_tier_override<Venue>()) {
        venue_config.tier_override<Venue>()
    } else {
        (DEFAULT_TICK_SPACING, DEFAULT_FEE_RATE)
    }
}

fun full_range_ticks(
    bluefin_config: &GlobalConfig,
    tick_spacing: u32,
): (u32, u32) {
    assert!(tick_spacing > 0, EInvalidTickSpacing);

    let (minimum_tick, maximum_tick) = bluefin_config.tick_range();
    let tick_spacing = i32::from(tick_spacing);
    let lower_tick = minimum_tick.div(tick_spacing).mul(tick_spacing);
    let upper_tick = maximum_tick.div(tick_spacing).mul(tick_spacing);

    (lower_tick.as_u32(), upper_tick.as_u32())
}

fun zero_creation_fee<Quote>(
    bluefin_config: &GlobalConfig,
): Balance<Quote> {
    let (supported, fee_amount) = bluefin_config.pool_creation_fee_amount<Quote>();
    assert!(supported, EUnsupportedCreationFee);
    assert!(fee_amount == 0, ENonzeroCreationFee);

    balance::zero<Quote>()
}

fun pool_name<CoinA, CoinB>(
    currency_a: &Currency<CoinA>,
    currency_b: &Currency<CoinB>,
): vector<u8> {
    let mut name = currency_a.symbol().into_bytes();
    name.append(b"-");
    name.append(currency_b.symbol().into_bytes());

    name
}

fun assert_valid_sqrt_price(sqrt_price_x64: u128) {
    assert!(
        sqrt_price_x64 >= MIN_SQRT_PRICE_X64
            && sqrt_price_x64 < MAX_SQRT_PRICE_X64,
        EInvalidSqrtPrice,
    );
}

fun lock_and_share<Meme, Quote>(
    launch_id: ID,
    pool_id: ID,
    position: Position,
    source_meme_amount: u64,
    source_quote_amount: u64,
    used_meme_amount: u64,
    used_quote_amount: u64,
    residual_meme: Balance<Meme>,
    residual_quote: Balance<Quote>,
    sqrt_price_x64: u128,
    lower_tick_bits: u32,
    upper_tick_bits: u32,
    tick_spacing: u32,
    fee_rate: u64,
    ctx: &mut TxContext,
) {
    assert!(position.pool_id() == pool_id, EPositionPoolMismatch);
    assert!(position.liquidity() > 0, EZeroPositionLiquidity);
    let residual_meme_amount = residual_meme.value();
    let residual_quote_amount = residual_quote.value();
    migration_math::assert_residual_within_bps(
        source_meme_amount,
        residual_meme_amount,
        MAX_RESIDUAL_BPS,
    );
    migration_math::assert_residual_within_bps(
        source_quote_amount,
        residual_quote_amount,
        MAX_RESIDUAL_BPS,
    );
    assert!(
        used_meme_amount == source_meme_amount - residual_meme_amount
            && used_quote_amount
                == source_quote_amount - residual_quote_amount,
        EVenueAmountMismatch,
    );

    let vault_id = vault::new<Meme, Quote, Venue, Position>(
        Venue(),
        pool_id,
        position,
        residual_meme,
        residual_quote,
        ctx,
    );
    events::migration_completed<Meme, Quote, Venue>(
        launch_id,
        vault_id,
        pool_id,
        source_meme_amount,
        source_quote_amount,
        used_meme_amount,
        used_quote_amount,
        residual_meme_amount,
        residual_quote_amount,
        sqrt_price_x64,
        lower_tick_bits,
        upper_tick_bits,
        tick_spacing,
        fee_rate,
    );
}

// === Test-Only Functions ===

#[test_only]
public fun effective_tier_for_testing(venue_config: &VenueConfig): (u32, u64) {
    effective_tier(venue_config)
}
