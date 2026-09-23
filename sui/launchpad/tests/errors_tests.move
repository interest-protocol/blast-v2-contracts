// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::errors_tests;

// === Tests ===

#[test]
fun launch_protection_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_protection!(), 53);
    assert_eq!(blast_fun::errors::per_transaction_limit_exceeded!(), 54);
    assert_eq!(blast_fun::errors::cumulative_limit_exceeded!(), 55);
}

#[test]
fun pre_share_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::launch_already_shared!(), 56);
    assert_eq!(blast_fun::errors::pre_share_buy_already_completed!(), 57);
    assert_eq!(blast_fun::errors::pre_share_buy_would_graduate!(), 58);
}

#[test]
fun recurring_router_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::router_mismatch!(), 60);
    assert_eq!(blast_fun::errors::router_not_active!(), 61);
    assert_eq!(blast_fun::errors::router_already_active!(), 62);
    assert_eq!(blast_fun::errors::route_capacity_reached!(), 63);
    assert_eq!(blast_fun::errors::route_sum_invalid!(), 64);
    assert_eq!(blast_fun::errors::route_duplicate_destination!(), 65);
    assert_eq!(blast_fun::errors::route_invalid_destination!(), 66);
    assert_eq!(blast_fun::errors::route_unchanged!(), 67);
    assert_eq!(blast_fun::errors::settlement_binding_mismatch!(), 68);
    assert_eq!(blast_fun::errors::protocol_destination_unchanged!(), 69);
}

#[test]
fun authority_and_claim_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_creator_claim_public_key!(), 0);
    assert_eq!(blast_fun::errors::creator_claim_signer_inactive!(), 1);
    assert_eq!(blast_fun::errors::invalid_creator_claim_signature!(), 2);
    assert_eq!(blast_fun::errors::invalid_creator_recipient!(), 3);
    assert_eq!(blast_fun::errors::invalid_account_commitment!(), 4);
    assert_eq!(blast_fun::errors::unexpected_creator_claim_attestation!(), 5);
    assert_eq!(blast_fun::errors::creator_claim_expired!(), 6);
    assert_eq!(blast_fun::errors::creator_claim_signer_unchanged!(), 7);
    assert_eq!(blast_fun::errors::missing_creator_claim_attestation!(), 8);
    assert_eq!(blast_fun::errors::creator_not_sender!(), 9);
    assert_eq!(blast_fun::errors::invalid_creator_claim_attestation!(), 10);
}

#[test]
fun market_and_launch_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_curve_reserve!(), 11);
    assert_eq!(blast_fun::errors::invalid_quote_fee_bps!(), 12);
    assert_eq!(blast_fun::errors::zero_trade_input!(), 13);
    assert_eq!(blast_fun::errors::zero_trade_output!(), 14);
    assert_eq!(blast_fun::errors::sell_back_invariant_violated!(), 15);
    assert_eq!(blast_fun::errors::invalid_meme_fee_bps!(), 16);
    assert_eq!(blast_fun::errors::nothing_accrued!(), 17);
    assert_eq!(blast_fun::errors::zero_fee_accrual!(), 18);
    assert_eq!(blast_fun::errors::protocol_fee_share_unchanged!(), 19);
    assert_eq!(blast_fun::errors::quote_not_allowed!(), 20);
    assert_eq!(blast_fun::errors::migration_witness_already_allowed!(), 21);
    assert_eq!(blast_fun::errors::migration_witness_capacity_reached!(), 22);
    assert_eq!(blast_fun::errors::migration_witness_not_allowed!(), 23);
    assert_eq!(blast_fun::errors::invalid_virtual_quote!(), 25);
    assert_eq!(blast_fun::errors::quote_parameters_unchanged!(), 26);
    assert_eq!(blast_fun::errors::creator_authority_unavailable!(), 27);
    assert_eq!(blast_fun::errors::trade_fee_defaults_unchanged!(), 28);
    assert_eq!(blast_fun::errors::invalid_launch_lifecycle!(), 29);
    assert_eq!(blast_fun::errors::slippage_exceeded!(), 30);
    assert_eq!(blast_fun::errors::invalid_migration_witness!(), 31);
    assert_eq!(blast_fun::errors::invalid_bps!(), 32);
    assert_eq!(blast_fun::errors::invalid_meme_quote_pair!(), 33);
    assert_eq!(blast_fun::errors::invalid_initial_meme_supply!(), 34);
    assert_eq!(blast_fun::errors::invalid_migration_witness_type!(), 35);
    assert_eq!(blast_fun::errors::invalid_sell_burn_bps!(), 36);
    assert_eq!(blast_fun::errors::constant_product_invariant_decreased!(), 37);
}

#[test]
fun reusable_launch_and_allocation_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_curve_fee!(), 44);
    assert_eq!(blast_fun::errors::decimals_not_allowed!(), 45);
    assert_eq!(blast_fun::errors::allocation_sum_invalid!(), 46);
    assert_eq!(blast_fun::errors::duplicate_migration_channel!(), 47);
    assert_eq!(blast_fun::errors::unknown_migration_channel!(), 48);
    assert_eq!(blast_fun::errors::migration_channel_capacity_reached!(), 49);
    assert_eq!(blast_fun::errors::invalid_liquidity_channel!(), 50);
    assert_eq!(blast_fun::errors::protocol_channel_mismatch!(), 51);
    assert_eq!(blast_fun::errors::invalid_graduation_target!(), 52);
    assert_eq!(blast_fun::errors::migration_settlement_mismatch!(), 59);
}

#[test]
fun creator_authority_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::curve_fee_cap_not_live!(), 38);
    assert_eq!(blast_fun::errors::metadata_unchanged!(), 39);
    assert_eq!(blast_fun::errors::creator_fees_locked!(), 40);
    assert_eq!(blast_fun::errors::creator_custodian_mismatch!(), 41);
    assert_eq!(blast_fun::errors::metadata_cap_not_live!(), 42);
    assert_eq!(blast_fun::errors::invalid_fee_custodian!(), 43);
}

#[test]
/// Only Blast's own module-provenance rule remains local; every reusable
/// custody, policy, and generation code now belongs to `blast_admin`.
fun package_admin_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_package_publisher!(), 24);
}

// === Imports ===

use std::unit_test::assert_eq;
