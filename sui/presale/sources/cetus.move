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

/// Starts a presale that migrates to a Cetus pool at `tick_spacing`, whose fee rate Cetus derives
/// from it, and reserves the pair's pool creation at that tier before the supply is minted. Every
/// sale token has one sale, so the tier is recorded under its type.
public fun new<Meme, Quote>(
    mut treasury_cap: TreasuryCap<Meme>,
    creation_policy: &CreationPolicy,
    fee_policy: &FeePolicy,
    venue_config: &mut VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    tick_spacing: u32,
    ctx: &mut TxContext,
): PresaleInitializer<Meme, Quote> {
    let creation_cap = factory::mint_pool_creation_cap(cetus_config, pools, &mut treasury_cap, ctx);
    factory::register_permission_pair<Meme, Quote>(
        cetus_config,
        pools,
        tick_spacing,
        &creation_cap,
        ctx,
    );
    venue_config.add_object(CreationCapKey<Meme>(), creation_cap);
    venue_config.add_pool_tier<Meme, Quote, _>(
        &Venue(),
        tick_spacing,
        config::get_fee_rate(tick_spacing, cetus_config),
    );

    presale::new(treasury_cap, Witness(), creation_policy, fee_policy)
}

/// Anyone may migrate a funded presale into its reserved Cetus pool. `CoinA` and `CoinB` name the
/// presale's Meme and Quote in Cetus's canonical coin order.
public fun migrate<Meme, Quote, CoinA, CoinB>(
    sale: &mut Presale<Meme, Quote>,
    fee_policy: &FeePolicy,
    venue_config: &VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    burn_manager: &mut BurnManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(factory::is_right_order<CoinA, CoinB>(), EInvalidCoinOrder);
    let meme_is_a = meme_is_coin_a<Meme, Quote, CoinA, CoinB>();

    let (tick_spacing, _) = venue_config.pool_tier<Meme>();
    let (meme, quote) = sale.migrate(fee_policy, Witness(), clock, ctx);

    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let (tick_lower, tick_upper) = pool_creator::full_range_tick_range(tick_spacing);
    let sqrt_price = migration_math::sqrt_price_x64(meme_amount, quote_amount, meme_is_a);
    let fix_coin_a = fixed_side_is_a(
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

    let (position, residual_a, residual_b) = pool_creator::create_pool_v3_with_creation_cap(
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
        fix_coin_a,
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

/// Burns the caller's own Cetus position in `pool` for its fee-claiming proof and seals the proof
/// in a new shared vault splitting its LP fees by `fee_split`, after Blast's current rates. The
/// liquidity is locked for good. Blast must allow Quote and this migrator, as for a presale,
/// and accept the partner, if one is named.
public fun new_vault<Meme, Quote, CoinA, CoinB>(
    position: Position,
    fee_split: FeeSplit,
    partner_id: Option<ID>,
    creation_policy: &CreationPolicy,
    fee_policy: &FeePolicy,
    pool: &Pool<CoinA, CoinB>,
    burn_manager: &mut BurnManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    creation_policy.assert_allowed<Quote, Witness>();
    meme_is_coin_a<Meme, Quote, CoinA, CoinB>();
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
        lp_burn::burn_lp_v2(burn_manager, position, ctx),
        liquidity,
        ctx,
    );
}

/// Anyone may collect LP fees from a migrated presale's Cetus position, paying Blast and each fee
/// recipient and accruing the holder Quote and paying holder Meme to the governed treasury. `CoinA` and `CoinB` are the pool's coin order.
public fun collect_fees<Meme, Quote, CoinA, CoinB>(
    vault: &mut Vault<Meme, Quote>,
    fee_policy: &FeePolicy,
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

    vault.split_fees(fee_policy, meme.into_balance(), quote.into_balance(), ctx);
}

// === Private Functions ===

/// Whether Meme is `CoinA`, after proving `(CoinA, CoinB)` is exactly the presale's pair.
fun meme_is_coin_a<Meme, Quote, CoinA, CoinB>(): bool {
    let (meme, quote) = (type_name::with_original_ids<Meme>(), type_name::with_original_ids<Quote>());
    let (coin_a, coin_b) = (
        type_name::with_original_ids<CoinA>(),
        type_name::with_original_ids<CoinB>(),
    );
    assert!(
        (meme == coin_a && quote == coin_b) || (meme == coin_b && quote == coin_a),
        EWrongCoinPair,
    );

    meme == coin_a
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
const EPositionPoolMismatch: vector<u8> = b"Pool must be the one holding the position.";

#[error(code = 2)]
const EWrongCoinPair: vector<u8> = b"CoinA and CoinB must be exactly the presale's Meme and Quote.";

// === Imports ===

use blast_presale::{
    blast_presale::{Self as presale, FeeSplit, Presale, PresaleInitializer},
    creation_policy::CreationPolicy,
    fee_policy::FeePolicy,
    migration_math,
    presale_vault::{Self as vault, Vault},
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

use sui::{balance::Balance, clock::Clock, coin::{Coin, TreasuryCap}, dynamic_field};

use fun cast as UID.cast;
use fun cast_pair as UID.cast_pair;
use fun dynamic_field::add as UID.add_dynamic_field;
use fun dynamic_field::remove as UID.remove_dynamic_field;
use fun pool_creation_cap as VenueConfig.pool_creation_cap;
