#[test_only]
module blast_leverage_series_one::acl_role_constants_tests;

use blast_leverage_series_one::constants;
use std::unit_test::assert_eq;

// === Tests ===

/// Pins the role-bit ABI used by transaction builders and future consumers.
#[test]
fun role_bits_are_stable_and_compose_to_the_complete_set() {
    assert_eq!(constants::vault_issuer_role!(), 1);
    assert_eq!(constants::risk_admin_role!(), 2);
    assert_eq!(constants::adapter_admin_role!(), 4);
    assert_eq!(constants::shutdown_admin_role!(), 8);
    assert_eq!(constants::package_admin_role!(), 16);
    assert_eq!(constants::all_admin_roles!(), 31);
}
