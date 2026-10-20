// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Permissionless Bluefin migration and LP-fee collection for configured presales.
module blast_presale::bluefin;

// === Public Types ===

/// Sealed Bluefin migrator identity fixed before commitments open.
public struct Witness() has drop;

/// Sealed marker for the Bluefin position held by a presale vault.
public struct Venue() has drop;

// === Public Functions ===

/// Starts a presale irrevocably configured to migrate to a Bluefin pool at this tier. Every sale
/// token has one sale, so the tier is recorded under its type.
public fun new<Meme, Quote>(
    treasury_cap: TreasuryCap<Meme>,
    package_version: &PackageVersion,
    currency: &Currency<Meme>,
    creation_policy: &CreationPolicy,
    fee_policy: &FeePolicy,
    venue_config: &mut VenueConfig,
    tick_spacing: u32,
    pool_fee_rate: u64,
): PresaleInitializer<Meme, Quote> {
    package_version.assert_current();

    assert!(
        tick_spacing > 0
            && tick_spacing <= MAX_TICK_SPACING
            && pool_fee_rate > 0
            && pool_fee_rate <= MAX_POOL_FEE_RATE,
        EInvalidTier,
    );
    assert!(currency.symbol().length() <= MAX_MEME_SYMBOL_LENGTH, ESymbolTooLong);

    venue_config.add_pool_tier<Meme, Quote, _>(&Venue(), tick_spacing, pool_fee_rate);

    presale::new(treasury_cap, package_version, Witness(), creation_policy, fee_policy)
}

/// Anyone may atomically migrate a funded presale into its configured Bluefin pool.
public fun migrate<Meme, Quote>(
    sale: &mut Presale<Meme, Quote>,
    package_version: &PackageVersion,
    fee_policy: &FeePolicy,
    venue_config: &VenueConfig,
    currency: &Currency<Meme>,
    quote_currency: &Currency<Quote>,
    bluefin_config: &mut GlobalConfig,
    creation_fee: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    let (tick_spacing, pool_fee_rate) = venue_config.pool_tier<Meme>();
    let (meme, quote) = sale.migrate(package_version, fee_policy, Witness(), clock, ctx);

    let source_meme = meme.value();
    let source_quote = quote.value();
    let (lower_tick, upper_tick) = full_range(bluefin_config, tick_spacing);

    let mut pool = pool::create_pool_and_get_object<Meme, Quote, SUI>(
        clock,
        bluefin_config,
        pool_name(currency, quote_currency),
        b"",
        currency.symbol().into_bytes(),
        currency.decimals(),
        b"",
        quote_currency.symbol().into_bytes(),
        quote_currency.decimals(),
        quote_currency.icon_url().into_bytes(),
        tick_spacing,
        pool_fee_rate,
        migration_math::sqrt_price_x64(source_meme, source_quote, true),
        creation_fee.into_balance(),
        ctx,
    );

    let mut position = pool::open_position(
        bluefin_config,
        &mut pool,
        lower_tick.as_u32(),
        upper_tick.as_u32(),
        ctx,
    );
    let fix_meme = fixes_meme(&pool, lower_tick, upper_tick, source_meme, source_quote);
    let (_, _, residual_meme, residual_quote) = pool::add_liquidity_with_fixed_amount(
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
        sale,
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

/// Seals the caller's own Bluefin position in `pool`, whose first coin must be Meme, in a new
/// shared vault splitting its LP fees by `fee_split`, after Blast's current rates. The liquidity is
/// locked for good. Blast must allow Quote and this migrator, as for a presale,
/// and accept the partner, if one is named.
public fun new_vault<Meme, Quote>(
    position: Position,
    package_version: &PackageVersion,
    fee_split: FeeSplit,
    partner_id: Option<ID>,
    creation_policy: &CreationPolicy,
    fee_policy: &FeePolicy,
    pool: &Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    creation_policy.assert_allowed<Quote, Witness>();
    assert!(position.pool_id() == object::id(pool), EPositionPoolMismatch);

    let liquidity = position.liquidity();

    vault::create_without_presale<Meme, Quote, _, _>(
        fee_split,
        partner_id,
        creation_policy,
        fee_policy,
        clock,
        &Venue(),
        object::id(pool),
        position,
        liquidity,
        ctx,
    );
}

/// Anyone may collect LP fees, paying Blast and each fee recipient and accruing the
/// holder Quote and paying holder Meme to the governed treasury.
public fun collect_fees<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    package_version: &PackageVersion,
    fee_policy: &FeePolicy,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current();

    assert!(vault.pool_id() == object::id(pool), EPositionPoolMismatch);

    let (_, _, meme, quote) = pool::collect_fee(
        clock,
        bluefin_config,
        pool,
        vault.position_mut<_, _, _, Position>(&Venue()),
    );

    vault.split_fees(fee_policy, meme, quote, ctx);
}

// === Private Functions ===

/// The full tick range, with both bounds aligned inward to the pool's tick spacing.
fun full_range(bluefin_config: &GlobalConfig, tick_spacing: u32): (I32, I32) {
    let (minimum_tick, maximum_tick) = bluefin_config.get_tick_range();
    let spacing = i32::from(tick_spacing);

    (minimum_tick.div(spacing).mul(spacing), maximum_tick.div(spacing).mul(spacing))
}

/// The pool name, `<Meme symbol>-<Quote symbol>`.
fun pool_name<Meme, Quote>(
    currency: &Currency<Meme>,
    quote_currency: &Currency<Quote>,
): vector<u8> {
    let mut name = currency.symbol().into_bytes();
    name.append(b"-");
    name.append(quote_currency.symbol().into_bytes());
    name
}

/// Whether to fix the Meme side when seeding. Fix the side with more atoms: a full-range position
/// needs slightly more of the other side than the seed ratio, so that partner balance covers it.
/// When both sides are nearly equal, rounding can still overdraw by one atom, so ask Bluefin's own
/// math and fix the other side.
fun fixes_meme<Meme, Quote>(
    pool: &Pool<Meme, Quote>,
    lower_tick: I32,
    upper_tick: I32,
    source_meme: u64,
    source_quote: u64,
): bool {
    let prefer_meme = source_meme >= source_quote;
    let (_, needed_meme, needed_quote) = pool::get_liquidity_by_amount(
        lower_tick,
        upper_tick,
        pool.current_tick_index(),
        pool.current_sqrt_price(),
        if (prefer_meme) source_meme else source_quote,
        prefer_meme,
    );

    if (needed_meme <= source_meme && needed_quote <= source_quote) prefer_meme else !prefer_meme
}

// === Constants ===

const MAX_TICK_SPACING: u32 = 400;
const MAX_POOL_FEE_RATE: u64 = 20_000;

/// Bluefin stores the pool name, built from this symbol, twice in every `Position`; the
/// bound keeps a migrated position inside Sui's object size limit (ADR 0088).
const MAX_MEME_SYMBOL_LENGTH: u64 = 32;

// === Errors ===

#[error(code = 0)]
const EPositionPoolMismatch: vector<u8> = b"Pool must be the one holding the position.";

#[error(code = 1)]
const EInvalidTier: vector<u8> = b"Bluefin tier needs tick spacing 1..=400 and fee rate 1..=20,000.";

#[error(code = 2)]
const ESymbolTooLong: vector<u8> = b"The Meme symbol must be at most 32 bytes for Bluefin migration.";

// === Imports ===

use blast_presale::{
    blast_presale::{Self as presale, FeeSplit, Presale, PresaleInitializer},
    blast_presale_package::PackageVersion,
    creation_policy::CreationPolicy,
    fee_policy::FeePolicy,
    migration_math,
    presale_vault::{Self as vault, Vault},
    venue_config::VenueConfig
};

use bluefin_spot::{config::GlobalConfig, pool::{Self, Pool}, position::Position};

use integer_mate::i32::{Self, I32};

use sui::{clock::Clock, coin::{Coin, TreasuryCap}, coin_registry::Currency, sui::SUI};
