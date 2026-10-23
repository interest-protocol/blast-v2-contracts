// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_market_maker::signed_action_tests;

// === Constants ===

const ROOT: address = @0xA;
const PAYOUT: address = @0xD;

// === Test-Only Types ===

public struct MEME has drop {}
public struct Fixture {
    scenario: Scenario,
    clock: Clock,
    version: PackageVersion,
    vault: BlastMarketMakerVault<MEME, SUI>,
    operator: BlastMarketMakerOperatorCap,
    creator: BlastMarketMakerCreatorCap,
}

// === Tests ===

#[test]
fun valid_signature_charges_actual_input_and_next_nonce() {
    let mut f = start(default_limits());
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.finish(risk::new_curve_buy(100, 1), 70, 70, 0);
    f.authorize(risk::new_curve_buy(100, 1), signature(1));
    f.finish(risk::new_curve_buy(100, 1), 100, 100, 0);
    f.end();
}

#[test]
#[expected_failure(abort_code = risk::EInvalidSignature, location = blast_market_maker::risk)]
fun consumed_signature_cannot_be_replayed() {
    let mut f = start(default_limits());
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.finish(risk::new_curve_buy(100, 1), 100, 100, 0);
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.end();
}

#[test]
#[expected_failure(abort_code = risk::EInvalidSignature, location = blast_market_maker::risk)]
fun signed_minimum_output_cannot_be_changed() {
    let f = start(default_limits());
    f.authorize(risk::new_curve_buy(100, 2), signature(0));
    f.end();
}

#[test]
fun token_bucket_refills_at_exact_boundary_without_changing_lifetime_spend() {
    let limits = market_maker::with_rate_limits(default_limits(), 100, 100, 10, 10, 200, 200);
    let mut f = start(limits);
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.finish(risk::new_curve_buy(100, 1), 100, 100, 0);
    f.clock.set_for_testing(110);
    f.authorize(risk::new_curve_buy(100, 1), signature(1));
    f.finish(risk::new_curve_buy(100, 1), 100, 100, 0);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::ERateLimit,
        location = blast_market_maker::market_maker,
    ),
]
fun token_bucket_rejects_one_millisecond_before_refill_boundary() {
    let limits = market_maker::with_rate_limits(default_limits(), 100, 100, 10, 10, 200, 200);
    let mut f = start(limits);
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.finish(risk::new_curve_buy(100, 1), 100, 100, 0);
    f.clock.set_for_testing(109);
    f.authorize(risk::new_curve_buy(100, 1), signature(1));
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::ETradingInputLimit,
        location = blast_market_maker::market_maker,
    ),
]
fun lifetime_spend_stays_exhausted_after_bucket_refill() {
    let limits = market_maker::with_rate_limits(
        market_maker::new_trading_limits(100, 100, 100, 100, 0, 5),
        100,
        100,
        100,
        100,
        200,
        200,
    );
    let mut f = start(limits);
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.finish(risk::new_curve_buy(100, 1), 100, 100, 0);
    f.clock.set_for_testing(200);
    f.authorize(risk::new_curve_buy(100, 1), signature(1));
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EActionLimit,
        location = blast_market_maker::market_maker,
    ),
]
fun discretionary_limit_rejects_first_action_past_exact_limit() {
    let mut f = start(market_maker::new_trading_limits(100, 100, 200, 200, 0, 1));
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.finish(risk::new_curve_buy(100, 1), 100, 100, 0);
    f.authorize(risk::new_curve_buy(100, 1), signature(1));
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::ESelfFeeLimit,
        location = blast_market_maker::market_maker,
    ),
]
fun curve_basis_accepts_exact_limit_and_rejects_first_over() {
    let limits = market_maker::with_rate_limits(default_limits(), 200, 200, 0, 0, 100, 100);
    let mut f = start(limits);
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.finish(risk::new_curve_buy(100, 1), 100, 100, 0);
    f.authorize(risk::new_curve_buy(100, 1), signature(1));
    f.finish(risk::new_curve_buy(100, 1), 1, 1, 0);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::ESelfFeeLimit,
        location = blast_market_maker::market_maker,
    ),
]
fun pool_basis_accepts_exact_limit_and_rejects_first_over() {
    let limits = market_maker::with_rate_limits(default_limits(), 200, 200, 0, 0, 100, 100);
    let mut f = start(limits);
    // Isolate the common post-venue receipt gate, without executing a Cetus stub.
    f.finish(risk::new_curve_buy(100, 1), 100, 0, 100);
    f.finish(risk::new_curve_buy(100, 1), 1, 0, 1);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EIdleQuoteFloor,
        location = blast_market_maker::market_maker,
    ),
]
fun quote_input_must_preserve_idle_floor_before_signature_verification() {
    let f = start(market_maker::new_trading_limits(100, 100, 200, 200, 18_999_901, 2));
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EClockRegression,
        location = blast_market_maker::market_maker,
    ),
]
fun clock_cannot_regress_after_successful_action() {
    let mut f = start(default_limits());
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.finish(risk::new_curve_buy(100, 1), 100, 100, 0);
    let f = f.replace_with_synthetic_earlier_clock(99);
    f.authorize(risk::new_curve_buy(100, 1), signature(1));
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongOperator,
        location = blast_market_maker::market_maker,
    ),
]
fun discretionary_action_without_operator_uses_local_error() {
    let f = start(default_limits());
    f.vault.authorize_action(
        &f.version,
        option::none(),
        risk::new_curve_buy(100, 1),
        100,
        200,
        &signature(0),
        &f.clock,
    );
    f.end();
}

#[test]
#[expected_failure(abort_code = market_maker::EPaused, location = blast_market_maker::market_maker)]
fun pause_blocks_discretionary_actions() {
    let mut f = start(default_limits());
    f.pause();
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.end();
}

#[test]
fun signed_unwind_remains_available_paused_and_after_discretionary_exhaustion() {
    let mut f = start(market_maker::new_trading_limits(100, 100, 200, 200, 0, 1));
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.finish(risk::new_curve_buy(100, 1), 100, 100, 0);
    f.pause();
    let Fixture { vault, version, clock, .. } = &mut f;
    vault.activate_pool(object::id_from_address(@0xFACE));
    let action = risk::new_unwind(object::id_from_address(@0xCAFE), 1, 0, 0);
    vault.authorize_action(version, option::none(), action, 100, 200, &unwind_signature(), clock);
    vault.finish_action(action, 0, 0, 0, 0, clock);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongPhase,
        location = blast_market_maker::market_maker,
    ),
]
fun pool_action_cannot_authorize_in_curve_phase() {
    let f = start(default_limits());
    f.authorize(risk::new_pool_swap(0, 100, 1, 0, 1), signature(0));
    f.end();
}

#[test]
#[expected_failure(abort_code = risk::EInvalidSignature, location = blast_market_maker::risk)]
fun restoring_signer_key_does_not_restore_old_epoch_signature() {
    let mut f = start(default_limits());
    let Fixture { vault, creator, version, .. } = &mut f;
    vault.rotate_signer(creator, version, vector::tabulate!(32, |_| 1));
    vault.rotate_signer(
        creator,
        version,
        x"d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
    );
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = package_version::EVersionMismatch,
        location = blast_market_maker::package_version,
    ),
]
fun stale_generation_rejects_before_signature_verification() {
    let mut f = start(default_limits());
    f.version.set_generation_for_testing(2);
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.end();
}

#[test]
fun risk_window_accepts_exact_fifteen_seconds() {
    verify_window(100, 15_100, 100);
}

#[test]
#[expected_failure(abort_code = risk::EInvalidValidityWindow, location = blast_market_maker::risk)]
fun risk_window_rejects_first_millisecond_over_fifteen_seconds() {
    verify_window(100, 15_101, 100);
}

#[test]
#[expected_failure(abort_code = risk::EInvalidValidityWindow, location = blast_market_maker::risk)]
fun risk_window_rejects_issued_after_expiry() {
    verify_window(101, 100, 100);
}

#[test]
#[expected_failure(abort_code = risk::EAuthorizationExpired, location = blast_market_maker::risk)]
fun risk_window_rejects_before_issue_time() {
    verify_window(100, 200, 99);
}

#[test]
#[expected_failure(abort_code = risk::EAuthorizationExpired, location = blast_market_maker::risk)]
fun risk_window_rejects_first_millisecond_after_expiry() {
    verify_window(100, 200, 201);
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongPhase,
        location = blast_market_maker::market_maker,
    ),
]
fun paused_unwind_in_curve_phase_rejects_wrong_phase_before_any_pause_check() {
    let mut f = start(default_limits());
    f.pause();
    f.vault.authorize_action(
        &f.version,
        option::none(),
        risk::new_unwind(object::id_from_address(@0xCAFE), 1, 0, 0),
        100,
        200,
        &unwind_signature(),
        &f.clock,
    );
    f.end();
}

#[test]
fun event_reducer_reconciles_two_signed_actions_and_actual_fee_receipts() {
    let mut f = start(default_limits());
    f.authorize(risk::new_curve_buy(100, 1), signature(0));
    f.finish(risk::new_curve_buy(100, 1), 70, 70, 0);
    f.vault.credit_curve_fees(
        balance::create_for_testing<MEME>(5),
        balance::create_for_testing<SUI>(125),
    );
    f.authorize(risk::new_curve_buy(100, 1), signature(1));
    f.finish(risk::new_curve_buy(100, 1), 100, 100, 0);
    f.vault.credit_curve_fees(
        balance::create_for_testing<MEME>(5),
        balance::create_for_testing<SUI>(125),
    );
    f.reconcile_action_and_fee_events();
    f.end();
}

#[test]
fun signature_is_valid_at_exact_expiry() { verify_window(100, 200, 200); }

#[test]
#[
    expected_failure(
        abort_code = market_maker::EInvalidTradingLimits,
        location = blast_market_maker::market_maker,
    ),
]
fun rolling_bucket_cannot_be_smaller_than_one_admitted_action() {
    let _ = market_maker::with_rate_limits(default_limits(), 100, 99, 1, 1, 200, 200);
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EInvalidTradingLimits,
        location = blast_market_maker::market_maker,
    ),
]
fun zero_self_fee_conversion_allowance_rejects_at_construction() {
    let _ = market_maker::with_rate_limits(default_limits(), 100, 100, 1, 1, 0, 200);
}

// === Test Helpers ===

// Decode emitted BCS as an independent reducer rather than reading private event fields.
// The common post-venue gate is isolated here; successful venue execution is a separate gate.
fun reconcile_action_and_fee_events(f: &Fixture) {
    let events = sui::event::events_by_type<market_maker::BlastActionExecuted>();
    assert_eq!(events.length(), 2);
    let mut quote_inputs = 0;
    events.do_ref!(|event| {
        let mut data = sui::bcs::new(std::bcs::to_bytes(event));
        assert_eq!(data.peel_address(), object::id(&f.vault).to_address());
        assert_eq!(data.peel_u8(), 0); // curve buy
        assert_eq!(data.peel_u64(), 0); // approved Meme
        assert_eq!(data.peel_u64(), 100); // approved Quote
        assert_eq!(data.peel_u64(), 1); // minimum Meme
        assert_eq!(data.peel_u64(), 0); // minimum Quote
        assert_eq!(data.peel_u128(), 0); // venue price limit
        assert_eq!(data.peel_option_address(), option::none());
        assert_eq!(data.peel_u32(), 0);
        assert_eq!(data.peel_u32(), 0);
        assert_eq!(data.peel_u128(), 0);
        let nonce = data.peel_u64();
        assert_eq!(data.peel_u64(), nonce + 1);
        assert_eq!(data.peel_u64(), 0); // actual Meme spent
        let actual_quote = data.peel_u64();
        assert_eq!(actual_quote, if (nonce == 0) 70 else 100);
        quote_inputs = quote_inputs + actual_quote;
        assert_eq!(data.peel_u64(), quote_inputs); // cumulative self-fee basis
        assert_eq!(data.peel_u64(), 0); // no pool inputs
        let _ = data.peel_u64(); // capital at action completion, before next fee receipt
        assert_eq!(data.peel_u64(), 19_000_000);
        assert_eq!(data.into_remainder_bytes(), vector[]);
    });
    assert_eq!(quote_inputs, 170);
    let fees = sui::event::events_by_type<market_maker::BlastFeesCredited<MEME, SUI>>();
    assert_eq!(fees.length(), 2);
    let mut gross_meme = 0;
    let mut gross_quote = 0;
    fees.do_ref!(|event| {
        let mut data = sui::bcs::new(std::bcs::to_bytes(event));
        assert_eq!(data.peel_address(), object::id(&f.vault).to_address());
        gross_meme = gross_meme + data.peel_u64();
        gross_quote = gross_quote + data.peel_u64();
        assert_eq!(data.into_remainder_bytes(), vector[]);
    });
    let (
        available_meme,
        available_quote,
        reserved_meme,
        reserved_quote,
    ) = f.vault.fee_balances(
    );
    assert_eq!(available_meme, gross_meme);
    assert_eq!(available_quote, gross_quote);
    assert_eq!(reserved_meme, 0);
    assert_eq!(reserved_quote, 0);
    assert_eq!(gross_meme, 10);
    assert_eq!(gross_quote, 250);
    let (meme_capital, quote_capital) = f.vault.capital_for_testing();
    assert_eq!(meme_capital, 1_000);
    assert_eq!(quote_capital, 19_000_000);
}

// Canonical Clock is monotonic. This synthetic replacement isolates the defensive regression
// check and preserves every signed-action check; it is not a reachable canonical clock update.
fun replace_with_synthetic_earlier_clock(f: Fixture, now: u64): Fixture {
    let Fixture { mut scenario, clock, version, vault, operator, creator } = f;
    clock.destroy_for_testing();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(now);
    Fixture { scenario, clock, version, vault, operator, creator }
}

// Public RFC8032 seed signs a fixed test message; production actions still bind complete BCS.
fun verify_window(issued: u64, expires: u64, now: u64) {
    let mut scenario = test_scenario::begin(ROOT);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(now);
    risk::verify(
        &x"d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        &x"ea056f5f202531a91cbb4bfb9c48a5beec3ac1ec459060b7c987d805b33de8000aa2fcc0b27c85202b292ecce9ce05bf732a2d550ae01c4050e99d6dc45e0308",
        &b"window",
        issued,
        expires,
        &clock,
    );
    clock.destroy_for_testing();
    scenario.end();
}

fun authorize(f: &Fixture, action: risk::Action, signature: vector<u8>) {
    f.vault.authorize_action(
        &f.version,
        option::some(object::id(&f.operator)),
        action,
        100,
        200,
        &signature,
        &f.clock,
    );
}

fun finish(f: &mut Fixture, action: risk::Action, quote: u64, curve_basis: u64, pool_basis: u64) {
    let Fixture { vault, clock, .. } = f;
    vault.finish_action(action, 0, quote, curve_basis, pool_basis, clock);
}

fun pause(f: &mut Fixture) {
    let Fixture { vault, creator, version, .. } = f;
    vault.set_paused(creator, version, true);
}

/// RFC8032 public test seed; signatures bind exact deterministic Scenario IDs, types and Action.
fun signature(nonce: u64): vector<u8> {
    if (nonce == 0)
        x"f6664c7275c5cad12ea1237c417a43b28489414f102bb97ae9ae51f5d7c476b9a382fbed971dad78f503149d2afb543311e480e2e40b650c66c5d8fe96f59907"
    else
        x"a4dc153dce2ccc85cb1e53e02f145b614df7c2fa6f8a4c62679003ee084f1a2a595cd24ab25626b5339475f2955ad7dab1285dc86708d4010182e6e70114c40e"
}

fun unwind_signature(): vector<u8> {
    x"b79c4723074e55bfba2ecfc308b4a37aa85ae97109b373c065238f461ff4c0d404b629666754be4ee33a60c5b62667cb001812ac31e877fd67880a0f34962f0b"
}

fun default_limits(): market_maker::TradingLimits {
    market_maker::new_trading_limits(100, 100, 200, 200, 0, 2)
}

fun start(limits: market_maker::TradingLimits): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let ctx = scenario.ctx();
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(100);
    let creator = market_maker::new_creator_cap(ctx);
    let mut treasury = protocol_treasury::new_for_testing(ctx);
    let policy = market_maker_fee_policy::new_for_testing(object::id(&treasury), ctx);
    let version = package_version::new_for_testing(
        object::id(&treasury),
        object::id(&policy),
        ctx,
    );
    treasury.set_payout(&blast_acl::witness_for_testing<TreasuryAdmin>(), &version, PAYOUT);
    let mut vault = market_maker::new_and_transfer_operator_cap<MEME, SUI>(
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
    vault.set_trading_limits(limits);
    let payment = coin::mint_for_testing<SUI>(20_000_000, ctx);
    coin::burn_for_testing(
        vault.contribute_and_return_change(&version, payment, &clock, ctx),
    );
    let funding = vault.charge_raise_fee_and_enter_curve(&version, &clock);
    vault.join_capital(balance::create_for_testing<MEME>(1_000), funding);
    vault.bind_external(object::id_from_address(@0xCAFE));
    destroy(treasury);
    destroy(policy);
    scenario.next_tx(ROOT);
    let operator = scenario.take_from_sender<BlastMarketMakerOperatorCap>();

    Fixture { scenario, clock, version, vault, operator, creator }
}

fun end(f: Fixture) {
    let Fixture { scenario, clock, version, vault, operator, creator } = f;
    clock.destroy_for_testing();
    destroy(version);
    destroy(vault);
    destroy(operator);
    destroy(creator);
    scenario.end();
}

// === Imports ===

use blast_admin::blast_acl;
use blast_market_maker::{
    blast_market_maker_domain::TreasuryAdmin,
    market_maker::{
        Self,
        BlastMarketMakerVault,
        BlastMarketMakerOperatorCap,
        BlastMarketMakerCreatorCap,
    },
    market_maker_fee_policy,
    package_version::{Self, BlastMarketMakerVersion as PackageVersion},
    protocol_treasury,
    risk,
};
use std::unit_test::{assert_eq, destroy};
use sui::{balance, clock::{Self, Clock}, coin, sui::SUI, test_scenario::{Self, Scenario}};
