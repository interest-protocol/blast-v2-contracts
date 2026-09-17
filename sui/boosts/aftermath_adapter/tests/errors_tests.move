#[test_only]
module blast_boosts_aftermath::errors_tests;

#[test]
fun adapter_error_registry_is_stable() {
    // Codes 0, 1, 5, 6, and 7 are retired: generation checking, custody
    // provenance, digest length, and policy narrowing raise `blast_admin` codes.
    assert_eq!(errors::invalid_risk_module_witness_type!(), 2);
    assert_eq!(errors::risk_module_witness_unchanged!(), 3);
    assert_eq!(errors::invalid_package_publisher!(), 4);
    assert_eq!(errors::invalid_product_witness_type!(), 8);
    assert_eq!(errors::risk_module_witness_mismatch!(), 10);
    assert_eq!(errors::admin_cap_account_mismatch!(), 11);
    assert_eq!(errors::account_object_mismatch!(), 12);
    assert_eq!(errors::account_number_mismatch!(), 13);
    assert_eq!(errors::registry_mismatch!(), 14);
    assert_eq!(errors::clearing_house_mismatch!(), 15);
    assert_eq!(errors::base_oracle_mismatch!(), 16);
    assert_eq!(errors::collateral_oracle_mismatch!(), 17);
    assert_eq!(errors::collateral_type_mismatch!(), 18);
    assert_eq!(errors::venue_account_already_installed!(), 19);
    assert_eq!(errors::oracle_storage_mismatch!(), 20);
    assert_eq!(errors::oracle_source_mismatch!(), 21);
    assert_eq!(errors::pyth_price_info_mismatch!(), 22);
    assert_eq!(errors::invalid_pyth_price!(), 23);
    assert_eq!(errors::pyth_normalization_overflow!(), 24);
    assert_eq!(errors::oracle_observation_mismatch!(), 25);
    assert_eq!(errors::normalization_overflow!(), 26);
    assert_eq!(errors::incoherent_position_signs!(), 27);
    assert_eq!(errors::invalid_collateral_decimals!(), 28);
    assert_eq!(errors::invalid_seed!(), 29);
    assert_eq!(errors::invalid_seed_reserve!(), 30);
    assert_eq!(errors::share_supply_not_zero!(), 31);
    assert_eq!(errors::invalid_initialization_order_size!(), 32);
    assert_eq!(errors::initialization_fill_mismatch!(), 33);
    assert_eq!(errors::initialization_orders_posted!(), 34);
    assert_eq!(errors::initialization_liquidation!(), 35);
    assert_eq!(errors::initialization_imr_mismatch!(), 36);
    assert_eq!(errors::locked_shares_overflow!(), 37);
    assert_eq!(errors::initialization_order_count_exceeded!(), 38);
    assert_eq!(errors::venue_account_not_installed!(), 39);
}

#[test]
fun active_lifecycle_error_registry_is_stable() {
    assert_eq!(errors::zero_amount!(), 40);
    assert_eq!(errors::insufficient_admin_cash!(), 41);
    assert_eq!(errors::cash_checkpoint_mismatch!(), 42);
    assert_eq!(errors::active_fill_mismatch!(), 43);
    assert_eq!(errors::active_orders_posted!(), 44);
    assert_eq!(errors::active_liquidation!(), 45);
    assert_eq!(errors::active_order_count_exceeded!(), 46);
    assert_eq!(errors::deadline_expired!(), 47);
    assert_eq!(errors::active_checkpoint_mismatch!(), 48);
    assert_eq!(errors::redemption_share_mismatch!(), 49);
    assert_eq!(errors::venue_fee_unusable!(), 50);
    assert_eq!(errors::seed_already_recorded!(), 51);
    assert_eq!(errors::invalid_seed_funder!(), 52);
    assert_eq!(errors::unresolved_checkpoint!(), 53);
    assert_eq!(errors::terminal_venue_unsettled!(), 54);
    assert_eq!(errors::invalid_unwind_exposure!(), 55);
}

// === Imports ===

use blast_boosts_aftermath::errors;

use std::unit_test::assert_eq;
