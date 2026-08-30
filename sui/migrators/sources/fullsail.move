/// Full Sail migration with custodied concentrated-liquidity principal.
module blast_fun_migrators::fullsail;

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
use clmm_pool::{
    config::{Self, GlobalConfig},
    factory::{Self, Pools},
    pool::{Self, Pool},
    position::Position,
    rewarder::RewarderGlobalVault,
    tick_math,
};
use fullsail_integer_mate::i32;
use std::type_name;
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, coin_registry::Currency};


// === Constants ===

/// Full Sail must use at least 99.99% of both migration balances.
const MAX_RESIDUAL_BPS: u64 = 1;

/// The highest of Full Sail's five registered fee tiers — spacing 20 at a 1%
/// base fee (1e6 denominator) — read from the live mainnet `GlobalConfig`
/// fee-tier registry on 2026-08-30. Meme pools take the venue's highest tier.
/// The pinned fee is the registered base only: Full Sail adjusts pool fees
/// dynamically, so adopted pools match on tick spacing alone.
const DEFAULT_TICK_SPACING: u32 = 20;
const DEFAULT_FEE_RATE: u64 = 10_000;

/// Coarse adoption gate; the residual rule below binds far tighter.
const MAX_PRICE_DEVIATION_BPS: u64 = 50;

const EInvalidCoinOrder: u64 = 0;
const EInvalidTickSpacing: u64 = 1;
const EPositionPoolMismatch: u64 = 2;
const EZeroPositionLiquidity: u64 = 3;
const EPositionLiquidityChanged: u64 = 4;
const EPaymentExceedsBalance: u64 = 5;
const EInsufficientUtilization: u64 = 6;
const ETierMismatch: u64 = 7;
const EMemeBelowQuote: u64 = 8;

// === Public Structs ===

/// Sealed adapter identity selected by a Blast launch.
public struct Witness() has drop;

/// Sealed marker for the Full Sail position attached to the common vault.
public struct Venue() has drop;

// === Public Functions ===

/// Creates a Full Sail pool when Meme is canonical coin A.
public fun migrate_new_meme_a<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    fullsail_config: &GlobalConfig,
    rewarder_vault: &mut RewarderGlobalVault,
    pools: &mut Pools,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_canonical_order<Meme, Quote>(true);
    let (tick_spacing, pinned_fee_rate) = effective_tier(venue_config);
    let fee_rate = config::get_fee_rate(tick_spacing, fullsail_config);
    assert!(fee_rate == pinned_fee_rate, ETierMismatch);
    let (lower_tick_bits, upper_tick_bits) = full_range_ticks(tick_spacing);
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
        factory::create_pool_with_liquidity<Meme, Quote>(
            pools,
            fullsail_config,
            rewarder_vault,
            tick_spacing,
            sqrt_price_x64,
            b"".to_string(),
            lower_tick_bits,
            upper_tick_bits,
            meme.into_coin(ctx),
            quote.into_coin(ctx),
            source_meme_amount,
            source_quote_amount,
            true,
            @0x0,
            @0x0,
            false,
            clock,
            ctx,
        );

    lock_and_share<Meme, Quote>(
        runtime_config,
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

/// Creates a Full Sail pool when Meme is canonical coin B.
public fun migrate_new_meme_b<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    fullsail_config: &GlobalConfig,
    rewarder_vault: &mut RewarderGlobalVault,
    pools: &mut Pools,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_canonical_order<Meme, Quote>(false);
    let (tick_spacing, pinned_fee_rate) = effective_tier(venue_config);
    let fee_rate = config::get_fee_rate(tick_spacing, fullsail_config);
    assert!(fee_rate == pinned_fee_rate, ETierMismatch);
    let (lower_tick_bits, upper_tick_bits) = full_range_ticks(tick_spacing);
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
        factory::create_pool_with_liquidity<Quote, Meme>(
            pools,
            fullsail_config,
            rewarder_vault,
            tick_spacing,
            sqrt_price_x64,
            b"".to_string(),
            lower_tick_bits,
            upper_tick_bits,
            quote.into_coin(ctx),
            meme.into_coin(ctx),
            source_quote_amount,
            source_meme_amount,
            false,
            @0x0,
            @0x0,
            false,
            clock,
            ctx,
        );

    lock_and_share<Meme, Quote>(
        runtime_config,
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

/// Adds locked full-range liquidity to an adopted Full Sail pool with Meme as coin A.
public fun migrate_existing_meme_a<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    fullsail_config: &GlobalConfig,
    rewarder_vault: &mut RewarderGlobalVault,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_canonical_order<Meme, Quote>(true);
    let tick_spacing = pool.tick_spacing();
    let fee_rate = pool.fee_rate();
    assert_adopted_tier(venue_config, tick_spacing);
    let (lower_tick_bits, upper_tick_bits) = full_range_ticks(tick_spacing);
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
        fullsail_config,
        pool,
        lower_tick_bits,
        upper_tick_bits,
        ctx,
    );
    let receipt = pool::add_liquidity_fix_coin<Meme, Quote>(
        fullsail_config,
        rewarder_vault,
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
        fullsail_config,
        pool,
        paid_meme,
        paid_quote,
        receipt,
    );
    assert!(position.pool_id() == object::id(pool), EPositionPoolMismatch);

    lock_and_share<Meme, Quote>(
        runtime_config,
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

/// Adds locked full-range liquidity to an adopted Full Sail pool with Meme as coin B.
public fun migrate_existing_meme_b<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    venue_config: &VenueConfig,
    meme_currency: &mut Currency<Meme>,
    fullsail_config: &GlobalConfig,
    rewarder_vault: &mut RewarderGlobalVault,
    pool: &mut Pool<Quote, Meme>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_canonical_order<Meme, Quote>(false);
    let tick_spacing = pool.tick_spacing();
    let fee_rate = pool.fee_rate();
    assert_adopted_tier(venue_config, tick_spacing);
    let (lower_tick_bits, upper_tick_bits) = full_range_ticks(tick_spacing);
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
        fullsail_config,
        pool,
        lower_tick_bits,
        upper_tick_bits,
        ctx,
    );
    let receipt = pool::add_liquidity_fix_coin<Quote, Meme>(
        fullsail_config,
        rewarder_vault,
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
        fullsail_config,
        pool,
        paid_quote,
        paid_meme,
        receipt,
    );
    assert!(position.pool_id() == object::id(pool), EPositionPoolMismatch);

    lock_and_share<Meme, Quote>(
        runtime_config,
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
    fullsail_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    ctx: &mut TxContext,
) {
    let venue = Venue();
    let (position_id, meme_fee, quote_fee, liquidity_before, liquidity_after) =
        collect_position_fees<Meme, Quote, Meme, Quote>(
            self,
            &venue,
            fullsail_config,
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
    fullsail_config: &GlobalConfig,
    pool: &mut Pool<Quote, Meme>,
    ctx: &mut TxContext,
) {
    let venue = Venue();
    let (position_id, quote_fee, meme_fee, liquidity_before, liquidity_after) =
        collect_position_fees<Quote, Meme, Meme, Quote>(
            self,
            &venue,
            fullsail_config,
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

/// Pins the Full Sail tier under a live core admin witness, replacing the default.
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
    let meme_a_order = is_type_name_greater<Meme, Quote>();
    let meme_b_order = is_type_name_greater<Quote, Meme>();
    assert!(meme_a_order != meme_b_order, EInvalidCoinOrder);
    assert!(meme_a_order == meme_is_a, EInvalidCoinOrder);
}

/// Replicates `clmm_pool::factory::new_pool_key`, which orders coin types with
/// deprecated `type_name::get`. That helper returns defining IDs, so the guard
/// must compare defining IDs to agree with the pinned venue bytecode.
fun is_type_name_greater<A, B>(): bool {
    let a_name = type_name::with_defining_ids<A>().into_string();
    let b_name = type_name::with_defining_ids<B>().into_string();
    let a_bytes = a_name.as_bytes();
    let b_bytes = b_name.as_bytes();
    let a_length = a_bytes.length();
    let b_length = b_bytes.length();
    let limit = if (a_length < b_length) a_length else b_length;
    let mut index = 0;
    while (index < limit) {
        let a_byte = a_bytes[index];
        let b_byte = b_bytes[index];
        if (a_byte > b_byte) return true;
        if (a_byte < b_byte) return false;
        index = index + 1;
    };

    a_length > b_length
}

/// Full Sail adjusts a live pool's fee dynamically, so an adopted pool can
/// never be bound to the registered base fee; only its tick spacing is pinned.
fun assert_adopted_tier(venue_config: &VenueConfig, tick_spacing: u32) {
    let (pinned_tick_spacing, _) = effective_tier(venue_config);
    assert!(tick_spacing == pinned_tick_spacing, ETierMismatch);
}

fun effective_tier(venue_config: &VenueConfig): (u32, u64) {
    if (venue_config.has_tier_override<Venue>()) {
        venue_config.tier_override<Venue>()
    } else {
        (DEFAULT_TICK_SPACING, DEFAULT_FEE_RATE)
    }
}

/// Aligns the venue tick bounds by truncating their magnitudes toward zero,
/// which keeps the aligned bounds inside the venue range, then re-encodes the
/// negative lower bound as two's-complement bits.
fun full_range_ticks(tick_spacing: u32): (u32, u32) {
    assert!(tick_spacing > 0, EInvalidTickSpacing);

    let lower_magnitude = tick_math::min_tick().abs_u32();
    let upper_magnitude = tick_math::max_tick().as_u32();
    let lower_aligned = lower_magnitude / tick_spacing * tick_spacing;
    let upper_aligned = upper_magnitude / tick_spacing * tick_spacing;

    (i32::neg_from(lower_aligned).as_u32(), upper_aligned)
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
    let protocol_treasury = runtime_config.protocol_treasury();
    transfer_residual(residual_meme, protocol_treasury);
    transfer_residual(residual_quote, protocol_treasury);

    let vault_id = vault::new<Meme, Quote, Venue, Position>(
        Venue(),
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

fun collect_position_fees<X, Y, Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    venue: &Venue,
    fullsail_config: &GlobalConfig,
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
        fullsail_config,
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
public fun is_type_name_greater_for_testing<A, B>(): bool {
    is_type_name_greater<A, B>()
}

#[test_only]
public fun effective_tier_for_testing(venue_config: &VenueConfig): (u32, u64) {
    effective_tier(venue_config)
}
