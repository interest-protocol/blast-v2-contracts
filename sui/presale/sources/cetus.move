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
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
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
        duration_ms,
        liquidity_window_ms,
        eligibility,
        Witness(),
        tick_spacing,
        fee_rate,
        fee_recipients,
        rewards_fee_bps,
        ctx,
    )
}

/// Anyone may migrate when Meme is Cetus coin A.
public fun migrate_meme_a<Meme, Quote>(
    sale: &mut Presale<Meme, Quote>,
    venue_config: &VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    burn_manager: &mut BurnManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(factory::is_right_order<Meme, Quote>(), EInvalidCoinOrder);

    let (presale_id, cap_id, tick_spacing, _, fee_recipients, rewards_fee_bps) = sale
        .migration_config();
    let (meme, quote) = sale.migrate(Witness(), ctx);

    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let (tick_lower, tick_upper) = pool_creator::full_range_tick_range(tick_spacing);

    let (position, residual_meme, residual_quote) = pool_creator::create_pool_v3_with_creation_cap<
        Meme,
        Quote,
    >(
        cetus_config,
        pools,
        venue_config.pool_creation_cap<Meme>(),
        tick_spacing,
        migration_math::sqrt_price_x64(meme_amount, quote_amount, true),
        b"".to_string(),
        tick_lower,
        tick_upper,
        meme.into_coin(ctx),
        quote.into_coin(ctx),
        meme_amount >= quote_amount,
        clock,
        ctx,
    );

    burn_into_vault(
        presale_id,
        cap_id,
        fee_recipients,
        rewards_fee_bps,
        burn_manager,
        position,
        residual_meme,
        residual_quote,
        ctx,
    );
}

/// Anyone may migrate when Meme is Cetus coin B.
public fun migrate_meme_b<Meme, Quote>(
    sale: &mut Presale<Meme, Quote>,
    venue_config: &VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    burn_manager: &mut BurnManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(factory::is_right_order<Quote, Meme>(), EInvalidCoinOrder);

    let (presale_id, cap_id, tick_spacing, _, fee_recipients, rewards_fee_bps) = sale
        .migration_config();
    let (meme, quote) = sale.migrate(Witness(), ctx);

    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let (tick_lower, tick_upper) = pool_creator::full_range_tick_range(tick_spacing);

    let (position, residual_quote, residual_meme) = pool_creator::create_pool_v3_with_creation_cap<
        Quote,
        Meme,
    >(
        cetus_config,
        pools,
        venue_config.pool_creation_cap<Meme>(),
        tick_spacing,
        migration_math::sqrt_price_x64(meme_amount, quote_amount, false),
        b"".to_string(),
        tick_lower,
        tick_upper,
        quote.into_coin(ctx),
        meme.into_coin(ctx),
        meme_amount < quote_amount,
        clock,
        ctx,
    );

    burn_into_vault(
        presale_id,
        cap_id,
        fee_recipients,
        rewards_fee_bps,
        burn_manager,
        position,
        residual_meme,
        residual_quote,
        ctx,
    );
}

/// Anyone may collect fees from a Meme-A Cetus migration position.
public fun collect_fees_meme_a<Meme, Quote>(
    vault: &mut PresaleVault<Meme, Quote>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<Meme, Quote>,
    ctx: &mut TxContext,
) {
    let (meme, quote) = collect_position_fees(vault, cetus_config, burn_manager, pool, ctx);
    vault.split_fees(meme, quote, ctx);
}

/// Anyone may collect fees from a Meme-B Cetus migration position.
public fun collect_fees_meme_b<Meme, Quote>(
    vault: &mut PresaleVault<Meme, Quote>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<Quote, Meme>,
    ctx: &mut TxContext,
) {
    let (quote, meme) = collect_position_fees(vault, cetus_config, burn_manager, pool, ctx);
    vault.split_fees(meme, quote, ctx);
}

// === Private Functions ===

fun pool_creation_cap<Meme>(self: &VenueConfig): &PoolCreationCap {
    self.object(CreationCapKey<Meme>())
}

fun burn_into_vault<Meme, Quote>(
    presale_id: ID,
    cap_id: ID,
    fee_recipients: vector<FeeRecipient>,
    rewards_fee_bps: u64,
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
        presale_id,
        cap_id,
        &Venue(),
        pool_id,
        burn_proof,
        liquidity,
        fee_recipients,
        rewards_fee_bps,
        residual_meme.into_balance(),
        residual_quote.into_balance(),
        ctx,
    );
}

fun collect_position_fees<X, Y, Meme, Quote>(
    vault: &mut PresaleVault<Meme, Quote>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<X, Y>,
    ctx: &mut TxContext,
): (Balance<X>, Balance<Y>) {
    assert!(vault.pool_id() == object::id(pool), EPositionPoolMismatch);

    let burn_proof = vault.position_mut<_, _, _, CetusLPBurnProof>(&Venue());
    let (fee_x, fee_y) = lp_burn::collect_fee(burn_manager, cetus_config, pool, burn_proof, ctx);

    (fee_x.into_balance(), fee_y.into_balance())
}

// === Errors ===

#[error(code = 0)]
const EInvalidCoinOrder: vector<u8> = b"Migration route must match the Cetus coin order.";

#[error(code = 1)]
const EPositionPoolMismatch: vector<u8> = b"Pool must be the vault's migration pool.";

// === Imports ===

use blast_presale::{
    blast_presale::{
        Self as presale,
        EligibilityPolicy,
        FeeRecipient,
        Presale,
        PresaleCap,
        RecipientAllocation,
    },
    migration_math,
    presale_vault::{Self as vault, PresaleVault},
    venue_config::VenueConfig,
};

use cetus_clmm::{
    config::{Self, GlobalConfig},
    factory::{Self, PoolCreationCap, Pools},
    pool::Pool,
    pool_creator,
    position::Position,
};

use lp_burn::lp_burn::{Self, BurnManager, CetusLPBurnProof};

use sui::{
    balance::Balance,
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::Currency,
};

use fun pool_creation_cap as VenueConfig.pool_creation_cap;
