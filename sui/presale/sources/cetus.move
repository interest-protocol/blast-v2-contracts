// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Permissionless Cetus migration and LP-fee collection for configured presales.
module blast_presale::cetus;

// === Public Types ===

/// Sealed Cetus migrator identity fixed before commitments open.
public struct Witness() has drop;

/// Sealed marker for the Cetus burn proof held by a presale vault.
public struct Venue() has drop;

/// Key for a Meme type's reserved Cetus pool-creation capability.
public struct CreationCapKey<phantom Meme>() has copy, drop, store;

/// Transient dynamic-field name `cast` uses to retype a coin or balance.
public struct CastKey() has copy, drop, store;

// === Public Functions ===

/// Creates a presale configured for Cetus and reserves pool creation before Meme leaves custody.
public fun new<Meme, Quote>(
    mut treasury_cap: TreasuryCap<Meme>,
    currency: &mut Currency<Meme>,
    token_supply: u64,
    token_allocation_bps: u64,
    liquidity_token_allocation_bps: u64,
    recipient_allocations: vector<RecipientAllocation>,
    burnable: bool,
    raise_target: u64,
    raise_allocations: vector<RecipientAllocation>,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    fee_recipients: vector<FeeRecipient>,
    rewards_fee_bps: u64,
    venue_config: &mut VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    tick_spacing: u32,
    ctx: &mut TxContext,
): (Presale<Meme, Quote>, PresaleCap) {
    let fee_rate = config::get_fee_rate(tick_spacing, cetus_config);

    // Reserve the pair's Cetus pool creation before the Meme supply leaves the creator.
    let creation_cap = factory::mint_pool_creation_cap(cetus_config, pools, &mut treasury_cap, ctx);
    factory::register_permission_pair<Meme, Quote>(
        cetus_config,
        pools,
        tick_spacing,
        &creation_cap,
        ctx,
    );
    venue_config.add_object(CreationCapKey<Meme>(), creation_cap);

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
        fee_rate,
        fee_recipients,
        rewards_fee_bps,
        ctx,
    )
}

/// Anyone may migrate a funded presale into its reserved Cetus pool. `CoinA` and `CoinB` name the
/// presale's Meme and Quote in Cetus's canonical coin order.
public fun migrate<Meme, Quote, CoinA, CoinB>(
    sale: &mut Presale<Meme, Quote>,
    venue_config: &VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    burn_manager: &mut BurnManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(factory::is_right_order<CoinA, CoinB>(), EInvalidCoinOrder);
    let meme_is_a = meme_is_coin_a<Meme, Quote, CoinA, CoinB>();

    let (tick_spacing, _) = sale.pool_tier();
    let (meme, quote) = sale.migrate(Witness(), ctx);

    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let (tick_lower, tick_upper) = pool_creator::full_range_tick_range(tick_spacing);
    let sqrt_price = migration_math::sqrt_price_x64(meme_amount, quote_amount, meme_is_a);
    let fix_a = fixed_side_is_a(
        tick_lower,
        tick_upper,
        sqrt_price,
        meme_amount,
        quote_amount,
        meme_is_a,
    );

    let mut scratch = object::new(ctx);
    let (coin_a, coin_b) = scratch.cast_pair<_, _, Balance<CoinA>, Balance<CoinB>>(
        meme,
        quote,
        meme_is_a,
    );

    let (position, residual_a, residual_b) = pool_creator::create_pool_v3_with_creation_cap<
        CoinA,
        CoinB,
    >(
        cetus_config,
        pools,
        venue_config.pool_creation_cap<Meme>(),
        tick_spacing,
        sqrt_price,
        b"".to_string(),
        tick_lower,
        tick_upper,
        coin_a.into_coin(ctx),
        coin_b.into_coin(ctx),
        fix_a,
        clock,
        ctx,
    );

    let (residual_meme, residual_quote) = scratch.cast_pair<_, _, Coin<Meme>, Coin<Quote>>(
        residual_a,
        residual_b,
        meme_is_a,
    );
    scratch.delete();

    burn_into_vault(sale, burn_manager, position, residual_meme, residual_quote, ctx);
}

/// Anyone may collect LP fees from a migrated presale's Cetus position, paying each fee recipient
/// and accruing the holder-reward share. `CoinA` and `CoinB` are the pool's coin order.
public fun collect_fees<Meme, Quote, CoinA, CoinB>(
    vault: &mut PresaleVault<Meme, Quote>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<CoinA, CoinB>,
    ctx: &mut TxContext,
) {
    let meme_is_a = meme_is_coin_a<Meme, Quote, CoinA, CoinB>();
    assert!(vault.pool_id() == object::id(pool), EPositionPoolMismatch);

    let (fee_a, fee_b) = lp_burn::collect_fee(
        burn_manager,
        cetus_config,
        pool,
        vault.position_mut<_, _, _, CetusLPBurnProof>(&Venue()),
        ctx,
    );

    let mut scratch = object::new(ctx);
    let (meme, quote) = scratch.cast_pair<_, _, Coin<Meme>, Coin<Quote>>(fee_a, fee_b, meme_is_a);
    scratch.delete();

    vault.split_fees(meme.into_balance(), quote.into_balance(), ctx);
}

// === Private Functions ===

/// Whether Meme is `CoinA`, after proving `(CoinA, CoinB)` is exactly the presale's pair.
fun meme_is_coin_a<Meme, Quote, CoinA, CoinB>(): bool {
    let (meme, quote) = (type_name::with_original_ids<Meme>(), type_name::with_original_ids<Quote>());
    let (a, b) = (type_name::with_original_ids<CoinA>(), type_name::with_original_ids<CoinB>());
    assert!((meme == a && quote == b) || (meme == b && quote == a), EWrongCoinPair);

    meme == a
}

/// Chooses the side to fix, preferring the side with more atoms, Meme on a tie: a full-range
/// position needs slightly more of the other side than the seed ratio, so that partner balance
/// covers it. When both sides are nearly equal, rounding can still overdraw by one atom, so
/// Cetus's own math decides and the other side is fixed instead. Any tick inside the full range
/// selects Cetus's in-range branch; pool creation aborts anyway if the seed price lies outside it.
fun fixed_side_is_a(
    tick_lower: u32,
    tick_upper: u32,
    sqrt_price: u128,
    meme_amount: u64,
    quote_amount: u64,
    meme_is_a: bool,
): bool {
    let (amount_a, amount_b) = if (meme_is_a) (meme_amount, quote_amount)
    else (quote_amount, meme_amount);
    let prefer_a = (meme_amount >= quote_amount) == meme_is_a;
    let (_, needed_a, needed_b) = clmm_math::get_liquidity_by_amount(
        i32::from_u32(tick_lower),
        i32::from_u32(tick_upper),
        i32::zero(),
        sqrt_price,
        if (prefer_a) amount_a else amount_b,
        prefer_a,
    );

    if (needed_a <= amount_a && needed_b <= amount_b) prefer_a else !prefer_a
}

/// Retypes `value` as `To` through a dynamic field on `scratch`. Removal succeeds only under the
/// stored type, so this aborts unless `From` and `To` are the same type; `meme_is_coin_a` has
/// already proven that for every call.
fun cast<From: store, To: store>(scratch: &mut UID, value: From): To {
    scratch.add_dynamic_field(CastKey(), value);
    scratch.remove_dynamic_field(CastKey())
}

/// Retypes a Meme-and-Quote pair into Cetus's coin order, or a coin-order pair back, through
/// `scratch`: in place when Meme is coin A, crossed otherwise.
fun cast_pair<First: store, Second: store, ToFirst: store, ToSecond: store>(
    scratch: &mut UID,
    first: First,
    second: Second,
    meme_is_a: bool,
): (ToFirst, ToSecond) {
    if (meme_is_a) (scratch.cast(first), scratch.cast(second))
    else (scratch.cast(second), scratch.cast(first))
}

fun pool_creation_cap<Meme>(self: &VenueConfig): &PoolCreationCap {
    self.object(CreationCapKey<Meme>())
}

/// Burns the LP position for its fee-claiming proof and seals the proof in the presale's vault.
fun burn_into_vault<Meme, Quote>(
    sale: &Presale<Meme, Quote>,
    burn_manager: &mut BurnManager,
    position: Position,
    residual_meme: Coin<Meme>,
    residual_quote: Coin<Quote>,
    ctx: &mut TxContext,
) {
    let pool_id = position.pool_id();
    let liquidity = position.liquidity();
    let burn_proof = lp_burn::burn_lp_v2(burn_manager, position, ctx);

    vault::create(
        sale,
        &Venue(),
        pool_id,
        burn_proof,
        liquidity,
        residual_meme.into_balance(),
        residual_quote.into_balance(),
        ctx,
    );
}

// === Test-Only Functions ===

#[test_only]
public fun meme_is_coin_a_for_testing<Meme, Quote, CoinA, CoinB>(): bool {
    meme_is_coin_a<Meme, Quote, CoinA, CoinB>()
}

#[test_only]
public fun cast_for_testing<From: store, To: store>(scratch: &mut UID, value: From): To {
    scratch.cast(value)
}

// === Errors ===

#[error(code = 0)]
const EInvalidCoinOrder: vector<u8> = b"CoinA and CoinB must follow the Cetus coin order.";

#[error(code = 1)]
const EPositionPoolMismatch: vector<u8> = b"Pool must be the vault's migration pool.";

#[error(code = 2)]
const EWrongCoinPair: vector<u8> = b"CoinA and CoinB must be exactly the presale's Meme and Quote.";

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
    migration_math,
    presale_vault::{Self as vault, PresaleVault},
    venue_config::VenueConfig,
};

use cetus_clmm::{
    clmm_math,
    config::{Self, GlobalConfig},
    factory::{Self, PoolCreationCap, Pools},
    pool::Pool,
    pool_creator,
    position::Position,
};

use integer_mate::i32;

use lp_burn::lp_burn::{Self, BurnManager, CetusLPBurnProof};

use std::type_name;

use sui::{
    balance::Balance,
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::Currency,
    dynamic_field,
};

use fun cast as UID.cast;
use fun cast_pair as UID.cast_pair;
use fun dynamic_field::add as UID.add_dynamic_field;
use fun dynamic_field::remove as UID.remove_dynamic_field;
use fun pool_creation_cap as VenueConfig.pool_creation_cap;
