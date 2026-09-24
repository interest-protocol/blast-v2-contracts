// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::errors_tests;

// === Tests ===

#[test]
fun launch_protection_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_protection!(), 50);
    assert_eq!(blast_fun::errors::per_transaction_limit_exceeded!(), 51);
    assert_eq!(blast_fun::errors::cumulative_limit_exceeded!(), 52);
}

#[test]
fun pre_share_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::launch_already_shared!(), 53);
    assert_eq!(blast_fun::errors::pre_share_buy_already_completed!(), 54);
    assert_eq!(blast_fun::errors::pre_share_buy_would_graduate!(), 55);
}

#[test]
fun route_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::route_capacity_reached!(), 57);
    assert_eq!(blast_fun::errors::route_sum_invalid!(), 58);
    assert_eq!(blast_fun::errors::route_duplicate_destination!(), 59);
    assert_eq!(blast_fun::errors::route_invalid_destination!(), 60);
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
    assert_eq!(blast_fun::errors::invalid_curve_fee!(), 41);
    assert_eq!(blast_fun::errors::decimals_not_allowed!(), 42);
    assert_eq!(blast_fun::errors::allocation_sum_invalid!(), 43);
    assert_eq!(blast_fun::errors::duplicate_migration_channel!(), 44);
    assert_eq!(blast_fun::errors::unknown_migration_channel!(), 45);
    assert_eq!(blast_fun::errors::migration_channel_capacity_reached!(), 46);
    assert_eq!(blast_fun::errors::invalid_liquidity_channel!(), 47);
    assert_eq!(blast_fun::errors::protocol_channel_mismatch!(), 48);
    assert_eq!(blast_fun::errors::invalid_graduation_target!(), 49);
    assert_eq!(blast_fun::errors::migration_settlement_mismatch!(), 56);
    assert_eq!(blast_fun::errors::meme_symbol_too_long!(), 61);
    assert_eq!(blast_fun::errors::launch_settings_incomplete!(), 62);
}

#[test]
fun creator_authority_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::curve_fee_cap_not_live!(), 38);
    assert_eq!(blast_fun::errors::metadata_unchanged!(), 39);
    assert_eq!(blast_fun::errors::metadata_cap_not_live!(), 40);
}

#[test]
/// Only Blast's own module-provenance rule remains local; every reusable
/// custody, policy, and generation code now belongs to `blast_admin`.
fun package_admin_error_registry_is_stable() {
    assert_eq!(blast_fun::errors::invalid_package_publisher!(), 24);
}

// === Imports ===

use std::unit_test::assert_eq;
