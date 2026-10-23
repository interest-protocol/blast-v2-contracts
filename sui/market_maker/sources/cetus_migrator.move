// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Independent bonding-curve adapter. Existing Launchpad and Migrators packages remain untouched.
module blast_market_maker::cetus_migrator;

// === Public Types ===

/// Sealed migration identity; no external constructor or witness factory exists.
public struct Witness() has drop;
public struct TicketKey() has copy, drop, store;
public struct CreationCapKey() has copy, drop, store;
public struct CurveCapKey() has copy, drop, store;
public struct TermsKey() has copy, drop, store;

/// Ticket internals have no public cross-package getters: unverified creator/burn hints require
/// source/event preflight. Runtime cap intake separately checks the real core's live authority.
public struct CurveTerms has copy, drop, store {
    target: u64,
    deadline_at_ms: u64,
    initial_buy_budget: u64,
    initial_min_meme: u64,
    initial_idle_quote: u64,
    virtual_quote: u64,
    graduation_target: u64,
    curve_meme_bps: u64,
    lp_meme_bps: u64,
    lp_quote_bps: u64,
    tick_spacing: u32,
    unverified_creator: CreatorRecipient,
    expected_decimals: u8,
    unverified_burnable: bool,
    unverified_sell_burn_bps: u64,
}

/// Immutable local inputs plus explicitly unverified ticket hints; only live cap intake proves fee authority.
public struct CommittedTerms has copy, drop, store {
    terms: CurveTerms,
    ticket_id: ID,
    ticket_supplier: address,
    partner_id: ID,
    fee_rate: u64,
}

// === Public Functions ===

/// The initial buy may intentionally graduate immediately. Backers commit its exact budget.
public fun new_terms(
    target: u64,
    deadline_at_ms: u64,
    initial_buy_budget: u64,
    initial_min_meme: u64,
    initial_idle_quote: u64,
    virtual_quote: u64,
    graduation_target: u64,
    curve_meme_bps: u64,
    lp_meme_bps: u64,
    lp_quote_bps: u64,
    tick_spacing: u32,
    unverified_creator: CreatorRecipient,
    expected_decimals: u8,
    unverified_burnable: bool,
    unverified_sell_burn_bps: u64,
): CurveTerms {
    assert!(target >= 10_000_000 && virtual_quote > 0 && graduation_target > 0, EInvalidTerms);
    assert!(initial_buy_budget > 0 && initial_min_meme > 0 && tick_spacing > 0, EInvalidTerms);
    assert!(
        curve_meme_bps > 0 && lp_meme_bps > 0 && curve_meme_bps + lp_meme_bps <= 10_000,
        EInvalidTerms,
    );
    assert!(
        lp_quote_bps > 0 && lp_quote_bps <= 10_000 && expected_decimals <= 9 && unverified_sell_burn_bps <= 5_000,
        EInvalidTerms,
    );
    CurveTerms {
        target,
        deadline_at_ms,
        initial_buy_budget,
        initial_min_meme,
        initial_idle_quote,
        virtual_quote,
        graduation_target,
        curve_meme_bps,
        lp_meme_bps,
        lp_quote_bps,
        tick_spacing,
        unverified_creator,
        expected_decimals,
        unverified_burnable,
        unverified_sell_burn_bps,
    }
}

/// No owned vault or initializer escapes. Funding discovers only atomically shared vaults.
/// The creator cap binds the new instance; it does not authorize a mutation of an existing vault.
public fun create_and_share<Meme>(
    ticket: LaunchTicket<Meme>,
    currency: &Currency<Meme>,
    partner: &Partner,
    version: &PackageVersion,
    policy: &BlastMarketMakerFeePolicy,
    treasury: &BlastMarketMakerTreasury,
    config: &GlobalConfig,
    terms: CurveTerms,
    limits: TradingLimits,
    operator: address,
    creator: &BlastMarketMakerCreatorCap,
    signer_pk: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    version.assert_current();
    assert_funding_window(clock.timestamp_ms(), terms.deadline_at_ms);
    assert!(
        currency.symbol().length() <= 32 && currency.decimals() == terms.expected_decimals,
        EUnsupportedCurrency,
    );
    let fee_rate = cetus_config::get_fee_rate(terms.tick_spacing, config);
    terms.preflight_profile<Meme>();
    let mut vault = market_maker::new_and_transfer_operator_cap<Meme, SUI>(
        market_maker::curve_route(),
        terms.target,
        terms.deadline_at_ms,
        operator,
        creator,
        signer_pk,
        version,
        policy,
        treasury,
        ctx,
    );
    vault.set_trading_limits(limits);
    vault.assert_initial_budget(terms.initial_buy_budget, terms.initial_idle_quote);
    let ticket_id = object::id(&ticket);
    vault.escrow_child(TicketKey(), ticket);
    vault.add_adapter_state(
        TermsKey(),
        CommittedTerms {
            terms,
            ticket_id,
            ticket_supplier: ctx.sender(),
            partner_id: object::id(partner),
            fee_rate,
        },
    );
    sui::event::emit(BlastCurveMarketMakerCreated<Meme> {
        vault_id: object::id(&vault),
        ticket_id,
        partner_id: object::id(partner),
        terms,
        fee_rate,
    });

    vault.share();
}

/// The caller funds Blast's creation fee separately. Stored backer terms cannot be repaired or repriced.
public fun launch_buy_and_share<Meme>(
    vault: &mut BlastMarketMakerVault<Meme, SUI>,
    version: &PackageVersion,
    core_version: &CoreVersion,
    launch_config: &LaunchConfig,
    runtime_config: &RuntimeConfig,
    currency: &mut Currency<Meme>,
    partner: &Partner,
    config: &GlobalConfig,
    pools: &mut Pools,
    creation_fee: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    version.assert_current();
    vault.assert_can_contribute(version, clock);
    let committed = *vault.adapter_state<Meme, SUI, _, CommittedTerms>(TermsKey());
    committed.assert_committed_partner(partner);
    let terms = committed.terms;
    assert!(
        cetus_config::get_fee_rate(terms.tick_spacing, config) == committed.fee_rate,
        EVenueRateChanged,
    );
    let funding = vault.charge_raise_fee_and_enter_curve(version, clock);
    let ticket = vault.take_escrowed_child<Meme, SUI, _, LaunchTicket<Meme>>(TicketKey());
    assert!(object::id(&ticket) == committed.ticket_id, EWrongTicket);
    let mut initializer = launch::new<Meme, SUI, Witness>(
        ticket,
        core_version,
        launch_config,
        Witness(),
        terms.tick_spacing,
        committed.fee_rate,
    );
    initializer.apply_committed_partner(&committed, core_version, launch_config, partner, clock);
    let creation_cap = factory::mint_pool_creation_cap(
        config,
        pools,
        initializer.treasury_cap_mut(Witness()),
        ctx,
    );
    factory::register_permission_pair<Meme, SUI>(
        config,
        pools,
        terms.tick_spacing,
        &creation_cap,
        ctx,
    );
    initializer.set_virtual_quote(core_version, terms.virtual_quote);
    initializer.set_graduation_target(core_version, terms.graduation_target);
    initializer.set_allocation_plan(
        core_version,
        allocation::plan(
            bps::new(terms.curve_meme_bps),
            bps::new(terms.lp_meme_bps),
            bps::new(terms.lp_quote_bps),
            vector[],
        ),
    );
    initializer.set_lp_fee_split(
        core_version,
        allocation::fee_split(bps::new(10_000), bps::new(0), bps::new(0), bps::new(0), vector[]),
    );
    initializer.set_opening_round(core_version, 0);
    let mut launch = initializer.finalize(core_version, currency, launch_config, creation_fee, ctx);
    vault.bind_external(object::id(&launch));
    vault.escrow_child(CreationCapKey(), creation_cap);
    vault.join_capital(balance::zero(), funding);
    let quote = vault.take_capital_quote(terms.initial_buy_budget).into_coin(ctx);
    let (meme, change) = launch.buy(
        core_version,
        runtime_config,
        quote,
        terms.initial_min_meme,
        ctx,
    );
    assert!(meme.value() > 0, EZeroInitialOutput);
    let spent = terms.initial_buy_budget - change.value();
    vault.join_capital(meme.into_balance(), change.into_balance());
    vault.record_initial_buy(spent, terms.initial_idle_quote);

    launch.share(core_version, clock);
}

public fun transfer_unused_ticket_to_supplier<Meme>(
    vault: &mut BlastMarketMakerVault<Meme, SUI>,
    version: &PackageVersion,
) {
    version.assert_current();
    vault.assert_refunding();
    let committed = *vault.adapter_state<Meme, SUI, _, CommittedTerms>(TermsKey());
    let ticket = vault.take_escrowed_child<Meme, SUI, _, LaunchTicket<Meme>>(TicketKey());
    let ticket_id = object::id(&ticket);
    transfer::public_transfer(ticket, committed.ticket_supplier);
    sui::event::emit(BlastUnusedTicketReturned {
        vault_id: object::id(vault),
        ticket_id,
        recipient: committed.ticket_supplier,
    });
}

/// Permissionless intake authenticates the live cap against the exact bound launch.
public fun escrow_curve_fee_cap<Meme>(
    vault: &mut BlastMarketMakerVault<Meme, SUI>,
    version: &PackageVersion,
    launch: &Launch<Meme, SUI>,
    cap: CurveFeeCap<Meme>,
) {
    version.assert_current();
    vault.assert_external(object::id(launch));
    launch.assert_curve_fee_cap(&cap);
    vault.replace_escrowed_cap(cap);
}

public fun receive_and_escrow_curve_fee_cap<Meme>(
    vault: &mut BlastMarketMakerVault<Meme, SUI>,
    version: &PackageVersion,
    launch: &Launch<Meme, SUI>,
    cap: Receiving<CurveFeeCap<Meme>>,
) {
    version.assert_current();
    vault.assert_external(object::id(launch));
    let cap = vault.receive_curve_cap(cap);
    launch.assert_curve_fee_cap(&cap);
    vault.replace_escrowed_cap(cap);
}

public fun claim_and_credit_curve_fees<Meme>(
    vault: &mut BlastMarketMakerVault<Meme, SUI>,
    version: &PackageVersion,
    launch: &mut Launch<Meme, SUI>,
    core_version: &CoreVersion,
    ctx: &mut TxContext,
) {
    version.assert_current();
    vault.assert_external(object::id(launch));
    let cap = vault.escrowed_child<Meme, SUI, _, CurveFeeCap<Meme>>(CurveCapKey());
    let (meme, quote) = launch.claim_creator_fees(core_version, cap, ctx);

    vault.credit_curve_fees(meme.into_balance(), quote.into_balance());
}

public fun migrate_burn_and_activate<Meme, CoinA, CoinB>(
    vault: &mut BlastMarketMakerVault<Meme, SUI>,
    version: &PackageVersion,
    launch: &mut Launch<Meme, SUI>,
    core_version: &CoreVersion,
    currency: &mut Currency<Meme>,
    config: &GlobalConfig,
    pools: &mut Pools,
    manager: &mut BurnManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    version.assert_current();
    vault.assert_curve();
    vault.assert_external(object::id(launch));
    let committed = *vault.adapter_state<Meme, SUI, _, CommittedTerms>(TermsKey());
    // After launch, fee-tier changes must not strand graduated principal. Pool creation uses
    // the live rate for the already committed tick spacing, as the frozen core migrator does.
    let creation_cap = vault.take_escrowed_child<Meme, SUI, _, PoolCreationCap>(CreationCapKey());
    let (meme, quote) = launch.migrate(core_version, currency, Witness(), ctx);

    vault.create_burn_and_activate<Meme, SUI, CoinA, CoinB>(
        meme,
        quote,
        0,
        committed.terms.tick_spacing,
        config,
        pools,
        &creation_cap,
        manager,
        clock,
        ctx,
    );
    vault.restore_escrowed_child(CreationCapKey(), creation_cap);
}

/// Curve trading uses original core entry points and rejoins every returned asset to capital.
public fun buy<Meme>(
    vault: &mut BlastMarketMakerVault<Meme, SUI>,
    cap: &BlastMarketMakerOperatorCap,
    version: &PackageVersion,
    launch: &mut Launch<Meme, SUI>,
    core_version: &CoreVersion,
    runtime: &RuntimeConfig,
    quote_input: u64,
    min_meme: u64,
    issued_at_ms: u64,
    expires_at_ms: u64,
    signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    version.assert_current();
    vault.assert_external(object::id(launch));
    assert!(quote_input > 0 && min_meme > 0, EInvalidTrade);
    let action = risk::new_curve_buy(quote_input, min_meme);
    vault.authorize_action(
        version,
        option::some(object::id(cap)),
        action,
        issued_at_ms,
        expires_at_ms,
        &signature,
        clock,
    );
    let input = vault.take_capital_quote(quote_input).into_coin(ctx);
    let (meme, change) = launch.buy(core_version, runtime, input, min_meme, ctx);
    assert!(meme.value() >= min_meme, EInvalidTrade);
    let spent = quote_input - change.value();
    vault.join_capital(meme.into_balance(), change.into_balance());

    vault.finish_action(action, 0, spent, spent, 0, clock);
}

public fun sell<Meme>(
    vault: &mut BlastMarketMakerVault<Meme, SUI>,
    cap: &BlastMarketMakerOperatorCap,
    version: &PackageVersion,
    launch: &mut Launch<Meme, SUI>,
    core_version: &CoreVersion,
    runtime: &RuntimeConfig,
    meme_input: u64,
    min_quote: u64,
    issued_at_ms: u64,
    expires_at_ms: u64,
    signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    version.assert_current();
    vault.assert_external(object::id(launch));
    assert!(meme_input > 0 && min_quote > 0, EInvalidTrade);
    let action = risk::new_curve_sell(meme_input, min_quote);
    vault.authorize_action(
        version,
        option::some(object::id(cap)),
        action,
        issued_at_ms,
        expires_at_ms,
        &signature,
        clock,
    );
    let input = vault.take_capital_meme(meme_input).into_coin(ctx);
    let quote = launch.sell(core_version, runtime, input, min_quote, ctx);
    let basis = sell_quote_basis_up(quote.value());
    vault.join_capital(balance::zero(), quote.into_balance());

    vault.finish_action(action, meme_input, 0, basis, 0, clock);
}

// === Private Functions ===

/// Rejects partner substitution before any funding mutation or external venue effects.
fun assert_committed_partner(committed: &CommittedTerms, partner: &Partner) {
    assert!(committed.partner_id == object::id(partner), EWrongPartner);
}

/// Uses the core's real allowlist and fixed initializer partner; no local partner split exists.
fun apply_committed_partner<Meme>(
    initializer: &mut LaunchInitializer<Meme, SUI>,
    committed: &CommittedTerms,
    core_version: &CoreVersion,
    config: &LaunchConfig,
    partner: &Partner,
    clock: &Clock,
) {
    committed.assert_committed_partner(partner);
    initializer.set_partner(core_version, config, partner, clock);
}

/// Bounds capital lockup even when an upstream private profile later rejects launch.
fun assert_funding_window(now_at_ms: u64, deadline_at_ms: u64) {
    assert!(deadline_at_ms > now_at_ms, EInvalidTerms);
    assert!(deadline_at_ms - now_at_ms <= MAX_FUNDING_WINDOW_DURATION_MS, EInvalidTerms);
}

fun replace_escrowed_cap<Meme>(
    vault: &mut BlastMarketMakerVault<Meme, SUI>,
    cap: CurveFeeCap<Meme>,
) {
    let cap_id = object::id(&cap);
    if (vault.has_escrowed_child(CurveCapKey())) {
        let previous = vault.escrowed_child<Meme, SUI, _, CurveFeeCap<Meme>>(CurveCapKey());
        assert!(object::id(previous) != cap_id, ECurveCapUnchanged);
        let previous = vault.take_escrowed_child<Meme, SUI, _, CurveFeeCap<Meme>>(CurveCapKey());
        previous.destroy_curve_fee_cap();
    };
    vault.escrow_child(CurveCapKey(), cap);
    sui::event::emit(BlastCurveCapEscrowed { vault_id: object::id(vault), cap_id });
}

/// Frozen core Quote-fee ceiling is 10%; include one atom for its ceiling rounding.
fun sell_quote_basis_up(net: u64): u64 {
    let basis = (((net as u128) + 1) * 10).div_ceil(9);
    assert!(basis <= (std::u64::max_value!() as u128), EInvalidTrade);
    basis as u64
}

/// Reproduce only the frozen three-way no-recipient allocation, then ask the admitted venue's
/// pure seed math before accepting funding. Protocol allocation remains checked by core finalize.
fun preflight_profile<Meme>(terms: CurveTerms) {
    let supply = 1_000_000_000u64 * std::u64::pow(10, terms.expected_decimals);
    let protocol_bps = 10_000 - terms.curve_meme_bps - terms.lp_meme_bps;
    let curve = market_maker_math::apply_down(supply, terms.curve_meme_bps);
    let mut lp_meme = market_maker_math::apply_down(supply, terms.lp_meme_bps);
    let protocol = market_maker_math::apply_up(supply, protocol_bps);
    if (supply > curve + lp_meme + protocol) {
        let curve_remainder = (supply as u128) * (terms.curve_meme_bps as u128) % 10_000;
        let lp_remainder = (supply as u128) * (terms.lp_meme_bps as u128) % 10_000;
        if (lp_remainder > curve_remainder) lp_meme = lp_meme + 1;
    };
    let lp_quote =
        terms.graduation_target - market_maker_math::apply_up(terms.graduation_target, 10_000 - terms.lp_quote_bps);
    assert!(lp_meme > 0 && lp_quote > 0, EUnsupportedMigrationProfile);
    let meme_is_a = factory::is_right_order<Meme, SUI>();
    let sqrt_price = venue_math::sqrt_price_x64_down(lp_meme, lp_quote, meme_is_a);
    let (lower, upper) = pool_creator::full_range_tick_range(terms.tick_spacing);
    let (_, needed_a, needed_b) = clmm_math::get_liquidity_by_amount(
        integer_mate::i32::from_u32(lower),
        integer_mate::i32::from_u32(upper),
        integer_mate::i32::zero(),
        sqrt_price,
        if (lp_meme >= lp_quote) lp_meme else lp_quote,
        (lp_meme >= lp_quote) == meme_is_a,
    );
    let (a, b) = if (meme_is_a) (lp_meme, lp_quote) else (lp_quote, lp_meme);
    assert!(
        needed_a > 0 && needed_b > 0 && needed_a <= a && needed_b <= b,
        EUnsupportedMigrationProfile,
    );
}

// === Test-Only Functions ===

#[test_only]
public fun assert_funding_window_for_testing(now_at_ms: u64, deadline_at_ms: u64) {
    assert_funding_window(now_at_ms, deadline_at_ms);
}

#[test_only]
public fun assert_committed_partner_for_testing(committed: &CommittedTerms, partner: &Partner) {
    assert_committed_partner(committed, partner);
}

#[test_only]
public fun apply_committed_partner_for_testing<Meme>(
    initializer: &mut LaunchInitializer<Meme, SUI>,
    committed: &CommittedTerms,
    core_version: &CoreVersion,
    config: &LaunchConfig,
    partner: &Partner,
    clock: &Clock,
) {
    apply_committed_partner(initializer, committed, core_version, config, partner, clock);
}

/// Fixtures exercise immutable partner matching and the real public core initializer without Cetus.
#[test_only]
public fun committed_terms_for_testing(
    terms: CurveTerms,
    ticket_id: ID,
    ticket_supplier: address,
    partner: &Partner,
    fee_rate: u64,
): CommittedTerms {
    CommittedTerms { terms, ticket_id, ticket_supplier, partner_id: object::id(partner), fee_rate }
}

// === Events ===

public struct BlastCurveMarketMakerCreated<phantom Meme> has copy, drop {
    vault_id: ID,
    ticket_id: ID,
    partner_id: ID,
    terms: CurveTerms,
    fee_rate: u64,
}
public struct BlastCurveCapEscrowed has copy, drop { vault_id: ID, cap_id: ID }
public struct BlastUnusedTicketReturned has copy, drop {
    vault_id: ID,
    ticket_id: ID,
    recipient: address,
}

// === Constants ===

const MAX_FUNDING_WINDOW_DURATION_MS: u64 = 604_800_000;

// === Errors ===

#[error(code = 0)]
const EInvalidTerms: vector<u8> =
    b"Curve terms must have positive targets, executable allocations and bounded ticket controls.";
#[error(code = 1)]
const EUnsupportedCurrency: vector<u8> =
    b"The currency symbol or decimals do not match the admitted profile.";
#[error(code = 2)]
const EVenueRateChanged: vector<u8> = b"The committed Cetus tier fee rate changed.";
#[error(code = 3)]
const EWrongTicket: vector<u8> = b"The original committed ticket identity does not match.";
#[error(code = 4)]
const EZeroInitialOutput: vector<u8> = b"The initial purchase must return positive Meme.";
#[error(code = 5)]
const EInvalidTrade: vector<u8> = b"Trade input, output or conservative basis is invalid.";
#[error(code = 6)]
const ECurveCapUnchanged: vector<u8> =
    b"A replacement curve cap must be a different live capability.";
#[error(code = 7)]
const EUnsupportedMigrationProfile: vector<u8> =
    b"The frozen migration profile cannot cover a positive base-pool seed.";

#[error(code = 8)]
const EWrongPartner: vector<u8> =
    b"The partner must match the creator's immutable market maker choice.";

// === Imports ===

use blast_fun::{
    allocation,
    blast_fun::PackageVersion as CoreVersion,
    bps,
    creator_authority::{Self, CreatorRecipient, CurveFeeCap},
    launch::{Self, Launch, LaunchInitializer},
    launch_config::LaunchConfig,
    launch_ticket::LaunchTicket,
    runtime_config::RuntimeConfig,
};
use blast_partners::blast_partners::Partner;
use blast_market_maker::{
    market_maker::{
        Self,
        BlastMarketMakerCreatorCap,
        BlastMarketMakerVault,
        BlastMarketMakerOperatorCap,
        TradingLimits,
    },
    market_maker_fee_policy::BlastMarketMakerFeePolicy,
    market_maker_math,
    cetus_engine,
    package_version::BlastMarketMakerVersion as PackageVersion,
    protocol_treasury::BlastMarketMakerTreasury,
    risk,
    venue_math,
};
use cetus_clmm::{
    clmm_math,
    config::{Self as cetus_config, GlobalConfig},
    factory::{Self, Pools, PoolCreationCap},
    pool_creator,
};
use lp_burn::lp_burn::BurnManager;
use sui::{
    balance,
    clock::Clock,
    coin::Coin,
    coin_registry::Currency,
    sui::SUI,
    transfer::Receiving,
};

use fun apply_committed_partner as LaunchInitializer.apply_committed_partner;
use fun replace_escrowed_cap as BlastMarketMakerVault.replace_escrowed_cap;
use fun cetus_engine::create_burn_and_activate as BlastMarketMakerVault.create_burn_and_activate;
