/// Cetus migration with custodied concentrated-liquidity principal.
module blast_fun_migrators::cetus;

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
use cetus_clmm::{
    config::{Self, GlobalConfig},
    factory::{Self, Pools},
    pool::{Self, Pool},
    pool_creator,
    position::Position,
};
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, coin_registry::Currency};

// === Constants ===

/// Cetus must use at least 99.99% of both migration balances.
const MAX_RESIDUAL_BPS: u64 = 1;

/// The highest of Cetus's sixteen registered fee tiers — spacing 260 at a 4%
/// fee (1e6 denominator) — read from the live mainnet `GlobalConfig` fee-tier
/// registry on 2026-08-30. Meme pools take the venue's highest tier.
const DEFAULT_TICK_SPACING: u32 = 260;
const DEFAULT_FEE_RATE: u64 = 40_000;

/// Coarse adoption gate; the residual rule below binds far tighter.
const MAX_PRICE_DEVIATION_BPS: u64 = 50;

#[error(code = 0)]
const EInvalidCoinOrder: vector<u8> = b"Meme and Quote types do not match the selected Cetus pool order.";
#[error(code = 1)]
const EPositionPoolMismatch: vector<u8> = b"Cetus position does not belong to the selected pool.";
#[error(code = 2)]
const EZeroPositionLiquidity: vector<u8> = b"Cetus position liquidity must be greater than zero.";
#[error(code = 3)]
const EPositionLiquidityChanged: vector<u8> = b"Cetus fee collection must not change position liquidity.";
#[error(code = 4)]
const EPaymentExceedsBalance: vector<u8> = b"Cetus payment exceeds the available migration balance.";
#[error(code = 5)]
const EInsufficientUtilization: vector<u8> = b"Cetus migration did not use enough of the supplied balances.";
#[error(code = 6)]
const ETierMismatch: vector<u8> = b"Cetus pool tier does not match the configured venue tier.";
#[error(code = 7)]
const EMemeBelowQuote: vector<u8> = b"Migration Meme balance must be at least the Quote balance.";

// === Public Structs ===

/// Sealed adapter identity selected by a Blast launch.
public struct Witness() has drop;

/// Sealed marker for the Cetus position attached to the common vault.
public struct Venue() has drop;

// === Public Functions ===

/// Creates an unpermissioned Cetus pool when Meme is canonical coin A.
public fun migrate_new_meme_a<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_canonical_order<Meme, Quote>(true);
    let (tick_spacing, pinned_fee_rate) = effective_tier(venue_config);
    // The key value is unused; the call aborts when the pair and spacing
    // cannot form a canonical Cetus pool key.
    let _ = factory::new_pool_key<Meme, Quote>(tick_spacing);
    let fee_rate = config::get_fee_rate(tick_spacing, cetus_config);
    assert!(fee_rate == pinned_fee_rate, ETierMismatch);
    let (lower_tick_bits, upper_tick_bits) =
        pool_creator::full_range_tick_range(tick_spacing);
    let launch_id = object::id(launch);

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

    // Meme is the fixed side: at the derived opening price a full-range seed
    // leaves its rounding residual on the Quote requirement.
    let (position, residual_meme, residual_quote) =
        pool_creator::create_pool_v3<Meme, Quote>(
            cetus_config,
            pools,
            tick_spacing,
            sqrt_price_x64,
            b"".to_string(),
            lower_tick_bits,
            upper_tick_bits,
            meme.into_coin(ctx),
            quote.into_coin(ctx),
            true,
            clock,
            ctx,
        );

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

/// Creates an unpermissioned Cetus pool when Meme is canonical coin B.
public fun migrate_new_meme_b<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_canonical_order<Meme, Quote>(false);
    let (tick_spacing, pinned_fee_rate) = effective_tier(venue_config);
    // The key value is unused; the call aborts when the pair and spacing
    // cannot form a canonical Cetus pool key.
    let _ = factory::new_pool_key<Quote, Meme>(tick_spacing);
    let fee_rate = config::get_fee_rate(tick_spacing, cetus_config);
    assert!(fee_rate == pinned_fee_rate, ETierMismatch);
    let (lower_tick_bits, upper_tick_bits) =
        pool_creator::full_range_tick_range(tick_spacing);
    let launch_id = object::id(launch);

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
        false,
    );

    // Meme is coin B here, so the fixed side flag is false: fixing Meme keeps
    // the rounding residual on the Quote requirement at the derived price.
    let (position, residual_quote, residual_meme) =
        pool_creator::create_pool_v3<Quote, Meme>(
            cetus_config,
            pools,
            tick_spacing,
            sqrt_price_x64,
            b"".to_string(),
            lower_tick_bits,
            upper_tick_bits,
            quote.into_coin(ctx),
            meme.into_coin(ctx),
            false,
            clock,
            ctx,
        );

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

/// Adds locked full-range liquidity to an adopted Cetus pool with Meme as coin A.
public fun migrate_existing_meme_a<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_canonical_order<Meme, Quote>(true);
    let tick_spacing = pool.tick_spacing();
    let fee_rate = pool.fee_rate();
    assert_adopted_tier(venue_config, tick_spacing, fee_rate);
    let (lower_tick_bits, upper_tick_bits) =
        pool_creator::full_range_tick_range(tick_spacing);
    let launch_id = object::id(launch);

    let payload = launch.migrate<Meme, Quote, Witness>(
        package_version,
        meme_currency,
        ctx,
    );
    let (mut meme, mut quote) = payload.redeem_migration(Witness());
    let source_meme_amount = meme.value();
    let source_quote_amount = quote.value();
    let pool_sqrt_price = pool.current_sqrt_price();
    migration_math::assert_price_within_bps(
        source_meme_amount,
        source_quote_amount,
        true,
        pool_sqrt_price,
        MAX_PRICE_DEVIATION_BPS,
    );

    // Fix the side the adopted price leaves affordable: at or below the
    // derived price the Quote requirement shrinks, above it the Meme
    // requirement shrinks.
    let derived_sqrt_price = migration_math::sqrt_price_x64(
        source_meme_amount,
        source_quote_amount,
        true,
    );
    let fix_meme = pool_sqrt_price <= derived_sqrt_price;
    let (fixed_amount, fix_amount_a) = if (fix_meme) {
        (source_meme_amount, true)
    } else {
        (source_quote_amount, false)
    };

    let mut position = pool::open_position<Meme, Quote>(
        cetus_config,
        pool,
        lower_tick_bits,
        upper_tick_bits,
        ctx,
    );
    let receipt = pool::add_liquidity_fix_coin<Meme, Quote>(
        cetus_config,
        pool,
        &mut position,
        fixed_amount,
        fix_amount_a,
        clock,
    );
    let (paid_meme, paid_quote) = pool::add_liquidity_pay_amount(&receipt);
    assert_payment_amounts(
        source_meme_amount,
        source_quote_amount,
        paid_meme,
        paid_quote,
    );
    let paid_meme = meme.split(paid_meme);
    let paid_quote = quote.split(paid_quote);
    pool::repay_add_liquidity<Meme, Quote>(
        cetus_config,
        pool,
        paid_meme,
        paid_quote,
        receipt,
    );
    assert!(position.pool_id() == object::id(pool), EPositionPoolMismatch);

    lock_and_share<Meme, Quote>(
        launch_id,
        position,
        meme.into_coin(ctx),
        quote.into_coin(ctx),
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

/// Adds locked full-range liquidity to an adopted Cetus pool with Meme as coin B.
public fun migrate_existing_meme_b<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<Quote, Meme>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_canonical_order<Meme, Quote>(false);
    let tick_spacing = pool.tick_spacing();
    let fee_rate = pool.fee_rate();
    assert_adopted_tier(venue_config, tick_spacing, fee_rate);
    let (lower_tick_bits, upper_tick_bits) =
        pool_creator::full_range_tick_range(tick_spacing);
    let launch_id = object::id(launch);

    let payload = launch.migrate<Meme, Quote, Witness>(
        package_version,
        meme_currency,
        ctx,
    );
    let (mut meme, mut quote) = payload.redeem_migration(Witness());
    let source_meme_amount = meme.value();
    let source_quote_amount = quote.value();
    let pool_sqrt_price = pool.current_sqrt_price();
    migration_math::assert_price_within_bps(
        source_meme_amount,
        source_quote_amount,
        false,
        pool_sqrt_price,
        MAX_PRICE_DEVIATION_BPS,
    );

    // Meme is coin B here, so the affordable fixed side flips: at or above
    // the derived price the Quote requirement shrinks, below it the Meme
    // requirement shrinks.
    let derived_sqrt_price = migration_math::sqrt_price_x64(
        source_meme_amount,
        source_quote_amount,
        false,
    );
    let fix_meme = pool_sqrt_price >= derived_sqrt_price;
    let (fixed_amount, fix_amount_a) = if (fix_meme) {
        (source_meme_amount, false)
    } else {
        (source_quote_amount, true)
    };

    let mut position = pool::open_position<Quote, Meme>(
        cetus_config,
        pool,
        lower_tick_bits,
        upper_tick_bits,
        ctx,
    );
    let receipt = pool::add_liquidity_fix_coin<Quote, Meme>(
        cetus_config,
        pool,
        &mut position,
        fixed_amount,
        fix_amount_a,
        clock,
    );
    let (paid_quote, paid_meme) = pool::add_liquidity_pay_amount(&receipt);
    assert_payment_amounts(
        source_meme_amount,
        source_quote_amount,
        paid_meme,
        paid_quote,
    );
    let paid_quote = quote.split(paid_quote);
    let paid_meme = meme.split(paid_meme);
    pool::repay_add_liquidity<Quote, Meme>(
        cetus_config,
        pool,
        paid_quote,
        paid_meme,
        receipt,
    );
    assert!(position.pool_id() == object::id(pool), EPositionPoolMismatch);

    lock_and_share<Meme, Quote>(
        launch_id,
        position,
        meme.into_coin(ctx),
        quote.into_coin(ctx),
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
public fun collect_fees_meme_a<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    runtime_config: &RuntimeConfig,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    ctx: &mut TxContext,
) {
    let venue = Venue();
    let (position_id, meme_fee, quote_fee, liquidity_before, liquidity_after) =
        collect_position_fees<Meme, Quote, Meme, Quote>(
            self,
            &venue,
            cetus_config,
            pool,
        );

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

/// Collects normalized Meme-B and Quote-A fees without changing principal.
public fun collect_fees_meme_b<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    runtime_config: &RuntimeConfig,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<Quote, Meme>,
    ctx: &mut TxContext,
) {
    let venue = Venue();
    let (position_id, quote_fee, meme_fee, liquidity_before, liquidity_after) =
        collect_position_fees<Quote, Meme, Meme, Quote>(
            self,
            &venue,
            cetus_config,
            pool,
        );

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

/// Pins the Cetus tier under a live core admin witness, replacing the default.
public fun set_tier(
    venue_config: &mut VenueConfig,
    _: &AdminWitness,
    tick_spacing: u32,
    fee_rate: u64,
) {
    venue_config.set_tier(Venue(), tick_spacing, fee_rate);
}

// === Private Functions ===

fun assert_canonical_order<Meme, Quote>(meme_is_a: bool) {
    let meme_a_order = factory::is_right_order<Meme, Quote>();
    let meme_b_order = factory::is_right_order<Quote, Meme>();
    assert!(meme_a_order != meme_b_order, EInvalidCoinOrder);
    assert!(meme_a_order == meme_is_a, EInvalidCoinOrder);
}

fun assert_adopted_tier(
    venue_config: &VenueConfig,
    tick_spacing: u32,
    fee_rate: u64,
) {
    let (pinned_tick_spacing, pinned_fee_rate) = effective_tier(venue_config);
    assert!(tick_spacing == pinned_tick_spacing, ETierMismatch);
    assert!(fee_rate == pinned_fee_rate, ETierMismatch);
}

fun effective_tier(venue_config: &VenueConfig): (u32, u64) {
    if (venue_config.has_tier_override<Venue>()) {
        venue_config.tier_override<Venue>()
    } else {
        (DEFAULT_TICK_SPACING, DEFAULT_FEE_RATE)
    }
}

fun assert_payment_amounts(
    source_meme_amount: u64,
    source_quote_amount: u64,
    paid_meme: u64,
    paid_quote: u64,
) {
    assert!(paid_meme <= source_meme_amount, EPaymentExceedsBalance);
    assert!(paid_quote <= source_quote_amount, EPaymentExceedsBalance);
    assert!(
        paid_meme >= migration_math::minimum_utilized_amount(
            source_meme_amount,
            MAX_RESIDUAL_BPS,
        ),
        EInsufficientUtilization,
    );
    assert!(
        paid_quote >= migration_math::minimum_utilized_amount(
            source_quote_amount,
            MAX_RESIDUAL_BPS,
        ),
        EInsufficientUtilization,
    );
}

fun lock_and_share<Meme, Quote>(
    launch_id: ID,
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
    let pool_id = position.pool_id();
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

    let vault_id = vault::new<Meme, Quote, Venue, Position>(
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

fun collect_position_fees<X, Y, Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    venue: &Venue,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<X, Y>,
): (ID, Balance<X>, Balance<Y>, u128, u128) {
    let pool_id = object::id(pool);
    assert!(self.pool_id() == pool_id, EPositionPoolMismatch);

    let position =
        self.position_mut<Meme, Quote, Venue, Position>(venue);
    let position_id = object::id(position);
    assert!(position.pool_id() == pool_id, EPositionPoolMismatch);
    let liquidity_before = position.liquidity();
    assert!(liquidity_before > 0, EZeroPositionLiquidity);

    let (fee_a, fee_b) = pool::collect_fee(
        cetus_config,
        pool,
        position,
        true,
    );

    assert!(position.pool_id() == pool_id, EPositionPoolMismatch);
    let liquidity_after = position.liquidity();
    assert!(liquidity_after == liquidity_before, EPositionLiquidityChanged);
    assert!(self.pool_id() == pool_id, EPositionPoolMismatch);

    (position_id, fee_a, fee_b, liquidity_before, liquidity_after)
}

// === Test-Only Functions ===

#[test_only]
public fun effective_tier_for_testing(venue_config: &VenueConfig): (u32, u64) {
    effective_tier(venue_config)
}
