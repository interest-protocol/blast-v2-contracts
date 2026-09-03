#[test_only]
module blast_leverage_series_one::authority_errors_tests;

use std::unit_test::assert_eq;

// === Tests ===

/// Pins the appended version and authority codes without overflowing one bytecode table.
#[test]
fun version_and_authority_error_registry_is_stable() {
    assert_eq!(blast_leverage_series_one::errors::package_version_mismatch!(), 38);
    assert_eq!(blast_leverage_series_one::errors::package_version_overflow!(), 39);
    assert_eq!(blast_leverage_series_one::errors::invalid_super_admin_cap!(), 40);
    assert_eq!(blast_leverage_series_one::errors::invalid_admin_cap!(), 41);
    assert_eq!(blast_leverage_series_one::errors::invalid_admin_recipient!(), 42);
    assert_eq!(blast_leverage_series_one::errors::admin_capacity_reached!(), 43);
    assert_eq!(blast_leverage_series_one::errors::invalid_admin_roles!(), 44);
    assert_eq!(blast_leverage_series_one::errors::invalid_admin_role!(), 45);
    assert_eq!(
        blast_leverage_series_one::errors::admin_role_already_granted!(),
        46,
    );
    assert_eq!(
        blast_leverage_series_one::errors::admin_role_not_granted!(),
        47,
    );
    assert_eq!(
        blast_leverage_series_one::errors::invalid_super_admin_recipient!(),
        48,
    );
    assert_eq!(
        blast_leverage_series_one::errors::no_pending_super_admin_transfer!(),
        49,
    );
    assert_eq!(
        blast_leverage_series_one::errors::not_pending_super_admin_recipient!(),
        50,
    );
    assert_eq!(
        blast_leverage_series_one::errors::super_admin_transfer_not_ready!(),
        51,
    );
    assert_eq!(
        blast_leverage_series_one::errors::super_admin_transfer_time_overflow!(),
        52,
    );
    assert_eq!(
        blast_leverage_series_one::errors::super_admin_cap_still_active!(),
        53,
    );
    assert_eq!(
        blast_leverage_series_one::errors::super_admin_transfer_unchanged!(),
        54,
    );
}
