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
}
