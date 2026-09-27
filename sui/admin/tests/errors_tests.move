// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Pins the shared administration error registry.
module blast_admin::errors_tests;

// === Tests ===

#[test]
fun shared_error_codes_are_stable() {
    assert_eq!(errors::invalid_super_admin_cap!(), 0);
    assert_eq!(errors::invalid_admin_cap!(), 1);
    assert_eq!(errors::invalid_admin_recipient!(), 2);
    assert_eq!(errors::admin_capacity_reached!(), 3);
    assert_eq!(errors::admin_role_capacity_reached!(), 4);
    assert_eq!(errors::admin_role_already_granted!(), 5);
    assert_eq!(errors::admin_role_not_granted!(), 6);
    assert_eq!(errors::invalid_super_admin_transfer_delay!(), 7);
    assert_eq!(errors::invalid_super_admin_recipient!(), 8);
    assert_eq!(errors::super_admin_transfer_unchanged!(), 9);
    assert_eq!(errors::super_admin_transfer_time_overflow!(), 10);
    assert_eq!(errors::no_pending_super_admin_transfer!(), 11);
    assert_eq!(errors::not_pending_super_admin_recipient!(), 12);
    assert_eq!(errors::super_admin_transfer_not_ready!(), 13);
    assert_eq!(errors::super_admin_cap_still_active!(), 14);
    assert_eq!(errors::operational_version_mismatch!(), 15);
    assert_eq!(errors::operational_version_overflow!(), 16);
    assert_eq!(errors::invalid_package_publisher!(), 17);
    assert_eq!(errors::invalid_upgrade_cap!(), 18);
    assert_eq!(errors::invalid_package_digest!(), 19);
    assert_eq!(errors::upgrade_cap_unavailable!(), 20);
    assert_eq!(errors::upgrade_policy_not_more_restrictive!(), 21);
}

// === Imports ===

use blast_admin::errors;

use std::unit_test::assert_eq;
