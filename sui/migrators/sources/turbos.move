/// Turbos migration with custodied concentrated-liquidity principal.
///
/// Turbos pools are keyed by their exact `(CoinA, CoinB, FeeType)` order and
/// the venue registers no canonical pair order, so both type orders are real
/// routes. The admin-pinned tier makes the venue fee object deterministic.
module blast_fun_migrators::turbos;

use blast_fun::{
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
use sui::{clock::Clock, coin::Coin, coin_registry::Currency};
use turbos_clmm::{
    fee::{Self, Fee},
    i32,
    math_tick,
    pool::{Self, Pool, Versioned},
    pool_factory::{Self, PoolConfig},
    position_manager::{Self, Positions},
    position_nft::TurbosPositionNFT,
};

// === Constants ===

/// Turbos must use at least 99.99% of both migration balances.
const MAX_RESIDUAL_BPS: u64 = 1;

/// Coarse adoption gate; the residual rule below binds far tighter.
const MAX_PRICE_DEVIATION_BPS: u64 = 50;

const EInvalidTickSpacing: u64 = 0;
const EPositionPoolMismatch: u64 = 1;
const EZeroPositionLiquidity: u64 = 2;
const EPositionLiquidityChanged: u64 = 3;
const ETierMismatch: u64 = 5;

// === Public Structs ===

/// Sealed adapter identity selected by a Blast launch.
public struct Witness() has drop;

/// Sealed marker for the Turbos position attached to the common vault.
public struct Venue() has drop;

// === Public Functions ===

/// Creates a Turbos pool with Meme as coin A and locks its full-range NFT.
public fun migrate_new_meme_a<Meme, Quote, FeeType>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    pool_config: &mut PoolConfig,
    fee: &Fee<FeeType>,
    positions: &mut Positions,
    deadline: u64,
    clock: &Clock,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    let (tick_spacing, fee_rate) = assert_fee_tier(venue_config, fee);
    let (lower_magnitude, lower_is_neg, upper_magnitude, upper_is_neg) =
        full_range_ticks(tick_spacing);
    let lower_tick_bits = tick_bits(lower_magnitude, lower_is_neg);
    let upper_tick_bits = tick_bits(upper_magnitude, upper_is_neg);
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

    let (position, residual_meme, residual_quote, pool_id) =
        pool_factory::deploy_pool_and_mint_with_return_<Meme, Quote, FeeType>(
            pool_config,
            fee,
            sqrt_price_x64,
            positions,
            vector[meme.into_coin(ctx)],
            vector[quote.into_coin(ctx)],
            lower_magnitude,
            lower_is_neg,
            upper_magnitude,
            upper_is_neg,
            source_meme_amount,
            source_quote_amount,
            minimum_meme_amount,
            minimum_quote_amount,
            deadline,
            clock,
            versioned,
            ctx,
    );
    assert!(position.pool_id() == pool_id, EPositionPoolMismatch);
    assert_positive_liquidity(&position, positions);

    let venue = Venue();
    lock_and_share<Meme, Quote>(
        runtime_config,
        venue,
        launch_id,
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

/// Creates a Turbos pool with Meme as coin B and locks its full-range NFT.
public fun migrate_new_meme_b<Meme, Quote, FeeType>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    pool_config: &mut PoolConfig,
    fee: &Fee<FeeType>,
    positions: &mut Positions,
    deadline: u64,
    clock: &Clock,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    let (tick_spacing, fee_rate) = assert_fee_tier(venue_config, fee);
    let (lower_magnitude, lower_is_neg, upper_magnitude, upper_is_neg) =
        full_range_ticks(tick_spacing);
    let lower_tick_bits = tick_bits(lower_magnitude, lower_is_neg);
    let upper_tick_bits = tick_bits(upper_magnitude, upper_is_neg);
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

    let (position, residual_quote, residual_meme, pool_id) =
        pool_factory::deploy_pool_and_mint_with_return_<Quote, Meme, FeeType>(
            pool_config,
            fee,
            sqrt_price_x64,
            positions,
            vector[quote.into_coin(ctx)],
            vector[meme.into_coin(ctx)],
            lower_magnitude,
            lower_is_neg,
            upper_magnitude,
            upper_is_neg,
            source_quote_amount,
            source_meme_amount,
            minimum_quote_amount,
            minimum_meme_amount,
            deadline,
            clock,
            versioned,
            ctx,
    );
    assert!(position.pool_id() == pool_id, EPositionPoolMismatch);
    assert_positive_liquidity(&position, positions);

    let venue = Venue();
    lock_and_share<Meme, Quote>(
        runtime_config,
        venue,
        launch_id,
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

/// Adds locked full-range liquidity to an adopted Turbos pool with Meme as coin A.
public fun migrate_existing_meme_a<Meme, Quote, FeeType>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    pool: &mut Pool<Meme, Quote, FeeType>,
    positions: &mut Positions,
    deadline: u64,
    clock: &Clock,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    let (tick_spacing, fee_rate) = assert_pool_tier(venue_config, pool);
    let (lower_magnitude, lower_is_neg, upper_magnitude, upper_is_neg) =
        full_range_ticks(tick_spacing);
    let lower_tick_bits = tick_bits(lower_magnitude, lower_is_neg);
    let upper_tick_bits = tick_bits(upper_magnitude, upper_is_neg);
    let launch_id = object::id(launch);

    let payload = launch.migrate<Meme, Quote, Witness>(
        package_version,
        meme_currency,
        ctx,
    );
    let (meme, quote) = payload.redeem_migration(Witness());
    let source_meme_amount = meme.value();
    let source_quote_amount = quote.value();
    let pool_sqrt_price = pool.get_pool_sqrt_price();
    migration_math::assert_price_within_bps(
        source_meme_amount,
        source_quote_amount,
        true,
        pool_sqrt_price,
        MAX_PRICE_DEVIATION_BPS,
    );
    let minimum_meme_amount = migration_math::minimum_utilized_amount(
        source_meme_amount,
        MAX_RESIDUAL_BPS,
    );
    let minimum_quote_amount = migration_math::minimum_utilized_amount(
        source_quote_amount,
        MAX_RESIDUAL_BPS,
    );

    let (position, residual_meme, residual_quote) =
        position_manager::mint_with_return_<Meme, Quote, FeeType>(
            pool,
            positions,
            vector[meme.into_coin(ctx)],
            vector[quote.into_coin(ctx)],
            lower_magnitude,
            lower_is_neg,
            upper_magnitude,
            upper_is_neg,
            source_meme_amount,
            source_quote_amount,
            minimum_meme_amount,
            minimum_quote_amount,
            deadline,
            clock,
            versioned,
            ctx,
    );
    assert!(position.pool_id() == object::id(pool), EPositionPoolMismatch);
    assert_positive_liquidity(&position, positions);

    let venue = Venue();
    lock_and_share<Meme, Quote>(
        runtime_config,
        venue,
        launch_id,
        position,
        residual_meme,
        residual_quote,
        source_meme_amount,
        source_quote_amount,
        pool_sqrt_price,
        lower_tick_bits,
        upper_tick_bits,
        tick_spacing,
        fee_rate,
        ctx,
    );
}

/// Adds locked full-range liquidity to an adopted Turbos pool with Meme as coin B.
public fun migrate_existing_meme_b<Meme, Quote, FeeType>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    pool: &mut Pool<Quote, Meme, FeeType>,
    positions: &mut Positions,
    deadline: u64,
    clock: &Clock,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    let (tick_spacing, fee_rate) = assert_pool_tier(venue_config, pool);
    let (lower_magnitude, lower_is_neg, upper_magnitude, upper_is_neg) =
        full_range_ticks(tick_spacing);
    let lower_tick_bits = tick_bits(lower_magnitude, lower_is_neg);
    let upper_tick_bits = tick_bits(upper_magnitude, upper_is_neg);
    let launch_id = object::id(launch);

    let payload = launch.migrate<Meme, Quote, Witness>(
        package_version,
        meme_currency,
        ctx,
    );
    let (meme, quote) = payload.redeem_migration(Witness());
    let source_meme_amount = meme.value();
    let source_quote_amount = quote.value();
    let pool_sqrt_price = pool.get_pool_sqrt_price();
    migration_math::assert_price_within_bps(
        source_meme_amount,
        source_quote_amount,
        false,
        pool_sqrt_price,
        MAX_PRICE_DEVIATION_BPS,
    );
    let minimum_meme_amount = migration_math::minimum_utilized_amount(
        source_meme_amount,
        MAX_RESIDUAL_BPS,
    );
    let minimum_quote_amount = migration_math::minimum_utilized_amount(
        source_quote_amount,
        MAX_RESIDUAL_BPS,
    );

    let (position, residual_quote, residual_meme) =
        position_manager::mint_with_return_<Quote, Meme, FeeType>(
            pool,
            positions,
            vector[quote.into_coin(ctx)],
            vector[meme.into_coin(ctx)],
            lower_magnitude,
            lower_is_neg,
            upper_magnitude,
            upper_is_neg,
            source_quote_amount,
            source_meme_amount,
            minimum_quote_amount,
            minimum_meme_amount,
            deadline,
            clock,
            versioned,
            ctx,
    );
    assert!(position.pool_id() == object::id(pool), EPositionPoolMismatch);
    assert_positive_liquidity(&position, positions);

    let venue = Venue();
    lock_and_share<Meme, Quote>(
        runtime_config,
        venue,
        launch_id,
        position,
        residual_meme,
        residual_quote,
        source_meme_amount,
        source_quote_amount,
        pool_sqrt_price,
        lower_tick_bits,
        upper_tick_bits,
        tick_spacing,
        fee_rate,
        ctx,
    );
}

/// Collects normalized Meme-A and Quote-B fees without changing principal.
public fun collect_fees_meme_a<Meme, Quote, FeeType>(
    self: &mut LpVault<Meme, Quote>,
    runtime_config: &RuntimeConfig,
    pool: &mut Pool<Meme, Quote, FeeType>,
    positions: &mut Positions,
    deadline: u64,
    clock: &Clock,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    let venue = Venue();
    let (position_id, meme_fee, quote_fee, liquidity_before, liquidity_after) =
        collect_position_fees<Meme, Quote, Meme, Quote, FeeType>(
            self,
            &venue,
            runtime_config,
            pool,
            positions,
            deadline,
            clock,
            versioned,
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

/// Collects normalized Meme-B and Quote-A fees without changing principal.
public fun collect_fees_meme_b<Meme, Quote, FeeType>(
    self: &mut LpVault<Meme, Quote>,
    runtime_config: &RuntimeConfig,
    pool: &mut Pool<Quote, Meme, FeeType>,
    positions: &mut Positions,
    deadline: u64,
    clock: &Clock,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    let venue = Venue();
    let (position_id, quote_fee, meme_fee, liquidity_before, liquidity_after) =
        collect_position_fees<Quote, Meme, Meme, Quote, FeeType>(
            self,
            &venue,
            runtime_config,
            pool,
            positions,
            deadline,
            clock,
            versioned,
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

// === Private Functions ===

fun assert_fee_tier<FeeType>(
    venue_config: &VenueConfig,
    fee: &Fee<FeeType>,
): (u32, u64) {
    let (tick_spacing, fee_rate) = venue_config.turbos_tier();
    assert!(fee.get_tick_spacing() == tick_spacing, ETierMismatch);
    assert!((fee.get_fee() as u64) == fee_rate, ETierMismatch);

    (tick_spacing, fee_rate)
}

fun assert_pool_tier<CoinA, CoinB, FeeType>(
    venue_config: &VenueConfig,
    pool: &Pool<CoinA, CoinB, FeeType>,
): (u32, u64) {
    let (tick_spacing, fee_rate) = venue_config.turbos_tier();
    assert!(pool.get_pool_tick_spacing() == tick_spacing, ETierMismatch);
    assert!((pool.get_pool_fee() as u64) == fee_rate, ETierMismatch);

    (tick_spacing, fee_rate)
}

fun full_range_ticks(tick_spacing: u32): (u32, bool, u32, bool) {
    assert!(tick_spacing > 0, EInvalidTickSpacing);

    let lower_tick = math_tick::get_min_tick(tick_spacing);
    let upper_tick = math_tick::get_max_tick(tick_spacing);

    (
        i32::abs_u32(lower_tick),
        i32::is_neg(lower_tick),
        i32::abs_u32(upper_tick),
        i32::is_neg(upper_tick),
    )
}

/// Re-encodes the venue's magnitude-and-sign tick as two's-complement bits so
/// `MigrationCompleted` carries one tick encoding across every venue.
fun tick_bits(magnitude: u32, is_neg: bool): u32 {
    if (is_neg && magnitude != 0) {
        ((1u64 << 32) - (magnitude as u64)) as u32
    } else {
        magnitude
    }
}

fun assert_positive_liquidity(
    position: &TurbosPositionNFT,
    positions: &Positions,
) {
    let (_, _, liquidity) = position_manager::get_position_info(
        positions,
        object::id(position).to_address(),
    );
    assert!(liquidity > 0, EZeroPositionLiquidity);
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

fun lock_and_share<Meme, Quote>(
    runtime_config: &RuntimeConfig,
    venue: Venue,
    launch_id: ID,
    position: TurbosPositionNFT,
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
    let pool_id = position.pool_id();
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

    let vault_id = vault::new<Meme, Quote, Venue, TurbosPositionNFT>(
        venue,
        pool_id,
        position,
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
        protocol_treasury,
        sqrt_price_x64,
        lower_tick_bits,
        upper_tick_bits,
        tick_spacing,
        fee_rate,
    );
}

fun collect_position_fees<X, Y, Meme, Quote, FeeType>(
    self: &mut LpVault<Meme, Quote>,
    venue: &Venue,
    runtime_config: &RuntimeConfig,
    pool: &mut Pool<X, Y, FeeType>,
    positions: &mut Positions,
    deadline: u64,
    clock: &Clock,
    versioned: &Versioned,
    ctx: &mut TxContext,
): (ID, Coin<X>, Coin<Y>, u128, u128) {
    let pool_id = object::id(pool);
    assert!(self.pool_id() == pool_id, EPositionPoolMismatch);

    let position = self.borrow_position_mut<
        Meme,
        Quote,
        Venue,
        TurbosPositionNFT,
    >(venue);
    let position_id = object::id(position);
    assert!(position.pool_id() == pool_id, EPositionPoolMismatch);
    let (_, _, liquidity_before) = position_manager::get_position_info(
        positions,
        position_id.to_address(),
    );
    assert!(liquidity_before > 0, EZeroPositionLiquidity);

    let (fee_a, fee_b) = position_manager::collect_with_return_<X, Y, FeeType>(
        pool,
        positions,
        position,
        std::u64::max_value!(),
        std::u64::max_value!(),
        // The pinned interface implies return-only semantics; if the venue
        // ever paid this recipient, value would reach the protocol treasury
        // rather than the permissionless collector.
        runtime_config.protocol_treasury(),
        deadline,
        clock,
        versioned,
        ctx,
    );

    assert!(position.pool_id() == pool_id, EPositionPoolMismatch);
    let (_, _, liquidity_after) = position_manager::get_position_info(
        positions,
        position_id.to_address(),
    );
    assert!(liquidity_after == liquidity_before, EPositionLiquidityChanged);
    assert!(self.pool_id() == pool_id, EPositionPoolMismatch);

    (position_id, fee_a, fee_b, liquidity_before, liquidity_after)
}

// === Test-Only Functions ===

#[test_only]
public fun tick_bits_for_testing(magnitude: u32, is_neg: bool): u32 {
    tick_bits(magnitude, is_neg)
}
