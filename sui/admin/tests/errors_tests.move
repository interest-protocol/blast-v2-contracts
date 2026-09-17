#[test_only]
/// Pins the append-only shared administration error registry.
module blast_admin::errors_tests;

#[test]
fun shared_error_codes_are_stable() {
    assert_eq!(errors::invalid_domain_witness!(), 0);
    assert_eq!(errors::invalid_max_admins!(), 1);
    assert_eq!(errors::invalid_root_transfer_delay!(), 2);
    assert_eq!(errors::invalid_super_admin_cap!(), 3);
    assert_eq!(errors::invalid_admin_cap!(), 4);
    assert_eq!(errors::invalid_admin_recipient!(), 5);
    assert_eq!(errors::admin_capacity_reached!(), 6);
    assert_eq!(errors::invalid_role!(), 7);
    assert_eq!(errors::admin_role_already_granted!(), 8);
    assert_eq!(errors::admin_role_not_granted!(), 9);
    assert_eq!(errors::invalid_super_admin_recipient!(), 10);
    assert_eq!(errors::super_admin_transfer_unchanged!(), 11);
    assert_eq!(errors::super_admin_transfer_time_overflow!(), 12);
    assert_eq!(errors::no_pending_super_admin_transfer!(), 13);
    assert_eq!(errors::not_pending_super_admin_recipient!(), 14);
    assert_eq!(errors::super_admin_transfer_not_ready!(), 15);
    assert_eq!(errors::super_admin_cap_still_active!(), 16);
    assert_eq!(errors::operational_version_mismatch!(), 17);
    assert_eq!(errors::operational_version_overflow!(), 18);
    assert_eq!(errors::invalid_package_publisher!(), 19);
    assert_eq!(errors::invalid_upgrade_cap!(), 20);
    assert_eq!(errors::invalid_package_digest!(), 21);
    assert_eq!(errors::upgrade_cap_unavailable!(), 22);
    assert_eq!(errors::upgrade_policy_not_more_restrictive!(), 23);
}

// === Imports ===

use blast_admin::errors;

use std::unit_test::assert_eq;
