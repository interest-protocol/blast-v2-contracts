/// Cetus migration with custodied concentrated-liquidity principal.
module blast_fun_migrators::cetus;

use blast_fun::{
    launch::Launch,
    migration_math,
    package_version::PackageVersion,
    runtime_config::RuntimeConfig,
};
use blast_fun_migrators::{events, vault::{Self, LpVault}};
use cetus_clmm::{
    config::{Self, GlobalConfig},
    factory::{Self, Pools},
    pool::{Self, Pool},
    pool_creator,
    position::{Self, Position},
};
use std::string;
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, coin_registry::Currency};

// === Constants ===

/// Cetus must use at least 99.99% of both migration balances.
const MAX_RESIDUAL_BPS: u64 = 1;
const MAX_PRICE_DEVIATION_BPS: u64 = 50;

const EInvalidCoinOrder: u64 = 0;
const EPositionPoolMismatch: u64 = 1;
const EZeroPositionLiquidity: u64 = 2;
const EPositionLiquidityChanged: u64 = 3;
const EPaymentExceedsBalance: u64 = 4;
const EInsufficientUtilization: u64 = 5;

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
    runtime_config: &RuntimeConfig,
    meme_currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    tick_spacing: u32,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_canonical_order<Meme, Quote>(true);
    let _pool_key = factory::new_pool_key<Meme, Quote>(tick_spacing);
    let fee_rate = fee_rate(cetus_config, tick_spacing);
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
    let sqrt_price_x64 = migration_math::sqrt_price_x64(
        source_meme_amount,
        source_quote_amount,
        true,
    );
    let (position, residual_meme, residual_quote) =
        pool_creator::create_pool_v3<Meme, Quote>(
            cetus_config,
            pools,
            tick_spacing,
            sqrt_price_x64,
            string::utf8(b""),
            lower_tick_bits,
            upper_tick_bits,
            meme.into_coin(ctx),
            quote.into_coin(ctx),
            true,
            clock,
            ctx,
        );

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

/// Creates an unpermissioned Cetus pool when Meme is canonical coin B.
public fun migrate_new_meme_b<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    meme_currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    tick_spacing: u32,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_canonical_order<Meme, Quote>(false);
    let _pool_key = factory::new_pool_key<Quote, Meme>(tick_spacing);
    let fee_rate = fee_rate(cetus_config, tick_spacing);
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
    let sqrt_price_x64 = migration_math::sqrt_price_x64(
        source_meme_amount,
        source_quote_amount,
        false,
    );
    let (position, residual_quote, residual_meme) =
        pool_creator::create_pool_v3<Quote, Meme>(
            cetus_config,
            pools,
            tick_spacing,
            sqrt_price_x64,
            string::utf8(b""),
            lower_tick_bits,
            upper_tick_bits,
            quote.into_coin(ctx),
            meme.into_coin(ctx),
            true,
            clock,
            ctx,
        );

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

/// Adds locked full-range liquidity to an adopted Cetus pool with Meme as coin A.
public fun migrate_existing_meme_a<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    meme_currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_canonical_order<Meme, Quote>(true);
    let tick_spacing = pool::tick_spacing(pool);
    let fee_rate = pool::fee_rate(pool);
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
    migration_math::assert_price_within_bps(
        source_meme_amount,
        source_quote_amount,
        true,
        pool::current_sqrt_price(pool),
        MAX_PRICE_DEVIATION_BPS,
    );

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
        source_meme_amount,
        true,
        clock,
    );
    let (paid_meme, paid_quote) = pool::add_liquidity_pay_amount(&receipt);
    assert_payment_amounts(
        source_meme_amount,
        source_quote_amount,
        paid_meme,
        paid_quote,
    );
    let paid_meme = balance::split(&mut meme, paid_meme);
    let paid_quote = balance::split(&mut quote, paid_quote);
    pool::repay_add_liquidity<Meme, Quote>(
        cetus_config,
        pool,
        paid_meme,
        paid_quote,
        receipt,
    );
    assert!(position::pool_id(&position) == object::id(pool), EPositionPoolMismatch);

    let venue = Venue();
    lock_and_share<Meme, Quote>(
        runtime_config,
        venue,
        launch_id,
        position,
        meme.into_coin(ctx),
        quote.into_coin(ctx),
        source_meme_amount,
        source_quote_amount,
        migration_math::sqrt_price_x64(
            source_meme_amount,
            source_quote_amount,
            true,
        ),
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
    runtime_config: &RuntimeConfig,
    meme_currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<Quote, Meme>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_canonical_order<Meme, Quote>(false);
    let tick_spacing = pool::tick_spacing(pool);
    let fee_rate = pool::fee_rate(pool);
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
    migration_math::assert_price_within_bps(
        source_meme_amount,
        source_quote_amount,
        false,
        pool::current_sqrt_price(pool),
        MAX_PRICE_DEVIATION_BPS,
    );

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
        source_quote_amount,
        true,
        clock,
    );
    let (paid_quote, paid_meme) = pool::add_liquidity_pay_amount(&receipt);
    assert_payment_amounts(
        source_meme_amount,
        source_quote_amount,
        paid_meme,
        paid_quote,
    );
    let paid_quote = balance::split(&mut quote, paid_quote);
    let paid_meme = balance::split(&mut meme, paid_meme);
    pool::repay_add_liquidity<Quote, Meme>(
        cetus_config,
        pool,
        paid_quote,
        paid_meme,
        receipt,
    );
    assert!(position::pool_id(&position) == object::id(pool), EPositionPoolMismatch);

    let venue = Venue();
    lock_and_share<Meme, Quote>(
        runtime_config,
        venue,
        launch_id,
        position,
        meme.into_coin(ctx),
        quote.into_coin(ctx),
        source_meme_amount,
        source_quote_amount,
        migration_math::sqrt_price_x64(
            source_meme_amount,
            source_quote_amount,
            false,
        ),
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
    vault::accrue_fees<Meme, Quote, Venue>(
        self,
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
    vault::accrue_fees<Meme, Quote, Venue>(
        self,
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

// === Private Functions ===

fun assert_canonical_order<Meme, Quote>(meme_is_a: bool) {
    let meme_a_order = factory::is_right_order<Meme, Quote>();
    let meme_b_order = factory::is_right_order<Quote, Meme>();
    assert!(meme_a_order != meme_b_order, EInvalidCoinOrder);
    assert!(meme_a_order == meme_is_a, EInvalidCoinOrder);
}

fun fee_rate(config: &GlobalConfig, tick_spacing: u32): u64 {
    config::get_fee_rate(tick_spacing, config)
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
    runtime_config: &RuntimeConfig,
    venue: Venue,
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
    let pool_id = position::pool_id(&position);
    assert!(position::liquidity(&position) > 0, EZeroPositionLiquidity);
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
    assert!(
        used_meme_amount >= migration_math::minimum_utilized_amount(
            source_meme_amount,
            MAX_RESIDUAL_BPS,
        ),
        EInsufficientUtilization,
    );
    assert!(
        used_quote_amount >= migration_math::minimum_utilized_amount(
            source_quote_amount,
            MAX_RESIDUAL_BPS,
        ),
        EInsufficientUtilization,
    );
    let protocol_treasury = runtime_config.protocol_treasury();
    transfer::public_transfer(residual_meme, protocol_treasury);
    transfer::public_transfer(residual_quote, protocol_treasury);
    let vault_id = vault::new<Meme, Quote, Venue, Position>(
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

fun collect_position_fees<X, Y, Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    venue: &Venue,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<X, Y>,
): (ID, Balance<X>, Balance<Y>, u128, u128) {
    let pool_id = object::id(pool);
    assert!(vault::pool_id(self) == pool_id, EPositionPoolMismatch);
    let position = vault::borrow_position_mut<Meme, Quote, Venue, Position>(
        self,
        venue,
    );
    let position_id = object::id(position);
    assert!(position::pool_id(position) == pool_id, EPositionPoolMismatch);
    let liquidity_before = position::liquidity(position);
    assert!(liquidity_before > 0, EZeroPositionLiquidity);
    let (fee_a, fee_b) = pool::collect_fee(
        cetus_config,
        pool,
        position,
        true,
    );
    assert!(position::pool_id(position) == pool_id, EPositionPoolMismatch);
    let liquidity_after = position::liquidity(position);
    assert!(liquidity_after == liquidity_before, EPositionLiquidityChanged);
    assert!(vault::pool_id(self) == pool_id, EPositionPoolMismatch);
    (position_id, fee_a, fee_b, liquidity_before, liquidity_after)
}
