#[test_only]
module blast_boosts_aftermath::errors_tests;

// Every code is pinned so a renumbering is a deliberate, reviewed edit.

#[test]
/// Codes 0 to 17.
fun error_registry_first_half_is_sequential() {
    assert_eq!(errors::invalid_package_publisher!(), 0);
    assert_eq!(errors::invalid_product_witness_type!(), 1);
    assert_eq!(errors::admin_cap_account_mismatch!(), 2);
    assert_eq!(errors::account_object_mismatch!(), 3);
    assert_eq!(errors::account_number_mismatch!(), 4);
    assert_eq!(errors::registry_mismatch!(), 5);
    assert_eq!(errors::clearing_house_mismatch!(), 6);
    assert_eq!(errors::base_oracle_mismatch!(), 7);
    assert_eq!(errors::collateral_oracle_mismatch!(), 8);
    assert_eq!(errors::oracle_storage_mismatch!(), 9);
    assert_eq!(errors::oracle_source_mismatch!(), 10);
    assert_eq!(errors::pyth_price_info_mismatch!(), 11);
    assert_eq!(errors::oracle_observation_mismatch!(), 12);
    assert_eq!(errors::normalization_overflow!(), 13);
    assert_eq!(errors::invalid_collateral_decimals!(), 14);
    assert_eq!(errors::invalid_seed!(), 15);
    assert_eq!(errors::invalid_seed_reserve!(), 16);
    assert_eq!(errors::invalid_initialization_order_size!(), 17);
}

#[test]
/// Codes 18 to 36.
fun error_registry_second_half_is_sequential() {
    assert_eq!(errors::initialization_fill_mismatch!(), 18);
    assert_eq!(errors::initialization_imr_mismatch!(), 19);
    assert_eq!(errors::locked_shares_overflow!(), 20);
    assert_eq!(errors::initialization_order_count_exceeded!(), 21);
    assert_eq!(errors::zero_amount!(), 22);
    assert_eq!(errors::insufficient_admin_cash!(), 23);
    assert_eq!(errors::cash_checkpoint_mismatch!(), 24);
    assert_eq!(errors::fill_mismatch!(), 25);
    assert_eq!(errors::orders_posted!(), 26);
    assert_eq!(errors::liquidation!(), 27);
    assert_eq!(errors::active_order_count_exceeded!(), 28);
    assert_eq!(errors::deadline_expired!(), 29);
    assert_eq!(errors::active_checkpoint_mismatch!(), 30);
    assert_eq!(errors::redemption_share_mismatch!(), 31);
    assert_eq!(errors::venue_fee_unusable!(), 32);
    assert_eq!(errors::unresolved_checkpoint!(), 33);
    assert_eq!(errors::terminal_venue_unsettled!(), 34);
    assert_eq!(errors::invalid_unwind_exposure!(), 35);
    assert_eq!(errors::venue_not_ready!(), 36);
}

// === Imports ===

use blast_boosts_aftermath::errors;

use std::unit_test::assert_eq;
