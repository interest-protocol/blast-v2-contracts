#[test_only]
/// Pure binding tests for sealed Aftermath venue custody.
module blast_boosts_aftermath::venue_account_tests;

// === Constants ===

const ACCOUNT_NUMBER: u64 = 7;

// === Test Types ===

public struct Collateral {}
public struct OtherCollateral {}

// === Tests ===

#[test]
fun an_admin_cap_for_the_bound_account_seals_the_venue_account() {
    let mut ctx = tx_context::dummy();
    let venue = venue_account::new(standard_binding(), standard_checkpoint(), admin_cap_for(@0xA11CE, &mut ctx));

    assert_eq!(venue.binding().account_object_id(), @0xA11CE.to_id());
    destroy(venue);
}

#[test]
#[expected_failure(
    abort_code = 11,
    location = blast_boosts_aftermath::venue_account,
)]
fun an_admin_cap_for_another_account_is_rejected() {
    let mut ctx = tx_context::dummy();
    let venue = venue_account::new(standard_binding(), standard_checkpoint(), admin_cap_for(@0xBAD, &mut ctx));
    destroy(venue);
}

#[test]
fun exact_binding_accepts_every_matching_component() {
    let binding = standard_binding();

    binding.assert_object_graph(
        @0xA11CE.to_id(),
        ACCOUNT_NUMBER,
        @0xB.to_id(),
        @0xC.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        type_name::with_original_ids<Collateral>(),
    );

    destroy(binding);
}

#[test]
#[expected_failure(
    abort_code = 12,
    location = blast_boosts_aftermath::venue_account,
)]
fun wrong_account_object_is_rejected() {
    standard_binding().assert_object_graph(
        @0xBAD.to_id(),
        ACCOUNT_NUMBER,
        @0xB.to_id(),
        @0xC.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        type_name::with_original_ids<Collateral>(),
    );
}

#[test]
#[expected_failure(
    abort_code = 13,
    location = blast_boosts_aftermath::venue_account,
)]
fun wrong_account_number_is_rejected() {
    standard_binding().assert_object_graph(
        @0xA11CE.to_id(),
        ACCOUNT_NUMBER + 1,
        @0xB.to_id(),
        @0xC.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        type_name::with_original_ids<Collateral>(),
    );
}

#[test]
#[expected_failure(
    abort_code = 14,
    location = blast_boosts_aftermath::venue_account,
)]
fun wrong_registry_is_rejected() {
    standard_binding().assert_object_graph(
        @0xA11CE.to_id(),
        ACCOUNT_NUMBER,
        @0xBAD.to_id(),
        @0xC.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        type_name::with_original_ids<Collateral>(),
    );
}

#[test]
#[expected_failure(
    abort_code = 15,
    location = blast_boosts_aftermath::venue_account,
)]
fun wrong_clearing_house_is_rejected() {
    standard_binding().assert_object_graph(
        @0xA11CE.to_id(),
        ACCOUNT_NUMBER,
        @0xB.to_id(),
        @0xBAD.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        type_name::with_original_ids<Collateral>(),
    );
}

#[test]
#[expected_failure(
    abort_code = 16,
    location = blast_boosts_aftermath::venue_account,
)]
fun wrong_base_oracle_is_rejected() {
    standard_binding().assert_object_graph(
        @0xA11CE.to_id(),
        ACCOUNT_NUMBER,
        @0xB.to_id(),
        @0xC.to_id(),
        @0xBAD.to_id(),
        @0xE.to_id(),
        type_name::with_original_ids<Collateral>(),
    );
}

#[test]
#[expected_failure(
    abort_code = 17,
    location = blast_boosts_aftermath::venue_account,
)]
fun wrong_collateral_oracle_is_rejected() {
    standard_binding().assert_object_graph(
        @0xA11CE.to_id(),
        ACCOUNT_NUMBER,
        @0xB.to_id(),
        @0xC.to_id(),
        @0xD.to_id(),
        @0xBAD.to_id(),
        type_name::with_original_ids<Collateral>(),
    );
}

#[test]
#[expected_failure(
    abort_code = 18,
    location = blast_boosts_aftermath::venue_account,
)]
fun wrong_collateral_type_is_rejected() {
    standard_binding().assert_object_graph(
        @0xA11CE.to_id(),
        ACCOUNT_NUMBER,
        @0xB.to_id(),
        @0xC.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        type_name::with_original_ids<OtherCollateral>(),
    );
}

#[test]
#[expected_failure(
    abort_code = 12,
    location = blast_boosts_aftermath::venue_account,
)]
fun account_object_precedes_account_number() {
    standard_binding().assert_object_graph(
        @0xBAD.to_id(),
        ACCOUNT_NUMBER + 1,
        @0xB.to_id(),
        @0xC.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        type_name::with_original_ids<Collateral>(),
    );
}

#[test]
#[expected_failure(
    abort_code = 13,
    location = blast_boosts_aftermath::venue_account,
)]
fun account_number_precedes_registry() {
    standard_binding().assert_object_graph(
        @0xA11CE.to_id(),
        ACCOUNT_NUMBER + 1,
        @0xBAD.to_id(),
        @0xC.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        type_name::with_original_ids<Collateral>(),
    );
}

#[test]
#[expected_failure(
    abort_code = 14,
    location = blast_boosts_aftermath::venue_account,
)]
fun registry_precedes_clearing_house() {
    standard_binding().assert_object_graph(
        @0xA11CE.to_id(),
        ACCOUNT_NUMBER,
        @0xBAD.to_id(),
        @0xBAD.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        type_name::with_original_ids<Collateral>(),
    );
}

#[test]
#[expected_failure(
    abort_code = 15,
    location = blast_boosts_aftermath::venue_account,
)]
fun clearing_house_precedes_base_oracle() {
    standard_binding().assert_object_graph(
        @0xA11CE.to_id(),
        ACCOUNT_NUMBER,
        @0xB.to_id(),
        @0xBAD.to_id(),
        @0xBAD.to_id(),
        @0xE.to_id(),
        type_name::with_original_ids<Collateral>(),
    );
}

#[test]
#[expected_failure(
    abort_code = 16,
    location = blast_boosts_aftermath::venue_account,
)]
fun base_oracle_precedes_collateral_oracle() {
    standard_binding().assert_object_graph(
        @0xA11CE.to_id(),
        ACCOUNT_NUMBER,
        @0xB.to_id(),
        @0xC.to_id(),
        @0xBAD.to_id(),
        @0xBAD.to_id(),
        type_name::with_original_ids<Collateral>(),
    );
}

#[test]
#[expected_failure(
    abort_code = 17,
    location = blast_boosts_aftermath::venue_account,
)]
fun collateral_oracle_precedes_collateral_type() {
    standard_binding().assert_object_graph(
        @0xA11CE.to_id(),
        ACCOUNT_NUMBER,
        @0xB.to_id(),
        @0xC.to_id(),
        @0xD.to_id(),
        @0xBAD.to_id(),
        type_name::with_original_ids<OtherCollateral>(),
    );
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

// === Test Helpers ===

/// A real venue admin cap naming `account`, minted by the vendored interface's test constructor.
fun admin_cap_for(account: address, ctx: &mut TxContext): AuthorityCap<ACCOUNT, ADMIN> {
    authority::new_for_testing<ACCOUNT, ADMIN>(account.to_id(), ctx)
}

fun standard_checkpoint(): venue_account::Checkpoint {
    venue_account::checkpoint_for_testing(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, true, 14, 15, 16)
}

fun standard_binding(): Binding {
    venue_account::new_binding(
        @0xA11CE.to_id(),
        ACCOUNT_NUMBER,
        @0xB.to_id(),
        @0xC.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        type_name::with_original_ids<Collateral>(),
    )
}

fun assert_standard_checkpoint(checkpoint: &venue_account::Checkpoint) {
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

use blast_boosts_aftermath::venue_account::{Self, Binding};

use perpetuals::authority::ACCOUNT;

use std::{type_name, unit_test::{assert_eq, destroy}};
