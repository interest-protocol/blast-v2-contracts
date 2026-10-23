// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Starts presales with this protocol's sealed witness and preserves both assets for its
/// shared market-making vault. Only commitments through this adapter earn vault fee rights.
module blast_market_maker::presale_adapter;

// === Public Types ===

/// Only this module can release liquidity from a presale it creates.
public struct Witness() has drop;

/// Committed presale settings. Retention is a fraction of the actual net migration handoff,
/// after Blast's allocations, not of the participants' token allocation or gross raise.
public struct PresaleTerms has copy, drop, store {
    token_supply: u64,
    burnable: bool,
    participant_token_bps: u64,
    liquidity_token_bps: u64,
    raise_target: u64,
    commitment_duration_ms: u64,
    liquidity_window_ms: u64,
    wallet_cap: u64,
    max_participants: u64,
    minimum_commitment: u64,
    tick_spacing: u32,
    retention_bps: u64,
}

public struct CreationCapKey() has copy, drop, store;
public struct PresaleCapKey() has copy, drop, store;
public struct VenueKey() has copy, drop, store;
public struct VenueTerms has copy, drop, store { terms: PresaleTerms, fee_rate: u64 }

// === Public Functions ===

/// Builds bounded settings; upstream finalization also validates allocations and eligibility.
public fun terms(
    token_supply: u64,
    burnable: bool,
    participant_token_bps: u64,
    liquidity_token_bps: u64,
    raise_target: u64,
    commitment_duration_ms: u64,
    liquidity_window_ms: u64,
    wallet_cap: u64,
    max_participants: u64,
    minimum_commitment: u64,
    tick_spacing: u32,
    retention_bps: u64,
): PresaleTerms {
    assert!(retention_bps <= MAX_RETENTION_BPS, EInvalidRetention);
    assert!(tick_spacing > 0, EInvalidTickSpacing);
    assert!(max_participants <= MAX_BACKERS, ETooManyParticipants);
    assert!(
        token_supply > 0 && raise_target > 0 && commitment_duration_ms > 0,
        EInvalidPresaleTerms,
    );
    let _ = presale::open_eligibility(wallet_cap, max_participants, minimum_commitment);
    let _ = presale_bps::new(participant_token_bps);
    let _ = presale_bps::new(liquidity_token_bps);

    PresaleTerms {
        token_supply,
        burnable,
        participant_token_bps,
        liquidity_token_bps,
        raise_target,
        commitment_duration_ms,
        liquidity_window_ms,
        wallet_cap,
        max_participants,
        minimum_commitment,
        tick_spacing,
        retention_bps,
    }
}

/// Reserves Cetus creation before minting, creates and shares the real presale and its vault,
/// and escrows both capabilities. No initializer, vault, position or capability escapes.
public fun create_and_share<Meme, Quote>(
    mut treasury_cap: TreasuryCap<Meme>,
    currency: &mut Currency<Meme>,
    version: &PackageVersion,
    local_policy: &BlastMarketMakerFeePolicy,
    treasury: &BlastMarketMakerTreasury,
    presale_version: &PresaleVersion,
    creation_policy: &CreationPolicy,
    upstream_fee_policy: &PresaleFeePolicy,
    partner: &Partner,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    terms: PresaleTerms,
    limits: TradingLimits,
    operator: address,
    creator: &BlastMarketMakerCreatorCap,
    signer_pk: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    version.assert_current();
    market_maker::assert_presale_limits(&limits);
    let deadline_at_ms = commitment_deadline(terms, clock);
    let mut vault = market_maker::new<Meme, Quote>(
        market_maker::presale_route(),
        terms.raise_target,
        deadline_at_ms,
        operator,
        creator,
        signer_pk,
        version,
        local_policy,
        treasury,
        ctx,
    );
    market_maker::set_trading_limits(&mut vault, limits);
    let fee_rate = config::get_fee_rate(terms.tick_spacing, cetus_config);
    let creation_cap = factory::mint_pool_creation_cap(cetus_config, pools, &mut treasury_cap, ctx);
    factory::register_permission_pair<Meme, Quote>(
        cetus_config,
        pools,
        terms.tick_spacing,
        &creation_cap,
        ctx,
    );
    market_maker::escrow_child(&mut vault, CreationCapKey(), creation_cap);
    market_maker::add_adapter_state(&mut vault, VenueKey(), VenueTerms { terms, fee_rate });

    let sale = build_sale(
        &mut vault,
        treasury_cap,
        currency,
        presale_version,
        creation_policy,
        upstream_fee_policy,
        partner,
        terms,
        clock,
        ctx,
    );
    emit_created(&vault, &sale, terms, fee_rate);
    presale::share(sale, presale_version, clock.timestamp_ms(), clock);
    market_maker::share(vault);
}

/// Buys normal presale tokens and records only the Quote actually accepted after change.
/// Core direct buyers keep their token/refund rights but acquire no market-maker fee weight.
public fun commit<Meme, Quote>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    sale: &mut Presale<Meme, Quote>,
    version: &PackageVersion,
    presale_version: &PresaleVersion,
    payment: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    version.assert_current();
    market_maker::assert_presale_route(vault);
    market_maker::assert_can_contribute(vault, version, clock);
    market_maker::assert_external(vault, object::id(sale));
    let offered = payment.value();
    let change = presale::commit_open(sale, presale_version, payment, clock, ctx);
    let accepted = offered - change.value();

    market_maker::record_presale_contribution(vault, version, accepted, clock, ctx);
    change
}

/// Core destruction proves cancellation without inventing a public lifecycle getter.
/// Principal refunds remain in the upstream presale; the unused venue cap stays escrowed.
public fun destroy_cancelled_presale_cap<Meme, Quote>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    sale: &Presale<Meme, Quote>,
    version: &PackageVersion,
) {
    version.assert_current();
    market_maker::assert_presale_route(vault);
    market_maker::assert_external(vault, object::id(sale));
    assert!(market_maker::has_escrowed_child(vault, PresaleCapKey()), ENoPresaleCap);
    let cap = market_maker::take_escrowed_child<Meme, Quote, _, presale::PresaleCap>(
        vault,
        PresaleCapKey(),
    );
    let cap_id = object::id(&cap);

    presale::destroy_cap(sale, cap);
    sui::event::emit(BlastCancelledPresaleCapDestroyed {
        vault_id: object::id(vault),
        presale_id: object::id(sale),
        cap_id,
    });
}

/// Releases the exact bound sale through our witness, retains its committed fraction of both
/// handoff assets and atomically creates/burns the base LP. Zero wrapper backers cannot veto it.
public fun migrate<Meme, Quote, CoinA, CoinB>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    sale: &mut Presale<Meme, Quote>,
    version: &PackageVersion,
    presale_version: &PresaleVersion,
    upstream_fee_policy: &PresaleFeePolicy,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    burn_manager: &mut BurnManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    version.assert_current();
    market_maker::assert_presale_route(vault);
    market_maker::assert_external(vault, object::id(sale));
    let venue = *market_maker::adapter_state<Meme, Quote, _, VenueTerms>(vault, VenueKey());
    // The reservation binds tick spacing; later venue fee-rate changes must not veto settlement.
    // fee_rate remains creation-time metadata, while real venue execution uses its live config.
    let creation_cap = market_maker::take_escrowed_child<Meme, Quote, _, PoolCreationCap>(
        vault,
        CreationCapKey(),
    );
    let (meme, quote) = presale::migrate(
        sale,
        presale_version,
        upstream_fee_policy,
        Witness(),
        clock,
        ctx,
    );

    cetus_engine::create_burn_and_activate<Meme, Quote, CoinA, CoinB>(
        vault,
        meme,
        quote,
        venue.terms.retention_bps,
        venue.terms.tick_spacing,
        cetus_config,
        pools,
        &creation_cap,
        burn_manager,
        clock,
        ctx,
    );
    market_maker::escrow_child(vault, CreationCapKey(), creation_cap);
}

// === Private Functions ===

fun commitment_deadline(terms: PresaleTerms, clock: &Clock): u64 {
    clock
        .timestamp_ms()
        .checked_add(terms.commitment_duration_ms)
        .destroy_or!(abort EInvalidPresaleTerms)
}

fun build_sale<Meme, Quote>(
    vault: &mut BlastMarketMakerVault<Meme, Quote>,
    treasury_cap: TreasuryCap<Meme>,
    currency: &mut Currency<Meme>,
    presale_version: &PresaleVersion,
    creation_policy: &CreationPolicy,
    upstream_fee_policy: &PresaleFeePolicy,
    partner: &Partner,
    terms: PresaleTerms,
    clock: &Clock,
    ctx: &mut TxContext,
): Presale<Meme, Quote> {
    let mut initializer = presale::new<Meme, Quote, Witness>(
        treasury_cap,
        presale_version,
        Witness(),
        creation_policy,
        upstream_fee_policy,
    );
    presale::set_partner(&mut initializer, presale_version, creation_policy, partner, clock);
    presale::set_supply(&mut initializer, presale_version, terms.token_supply, terms.burnable);
    presale::set_token_allocations(
        &mut initializer,
        presale_version,
        presale_bps::new(terms.participant_token_bps),
        presale_bps::new(terms.liquidity_token_bps),
        vector[],
    );
    presale::set_raise(&mut initializer, presale_version, terms.raise_target, vector[]);
    presale::set_windows(
        &mut initializer,
        presale_version,
        terms.commitment_duration_ms,
        terms.liquidity_window_ms,
    );
    presale::set_eligibility(
        &mut initializer,
        presale_version,
        presale::open_eligibility(
            terms.wallet_cap,
            terms.max_participants,
            terms.minimum_commitment,
        ),
    );
    presale::set_hard_cap(&mut initializer, presale_version, 0, true);
    // Metadata for our witness. Actual LP routing is the common vault fee pipeline.
    presale::set_fee_split(
        &mut initializer,
        presale_version,
        presale::fee_split(
            vector[
                presale::recipient_share(
                    object::id(vault).to_address(),
                    presale_bps::new(BPS_DENOMINATOR),
                ),
            ],
            presale_bps::new(0),
        ),
    );
    let (sale, cap) = presale::finalize(initializer, presale_version, currency, ctx);

    market_maker::bind_external(vault, object::id(&sale));
    market_maker::escrow_child(vault, PresaleCapKey(), cap);
    sale
}

fun emit_created<Meme, Quote>(
    vault: &BlastMarketMakerVault<Meme, Quote>,
    sale: &Presale<Meme, Quote>,
    terms: PresaleTerms,
    fee_rate: u64,
) {
    sui::event::emit(BlastPresaleMarketMakerCreated<Meme, Quote> {
        vault_id: object::id(vault),
        presale_id: object::id(sale),
        terms,
        fee_rate,
        maximum_retention_bps: MAX_RETENTION_BPS,
    });
}

// === Test-Only Functions ===

#[test_only]
/// Executes the production witness and exact-sale binding against the real presale core.
/// Returning its balances deliberately excludes the external venue from this unit fixture.
public fun migration_handoff_for_testing<Meme, Quote>(
    vault: &BlastMarketMakerVault<Meme, Quote>,
    sale: &mut Presale<Meme, Quote>,
    version: &PackageVersion,
    presale_version: &PresaleVersion,
    upstream_fee_policy: &PresaleFeePolicy,
    clock: &Clock,
    ctx: &mut TxContext,
): (sui::balance::Balance<Meme>, sui::balance::Balance<Quote>) {
    version.assert_current();
    market_maker::assert_presale_route(vault);
    market_maker::assert_external(vault, object::id(sale));

    presale::migrate(sale, presale_version, upstream_fee_policy, Witness(), clock, ctx)
}

#[test_only]
/// Exercises the same real-core initializer/finalizer as production without running external
/// interface stubs. Venue reservation and atomic pool migration still require runtime evidence.
public fun create_without_venue_for_testing<Meme, Quote>(
    treasury_cap: TreasuryCap<Meme>,
    currency: &mut Currency<Meme>,
    version: &PackageVersion,
    local_policy: &BlastMarketMakerFeePolicy,
    treasury: &BlastMarketMakerTreasury,
    presale_version: &PresaleVersion,
    creation_policy: &CreationPolicy,
    upstream_fee_policy: &PresaleFeePolicy,
    partner: &Partner,
    terms: PresaleTerms,
    limits: TradingLimits,
    operator: address,
    creator: &BlastMarketMakerCreatorCap,
    signer_pk: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    version.assert_current();
    market_maker::assert_presale_limits(&limits);
    let mut vault = market_maker::new<Meme, Quote>(
        market_maker::presale_route(),
        terms.raise_target,
        commitment_deadline(terms, clock),
        operator,
        creator,
        signer_pk,
        version,
        local_policy,
        treasury,
        ctx,
    );
    market_maker::set_trading_limits(&mut vault, limits);
    market_maker::add_adapter_state(&mut vault, VenueKey(), VenueTerms { terms, fee_rate: 0 });
    let sale = build_sale(
        &mut vault,
        treasury_cap,
        currency,
        presale_version,
        creation_policy,
        upstream_fee_policy,
        partner,
        terms,
        clock,
        ctx,
    );

    emit_created(&vault, &sale, terms, 0);
    presale::share(sale, presale_version, clock.timestamp_ms(), clock);
    market_maker::share(vault);
}

// === Events ===

public struct BlastPresaleMarketMakerCreated<phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    presale_id: ID,
    terms: PresaleTerms,
    fee_rate: u64,
    maximum_retention_bps: u64,
}

public struct BlastCancelledPresaleCapDestroyed has copy, drop {
    vault_id: ID,
    presale_id: ID,
    cap_id: ID,
}

// === Constants ===

const BPS_DENOMINATOR: u64 = 10_000;
const MAX_BACKERS: u64 = 10_000;
const MAX_RETENTION_BPS: u64 = 5_000;

// === Errors ===

#[error(code = 0)]
const EInvalidRetention: vector<u8> =
    b"Presale retention may use at most half the net migration handoff.";
#[error(code = 1)]
const EInvalidTickSpacing: vector<u8> = b"The pool tick spacing must be positive.";
#[error(code = 2)]
const ETooManyParticipants: vector<u8> = b"The presale exceeds the protocol's backer bound.";
#[error(code = 3)]
const EInvalidPresaleTerms: vector<u8> = b"The presale amounts or time window are invalid.";
#[error(code = 4)]
const ENoPresaleCap: vector<u8> = b"The cancelled presale capability has already been destroyed.";

// === Imports ===

use blast_partners::blast_partners::Partner;
use blast_presale::{
    blast_presale::{Self as presale, Presale},
    blast_presale_package::PackageVersion as PresaleVersion,
    bps as presale_bps,
    creation_policy::CreationPolicy,
    fee_policy::FeePolicy as PresaleFeePolicy,
};
use blast_market_maker::{
    market_maker::{Self, BlastMarketMakerCreatorCap, BlastMarketMakerVault, TradingLimits},
    market_maker_fee_policy::BlastMarketMakerFeePolicy,
    cetus_engine,
    package_version::BlastMarketMakerVersion as PackageVersion,
    protocol_treasury::BlastMarketMakerTreasury,
};
use cetus_clmm::{config::{Self, GlobalConfig}, factory::{Self, PoolCreationCap, Pools}};
use lp_burn::lp_burn::BurnManager;
use sui::{clock::Clock, coin::{Coin, TreasuryCap}, coin_registry::Currency};
