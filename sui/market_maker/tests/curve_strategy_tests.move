// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_market_maker::curve_strategy_tests;

// === Constants ===

const ROOT: address = @0xA;
const BUY_INPUT: u64 = 100_000;
const SELL_INPUT: u64 = 1_000_000_000_000;

// === Test-Only Types ===

public struct CURVE_STRATEGY_TESTS has drop {}
public struct TestMigrationWitness() has drop;
public struct Fixture {
    scenario: Scenario,
    clock: Clock,
    version: PackageVersion,
    core_version: CoreVersion,
    runtime: RuntimeConfig,
    vault: BlastMarketMakerVault<CURVE_STRATEGY_TESTS, SUI>,
    launch: Launch<CURVE_STRATEGY_TESTS, SUI>,
    operator: BlastMarketMakerOperatorCap,
    partner: Option<Partner>,
}

// === Tests ===

#[test]
fun signed_public_curve_buy_sell_and_live_cap_fee_credit_preserve_custody() {
    let mut f = start();
    f.next_tx!(ROOT, |f| {
        f.buy();
        let (bought_meme, quote_after_buy) = f.vault.capital_for_testing();
        assert!(bought_meme > SELL_INPUT);
        assert_eq!(quote_after_buy, 19_000_000 - BUY_INPUT);
        f.sell();
        let (meme_after_sell, quote_after_sell) = f.vault.capital_for_testing();
        assert_eq!(meme_after_sell, bought_meme - SELL_INPUT);
        assert!(quote_after_sell > quote_after_buy);
        assert_eq!(sui::event::events_by_type<market_maker::BlastActionExecuted>().length(), 2);
        let (_, creator_meme, _, creator_quote) = f.launch.fee_totals_for_testing();
        assert!(creator_meme > 0 && creator_quote > 0);
        f.claim_and_escrow_cap();
        f.credit_curve_fees();
        let (meme_after_fees, quote_after_fees) = f.vault.capital_for_testing();
        let (
            available_meme,
            available_quote,
            reserved_meme,
            reserved_quote,
        ) = f.vault.fee_balances(
        );
        assert_eq!(meme_after_fees, meme_after_sell);
        assert_eq!(quote_after_fees, quote_after_sell);
        assert_eq!(available_meme, creator_meme);
        assert_eq!(available_quote, creator_quote);
        assert_eq!(reserved_meme, 0);
        assert_eq!(reserved_quote, 0);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = risk::EInvalidSignature, location = blast_market_maker::risk)]
fun public_curve_buy_rejects_replay_before_spending_again() {
    let mut f = start();
    f.next_tx!(ROOT, |f| { f.buy(); f.buy(); });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::ECreatorCapNotLive,
        location = blast_fun::launch,
    ),
]
fun reassigned_core_cap_cannot_credit_vault_creator_fees() {
    let mut f = start();
    f.next_tx!(ROOT, |f| {
        f.claim_and_escrow_cap();
        f.reassign_cap();
        f.credit_curve_fees();
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = cetus_migrator::EWrongPartner,
        location = blast_market_maker::cetus_migrator,
    ),
]
fun immutable_market_maker_partner_rejects_a_different_object() {
    let mut f = start_with_partner(true, true);
    f.next_tx!(ROOT, |f| { f.assert_wrong_partner(); });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EPartnerNotAccepted,
        location = blast_fun::launch_config,
    ),
]
fun initializer_requires_upstream_partner_admission() {
    let f = start_with_partner(true, false);
    f.end();
}

#[test]
fun finalized_partner_gets_core_fee_share_once_without_touching_creator_or_local_fees() {
    let mut f = start_with_partner(true, true);
    let expected_partner: u64;
    let expected_treasury: u64;
    f.next_tx!(ROOT, |f| {
        f.direct_core_buy();
        let (_, creator_meme, protocol_quote, creator_quote) = f.launch.fee_totals_for_testing(
        );
        assert!(protocol_quote > 0 && creator_quote > 0);
        let sui_creation = f.launch.protocol_sui_for_testing();
        assert_eq!(sui_creation, 1_000);
        let (
            meme_before,
            quote_before,
            reserve_meme_before,
            reserve_quote_before,
        ) = f.vault.fee_balances();
        f.claim_partner_fees();
        let (
            protocol_meme_left,
            creator_meme_left,
            protocol_quote_left,
            creator_quote_left,
        ) = f.launch.fee_totals_for_testing();
        assert_eq!(protocol_meme_left, 0);
        assert_eq!(protocol_quote_left, 0);
        assert_eq!(creator_meme_left, creator_meme);
        assert_eq!(creator_quote_left, creator_quote);
        assert_eq!(f.launch.protocol_sui_for_testing(), 0);
        let payments = sui::event::events_by_type<partners::PartnerPaid<SUI>>();
        assert_eq!(payments.length(), 2);
        let mut paid = 0;
        payments.do!(|payment| {
            let (partner_id, amount) = partners::partner_paid_fields(&payment);
            assert_eq!(partner_id, object::id(f.partner.borrow()));
            paid = paid + amount;
        });
        assert_eq!(paid, protocol_quote * 4_000 / 10_000 + 400);
        let (
            meme_after,
            quote_after,
            reserve_meme_after,
            reserve_quote_after,
        ) = f.vault.fee_balances();
        assert_eq!(meme_after, meme_before);
        assert_eq!(quote_after, quote_before);
        assert_eq!(reserve_meme_after, reserve_meme_before);
        assert_eq!(reserve_quote_after, reserve_quote_before);
        expected_partner = paid;
        expected_treasury = protocol_quote + sui_creation - paid;
    });
    f.next_tx!(@0xD, |f| { assert_eq!(f.take_two_sui(), expected_partner); });
    f.next_tx!(ROOT, |f| { assert_eq!(f.take_two_sui(), expected_treasury); });
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::ENothingAccrued, location = blast_fun::fees)]
fun partner_protocol_fee_claim_cannot_pay_twice() {
    let mut f = start_with_partner(true, true);
    f.next_tx!(ROOT, |f| { f.direct_core_buy(); f.claim_partner_fees(); f.claim_partner_fees(); });
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EPartnerMismatch, location = blast_fun::launch)]
fun finalized_partner_cannot_be_omitted_from_core_protocol_fee_claim() {
    let mut f = start_with_partner(true, true);
    f.next_tx!(ROOT, |f| { f.claim_without_partner(); });
    f.end();
}

// === Test Helpers ===

fun take_two_sui(f: &Fixture): u64 {
    let first = f.scenario.take_from_sender<coin::Coin<SUI>>();
    let second = f.scenario.take_from_sender<coin::Coin<SUI>>();
    let total = first.value() + second.value();
    first.burn_for_testing();
    second.burn_for_testing();
    total
}

fun committed_for_partner(partner: &Partner): cetus_migrator::CommittedTerms {
    cetus_migrator::committed_terms_for_testing(
        cetus_migrator::new_terms(
            20_000_000,
            2_000,
            100_000,
            1,
            0,
            5_000_000,
            25_000_000,
            8_000,
            2_000,
            10_000,
            200,
            creator_authority::new_address(ROOT),
            6,
            false,
            0,
        ),
        object::id_from_address(@0xCAFE),
        ROOT,
        partner,
        10_000,
    )
}

fun assert_wrong_partner(f: &mut Fixture) {
    let wrong = partners::new_for_testing(@0xD, 4_000, f.scenario.ctx());
    let committed = committed_for_partner(f.partner.borrow());
    committed.assert_committed_partner_for_testing(&wrong);
    destroy(wrong);
}

fun direct_core_buy(f: &mut Fixture) {
    let Fixture { launch, core_version, runtime, scenario, .. } = f;
    let payment = coin::mint_for_testing<SUI>(100_000, scenario.ctx());
    let (meme, change) = launch.buy(core_version, runtime, payment, 1, scenario.ctx());
    meme.burn_for_testing();
    change.burn_for_testing();
}

fun claim_partner_fees(f: &mut Fixture) {
    let Fixture { launch, core_version, runtime, partner, clock, scenario, .. } = f;
    launch.claim_protocol_fees_with_partner(
        core_version,
        runtime,
        partner.borrow(),
        clock,
        scenario.ctx(),
    );
}

fun claim_without_partner(f: &mut Fixture) {
    let Fixture { launch, core_version, runtime, scenario, .. } = f;
    launch.claim_protocol_fees(core_version, runtime, scenario.ctx());
}

macro fun fixture_next_tx($fixture: &mut Fixture, $sender: address, $body: |&mut Fixture|) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $body(fixture);
}

fun buy(f: &mut Fixture) {
    let Fixture { vault, launch, core_version, version, runtime, scenario, clock, operator, .. } =
        f;
    vault.buy(
        operator,
        version,
        launch,
        core_version,
        runtime,
        BUY_INPUT,
        1,
        100,
        200,
        buy_signature(),
        clock,
        scenario.ctx(),
    );
}

fun sell(f: &mut Fixture) {
    let Fixture { vault, launch, core_version, version, runtime, scenario, clock, operator, .. } =
        f;
    vault.sell(
        operator,
        version,
        launch,
        core_version,
        runtime,
        SELL_INPUT,
        1,
        100,
        200,
        sell_signature(),
        clock,
        scenario.ctx(),
    );
}

fun claim_and_escrow_cap(f: &mut Fixture) {
    let Fixture { vault, launch, core_version, version, runtime, scenario, clock, .. } = f;
    let (cap, metadata) = launch.claim_creator_caps(
        core_version,
        runtime,
        option::none(),
        clock,
        scenario.ctx(),
    );
    vault.escrow_curve_fee_cap(version, launch, cap);
    destroy(metadata);
}

fun credit_curve_fees(f: &mut Fixture) {
    let Fixture { vault, launch, core_version, version, scenario, .. } = f;
    vault.claim_and_credit_curve_fees(version, launch, core_version, scenario.ctx());
}

fun reassign_cap(f: &mut Fixture) {
    let Fixture { launch, core_version, scenario, .. } = f;
    launch.reassign_curve_fee_cap(
        core_version,
        &blast_acl::witness_for_testing<CreatorAdmin>(),
        ROOT,
        scenario.ctx(),
    );
}

// RFC8032 test key. These signatures cover complete deterministic fixture payloads, not a bypass.
fun buy_signature(): vector<u8> {
    x"d0590591dc5812981f06231b6a9f31d6c6db27ddb297391b1fd7f15e8ab62a97500da4b6a561bba8e83390d803391b54d20f0323fa1579284d77aa42241fd60f"
}

fun sell_signature(): vector<u8> {
    x"cd4c13a48117c705bf640fc907e9aa334bb99c33fc0786934d894b79c8e3fe7b2e017af3ebf3eb172c673a03d7ba865f39f3ec95b09f8c6ebb69b3d0d4187403"
}

/// A real frozen-core Launch, currency, curve and core fee ledger; no venue linkage stub executes.
fun start(): Fixture { start_with_partner(false, false) }

fun start_with_partner(with_partner: bool, admitted: bool): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let ctx = scenario.ctx();
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(100);
    let core_version = blast_fun::blast_fun::new_for_testing(ctx);
    let mut config = launch_config::new_for_testing(ctx);
    config.set_quote_allowed<SUI>(
        &core_version,
        &blast_acl::witness_for_testing<ListingAdmin>(),
        true,
    );
    config.set_migration_witness_allowed<TestMigrationWitness>(
        &core_version,
        &blast_acl::witness_for_testing<AdapterAdmin>(),
        true,
    );
    config.set_trade_fees(
        &core_version,
        &blast_acl::witness_for_testing<FeeAdmin>(),
        bps::new(100),
        bps::new(250),
    );
    let mut runtime = runtime_config::new_disabled_for_testing(ctx);
    let creator = market_maker::new_creator_cap(ctx);
    let treasury = protocol_treasury::new_for_testing(ctx);
    let policy = market_maker_fee_policy::new_for_testing(object::id(&treasury), ctx);
    let version = package_version::new_for_testing(
        object::id(&treasury),
        object::id(&policy),
        ctx,
    );
    let mut vault = market_maker::new_and_transfer_operator_cap<CURVE_STRATEGY_TESTS, SUI>(
        market_maker::curve_route(),
        20_000_000,
        2_000,
        ROOT,
        &creator,
        x"d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        &version,
        &policy,
        &treasury,
        ctx,
    );
    vault.set_trading_limits(
        market_maker::new_trading_limits(
            100_000_000_000_000,
            1_000_000,
            1_000_000_000_000_000,
            10_000_000,
            0,
            10,
        ),
    );
    let payment = coin::mint_for_testing<SUI>(20_000_000, ctx);
    coin::burn_for_testing(
        vault.contribute_and_return_change(&version, payment, &clock, ctx),
    );
    let funding = vault.charge_raise_fee_and_enter_curve(&version, &clock);
    vault.join_capital(balance::zero<CURVE_STRATEGY_TESTS>(), funding);
    let partner = if (with_partner) {
        let partner = partners::new_for_testing(@0xD, 4_000, ctx);
        if (admitted)
            config.add_partner(
                &core_version,
                &blast_acl::witness_for_testing<FeeAdmin>(),
                &partner,
            );
        config.set_creation_fee(&core_version, &blast_acl::witness_for_testing<FeeAdmin>(), 1_000);
        runtime.set_protocol_fee_share(
            &core_version,
            &blast_acl::witness_for_testing<FeeAdmin>(),
            bps::new(2_500),
        );
        option::some(partner)
    } else option::none();
    let ticket = launch_ticket::new(
        test_utils::create_one_time_witness<CURVE_STRATEGY_TESTS>(),
        6,
        b"CURVE".to_string(),
        b"Curve integration test".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(ROOT),
        false,
        0,
        ctx,
    );
    destroy(creator);
    destroy(treasury);
    destroy(policy);
    scenario.next_tx(ROOT);
    let mut currency = scenario.take_from_address<Currency<CURVE_STRATEGY_TESTS>>(@0xc);
    let mut initializer = launch::new<CURVE_STRATEGY_TESTS, SUI, _>(
        ticket,
        &core_version,
        &config,
        TestMigrationWitness(),
        200,
        10_000,
    );
    partner.do_ref!(|partner| {
        let committed = committed_for_partner(partner);
        initializer.apply_committed_partner_for_testing(&committed, &core_version, &config, partner, &clock);
    });
    initializer.set_virtual_quote(&core_version, 5_000_000);
    initializer.set_graduation_target(&core_version, 25_000_000);
    initializer.set_allocation_plan(
        &core_version,
        allocation::plan(bps::new(8_000), bps::new(2_000), bps::new(10_000), vector[]),
    );
    initializer.set_lp_fee_split(
        &core_version,
        allocation::fee_split(bps::new(10_000), bps::new(0), bps::new(0), bps::new(0), vector[]),
    );
    let creation_fee = if (with_partner) coin::mint_for_testing<SUI>(1_000, scenario.ctx())
    else coin::zero<SUI>(scenario.ctx());
    let launch = initializer.finalize(
        &core_version,
        &mut currency,
        &config,
        creation_fee,
        scenario.ctx(),
    );
    test_scenario::return_to_address(@0xc, currency);
    vault.bind_external(object::id(&launch));
    let launch_id = object::id(&launch);
    launch.share(&core_version, &clock);
    scenario.next_tx(ROOT);
    let launch = scenario.take_shared_by_id<Launch<CURVE_STRATEGY_TESTS, SUI>>(launch_id);
    let operator = scenario.take_from_sender<BlastMarketMakerOperatorCap>();
    destroy(config);

    Fixture { scenario, clock, version, core_version, runtime, vault, launch, operator, partner }
}

fun end(f: Fixture) {
    let Fixture {
        scenario,
        clock,
        version,
        core_version,
        runtime,
        vault,
        launch,
        operator,
        partner,
    } = f;
    clock.destroy_for_testing();
    destroy(version);
    destroy(core_version);
    destroy(runtime);
    destroy(vault);
    destroy(launch);
    destroy(operator);
    destroy(partner);
    scenario.end();
}

// === Imports ===

use fun fixture_next_tx as Fixture.next_tx;

use blast_admin::blast_acl;
use blast_fun::{
    allocation,
    blast_fun::PackageVersion as CoreVersion,
    blast_fun_domain::{AdapterAdmin, ListingAdmin, FeeAdmin, CreatorAdmin},
    bps,
    creator_authority,
    launch::{Self, Launch},
    launch_config,
    launch_ticket,
    runtime_config::{Self, RuntimeConfig},
};
use blast_partners::blast_partners::{Self as partners, Partner};
use blast_market_maker::{
    market_maker::{Self, BlastMarketMakerVault, BlastMarketMakerOperatorCap},
    market_maker_fee_policy,
    cetus_migrator,
    package_version::{Self, BlastMarketMakerVersion as PackageVersion},
    protocol_treasury,
    risk,
};
use std::unit_test::{assert_eq, destroy};
use sui::{
    balance,
    clock::{Self, Clock},
    coin,
    coin_registry::Currency,
    sui::SUI,
    test_scenario::{Self, Scenario},
    test_utils,
};

use fun cetus_migrator::apply_committed_partner_for_testing as blast_fun::launch::LaunchInitializer.apply_committed_partner_for_testing;
use fun cetus_migrator::buy as BlastMarketMakerVault.buy;
use fun cetus_migrator::claim_and_credit_curve_fees as BlastMarketMakerVault.claim_and_credit_curve_fees;
use fun cetus_migrator::escrow_curve_fee_cap as BlastMarketMakerVault.escrow_curve_fee_cap;
use fun cetus_migrator::sell as BlastMarketMakerVault.sell;
