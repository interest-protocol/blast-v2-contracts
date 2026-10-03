// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::fee_policy_tests;

// === Constants ===

const PUBLISHER: address = @0xB1A57;
const TREASURY: address = @0x7EA5;

// === Tests ===

#[test]
/// Publication shares one policy that charges nothing and pays the publisher.
fun publication_shares_a_zero_rate_policy_paying_the_publisher() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    fee_policy::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let policy = scenario.take_shared<FeePolicy>();
    assert_eq!(policy.fees(), fee_policy::protocol_fees_for_testing(0, 0, 0, 0));
    assert_eq!(policy.destination(), PUBLISHER);

    test_scenario::return_shared(policy);
    scenario.end();
}

#[test]
/// Every rate accepts its maximum and returns to zero.
fun the_admin_sets_maximum_and_zero_rates() {
    let mut policy = new_policy();
    let (admin_registry, admin_cap) = admin();

    policy.set_fees(
        &admin_registry,
        &admin_cap,
        bps::new(9_999),
        bps::new(9_998),
        bps::new(10_000),
        bps::new(10_000),
    );

    assert_eq!(policy.fees(), fee_policy::protocol_fees_for_testing(9_999, 9_998, 10_000, 10_000));
    let (raise_bps, token_bps, lp_fee_meme_bps, lp_fee_quote_bps) = last_event<FeesChanged>()
        .fees_changed_fields();
    assert_eq!(
        vector[raise_bps, token_bps, lp_fee_meme_bps, lp_fee_quote_bps],
        vector[9_999, 9_998, 10_000, 10_000],
    );

    policy.set_fees(&admin_registry, &admin_cap, bps::new(0), bps::new(0), bps::new(0), bps::new(0));

    assert_eq!(policy.fees(), fee_policy::protocol_fees_for_testing(0, 0, 0, 0));

    policy.destroy_for_testing();
    admin_registry.destroy_for_testing(admin_cap);
}

#[test]
#[expected_failure(abort_code = fee_policy::EInvalidFees, location = blast_presale::fee_policy)]
/// Blast cannot take the whole raise, which would leave the pool no Quote.
fun the_raise_share_must_stay_below_full() {
    set_fees(10_000, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = fee_policy::EInvalidFees, location = blast_presale::fee_policy)]
/// The sale and LP allocations each need at least one BPS of the supply.
fun the_token_share_must_leave_two_bps() {
    set_fees(0, 9_999, 0, 0);
}

#[test]
#[expected_failure(abort_code = fee_policy::EFeesUnchanged, location = blast_presale::fee_policy)]
fun a_fee_update_must_change_the_rates() {
    set_fees(0, 0, 0, 0);
}

#[test]
/// The administrator redirects every later payout.
fun the_admin_sets_the_destination() {
    let mut policy = new_policy();
    let (admin_registry, admin_cap) = admin();

    policy.set_destination(&admin_registry, &admin_cap, TREASURY);

    assert_eq!(policy.destination(), TREASURY);
    assert_eq!(last_event<DestinationChanged>().destination_changed_fields(), TREASURY);

    policy.destroy_for_testing();
    admin_registry.destroy_for_testing(admin_cap);
}

#[test]
#[expected_failure(abort_code = fee_policy::EInvalidDestination, location = blast_presale::fee_policy)]
fun the_destination_cannot_be_the_zero_address() {
    set_destination(@0x0);
}

#[test]
#[expected_failure(abort_code = fee_policy::EInvalidDestination, location = blast_presale::fee_policy)]
fun a_destination_update_must_change_the_address() {
    set_destination(tx_context::dummy().sender());
}

// === Test Helpers ===

/// A fresh policy: zero rates, paying the dummy context's sender.
fun new_policy(): FeePolicy {
    let mut ctx = tx_context::dummy();

    fee_policy::new_for_testing(&mut ctx)
}

fun set_fees(raise_bps: u64, token_bps: u64, lp_fee_meme_bps: u64, lp_fee_quote_bps: u64) {
    let mut policy = new_policy();
    let (admin_registry, admin_cap) = admin();

    policy.set_fees(
        &admin_registry,
        &admin_cap,
        bps::new(raise_bps),
        bps::new(token_bps),
        bps::new(lp_fee_meme_bps),
        bps::new(lp_fee_quote_bps),
    );

    policy.destroy_for_testing();
    admin_registry.destroy_for_testing(admin_cap);
}

fun set_destination(destination: address) {
    let mut policy = new_policy();
    let (admin_registry, admin_cap) = admin();

    policy.set_destination(&admin_registry, &admin_cap, destination);

    policy.destroy_for_testing();
    admin_registry.destroy_for_testing(admin_cap);
}

fun admin(): (AdminRegistry, AdminCap) {
    blast_presale_admin::new_for_testing(&mut tx_context::dummy())
}

fun last_event<Event: copy + drop>(): Event {
    let mut events = event::events_by_type<Event>();
    events.pop_back()
}

// === Imports ===

use blast_presale::{
    blast_presale_admin::{Self, AdminCap, AdminRegistry},
    bps,
    fee_policy::{Self, DestinationChanged, FeePolicy, FeesChanged},
};

use std::unit_test::assert_eq;

use sui::{event, test_scenario};
