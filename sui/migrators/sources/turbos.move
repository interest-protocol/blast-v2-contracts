/// Turbos migration with custodied concentrated-liquidity principal.
///
/// Turbos pools are keyed by their exact `(CoinA, CoinB, FeeType)` order and
/// the venue registers no canonical pair order, so both type orders are real
/// routes. The admin-pinned tier makes the venue fee object deterministic.
module blast_fun_migrators::turbos;

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

use fun position_manager::get_position_info as Positions.position_info;
use fun position_manager::collect_with_return_ as Pool.collect_with_return_;
use fun position_manager::mint_with_return_ as Pool.mint_with_return_;

// === Constants ===

/// Turbos must use at least 99.99% of both migration balances.
const MAX_RESIDUAL_BPS: u64 = 1;

/// The highest registered Turbos `Fee` tier object — `FEE40000BPS`, spacing
/// 800 at a 4% fee (1e6 denominator) — enumerated from live mainnet
/// `turbos_clmm::fee::Fee` objects on 2026-08-30. Meme pools take the venue's
/// highest tier.
const DEFAULT_TICK_SPACING: u32 = 800;
const DEFAULT_FEE_RATE: u64 = 40_000;

/// Coarse adoption gate; the residual rule below binds far tighter.
const MAX_PRICE_DEVIATION_BPS: u64 = 50;

// === Errors ===

#[error(code = 0)]
const EInvalidTickSpacing: vector<u8> = b"Selected Turbos tier must have positive tick spacing.";
#[error(code = 1)]
const EPositionPoolMismatch: vector<u8> = b"Pool, vault, and position identifiers must match.";
#[error(code = 2)]
const EZeroPositionLiquidity: vector<u8> = b"Position principal liquidity must be greater than zero.";
#[error(code = 3)]
const EPositionLiquidityChanged: vector<u8> = b"Fee collection must not change position principal liquidity.";
// Code 4 was retired before publication and must not be reused.
#[error(code = 5)]
const ETierMismatch: vector<u8> = b"Turbos fee object or adopted pool must match the effective tier.";
#[error(code = 6)]
const EInvalidFeeRate: vector<u8> = b"Turbos fee rate must fit the venue's u32 width.";

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
    let (tick_spacing, fee_rate) = checked_fee_tier(venue_config, fee);
    let (lower_magnitude, lower_is_neg, upper_magnitude, upper_is_neg) =
        full_range_ticks(tick_spacing);
    let lower_tick_bits = tick_bits(lower_magnitude, lower_is_neg);
    let upper_tick_bits = tick_bits(upper_magnitude, upper_is_neg);
    let launch_id = object::id(launch);

    let payload = launch.migrate<_, _, Witness>(
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

    lock_and_share<Meme, Quote>(
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
    let (tick_spacing, fee_rate) = checked_fee_tier(venue_config, fee);
    let (lower_magnitude, lower_is_neg, upper_magnitude, upper_is_neg) =
        full_range_ticks(tick_spacing);
    let lower_tick_bits = tick_bits(lower_magnitude, lower_is_neg);
    let upper_tick_bits = tick_bits(upper_magnitude, upper_is_neg);
    let launch_id = object::id(launch);

    let payload = launch.migrate<_, _, Witness>(
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

    lock_and_share<Meme, Quote>(
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
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    pool: &mut Pool<Meme, Quote, FeeType>,
    positions: &mut Positions,
    deadline: u64,
    clock: &Clock,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    let (tick_spacing, fee_rate) = checked_pool_tier(venue_config, pool);
    let (lower_magnitude, lower_is_neg, upper_magnitude, upper_is_neg) =
        full_range_ticks(tick_spacing);
    let lower_tick_bits = tick_bits(lower_magnitude, lower_is_neg);
    let upper_tick_bits = tick_bits(upper_magnitude, upper_is_neg);
    let launch_id = object::id(launch);

    let payload = launch.migrate<_, _, Witness>(
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
        pool.mint_with_return_<Meme, Quote, FeeType>(
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

    lock_and_share<Meme, Quote>(
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
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    pool: &mut Pool<Quote, Meme, FeeType>,
    positions: &mut Positions,
    deadline: u64,
    clock: &Clock,
    versioned: &Versioned,
    ctx: &mut TxContext,
) {
    let (tick_spacing, fee_rate) = checked_pool_tier(venue_config, pool);
    let (lower_magnitude, lower_is_neg, upper_magnitude, upper_is_neg) =
        full_range_ticks(tick_spacing);
    let lower_tick_bits = tick_bits(lower_magnitude, lower_is_neg);
    let upper_tick_bits = tick_bits(upper_magnitude, upper_is_neg);
    let launch_id = object::id(launch);

    let payload = launch.migrate<_, _, Witness>(
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
        pool.mint_with_return_<Quote, Meme, FeeType>(
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

    lock_and_share<Meme, Quote>(
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
    let (position_id, meme_fee, quote_fee, liquidity_after) =
        collect_position_fees<Meme, Quote, Meme, Quote, FeeType>(
            self,
            &venue,
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
    let (position_id, quote_fee, meme_fee, liquidity_after) =
        collect_position_fees<Quote, Meme, Meme, Quote, FeeType>(
            self,
            &venue,
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
        liquidity_after,
        runtime_config,
        ctx,
    );
}

/// Pins the Turbos tier under a live core admin witness, replacing the default.
///
/// The fee is bounded to `u32` because the venue's `Fee` objects carry a
/// `u32`; a larger pin could never match any tier.
public fun set_tier(
    venue_config: &mut VenueConfig,
    _: &AdminWitness,
    tick_spacing: u32,
    fee_rate: u64,
) {
    assert!(fee_rate <= (std::u32::max_value!() as u64), EInvalidFeeRate);

    venue_config.set_tier(Venue(), tick_spacing, fee_rate);
}

// === Private Functions ===

fun effective_tier(venue_config: &VenueConfig): (u32, u64) {
    if (venue_config.has_tier<Venue>()) {
        venue_config.tier<Venue>()
    } else {
        (DEFAULT_TICK_SPACING, DEFAULT_FEE_RATE)
    }
}

fun checked_fee_tier<FeeType>(
    venue_config: &VenueConfig,
    fee: &Fee<FeeType>,
): (u32, u64) {
    let (tick_spacing, fee_rate) = effective_tier(venue_config);
    assert!(fee.get_tick_spacing() == tick_spacing, ETierMismatch);
    assert!((fee.get_fee() as u64) == fee_rate, ETierMismatch);

    (tick_spacing, fee_rate)
}

fun checked_pool_tier<CoinA, CoinB, FeeType>(
    venue_config: &VenueConfig,
    pool: &Pool<CoinA, CoinB, FeeType>,
): (u32, u64) {
    let (tick_spacing, fee_rate) = effective_tier(venue_config);
    assert!(pool.get_pool_tick_spacing() == tick_spacing, ETierMismatch);
    assert!((pool.get_pool_fee() as u64) == fee_rate, ETierMismatch);

    (tick_spacing, fee_rate)
}

fun full_range_ticks(tick_spacing: u32): (u32, bool, u32, bool) {
    assert!(tick_spacing > 0, EInvalidTickSpacing);

    let lower_tick = math_tick::get_min_tick(tick_spacing);
    let upper_tick = math_tick::get_max_tick(tick_spacing);

    (
        lower_tick.abs_u32(),
        lower_tick.is_neg(),
        upper_tick.abs_u32(),
        upper_tick.is_neg(),
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
    let (_, _, liquidity) = positions.position_info(object::id(position).to_address());
    assert!(liquidity > 0, EZeroPositionLiquidity);
}

fun lock_and_share<Meme, Quote>(
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

    let vault_id = vault::new<Meme, Quote, Venue, TurbosPositionNFT>(
        Venue(),
        pool_id,
        position,
        residual_meme.into_balance(),
        residual_quote.into_balance(),
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

fun collect_position_fees<X, Y, Meme, Quote, FeeType>(
    self: &mut LpVault<Meme, Quote>,
    venue: &Venue,
    pool: &mut Pool<X, Y, FeeType>,
    positions: &mut Positions,
    deadline: u64,
    clock: &Clock,
    versioned: &Versioned,
    ctx: &mut TxContext,
): (ID, Coin<X>, Coin<Y>, u128) {
    let pool_id = object::id(pool);
    assert!(self.pool_id() == pool_id, EPositionPoolMismatch);
    let vault_address = object::id(self).to_address();

    let position = self.position_mut<
        _,
        _,
        _,
        TurbosPositionNFT,
    >(venue);
    let position_id = object::id(position);
    assert!(position.pool_id() == pool_id, EPositionPoolMismatch);
    let (_, _, liquidity_before) = positions.position_info(position_id.to_address());
    assert!(liquidity_before > 0, EZeroPositionLiquidity);

    let (fee_a, fee_b) = pool.collect_with_return_<X, Y, FeeType>(
        positions,
        position,
        std::u64::max_value!(),
        std::u64::max_value!(),
        // The pinned interface returns both fee coins and uses this recipient
        // only for attribution in its collection event.
        vault_address,
        deadline,
        clock,
        versioned,
        ctx,
    );

    assert!(position.pool_id() == pool_id, EPositionPoolMismatch);
    let (_, _, liquidity_after) = positions.position_info(position_id.to_address());
    assert!(liquidity_after == liquidity_before, EPositionLiquidityChanged);
    assert!(self.pool_id() == pool_id, EPositionPoolMismatch);

    (position_id, fee_a, fee_b, liquidity_after)
}

// === Test-Only Functions ===

#[test_only]
public fun tick_bits_for_testing(magnitude: u32, is_neg: bool): u32 {
    tick_bits(magnitude, is_neg)
}

#[test_only]
public fun effective_tier_for_testing(venue_config: &VenueConfig): (u32, u64) {
    effective_tier(venue_config)
}
