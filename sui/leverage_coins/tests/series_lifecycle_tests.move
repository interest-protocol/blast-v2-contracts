#[test_only]
/// Series lifecycle transitions and operation-permission matrix.
module blast_leverage_coins::series_lifecycle_tests;

use blast_leverage_coins::{errors, series_lifecycle};

// === Tests ===

#[test]
fun a_new_lifecycle_is_active() {
    let lifecycle = series_lifecycle::new();

    assert!(lifecycle.is_active());
}

#[test]
fun lifecycle_variants_are_distinct() {
    let active = series_lifecycle::new();
    let reduce_only = series_lifecycle::reduce_only_for_testing();
    let shutdown_pending = series_lifecycle::shutdown_pending_for_testing();
    let shutdown_settled = series_lifecycle::shutdown_settled_for_testing();

    assert!(active.is_active());
    assert!(!active.is_reduce_only());
    assert!(!active.is_shutdown_pending());
    assert!(!active.is_shutdown_settled());
    assert!(!reduce_only.is_active());
    assert!(reduce_only.is_reduce_only());
    assert!(!reduce_only.is_shutdown_pending());
    assert!(!reduce_only.is_shutdown_settled());
    assert!(!shutdown_pending.is_active());
    assert!(!shutdown_pending.is_reduce_only());
    assert!(shutdown_pending.is_shutdown_pending());
    assert!(!shutdown_pending.is_shutdown_settled());
    assert!(!shutdown_settled.is_active());
    assert!(!shutdown_settled.is_reduce_only());
    assert!(!shutdown_settled.is_shutdown_pending());
    assert!(shutdown_settled.is_shutdown_settled());
}

#[test]
fun active_can_enter_reduce_only() {
    let mut lifecycle = series_lifecycle::new();

    lifecycle.enter_reduce_only();

    assert!(lifecycle.is_reduce_only());
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_coins::series_lifecycle,
)]
fun reduce_only_cannot_enter_reduce_only_again() {
    let mut lifecycle = series_lifecycle::reduce_only_for_testing();

    lifecycle.enter_reduce_only();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_coins::series_lifecycle,
)]
fun shutdown_pending_cannot_enter_reduce_only() {
    let mut lifecycle = series_lifecycle::shutdown_pending_for_testing();

    lifecycle.enter_reduce_only();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_coins::series_lifecycle,
)]
fun shutdown_settled_cannot_enter_reduce_only() {
    let mut lifecycle = series_lifecycle::shutdown_settled_for_testing();

    lifecycle.enter_reduce_only();
}

#[test]
fun active_can_enter_shutdown_pending() {
    let mut lifecycle = series_lifecycle::new();

    lifecycle.enter_shutdown_pending();

    assert!(lifecycle.is_shutdown_pending());
}

#[test]
fun reduce_only_can_enter_shutdown_pending() {
    let mut lifecycle = series_lifecycle::reduce_only_for_testing();

    lifecycle.enter_shutdown_pending();

    assert!(lifecycle.is_shutdown_pending());
}

#[test]
fun lifecycle_degrades_through_the_complete_operating_chain() {
    let mut lifecycle = series_lifecycle::new();

    lifecycle.enter_reduce_only();
    lifecycle.enter_shutdown_pending();

    assert!(lifecycle.is_shutdown_pending());
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_coins::series_lifecycle,
)]
fun shutdown_pending_cannot_enter_shutdown_pending_again() {
    let mut lifecycle = series_lifecycle::shutdown_pending_for_testing();

    lifecycle.enter_shutdown_pending();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_coins::series_lifecycle,
)]
fun shutdown_settled_cannot_enter_shutdown_pending() {
    let mut lifecycle = series_lifecycle::shutdown_settled_for_testing();

    lifecycle.enter_shutdown_pending();
}

#[test]
fun active_permits_active_operations() {
    series_lifecycle::new().assert_active();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_coins::series_lifecycle,
)]
fun reduce_only_rejects_active_operations() {
    series_lifecycle::reduce_only_for_testing().assert_active();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_coins::series_lifecycle,
)]
fun shutdown_pending_rejects_active_operations() {
    series_lifecycle::shutdown_pending_for_testing().assert_active();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_coins::series_lifecycle,
)]
fun shutdown_settled_rejects_active_operations() {
    series_lifecycle::shutdown_settled_for_testing().assert_active();
}

#[test]
fun active_permits_normal_redemption() {
    series_lifecycle::new().assert_normal_redemption_allowed();
}

#[test]
fun reduce_only_permits_normal_redemption() {
    series_lifecycle::reduce_only_for_testing().assert_normal_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_coins::series_lifecycle,
)]
fun shutdown_pending_rejects_normal_redemption() {
    series_lifecycle::shutdown_pending_for_testing().assert_normal_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_coins::series_lifecycle,
)]
fun shutdown_settled_rejects_normal_redemption() {
    series_lifecycle::shutdown_settled_for_testing().assert_normal_redemption_allowed();
}

#[test]
fun active_permits_risk_reduction() {
    series_lifecycle::new().assert_operating_risk_reduction_allowed();
}

#[test]
fun reduce_only_permits_risk_reduction() {
    series_lifecycle::reduce_only_for_testing().assert_operating_risk_reduction_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_coins::series_lifecycle,
)]
fun shutdown_pending_rejects_operating_risk_reduction() {
    series_lifecycle::shutdown_pending_for_testing()
        .assert_operating_risk_reduction_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_coins::series_lifecycle,
)]
fun shutdown_settled_rejects_operating_risk_reduction() {
    series_lifecycle::shutdown_settled_for_testing()
        .assert_operating_risk_reduction_allowed();
}

#[test]
fun shutdown_pending_permits_shutdown_close() {
    series_lifecycle::shutdown_pending_for_testing().assert_shutdown_close_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_coins::series_lifecycle,
)]
fun active_rejects_shutdown_close() {
    series_lifecycle::new().assert_shutdown_close_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_coins::series_lifecycle,
)]
fun reduce_only_rejects_shutdown_close() {
    series_lifecycle::reduce_only_for_testing().assert_shutdown_close_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_coins::series_lifecycle,
)]
fun shutdown_settled_rejects_shutdown_close() {
    series_lifecycle::shutdown_settled_for_testing().assert_shutdown_close_allowed();
}

#[test]
fun shutdown_settled_permits_shutdown_redemption() {
    series_lifecycle::shutdown_settled_for_testing()
        .assert_shutdown_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_coins::series_lifecycle,
)]
fun active_rejects_shutdown_redemption() {
    series_lifecycle::new().assert_shutdown_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_coins::series_lifecycle,
)]
fun reduce_only_rejects_shutdown_redemption() {
    series_lifecycle::reduce_only_for_testing().assert_shutdown_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_coins::series_lifecycle,
)]
fun shutdown_pending_rejects_shutdown_redemption() {
    series_lifecycle::shutdown_pending_for_testing()
        .assert_shutdown_redemption_allowed();
}
