#[test_only]
module blast_leverage_aftermath::errors_tests;

use blast_leverage_aftermath::errors;
use std::unit_test::assert_eq;

#[test]
fun adapter_error_registry_is_stable() {
    assert_eq!(errors::package_version_mismatch!(), 0);
    assert_eq!(errors::package_version_overflow!(), 1);
    assert_eq!(errors::invalid_risk_module_witness_type!(), 2);
    assert_eq!(errors::risk_module_witness_unchanged!(), 3);
    assert_eq!(errors::invalid_package_publisher!(), 4);
    assert_eq!(errors::invalid_upgrade_cap!(), 5);
    assert_eq!(errors::invalid_package_digest!(), 6);
    assert_eq!(
        errors::upgrade_policy_not_more_restrictive!(),
        7,
    );
    assert_eq!(errors::invalid_product_witness_type!(), 8);
    assert_eq!(errors::product_witness_package_mismatch!(), 9);
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
}
