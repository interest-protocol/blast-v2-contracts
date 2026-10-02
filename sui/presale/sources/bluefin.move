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

/// Creates a presale irrevocably configured to migrate to Bluefin at this tier.
public fun new<Meme, Quote>(
    treasury_cap: TreasuryCap<Meme>,
    currency: &mut Currency<Meme>,
    token_supply: u64,
    token_allocation_bps: Bps,
    liquidity_token_allocation_bps: Bps,
    recipient_allocations: vector<RecipientAllocation>,
    burnable: bool,
    raise_target: u64,
    raise_allocations: vector<RecipientAllocation>,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    fee_recipients: vector<FeeRecipient>,
    holder_rewards_bps: Bps,
    fee_policy: &FeePolicy,
    tick_spacing: u32,
    pool_fee_rate: u64,
    ctx: &mut TxContext,
): (Presale<Meme, Quote>, PresaleCap) {
    assert!(
        tick_spacing > 0
            && tick_spacing <= MAX_TICK_SPACING
            && pool_fee_rate > 0
            && pool_fee_rate <= MAX_POOL_FEE_RATE,
        EInvalidTier,
    );
    assert!(currency.symbol().length() <= MAX_MEME_SYMBOL_LENGTH, ESymbolTooLong);

    presale::new(
        treasury_cap,
        currency,
        token_supply,
        token_allocation_bps,
        liquidity_token_allocation_bps,
        recipient_allocations,
        burnable,
        raise_target,
        raise_allocations,
        duration_ms,
        liquidity_window_ms,
        eligibility,
        uncapped,
        Witness(),
        tick_spacing,
        pool_fee_rate,
        fee_recipients,
        holder_rewards_bps,
        fee_policy,
        ctx,
    )
}

/// Anyone may atomically migrate a funded presale into its configured Bluefin pool.
public fun migrate<Meme, Quote>(
    sale: &mut Presale<Meme, Quote>,
    fee_policy: &FeePolicy,
    currency: &Currency<Meme>,
    quote_currency: &Currency<Quote>,
    bluefin_config: &mut GlobalConfig,
    creation_fee: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (tick_spacing, pool_fee_rate) = sale.pool_tier();
    let (meme, quote) = sale.migrate(fee_policy, Witness(), ctx);

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

/// Anyone may collect LP fees, paying Blast and each fee recipient and accruing the
/// holder-reward share.
public fun collect_fees<Meme, Quote>(
    vault: &mut PresaleVault<Meme, Quote>,
    fee_policy: &FeePolicy,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let position = vault.position_mut<_, _, _, Position>(&Venue());
    assert!(position.pool_id() == object::id(pool), EPositionPoolMismatch);

    let (_, _, meme, quote) = pool::collect_fee(clock, bluefin_config, pool, position);

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
const EPositionPoolMismatch: vector<u8> = b"Custodied position must belong to the supplied pool.";

#[error(code = 1)]
const EInvalidTier: vector<u8> = b"Bluefin tier needs tick spacing 1..=400 and fee rate 1..=20,000.";

#[error(code = 2)]
const ESymbolTooLong: vector<u8> = b"The Meme symbol must be at most 32 bytes for Bluefin migration.";

// === Imports ===

use blast_presale::{
    blast_presale::{
        Self as presale,
        EligibilityPolicy,
        FeeRecipient,
        Presale,
        PresaleCap,
        RecipientAllocation,
        UncappedPhase,
    },
    bps::Bps,
    fee_policy::FeePolicy,
    migration_math,
    presale_vault::{Self as vault, PresaleVault},
};

use bluefin_spot::{config::GlobalConfig, pool::{Self, Pool}, position::Position};

use integer_mate::i32::{Self, I32};

use sui::{clock::Clock, coin::{Coin, TreasuryCap}, coin_registry::Currency, sui::SUI};
