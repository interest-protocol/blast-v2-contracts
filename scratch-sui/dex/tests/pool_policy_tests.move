// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_dex::pool_policy_tests;

// === Test-Only Types ===

public struct POOL_POLICY_TESTS() has drop;

public struct QUOTE() has drop;

public struct PolicyFixture {
    scenario: Scenario,
    authority: Authority<DEX_DOMAIN>,
    admin: AdminCap<DEX_DOMAIN>,
    root: SuperAdminCap<DEX_DOMAIN>,
    factory: Factory,
    pool: Pool<POOL_POLICY_TESTS, QUOTE>,
    position: Position<POOL_POLICY_TESTS, QUOTE>,
    currency: Currency<POOL_POLICY_TESTS>,
    spare: Coin<POOL_POLICY_TESTS>,
    clock: Clock,
}

// === Tests ===

#[test]
fun burns_destroy_actual_supply_in_both_directions() {
    let mut f = start(500);
    let (meme, refund) = f.buy_and_burn(101_000, 47_500, 200, 0);
    assert_eq!(meme.value(), 47_500);
    assert_eq!(f.currency.total_supply(), option::some(197_500));
    assert_eq!(refund.value(), 0);
    destroy(refund);
    let output = f.sell_and_burn(meme, 1, 201, 0);
    assert_eq!(f.currency.total_supply(), option::some(195_125));
    let (meme_reserve, quote_reserve, fees) = f.pool.balances_for_testing();
    assert_eq!(meme_reserve, 95_125);
    assert_eq!(quote_reserve + fees + output.value(), 201_000);
    destroy(output);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EBurnPolicy, location = pool)]
fun ordinary_buy_cannot_bypass_configured_burn() {
    let mut f = start(500);
    let (meme, refund) = f.buy(101_000, 1, 200, 0);
    destroy(meme);
    destroy(refund);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EBurnPolicy, location = pool)]
fun ordinary_sell_cannot_bypass_configured_burn() {
    let mut f = start(500);
    let input = f.take_meme(10_000);
    let output = f.sell(input, 1, 200, 0);
    destroy(output);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EMinimumOutput, location = pool)]
fun minimum_buy_receipt_includes_burn() {
    let mut f = start(500);
    let (meme, refund) = f.buy_and_burn(101_000, 47_501, 200, 0);
    destroy(meme);
    destroy(refund);
    f.end();
}

#[test]
fun cap_updates_preserve_history_and_already_earned_fees() {
    let mut f = start(0);
    let (meme, refund) = f.buy(101_000, 1, 200, 0);
    destroy(meme);
    destroy(refund);
    f.set_max_fee(0);
    f.set_max_fee(300);
    f.set_max_fee(500);
    let changes = sui::event::events_by_type<pool::MaximumFeeChanged>();
    assert_eq!(changes.length(), 3);
    assert_eq!(bcs::to_bytes(&changes[0]), fee_change_bytes(object::id(&f.pool), 200, 0));
    assert_eq!(bcs::to_bytes(&changes[1]), fee_change_bytes(object::id(&f.pool), 0, 300));
    assert_eq!(bcs::to_bytes(&changes[2]), fee_change_bytes(object::id(&f.pool), 300, 500));
    let (maximum, burn, volume, timestamp) = f.pool.policy_for_testing();
    assert_eq!(maximum, 500);
    assert_eq!(burn, 0);
    assert_eq!(volume, 100_000u128 << 32);
    assert_eq!(timestamp, 0);
    let fees = f.claim_fees();
    assert_eq!(fees.value(), 989);
    destroy(fees);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EFeeCap, location = pool)]
fun administrator_cannot_exceed_hard_cap() {
    let mut f = start(0);
    f.set_max_fee(501);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EUnchangedFee, location = pool)]
fun unchanged_cap_is_rejected() {
    let mut f = start(0);
    f.set_max_fee(200);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EFeeLimit, location = pool)]
fun trade_signed_before_cap_increase_rejects_new_rate() {
    let mut f = start(0);
    let (meme, refund) = f.buy(101_000, 1, 200, 0);
    destroy(meme);
    destroy(refund);
    f.set_max_fee(500);
    let (meme, refund) = f.buy(10_500, 1, 200, 0);
    destroy(meme);
    destroy(refund);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EFeeLimit, location = pool)]
fun rounded_effective_fee_limit_is_stricter_than_marginal_cap() {
    let mut f = start(0);
    let (meme, refund) = f.buy(101_000, 1, 200, 0);
    destroy(meme);
    destroy(refund);
    let (meme, refund) = f.buy(1_022, 1, 200, 0);
    destroy(meme);
    destroy(refund);
    f.end();
}

#[test]
fun exact_millisecond_deadline_is_allowed() {
    let mut f = start(0);
    f.clock.set_for_testing(1_001);
    let (meme, refund) = f.buy(101_000, 1, 200, 1_001);
    destroy(meme);
    destroy(refund);
    let (_, _, _, timestamp) = f.pool.policy_for_testing();
    assert_eq!(timestamp, 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EExpired, location = pool)]
fun one_millisecond_after_deadline_rejects_trade() {
    let mut f = start(0);
    f.clock.set_for_testing(1_001);
    let (meme, refund) = f.buy(101_000, 1, 200, 1_000);
    destroy(meme);
    destroy(refund);
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_generation_rejects_fee_claims() {
    let mut f = start(0);
    f.factory.set_version_for_testing(2);
    destroy(f.claim_fees());
    f.end();
}

#[test]
/// The factory advances to exactly the generation this bytecode hands over to,
/// and the shared package emits the only cutover fact.
fun the_factory_advances_to_the_next_compiled_generation() {
    let mut f = start(0);
    assert_eq!(f.factory.version_for_testing(), 1);

    f.factory.advance_for_testing();

    let advanced = blast_admin::events::collect_one<
        blast_admin::events::OperationalVersionAdvanced<PACKAGE_MARKER>,
    >(0);
    let (_, _, previous_generation, new_generation) =
        advanced.operational_version_advanced_fields();
    assert_eq!(previous_generation, 1);
    assert_eq!(new_generation, 2);
    assert_eq!(new_generation, f.factory.version_for_testing());
    f.end();
}

#[test]
/// The finalizer proves the exact next generation before it commits a receipt.
fun the_finalizer_accepts_the_exact_next_generation_before_committing() {
    let f = start(0);
    f.factory.assert_next_for_testing();
    assert_eq!(f.factory.version_for_testing(), 1);
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun the_cutover_rejects_a_skipped_generation() {
    let mut f = start(0);
    f.factory.set_version_for_testing(5);
    f.factory.advance_for_testing();
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidAdminCap,
    location = blast_admin::acl,
)]
fun revoked_administrator_cannot_change_pool_cap() {
    let mut f = start(0);
    f.revoke_admin();
    f.next_tx!(@0xA, |f| f.set_max_fee(300));
    f.end();
}

#[test]
/// Pool policy is generic DEX administration: a live zero-role witness is enough
/// and no package-admin role is required.
fun a_zero_role_dex_administrator_may_change_the_pool_cap() {
    let mut f = start(0);

    f.set_max_fee(300);

    let (max_fee_bps, _, _, _) = f.pool.policy_for_testing();
    assert_eq!(max_fee_bps, 300);
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
/// The exported package-admin role is a real, separately granted bit; a generic
/// administrator does not carry it.
fun a_zero_role_dex_administrator_does_not_carry_the_package_admin_role() {
    let mut f = start(0);

    f.next_tx!(@0xA, |f| {
        let PolicyFixture { authority, admin, .. } = f;
        authority.sign_in(admin).assert_role(dex_domain::package_admin_role());
    });

    f.end();
}

#[test]
fun empty_fee_claim_returns_zero_without_emitting_an_economic_event() {
    let mut f = start(0);
    let fees = f.claim_fees();
    assert_eq!(fees.value(), 0);
    assert!(sui::event::events_by_type<pool::FeesClaimed>().is_empty());
    destroy(fees);
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionOverflow,
    location = blast_admin::operational_version,
)]
fun the_cutover_rejects_a_generation_overflow() {
    let mut f = start(0);
    f.factory.set_version_for_testing(std::u64::max_value!());
    f.factory.advance_for_testing();
    f.end();
}

#[test]
fun pool_trade_decays_the_score_before_charging_and_adds_only_principal() {
    let mut f = start(0);
    let (meme, refund) = f.buy(101_000, 1, 200, 0);
    destroy(meme);
    destroy(refund);
    f.clock.increment_for_testing(1_800_000);
    let (meme, refund) = f.buy(1000, 246, 102, 1_800_000);
    assert_eq!(meme.value(), 246);
    assert_eq!(refund.value(), 0);
    let (_, _, score, timestamp) = f.pool.policy_for_testing();
    assert_eq!(score, 50_990u128 << 32);
    assert_eq!(timestamp, 1800);
    let (_, quote, fees) = f.pool.balances_for_testing();
    assert_eq!(quote, 200_990);
    assert_eq!(fees, 1010);
    destroy(meme);
    destroy(refund);
    f.end();
}

#[test]
fun zero_fee_cap_trades_both_directions_without_funding_the_fee_pot() {
    let mut f = start(0);
    f.set_max_fee(0);
    let (meme, refund) = f.buy(100_000, 50_000, 0, 0);
    assert_eq!(refund.value(), 0);
    destroy(refund);
    let quote = f.sell(meme, 100_000, 0, 0);
    assert_eq!(quote.value(), 100_000);
    let (meme_reserve, quote_reserve, fees) = f.pool.balances_for_testing();
    assert_eq!(meme_reserve, 100_000);
    assert_eq!(quote_reserve, 100_000);
    assert_eq!(fees, 0);
    destroy(quote);
    f.end();
}

#[test]
fun burn_entrypoints_with_zero_policy_are_aliases_without_supply_destruction() {
    let mut f = start(0);
    let (meme, refund) = f.buy_and_burn(101_000, 50_000, 200, 0);
    assert_eq!(meme.value(), 50_000);
    destroy(refund);
    let quote = f.sell_and_burn(meme, 98_000, 200, 0);
    assert_eq!(quote.value(), 98_000);
    assert_eq!(f.currency.total_supply(), option::some(200_000));
    destroy(quote);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EMinimumOutput, location = pool)]
fun minimum_sell_receipt_includes_burn_and_quote_fees() {
    let mut f = start(500);
    let input = f.take_meme(10_000);
    let quote = f.sell_and_burn(input, 8668, 500, 0);
    destroy(quote);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EClockReversed, location = pool)]
fun reversed_clock_rejects_before_computing_decay() {
    let mut f = start(0);
    f.clock.set_for_testing(1000);
    let (meme, refund) = f.buy(101_000, 1, 200, 1000);
    destroy(meme);
    destroy(refund);
    let reversed = clock::create_for_testing(f.scenario.ctx());
    let input = coin::mint_for_testing<QUOTE>(1000, f.scenario.ctx());
    let PolicyFixture { factory, pool, scenario, .. } = &mut f;
    let (meme, refund) = pool.buy(factory, input, 1, 500, 1000, &reversed, scenario.ctx());
    reversed.destroy_for_testing();
    destroy(meme);
    destroy(refund);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EExpired, location = pool)]
fun swap_deadline_precedes_zero_input() {
    let mut f = start(0);
    f.clock.set_for_testing(1);
    let (meme, refund) = f.buy(0, 0, 0, 0);
    destroy(meme);
    destroy(refund);
    f.end();
}

// === Test Helpers ===

fun start(burn: u64): PolicyFixture {
    let mut scenario = test_scenario::begin(@0xA);
    let (root, mut authority) = domain_fixture::new_dex_authority(scenario.ctx());
    authority.grant_admin(&root, 0, @0xA, scenario.ctx());
    scenario.next_tx(@0xA);
    let admin = scenario.take_from_sender<AdminCap<DEX_DOMAIN>>();
    let (mut initializer, mut treasury) = coin_registry::new_currency_with_otw(
        POOL_POLICY_TESTS(),
        6,
        b"MEME".to_string(),
        b"Meme".to_string(),
        b"".to_string(),
        b"".to_string(),
        scenario.ctx(),
    );
    let mut spare = treasury.mint(200_000, scenario.ctx());
    let meme = spare.split(100_000, scenario.ctx()).into_balance();
    initializer.make_supply_burn_only(treasury);
    let currency = initializer.unwrap_for_testing();
    let mut factory = pool::new_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let (pool, position) = pool::create_from_balances(
        &mut factory,
        meme,
        balance::create_for_testing<QUOTE>(100_000),
        burn,
        &clock,
        scenario.ctx(),
    );
    PolicyFixture {
        scenario,
        authority,
        admin,
        root,
        factory,
        pool,
        position,
        currency,
        spare,
        clock,
    }
}

fun end(f: PolicyFixture) {
    let PolicyFixture {
        scenario,
        authority,
        admin,
        root,
        factory,
        pool,
        position,
        currency,
        spare,
        clock,
    } = f;
    destroy(root);
    destroy(authority);
    destroy(admin);
    destroy(factory);
    destroy(pool);
    destroy(position);
    destroy(currency);
    destroy(spare);
    clock.destroy_for_testing();
    scenario.end();
}

fun buy(
    f: &mut PolicyFixture,
    gross: u64,
    minimum: u64,
    fee: u64,
    deadline: u64,
): (Coin<POOL_POLICY_TESTS>, Coin<QUOTE>) {
    let PolicyFixture { scenario, factory, pool, clock, .. } = f;
    let input = coin::mint_for_testing<QUOTE>(gross, scenario.ctx());
    pool.buy(factory, input, minimum, fee, deadline, clock, scenario.ctx())
}

fun buy_and_burn(
    f: &mut PolicyFixture,
    gross: u64,
    minimum: u64,
    fee: u64,
    deadline: u64,
): (Coin<POOL_POLICY_TESTS>, Coin<QUOTE>) {
    let PolicyFixture { scenario, factory, pool, currency, clock, .. } = f;
    let input = coin::mint_for_testing<QUOTE>(gross, scenario.ctx());
    pool.buy_and_burn(factory, input, currency, minimum, fee, deadline, clock, scenario.ctx())
}

fun sell(
    f: &mut PolicyFixture,
    input: Coin<POOL_POLICY_TESTS>,
    minimum: u64,
    fee: u64,
    deadline: u64,
): Coin<QUOTE> {
    let PolicyFixture { scenario, factory, pool, clock, .. } = f;
    pool.sell(factory, input, minimum, fee, deadline, clock, scenario.ctx())
}

fun sell_and_burn(
    f: &mut PolicyFixture,
    input: Coin<POOL_POLICY_TESTS>,
    minimum: u64,
    fee: u64,
    deadline: u64,
): Coin<QUOTE> {
    let PolicyFixture { scenario, factory, pool, currency, clock, .. } = f;
    pool.sell_and_burn(factory, input, currency, minimum, fee, deadline, clock, scenario.ctx())
}

fun set_max_fee(f: &mut PolicyFixture, maximum: u64) {
    let PolicyFixture { authority, admin, factory, pool, .. } = f;
    pool.set_max_fee(factory, &authority.sign_in(admin), maximum);
}

fun claim_fees(f: &mut PolicyFixture): Coin<QUOTE> {
    let PolicyFixture { scenario, factory, pool, position, .. } = f;
    pool.claim_fees(factory, position, scenario.ctx())
}

fun take_meme(f: &mut PolicyFixture, amount: u64): Coin<POOL_POLICY_TESTS> {
    f.spare.split(amount, f.ctx!())
}

macro fun ctx($f: &mut PolicyFixture): &mut TxContext { let f = $f; f.scenario.ctx() }

macro fun next_tx($f: &mut PolicyFixture, $sender: address, $body: |&mut PolicyFixture|) {
    let f = $f;
    f.scenario.next_tx($sender);
    $body(f);
}

fun revoke_admin(f: &mut PolicyFixture) {
    let PolicyFixture { authority, root, admin, .. } = f;
    authority.revoke_admin(root, object::id(admin));
}

fun fee_change_bytes(pool_id: ID, previous: u64, maximum: u64): vector<u8> {
    let mut bytes = bcs::to_bytes(&pool_id);
    bytes.append(bcs::to_bytes(&previous));
    bytes.append(bcs::to_bytes(&maximum));
    bytes
}

// === Imports ===

use blast_admin::acl::{Authority, AdminCap, SuperAdminCap};

use blast_fun_dex::{
    dex_domain::{Self, DEX_DOMAIN},
    domain_fixture,
    package_marker::PACKAGE_MARKER,
    pool::{Self, Factory, Pool, Position}
};

use std::{bcs, unit_test::{assert_eq, destroy}};

use sui::{
    balance,
    clock::{Self, Clock},
    coin::{Self, Coin},
    coin_registry::{Self, Currency},
    test_scenario::{Self, Scenario}
};
