/// MMT migration with canonically ordered, custodied concentrated-liquidity principal.
module blast_fun_migrators::mmt;

use blast_fun::{
    acl::AdminWitness,
    launch::Launch,
    migration_math,
    package_version::PackageVersion,
    runtime_config::RuntimeConfig,
};
use blast_fun_migrators::{
    events,
    vault::{Self, LpVault},
    venue_config::VenueConfig,
};
use mmt_v3::{
    collect,
    create_pool,
    global_config::GlobalConfig,
    i32,
    liquidity,
    pool::{Self, Pool},
    position::Position,
    tick_math,
    version::Version,
};
use sui::{clock::Clock, coin::Coin, coin_registry::Currency};

use fun liquidity::add_liquidity as Pool.add_liquidity;
use fun liquidity::open_position as Pool.open_position;
use fun collect::fee as Pool.collect_fee;

// === Constants ===

/// MMT must use at least 99.99% of both migration balances.
const MAX_RESIDUAL_BPS: u64 = 1;

/// The highest of MMT's ten registered fee entries — a 2% fee (1e6
/// denominator) whose registered tick spacing is 400 — read from the live
/// mainnet `fee_amount_tick_spacing` table on 2026-08-30. Meme pools take the
/// venue's highest tier. The venue derives spacing from the fee, so the
/// created pool's spacing is asserted against the pinned value.
const DEFAULT_TICK_SPACING: u32 = 400;
const DEFAULT_FEE_RATE: u64 = 20_000;

const EInvalidCoinOrder: u64 = 0;
const EPositionPoolMismatch: u64 = 1;
const EZeroPositionLiquidity: u64 = 2;
const EPositionLiquidityChanged: u64 = 3;
const ETierMismatch: u64 = 4;

// === Public Structs ===

/// Sealed adapter identity selected by a Blast launch.
public struct Witness() has drop;

/// Sealed marker for the MMT position attached to the common vault.
public struct Venue() has drop;

// === Public Functions ===

/// Migrates when the canonical MMT order places Meme in coin X.
public fun migrate_meme_x<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    global_config: &mut GlobalConfig,
    mmt_version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_coin_order<Meme, Quote>(true);
    let (pinned_tick_spacing, fee_rate) = effective_tier(venue_config);

    let launch_id = object::id(launch);
    let payload = launch.migrate<Meme, Quote, Witness>(
        package_version,
        meme_currency,
        ctx,
    );
    let (meme, quote) = payload.redeem_migration(Witness());
    let source_meme_amount = meme.value();
    let source_quote_amount = quote.value();
    let sqrt_price_x64 = migration_math::sqrt_price_x64(
        source_meme_amount,
        source_quote_amount,
        true,
    );
    let minimum_meme_amount = migration_math::minimum_utilized_amount(
        source_meme_amount,
        MAX_RESIDUAL_BPS,
    );
    let minimum_quote_amount = migration_math::minimum_utilized_amount(
        source_quote_amount,
        MAX_RESIDUAL_BPS,
    );

    let (
        pool,
        position,
        residual_meme,
        residual_quote,
        lower_tick_bits,
        upper_tick_bits,
        tick_spacing,
    ) = create_and_seed_pool<Meme, Quote>(
        global_config,
        mmt_version,
        pinned_tick_spacing,
        fee_rate,
        sqrt_price_x64,
        meme.into_coin(ctx),
        quote.into_coin(ctx),
        minimum_meme_amount,
        minimum_quote_amount,
        clock,
        ctx,
    );

    lock_and_share<Meme, Quote, Meme, Quote>(
        runtime_config,
        launch_id,
        pool,
        position,
        residual_meme,
        residual_quote,
        source_meme_amount,
        source_quote_amount,
        sqrt_price_x64,
        lower_tick_bits,
        upper_tick_bits,
        tick_spacing,
        fee_rate,
        ctx,
    );
}

/// Migrates when the canonical MMT order places Meme in coin Y.
public fun migrate_meme_y<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    global_config: &mut GlobalConfig,
    mmt_version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_coin_order<Meme, Quote>(false);
    let (pinned_tick_spacing, fee_rate) = effective_tier(venue_config);

    let launch_id = object::id(launch);
    let payload = launch.migrate<Meme, Quote, Witness>(
        package_version,
        meme_currency,
        ctx,
    );
    let (meme, quote) = payload.redeem_migration(Witness());
    let source_meme_amount = meme.value();
    let source_quote_amount = quote.value();
    let sqrt_price_x64 = migration_math::sqrt_price_x64(
        source_meme_amount,
        source_quote_amount,
        false,
    );
    let minimum_meme_amount = migration_math::minimum_utilized_amount(
        source_meme_amount,
        MAX_RESIDUAL_BPS,
    );
    let minimum_quote_amount = migration_math::minimum_utilized_amount(
        source_quote_amount,
        MAX_RESIDUAL_BPS,
    );

    let (
        pool,
        position,
        residual_quote,
        residual_meme,
        lower_tick_bits,
        upper_tick_bits,
        tick_spacing,
    ) = create_and_seed_pool<Quote, Meme>(
        global_config,
        mmt_version,
        pinned_tick_spacing,
        fee_rate,
        sqrt_price_x64,
        quote.into_coin(ctx),
        meme.into_coin(ctx),
        minimum_quote_amount,
        minimum_meme_amount,
        clock,
        ctx,
    );

    lock_and_share<Meme, Quote, Quote, Meme>(
        runtime_config,
        launch_id,
        pool,
        position,
        residual_meme,
        residual_quote,
        source_meme_amount,
        source_quote_amount,
        sqrt_price_x64,
        lower_tick_bits,
        upper_tick_bits,
        tick_spacing,
        fee_rate,
        ctx,
    );
}

/// Collects normalized Meme-X and Quote-Y fees without changing principal.
public fun collect_fees_meme_x<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    runtime_config: &RuntimeConfig,
    pool: &mut Pool<Meme, Quote>,
    mmt_version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let venue = Venue();
    let (
        position_id,
        meme_fee,
        quote_fee,
        liquidity_before,
        liquidity_after,
    ) = collect_position_fees<Meme, Quote, Meme, Quote>(
        self,
        &venue,
        pool,
        mmt_version,
        clock,
        ctx,
    );

    self.accrue_fees(
        &venue,
        position_id,
        meme_fee.into_balance(),
        quote_fee.into_balance(),
        liquidity_before,
        liquidity_after,
        runtime_config,
        ctx,
    );
}

/// Collects normalized Meme-Y and Quote-X fees without changing principal.
public fun collect_fees_meme_y<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    runtime_config: &RuntimeConfig,
    pool: &mut Pool<Quote, Meme>,
    mmt_version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let venue = Venue();
    let (
        position_id,
        quote_fee,
        meme_fee,
        liquidity_before,
        liquidity_after,
    ) = collect_position_fees<Quote, Meme, Meme, Quote>(
        self,
        &venue,
        pool,
        mmt_version,
        clock,
        ctx,
    );

    self.accrue_fees(
        &venue,
        position_id,
        meme_fee.into_balance(),
        quote_fee.into_balance(),
        liquidity_before,
        liquidity_after,
        runtime_config,
        ctx,
    );
}

/// Pins the MMT tier under a live core admin witness, replacing the default.
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

fun assert_coin_order<Meme, Quote>(meme_is_x: bool) {
    let meme_x_order = create_pool::check_coin_order<Meme, Quote>();
    let meme_y_order = create_pool::check_coin_order<Quote, Meme>();
    assert!(meme_x_order != meme_y_order, EInvalidCoinOrder);
    assert!(meme_x_order == meme_is_x, EInvalidCoinOrder);
}

fun create_and_seed_pool<X, Y>(
    global_config: &mut GlobalConfig,
    mmt_version: &Version,
    pinned_tick_spacing: u32,
    fee_rate: u64,
    sqrt_price_x64: u128,
    coin_x: Coin<X>,
    coin_y: Coin<Y>,
    minimum_x_amount: u64,
    minimum_y_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Pool<X, Y>, Position, Coin<X>, Coin<Y>, u32, u32, u32) {
    let mut pool = create_pool::new<X, Y>(
        global_config,
        fee_rate,
        mmt_version,
        ctx,
    );
    pool.initialize(sqrt_price_x64, clock);

    let (lower_tick, upper_tick) = pool.get_friendly_ticks(
        tick_math::min_sqrt_price(),
        tick_math::max_sqrt_price(),
    );
    let lower_tick_bits = lower_tick.as_u32();
    let upper_tick_bits = upper_tick.as_u32();
    let tick_spacing = pool.tick_spacing();
    assert!(tick_spacing == pinned_tick_spacing, ETierMismatch);

    let mut position = pool.open_position(
        lower_tick,
        upper_tick,
        mmt_version,
        ctx,
    );
    let (residual_x, residual_y) = pool.add_liquidity(
        &mut position,
        coin_x,
        coin_y,
        minimum_x_amount,
        minimum_y_amount,
        clock,
        mmt_version,
        ctx,
    );

    (
        pool,
        position,
        residual_x,
        residual_y,
        lower_tick_bits,
        upper_tick_bits,
        tick_spacing,
    )
}

fun transfer_residual<CoinType>(
    residual: Coin<CoinType>,
    protocol_treasury: address,
) {
    if (residual.value() == 0) {
        residual.destroy_zero();
    } else {
        transfer::public_transfer(residual, protocol_treasury);
    };
}

fun lock_and_share<Meme, Quote, X, Y>(
    runtime_config: &RuntimeConfig,
    launch_id: ID,
    pool: Pool<X, Y>,
    position: Position,
    residual_meme: Coin<Meme>,
    residual_quote: Coin<Quote>,
    source_meme_amount: u64,
    source_quote_amount: u64,
    sqrt_price_x64: u128,
    lower_tick_bits: u32,
    upper_tick_bits: u32,
    tick_spacing: u32,
    fee_rate: u64,
    ctx: &mut TxContext,
) {
    let pool_id = object::id(&pool);
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

    let used_meme_amount = source_meme_amount - residual_meme_amount;
    let used_quote_amount = source_quote_amount - residual_quote_amount;
    let protocol_treasury = runtime_config.protocol_treasury();
    transfer_residual(residual_meme, protocol_treasury);
    transfer_residual(residual_quote, protocol_treasury);

    let vault_id = vault::new<Meme, Quote, Venue, Position>(
        Venue(),
        pool_id,
        position,
        ctx,
    );
    pool.transfer();

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
        protocol_treasury,
        sqrt_price_x64,
        lower_tick_bits,
        upper_tick_bits,
        tick_spacing,
        fee_rate,
    );
}

fun collect_position_fees<X, Y, Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    venue: &Venue,
    pool: &mut Pool<X, Y>,
    mmt_version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, Coin<X>, Coin<Y>, u128, u128) {
    let pool_id = object::id(pool);
    assert!(self.pool_id() == pool_id, EPositionPoolMismatch);

    let position =
        self.position_mut<Meme, Quote, Venue, Position>(venue);
    let position_id = object::id(position);
    assert!(position.pool_id() == pool_id, EPositionPoolMismatch);
    let liquidity_before = position.liquidity();
    assert!(liquidity_before > 0, EZeroPositionLiquidity);

    let (fee_x, fee_y) = pool.collect_fee(
        position,
        clock,
        mmt_version,
        ctx,
    );

    assert!(position.pool_id() == pool_id, EPositionPoolMismatch);
    let liquidity_after = position.liquidity();
    assert!(liquidity_after == liquidity_before, EPositionLiquidityChanged);
    assert!(self.pool_id() == pool_id, EPositionPoolMismatch);

    (position_id, fee_x, fee_y, liquidity_before, liquidity_after)
}

// === Test-Only Functions ===

#[test_only]
public fun effective_tier_for_testing(venue_config: &VenueConfig): (u32, u64) {
    effective_tier(venue_config)
}
