// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_aftermath::errors_tests;

// === Tests ===

// Every code is pinned so a renumbering is a deliberate, reviewed edit.

#[test]
/// Codes 0 to 13.
fun error_registry_first_half_is_sequential() {
    assert_eq!(errors::invalid_product_witness_type!(), 0);
    assert_eq!(errors::admin_cap_account_mismatch!(), 1);
    assert_eq!(errors::account_object_mismatch!(), 2);
    assert_eq!(errors::account_number_mismatch!(), 3);
    assert_eq!(errors::registry_mismatch!(), 4);
    assert_eq!(errors::clearing_house_mismatch!(), 5);
    assert_eq!(errors::base_oracle_mismatch!(), 6);
    assert_eq!(errors::collateral_oracle_mismatch!(), 7);
    assert_eq!(errors::oracle_observation_mismatch!(), 8);
    assert_eq!(errors::normalization_overflow!(), 9);
    assert_eq!(errors::invalid_collateral_decimals!(), 10);
    assert_eq!(errors::invalid_seed!(), 11);
    assert_eq!(errors::invalid_seed_reserve!(), 12);
    assert_eq!(errors::invalid_initialization_order_size!(), 13);
}

#[test]
/// Codes 14 to 35.
fun error_registry_second_half_is_sequential() {
    assert_eq!(errors::initialization_fill_mismatch!(), 14);
    assert_eq!(errors::initialization_imr_mismatch!(), 15);
    assert_eq!(errors::locked_shares_overflow!(), 16);
    assert_eq!(errors::initialization_order_count_exceeded!(), 17);
    assert_eq!(errors::zero_amount!(), 18);
    assert_eq!(errors::insufficient_admin_cash!(), 19);
    assert_eq!(errors::cash_checkpoint_mismatch!(), 20);
    assert_eq!(errors::fill_mismatch!(), 21);
    assert_eq!(errors::orders_posted!(), 22);
    assert_eq!(errors::liquidation!(), 23);
    assert_eq!(errors::active_order_count_exceeded!(), 24);
    assert_eq!(errors::deadline_expired!(), 25);
    assert_eq!(errors::active_checkpoint_mismatch!(), 26);
    assert_eq!(errors::redemption_share_mismatch!(), 27);
    assert_eq!(errors::venue_fee_unusable!(), 28);
    assert_eq!(errors::unresolved_checkpoint!(), 29);
    assert_eq!(errors::terminal_venue_unsettled!(), 30);
    assert_eq!(errors::invalid_unwind_exposure!(), 31);
    assert_eq!(errors::venue_not_ready!(), 32);
    assert_eq!(errors::metadata_unchanged!(), 33);
    assert_eq!(errors::priority_gas_price!(), 34);
    assert_eq!(errors::invalid_rebaseline!(), 35);
}

#[test]
fun redemption_exceeds_releasable_code_is_pinned() {
    assert_eq!(errors::redemption_exceeds_releasable!(), 36);
}

#[test]
fun profit_realization_no_progress_code_is_pinned() {
    assert_eq!(errors::profit_realization_no_progress!(), 37);
}

// === Imports ===

use blast_boosts_aftermath::errors;

use std::unit_test::assert_eq;
