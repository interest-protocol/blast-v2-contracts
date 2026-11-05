// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the venue's abort location.
#[allow(lint(abort_without_constant))]
/// Bluefin coin preparation, migration into `blast_vault` custody, fee collection with auto-LP,
/// settled fee-split updates, and buybacks over custodied concentrated-liquidity principal, for
/// launches and presales alike.
///
/// Bluefin pools are keyed by their exact type-parameter order, so this module
/// always creates and expects `Pool<Meme, Quote>` with Meme as coin A.
module blast_migrators::bluefin;

// === Public Types ===

/// The Bluefin venue's sealed witness: it issues tickets, redeems migrations, and keys the position
/// in the vault, so each product's venue list and the vault registry admit this one type.
public struct Venue() has drop;

/// A prepared coin's Bluefin pool tier.
public struct PoolTier has copy, drop, store {
    tick_spacing: u32,
    fee_rate: u64,
}

/// Sealed `VenueConfig` field name for the Meme type's Bluefin pool tier.
public struct PoolTierKey<phantom Meme>() has copy, drop, store;

// === Public Functions ===

/// Prepares `Meme` for a Bluefin sale in `Quote` at the creator's tier, recording the tier, and
/// returns the ticket the product's `new` redeems. `treasury_cap` proves the caller controls the
/// coin, so no one else can record its tier first.
///
/// Bluefin checks the tier only when migration creates the pool, and a sale cannot change its
/// tier, so the same bounds apply here first. The pool and its position store the Meme symbol, so
/// it is bounded here too.
public fun prepare<Meme, Quote>(
    migrators_version: &PackageVersion<BLAST_MIGRATORS>,
    venue_config: &mut VenueConfig,
    _: &TreasuryCap<Meme>,
    currency: &Currency<Meme>,
    tick_spacing: u32,
    fee_rate: u64,
): VenueTicket<Meme, Quote> {
    migrators_version.assert_current(constants::version!());
    assert!(
        tick_spacing > 0 && tick_spacing <= constants::bluefin_max_tick_spacing!() && fee_rate > 0
            && fee_rate <= constants::bluefin_max_fee_rate!(),
        blast_migrators::errors::invalid_tier!(),
    );
    assert!(
        currency.symbol().length() <= constants::max_meme_symbol_length!(),
        blast_migrators::errors::symbol_too_long!(),
    );

    venue_config.add_value(PoolTierKey<Meme>(), PoolTier { tick_spacing, fee_rate });

    events::bluefin_pool_tier_recorded<Meme, Quote>(tick_spacing, fee_rate);

    migration::issue_ticket(Venue())
}

/// Migrates a sale into a new full-range pool at the recorded tier and a `blast_vault` vault:
/// `migration` is the hand-off the launch's or presale's own `migrate` returned earlier in the
/// transaction.
///
/// Redeems the hand-off. The opening price derives from the handed-off balances, which
/// seed the position on the side `is_meme_seed_side` chooses. `creation_fee` is paid whole, and
/// Bluefin aborts unless it is exactly the configured SUI fee. The position and the venue
/// residuals go to the vault, which has no withdrawal path. The caller receives no object; Bluefin
/// records it as the new pool's manager, a role limited to the pool's reward emissions and to
/// handing the role on (ADR 0088).
public fun migrate<Meme, Quote>(
    migration: Migration<Meme, Quote>,
    migrators_version: &PackageVersion<BLAST_MIGRATORS>,
    venue_config: &VenueConfig,
    currency: &Currency<Meme>,
    quote_currency: &Currency<Quote>,
    bluefin_config: &mut GlobalConfig,
    registry: &mut VaultRegistry,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    creation_fee: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current(constants::version!());
    let (meme, quote, terms) = migration.redeem(Venue());

    let PoolTier { tick_spacing, fee_rate } = *venue_config.value(PoolTierKey<Meme>());
    let (lower_tick, upper_tick) = bluefin_config.full_range_tick_range(tick_spacing);

    let mut pool = pool::create_pool_and_get_object<Meme, Quote, SUI>(
        clock,
        bluefin_config,
        currency.pool_name(quote_currency),
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
        migration::sqrt_price_x64(meme.value(), quote.value(), true),
        creation_fee.into_balance(),
        ctx,
    );
    let mut position = pool::open_position(bluefin_config, &mut pool, lower_tick, upper_tick, ctx);
    let (residual_meme, residual_quote) = pool.seed(
        bluefin_config,
        &mut position,
        meme,
        quote,
        clock,
    );

    let pool_id = position.pool_id();
    let liquidity = position.liquidity();
    vault::new<Meme, Quote, _>(registry, &Venue(), vault_version, terms, pool_id)
        .share_with_position(
            &Venue(),
            treasury,
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
    self: &mut Vault<Meme, Quote>,
    migrators_version: &PackageVersion<BLAST_MIGRATORS>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current(constants::version!());

    self.settle_fees(vault_version, treasury, currency, bluefin_config, pool, clock, ctx);
}

/// Anyone may settle accrued fees under the current split, then apply the stored ready proposal.
public fun settle_and_apply_fee_split<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    migrators_version: &PackageVersion<BLAST_MIGRATORS>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current(constants::version!());
    self.assert_fee_split_ready(clock);

    self.settle_fees(vault_version, treasury, currency, bluefin_config, pool, clock, ctx);

    self.apply_fee_split(&Venue(), vault_version, clock);
}

/// Adds the vault's waiting auto-LP Meme and Quote to its position in `pool` at the current price
/// and keeps the rest for the next call. Anyone may call it, apart from collection, so a Bluefin
/// refusal of the add never blocks collecting fees.
public fun compound_auto_lp<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    migrators_version: &PackageVersion<BLAST_MIGRATORS>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
) {
    migrators_version.assert_current(constants::version!());
    assert!(self.pool_id() == object::id(pool), blast_migrators::errors::position_pool_mismatch!());

    self.compound(vault_version, bluefin_config, pool, clock);
}

/// Swaps `quote_in` of the vault's burn Quote for Meme in its pool and burns it, under a buyback
/// admin. Aborts unless `quote_in` is positive and at most the burn Quote held, and unless the swap
/// returns at least `min_meme_out`; the admin sets it from an off-chain price, since anyone can move
/// the pool's price within a transaction. Quote the pool does not take stays for the next buyback.
public fun buyback_and_burn<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    migrators_version: &PackageVersion<BLAST_MIGRATORS>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    admin_witness: &AdminWitness<BuybackAdmin>,
    currency: &mut Currency<Meme>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    quote_in: u64,
    min_meme_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current(constants::version!());
    assert!(self.pool_id() == object::id(pool), blast_migrators::errors::position_pool_mismatch!());

    let (quote, receipt) = self.take_buyback_quote(&Venue(), admin_witness, vault_version, quote_in);
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

    self.burn_buyback(&Venue(), vault_version, receipt, currency, meme, quote, min_meme_out, ctx);
}

// === Private Functions ===

/// Aligns Bluefin's configured tick bounds to `tick_spacing`, giving the widest range a position
/// at that spacing can open.
fun full_range_tick_range(bluefin_config: &GlobalConfig, tick_spacing: u32): (u32, u32) {
    let (minimum_tick, maximum_tick) = bluefin_config.get_tick_range();
    let spacing = i32::from(tick_spacing);

    (
        minimum_tick.div(spacing).mul(spacing).as_u32(),
        maximum_tick.div(spacing).mul(spacing).as_u32(),
    )
}

/// Names the pool by the two coin symbols around a one-byte separator.
fun pool_name<Meme, Quote>(
    currency: &Currency<Meme>,
    quote_currency: &Currency<Quote>,
): vector<u8> {
    let mut name = currency.symbol().into_bytes();
    name.append(b"-");
    name.append(quote_currency.symbol().into_bytes());

    name
}

/// Adds the handed-off balances to the new full-range position, fixing the side
/// `is_meme_seed_side` chooses, and returns the residuals.
fun seed<Meme, Quote>(
    pool: &mut Pool<Meme, Quote>,
    bluefin_config: &GlobalConfig,
    position: &mut Position,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    clock: &Clock,
): (Balance<Meme>, Balance<Quote>) {
    let fix_meme = pool.is_meme_seed_side(position, meme.value(), quote.value());
    let fixed_amount = if (fix_meme) meme.value() else quote.value();
    let (_, _, residual_meme, residual_quote) = pool::add_liquidity_with_fixed_amount(
        clock,
        bluefin_config,
        pool,
        position,
        meme,
        quote,
        fixed_amount,
        fix_meme,
    );

    (residual_meme, residual_quote)
}

/// Whether Meme is the side the migration seed fixes, preferring the side with more atoms: a
/// full-range position needs slightly more of the other side than the seed ratio, so that partner
/// balance covers it. When both sides are nearly equal, rounding can still overdraw by one atom, so
/// Bluefin's own math decides and the other side is fixed instead.
fun is_meme_seed_side<Meme, Quote>(
    pool: &Pool<Meme, Quote>,
    position: &Position,
    meme_amount: u64,
    quote_amount: u64,
): bool {
    let prefer_meme = meme_amount >= quote_amount;
    let (_, needed_meme, needed_quote) = pool::get_liquidity_by_amount(
        position.lower_tick(),
        position.upper_tick(),
        pool.current_tick_index(),
        pool.current_sqrt_price(),
        if (prefer_meme) meme_amount else quote_amount,
        prefer_meme,
    );

    seed_fixed_side(prefer_meme, meme_amount, quote_amount, needed_meme, needed_quote)
}

/// Keeps the preferred seed side if the venue's rounded requirements fit both balances, and fixes
/// the other side otherwise.
fun seed_fixed_side(
    preferred: bool,
    available_a: u64,
    available_b: u64,
    needed_a: u64,
    needed_b: u64,
): bool {
    if (needed_a <= available_a && needed_b <= available_b) preferred else !preferred
}

/// Collects the position's fees and splits them through the vault; the auto-LP share waits for
/// `compound_auto_lp`.
fun settle_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (meme_fee, quote_fee) = self.collect_position_fees(vault_version, bluefin_config, pool, clock);
    self.split_fees(&Venue(), vault_version, treasury, currency, meme_fee, quote_fee, ctx);
}

/// Collects the attached position's fees from `pool`, which must be the position's own pool.
fun collect_position_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
): (Balance<Meme>, Balance<Quote>) {
    let position = self.position_mut<_, _, _, Position>(&Venue(), vault_version);
    assert!(position.pool_id() == object::id(pool), blast_migrators::errors::position_pool_mismatch!());

    let (_, _, meme_fee, quote_fee) = pool::collect_fee(clock, bluefin_config, pool, position);

    (meme_fee, quote_fee)
}

/// Adds as much of the waiting auto-LP balances as the position takes at the pool's current price,
/// fixing the side the other can cover from the pool's and the position's bound sqrt prices, and
/// keeps the rest for the next call. `pool` is already matched to the vault.
fun compound<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
) {
    let (meme, quote, receipt) = self.take_auto_lp(&Venue(), vault_version);
    let position = self.position_mut<_, _, _, Position>(&Venue(), vault_version);
    let (fix_meme, fixed_amount) = pool.fixed_side(position, meme.value(), quote.value());

    let (_, _, meme, quote) = if (fixed_amount > 0) {
        pool::add_liquidity_with_fixed_amount(
            clock,
            bluefin_config,
            pool,
            position,
            meme,
            quote,
            fixed_amount,
            fix_meme,
        )
    } else {
        (0, 0, meme, quote)
    };

    self.keep_auto_lp(&Venue(), vault_version, receipt, meme, quote);
}

/// Chooses the side an auto-LP add fixes, and how much, from the pool's price and the position's
/// bound sqrt prices; a zero amount means nothing can be added now.
fun fixed_side<Meme, Quote>(
    pool: &Pool<Meme, Quote>,
    position: &Position,
    meme_amount: u64,
    quote_amount: u64,
): (bool, u64) {
    let ticks = pool.get_tick_manager();
    let sqrt_lower = ticks.get_tick_from_manager(position.lower_tick()).sqrt_price();
    let sqrt_upper = ticks.get_tick_from_manager(position.upper_tick()).sqrt_price();

    auto_lp_fixed_side(
        sqrt_lower,
        pool.current_sqrt_price(),
        sqrt_upper,
        meme_amount,
        quote_amount,
    )
}

/// Chooses the side a fixed-amount liquidity add fixes so the venue never needs more of the other
/// asset than is available, from the pool's and the position's bound sqrt prices (Q64.64).
///
/// Returns `(fix_a, amount)`; a zero amount means nothing can be added now (an empty side, a price
/// outside the range, or too little for positive liquidity), and the balances wait for later.
fun auto_lp_fixed_side(
    sqrt_lower: u128,
    sqrt_price: u128,
    sqrt_upper: u128,
    amount_a: u64,
    amount_b: u64,
): (bool, u64) {
    if (sqrt_price <= sqrt_lower || sqrt_price >= sqrt_upper) return (true, 0);

    let (lower, price, upper) = (sqrt_lower as u256, sqrt_price as u256, sqrt_upper as u256);
    if (can_fix_a(lower, price, upper, amount_a, amount_b)) return (true, amount_a);
    if (can_fix_b(lower, price, upper, amount_a, amount_b)) return (false, amount_b);

    (true, 0)
}

/// Whether fixing all of `amount_a` gives positive liquidity whose B need, plus the margin,
/// `amount_b` covers: L = a * P * U / (U - P), then B = ceil(L * (P - lower)).
fun can_fix_a(lower: u256, price: u256, upper: u256, amount_a: u64, amount_b: u64): bool {
    let one = 1u256 << constants::q64_shift!();
    let liquidity = (amount_a as u256) * (price * upper / one) / (upper - price);
    if (liquidity == 0 || liquidity >= (1u256 << constants::q128_shift!())) return false;

    let needed_b = (liquidity * (price - lower)).div_ceil(one);
    needed_b + constants::auto_lp_margin!() <= (amount_b as u256)
}

/// Whether fixing all of `amount_b` gives positive liquidity whose A need, plus the margin,
/// `amount_a` covers: L = b / (P - lower), then A = ceil(L / P) - floor(L / U).
fun can_fix_b(lower: u256, price: u256, upper: u256, amount_a: u64, amount_b: u64): bool {
    let liquidity = ((amount_b as u256) << constants::q64_shift!()) / (price - lower);
    if (liquidity == 0) return false;

    let needed_a =
        (liquidity << constants::q64_shift!()).div_ceil(price)
            - (liquidity << constants::q64_shift!()) / upper;
    needed_a + constants::auto_lp_margin!() <= (amount_a as u256)
}

// === Test-Only Functions ===

#[test_only]
/// Runs the seed-side rule on explicit balances and venue requirements.
public fun seed_fixed_side_for_testing(
    preferred: bool,
    available_a: u64,
    available_b: u64,
    needed_a: u64,
    needed_b: u64,
): bool {
    seed_fixed_side(preferred, available_a, available_b, needed_a, needed_b)
}

#[test_only]
/// Runs the auto-LP side selection on explicit sqrt prices and balances.
public fun auto_lp_fixed_side_for_testing(
    sqrt_lower: u128,
    sqrt_price: u128,
    sqrt_upper: u128,
    amount_a: u64,
    amount_b: u64,
): (bool, u64) {
    auto_lp_fixed_side(sqrt_lower, sqrt_price, sqrt_upper, amount_a, amount_b)
}

// === Imports ===

use blast_admin::{blast_acl::AdminWitness, package_version::PackageVersion};

use blast_core::{
    blast_domain::BuybackAdmin,
    blast_treasury::Treasury,
    migration::{Self, Migration, VenueTicket}
};

use blast_migrators::{
    blast_migrators::BLAST_MIGRATORS,
    constants,
    events,
    venue_config::VenueConfig
};

use blast_vault::{
    blast_vault_package::{BLAST_VAULT_PACKAGE, VaultRegistry},
    vault::{Self, Vault}
};

use bluefin_spot::{config::GlobalConfig, pool::{Self, Pool}, position::Position};

use integer_mate::i32;

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::Currency,
    sui::SUI
};

use fun collect_position_fees as Vault.collect_position_fees;
use fun compound as Vault.compound;
use fun settle_fees as Vault.settle_fees;

use fun fixed_side as Pool.fixed_side;

use fun full_range_tick_range as GlobalConfig.full_range_tick_range;

use fun is_meme_seed_side as Pool.is_meme_seed_side;

use fun pool_name as Currency.pool_name;

use fun seed as Pool.seed;
