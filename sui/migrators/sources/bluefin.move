// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Bluefin launch start, migration, fee collection with auto-LP, settled fee-split updates, and
/// buybacks over custodied concentrated-liquidity principal.
///
/// Bluefin pools are keyed by their exact type-parameter order, so this module
/// always creates and expects `Pool<Meme, Quote>` with Meme as coin A.
module blast_fun_migrators::bluefin;

// === Errors ===

#[error(code = 0)]
const EPositionPoolMismatch: vector<u8> = b"Custodied position must belong to the supplied pool.";

#[error(code = 1)]
const EInvalidTier: vector<u8> = b"Bluefin tier needs a tick spacing in 1..=400 and a fee rate in 1..=20,000.";

// === Public Types ===

/// Sealed adapter identity selected by a Blast launch.
public struct Witness() has drop;

/// Sealed marker for the Bluefin position attached to the common vault.
public struct Venue() has drop;

// === Public Functions ===

/// Starts a Bluefin launch in `Quote` at the creator's tier; the core aborts unless it admits
/// Bluefin and the Quote.
///
/// Bluefin checks the tier only when migration creates the pool, and a launch cannot change its
/// tier, so the same bounds apply here first. The creator completes the returned initializer with
/// `launch::finalize`.
public fun new<Meme, Quote>(
    ticket: LaunchTicket<Meme>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    config: &LaunchConfig,
    tick_spacing: u32,
    fee_rate: u64,
): LaunchInitializer<Meme, Quote> {
    migrators_version.assert_current();
    assert!(
        tick_spacing > 0 && tick_spacing <= constants::bluefin_max_tick_spacing!() && fee_rate > 0
            && fee_rate <= constants::bluefin_max_fee_rate!(),
        EInvalidTier,
    );

    launch::new<Meme, Quote, _>(ticket, package_version, config, Witness(), tick_spacing, fee_rate)
}

/// Migrates a MigrationReady launch into a new full-range pool at the launch's tier.
///
/// The opening price derives from the handed-off balances. Meme is the fixed side when its atoms
/// are at least the Quote atoms, and Quote otherwise: a full-range seed fixed on the fewer atoms
/// can need slightly more of the other asset than was handed off. `creation_fee` is paid whole,
/// and Bluefin aborts unless it is exactly the configured SUI fee. The position and the venue
/// residuals stay in a shared vault with no withdrawal path. The caller receives no object;
/// Bluefin records it as the new pool's manager, a role limited to the pool's reward emissions
/// and to handing the role on (ADR 0088).
public fun migrate<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    currency: &mut Currency<Meme>,
    quote_currency: &Currency<Quote>,
    bluefin_config: &mut GlobalConfig,
    creation_fee: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let (tick_spacing, fee_rate) = launch.pool_tier();
    let (minimum_tick, maximum_tick) = bluefin_config.get_tick_range();
    let spacing = i32::from(tick_spacing);
    let lower_tick = minimum_tick.div(spacing).mul(spacing).as_u32();
    let upper_tick = maximum_tick.div(spacing).mul(spacing).as_u32();
    let mut pool_name = currency.symbol().into_bytes();
    pool_name.append(b"-");
    pool_name.append(quote_currency.symbol().into_bytes());

    let (meme, quote) = launch.migrate(package_version, currency, Witness(), ctx);
    let source_meme = meme.value();
    let source_quote = quote.value();
    let fix_meme = source_meme >= source_quote;

    let mut pool = pool::create_pool_and_get_object<Meme, Quote, SUI>(
        clock,
        bluefin_config,
        pool_name,
        // No Meme icon, as Cetus: the metadata capability can grow the icon URL, and the position
        // stores it, so a long URL would make the position too large to create.
        b"",
        currency.symbol().into_bytes(),
        currency.decimals(),
        b"",
        quote_currency.symbol().into_bytes(),
        quote_currency.decimals(),
        quote_currency.icon_url().into_bytes(),
        tick_spacing,
        fee_rate,
        migration_math::sqrt_price_x64(source_meme, source_quote, true),
        creation_fee.into_balance(),
        ctx,
    );
    let mut position = pool::open_position(bluefin_config, &mut pool, lower_tick, upper_tick, ctx);
    let (_, _, residual_meme, residual_quote) =
        pool::add_liquidity_with_fixed_amount(
            clock,
            bluefin_config,
            &mut pool,
            &mut position,
            meme,
            quote,
            if (fix_meme) source_meme else source_quote,
            fix_meme,
        );

    let liquidity = position.liquidity();
    vault::create(
        launch,
        &Venue(),
        position.pool_id(),
        position,
        liquidity,
        residual_meme,
        residual_quote,
        ctx,
    );
    pool.share_pool_object();
}

/// Collects the custodied position's fees, splits them, burns the burn share's Meme, and adds the
/// auto-LP share back to the position. Anyone may call it.
public fun collect_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    policy: &LpFeePolicy,
    currency: &mut Currency<Meme>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let (meme_fee, quote_fee) = self.collect_position_fees(bluefin_config, pool, clock);

    self.split_fees(policy, currency, meme_fee, quote_fee, ctx);
    self.compound(bluefin_config, pool, clock);
}

/// Settles the custodied position's accrued fees under the current split, then commits `proposed`.
public fun settle_and_update_fee_split<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    policy: &LpFeePolicy,
    launch: &Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
    currency: &mut Currency<Meme>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    proposed: FeeSplit,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    self.assert_fee_split_update(launch, curve_fee_cap, proposed);
    let (meme_fee, quote_fee) = self.collect_position_fees(bluefin_config, pool, clock);

    self.split_fees(policy, currency, meme_fee, quote_fee, ctx);
    self.compound(bluefin_config, pool, clock);
    self.update_fee_split(proposed);
}

/// Swaps the vault's burn Quote for Meme in its pool and burns it, under a buyback admin. Aborts
/// unless the swap returns at least `min_meme_out`; the admin sets it from an off-chain price,
/// since anyone can move the pool's price within a transaction.
public fun buyback_and_burn<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    admin_witness: &AdminWitness<BuybackAdmin>,
    currency: &mut Currency<Meme>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    min_meme_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    assert!(self.pool_id() == object::id(pool), EPositionPoolMismatch);
    let quote = self.take_buyback_quote(admin_witness);
    let quote_in = quote.value();

    let (meme, quote) = pool::swap(
        clock,
        bluefin_config,
        pool,
        balance::zero(),
        quote,
        false,
        true,
        quote_in,
        0,
        constants::max_swap_sqrt_price!(),
    );

    self.burn_buyback(currency, meme, quote, quote_in, min_meme_out, ctx);
}

// === Private Functions ===

/// Collects the attached position's fees from `pool`, which must be the position's own pool.
fun collect_position_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
): (Balance<Meme>, Balance<Quote>) {
    let position = self.position_mut<_, _, _, Position>(&Venue());
    assert!(position.pool_id() == object::id(pool), EPositionPoolMismatch);

    let (_, _, meme_fee, quote_fee) = pool::collect_fee(clock, bluefin_config, pool, position);

    (meme_fee, quote_fee)
}

/// Adds as much of the waiting auto-LP balances as the position takes at the pool's current price,
/// fixing the side the other can cover from the pool's and the position's bound sqrt prices, and
/// keeps the rest for the next call. `collect_position_fees` already matched the pool.
fun compound<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
) {
    let (meme, quote) = self.take_auto_lp();
    let position = self.position_mut<_, _, _, Position>(&Venue());
    let ticks = pool.get_tick_manager();
    let sqrt_lower = ticks.get_tick_from_manager(position.lower_tick()).sqrt_price();
    let sqrt_upper = ticks.get_tick_from_manager(position.upper_tick()).sqrt_price();
    let (fix_meme, amount) = migration_math::auto_lp_fixed_side(
        sqrt_lower,
        pool.current_sqrt_price(),
        sqrt_upper,
        meme.value(),
        quote.value(),
    );

    let (added_meme, added_quote, meme, quote) = if (amount > 0) {
        pool::add_liquidity_with_fixed_amount(
            clock,
            bluefin_config,
            pool,
            position,
            meme,
            quote,
            amount,
            fix_meme,
        )
    } else {
        (0, 0, meme, quote)
    };
    self.keep_auto_lp(added_meme, added_quote, meme, quote);
}

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_fun::{
    allocation::FeeSplit,
    blast_fun_domain::BuybackAdmin,
    creator_authority::CurveFeeCap,
    launch::{Self, Launch, LaunchInitializer},
    launch_config::LaunchConfig,
    launch_ticket::LaunchTicket,
    package_version::PackageVersion,
};

use blast_fun_migrators::{
    constants,
    lp_fee_policy::LpFeePolicy,
    migration_math,
    package_version::PackageVersion as MigratorsVersion,
    vault::{Self, LpVault},
};

use bluefin_spot::{config::GlobalConfig, pool::{Self, Pool}, position::Position};

use integer_mate::i32;

use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, coin_registry::Currency, sui::SUI};

use fun collect_position_fees as LpVault.collect_position_fees;

use fun compound as LpVault.compound;
