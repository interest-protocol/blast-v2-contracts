#[test_only]
/// Pure binding tests for sealed Aftermath venue custody.
module blast_boosts_aftermath::venue_account_tests;

// === Constants ===

const ACCOUNT_NUMBER: u64 = 7;

// === Tests ===

#[test]
fun binding_exposes_the_bound_account_number() {
    assert_eq!(standard_binding().account_number(), ACCOUNT_NUMBER);
}

#[test]
fun an_admin_cap_for_the_bound_account_seals_the_venue_account() {
    let mut ctx = tx_context::dummy();
    let venue = venue_account::new(standard_binding(), standard_checkpoint(), admin_cap_for(@0xA11CE, &mut ctx));

    assert_eq!(venue.binding(), standard_binding());
    assert_eq!(*venue.checkpoint(), standard_checkpoint());
    destroy(venue);
}

#[test]
#[expected_failure(abort_code = errors::EAdminCapAccountMismatch, location = blast_boosts_aftermath::venue_account)]
fun an_admin_cap_for_another_account_is_rejected() {
    let mut ctx = tx_context::dummy();
    let venue = venue_account::new(standard_binding(), standard_checkpoint(), admin_cap_for(@0xBAD, &mut ctx));
    destroy(venue);
}

#[test]
fun exact_binding_accepts_every_matching_component() {
    let binding = standard_binding();

    binding.assert_object_graph(@0xA11CE.to_id(), ACCOUNT_NUMBER, @0xB.to_id(), @0xC.to_id());

    destroy(binding);
}

#[test]
#[expected_failure(abort_code = errors::EAccountObjectMismatch, location = blast_boosts_aftermath::venue_account)]
fun wrong_account_object_is_rejected() {
    standard_binding().assert_object_graph(@0xBAD.to_id(), ACCOUNT_NUMBER, @0xB.to_id(), @0xC.to_id());
}

#[test]
#[expected_failure(abort_code = errors::EAccountNumberMismatch, location = blast_boosts_aftermath::venue_account)]
fun wrong_account_number_is_rejected() {
    standard_binding().assert_object_graph(@0xA11CE.to_id(), ACCOUNT_NUMBER + 1, @0xB.to_id(), @0xC.to_id());
}

#[test]
#[expected_failure(abort_code = errors::ERegistryMismatch, location = blast_boosts_aftermath::venue_account)]
fun wrong_registry_is_rejected() {
    standard_binding().assert_object_graph(@0xA11CE.to_id(), ACCOUNT_NUMBER, @0xBAD.to_id(), @0xC.to_id());
}

#[test]
#[expected_failure(abort_code = errors::EClearingHouseMismatch, location = blast_boosts_aftermath::venue_account)]
fun wrong_clearing_house_is_rejected() {
    standard_binding().assert_object_graph(@0xA11CE.to_id(), ACCOUNT_NUMBER, @0xB.to_id(), @0xBAD.to_id());
}

#[test]
#[expected_failure(abort_code = errors::EAccountObjectMismatch, location = blast_boosts_aftermath::venue_account)]
fun account_object_precedes_account_number() {
    standard_binding().assert_object_graph(@0xBAD.to_id(), ACCOUNT_NUMBER + 1, @0xB.to_id(), @0xC.to_id());
}

#[test]
#[expected_failure(abort_code = errors::EAccountNumberMismatch, location = blast_boosts_aftermath::venue_account)]
fun account_number_precedes_registry() {
    standard_binding().assert_object_graph(@0xA11CE.to_id(), ACCOUNT_NUMBER + 1, @0xBAD.to_id(), @0xC.to_id());
}

#[test]
#[expected_failure(abort_code = errors::ERegistryMismatch, location = blast_boosts_aftermath::venue_account)]
fun registry_precedes_clearing_house() {
    standard_binding().assert_object_graph(@0xA11CE.to_id(), ACCOUNT_NUMBER, @0xBAD.to_id(), @0xBAD.to_id());
}

#[test]
fun checkpoint_preserves_every_raw_field() {
    let checkpoint = standard_checkpoint();
    let checkpoint_copy = checkpoint;

    assert_standard_checkpoint(&checkpoint);
    assert_standard_checkpoint(&checkpoint_copy);

    destroy(checkpoint);
    destroy(checkpoint_copy);
}

#[test]
fun funding_update_guard_accepts_the_largest_representable_boundary() {
    let max = std::u64::max_value!();

    assert!(venue_account::is_time_to_update_funding_for_testing(max, max - 1, 1));
    assert!(!venue_account::is_time_to_update_funding_for_testing(max - 1, max - 1, 1));
    assert!(venue_account::is_time_to_update_funding_for_testing(max, 0, max));
    assert!(!venue_account::is_time_to_update_funding_for_testing(max - 1, 0, max));
}

#[test]
fun next_funding_update_time_reaches_the_last_representable_instant() {
    let max = std::u64::max_value!();

    assert_eq!(venue_account::next_funding_update_time_ms_for_testing(max - 1, 1), max);
    assert_eq!(venue_account::next_funding_update_time_ms_for_testing(0, max), max);
    assert_eq!(venue_account::next_funding_update_time_ms_for_testing(max - 1, max), max);
}

#[test]
#[expected_failure(arithmetic_error, location = blast_boosts_aftermath::venue_account)]
fun next_funding_update_time_overflows_past_the_last_period() {
    venue_account::next_funding_update_time_ms_for_testing(std::u64::max_value!(), 1);
}

#[test]
#[expected_failure(arithmetic_error, location = blast_boosts_aftermath::venue_account)]
fun next_funding_update_time_divides_by_a_zero_cadence() {
    venue_account::next_funding_update_time_ms_for_testing(1_000, 0);
}

// === Test Helpers ===

/// A real venue admin cap naming `account`, minted by the vendored interface's test constructor.
fun admin_cap_for(account: address, ctx: &mut TxContext): AuthorityCap<ACCOUNT, ADMIN> {
    authority::new_for_testing<ACCOUNT, ADMIN>(account.to_id(), ctx)
}

fun standard_checkpoint(): Checkpoint {
    checkpoint::checkpoint_for_testing(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, true, 14, 15, 16)
}

fun standard_binding(): Binding {
    venue_account::new_binding(@0xA11CE.to_id(), ACCOUNT_NUMBER, @0xB.to_id(), @0xC.to_id())
}

fun assert_standard_checkpoint(checkpoint: &Checkpoint) {
    let (
        free_collateral,
        allocated_collateral,
        signed_base,
        signed_quote_notional,
        funding_snapshot_long,
        funding_snapshot_short,
        market_funding_long,
        market_funding_short,
        lot_size,
        pending_ask_base,
        pending_bid_base,
        pending_order_count,
        market_pause_mode,
        market_frozen,
        position_initial_margin_ratio,
        market_initial_margin_ratio,
        market_maintenance_margin_ratio,
    ) = (*checkpoint).unpack_for_testing();

    assert_eq!(free_collateral, 1);
    assert_eq!(allocated_collateral, 2);
    assert_eq!(signed_base, 3);
    assert_eq!(signed_quote_notional, 4);
    assert_eq!(funding_snapshot_long, 5);
    assert_eq!(funding_snapshot_short, 6);
    assert_eq!(market_funding_long, 7);
    assert_eq!(market_funding_short, 8);
    assert_eq!(lot_size, 9);
    assert_eq!(pending_ask_base, 10);
    assert_eq!(pending_bid_base, 11);
    assert_eq!(pending_order_count, 12);
    assert_eq!(market_pause_mode, 13);
    assert!(market_frozen);
    assert_eq!(position_initial_margin_ratio, 14);
    assert_eq!(market_initial_margin_ratio, 15);
    assert_eq!(market_maintenance_margin_ratio, 16);
}

// === Imports ===

use authority_cap::authority::{Self, ADMIN, AuthorityCap};

use blast_boosts_aftermath::{checkpoint::{Self, Checkpoint}, errors, venue_account::{Self, Binding}};

use perpetuals::authority::ACCOUNT;

use std::unit_test::{assert_eq, destroy};
