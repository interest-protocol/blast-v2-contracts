#[test_only]
/// Series lifecycle transitions and operation-permission matrix.
module blast_leverage_series_one::lifecycle_tests;

use blast_leverage_series_one::{errors, lifecycle};

// === Tests ===

#[test]
fun a_new_lifecycle_is_uninitialized() {
    let lifecycle = lifecycle::new();

    assert!(lifecycle.is_uninitialized());
}

#[test]
fun lifecycle_variants_are_distinct() {
    let uninitialized = lifecycle::new();
    let active = lifecycle::active_for_testing();
    let reduce_only = lifecycle::reduce_only_for_testing();
    let shutdown_pending = lifecycle::shutdown_pending_for_testing();
    let shutdown_settled = lifecycle::shutdown_settled_for_testing();

    assert!(uninitialized.is_uninitialized());
    assert!(!uninitialized.is_active());
    assert!(!uninitialized.is_reduce_only());
    assert!(!uninitialized.is_shutdown_pending());
    assert!(!uninitialized.is_shutdown_settled());
    assert!(!active.is_uninitialized());
    assert!(active.is_active());
    assert!(!active.is_reduce_only());
    assert!(!active.is_shutdown_pending());
    assert!(!active.is_shutdown_settled());
    assert!(!reduce_only.is_active());
    assert!(!reduce_only.is_uninitialized());
    assert!(reduce_only.is_reduce_only());
    assert!(!reduce_only.is_shutdown_pending());
    assert!(!reduce_only.is_shutdown_settled());
    assert!(!shutdown_pending.is_active());
    assert!(!shutdown_pending.is_uninitialized());
    assert!(!shutdown_pending.is_reduce_only());
    assert!(shutdown_pending.is_shutdown_pending());
    assert!(!shutdown_pending.is_shutdown_settled());
    assert!(!shutdown_settled.is_active());
    assert!(!shutdown_settled.is_uninitialized());
    assert!(!shutdown_settled.is_reduce_only());
    assert!(!shutdown_settled.is_shutdown_pending());
    assert!(shutdown_settled.is_shutdown_settled());
}

// --- Activation ---

#[test]
fun uninitialized_can_activate() {
    let mut lifecycle = lifecycle::new();

    lifecycle.activate();

    assert!(lifecycle.is_active());
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun active_cannot_activate_again() {
    let mut lifecycle = lifecycle::active_for_testing();

    lifecycle.activate();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun reduce_only_cannot_activate() {
    let mut lifecycle = lifecycle::reduce_only_for_testing();

    lifecycle.activate();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun shutdown_pending_cannot_activate() {
    let mut lifecycle = lifecycle::shutdown_pending_for_testing();

    lifecycle.activate();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun shutdown_settled_cannot_activate() {
    let mut lifecycle = lifecycle::shutdown_settled_for_testing();

    lifecycle.activate();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun uninitialized_cannot_enter_reduce_only() {
    let mut lifecycle = lifecycle::new();

    lifecycle.enter_reduce_only();
}

#[test]
fun active_can_enter_reduce_only() {
    let mut lifecycle = lifecycle::active_for_testing();

    lifecycle.enter_reduce_only();

    assert!(lifecycle.is_reduce_only());
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun reduce_only_cannot_enter_reduce_only_again() {
    let mut lifecycle = lifecycle::reduce_only_for_testing();

    lifecycle.enter_reduce_only();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun shutdown_pending_cannot_enter_reduce_only() {
    let mut lifecycle = lifecycle::shutdown_pending_for_testing();

    lifecycle.enter_reduce_only();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun shutdown_settled_cannot_enter_reduce_only() {
    let mut lifecycle = lifecycle::shutdown_settled_for_testing();

    lifecycle.enter_reduce_only();
}

#[test]
fun active_can_enter_shutdown_pending() {
    let mut lifecycle = lifecycle::active_for_testing();

    lifecycle.enter_shutdown_pending();

    assert!(lifecycle.is_shutdown_pending());
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun uninitialized_cannot_enter_shutdown_pending() {
    let mut lifecycle = lifecycle::new();

    lifecycle.enter_shutdown_pending();
}

#[test]
fun reduce_only_can_enter_shutdown_pending() {
    let mut lifecycle = lifecycle::reduce_only_for_testing();

    lifecycle.enter_shutdown_pending();

    assert!(lifecycle.is_shutdown_pending());
}

#[test]
fun lifecycle_degrades_through_the_complete_operating_chain() {
    let mut lifecycle = lifecycle::active_for_testing();

    lifecycle.enter_reduce_only();
    lifecycle.enter_shutdown_pending();

    assert!(lifecycle.is_shutdown_pending());
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun shutdown_pending_cannot_enter_shutdown_pending_again() {
    let mut lifecycle = lifecycle::shutdown_pending_for_testing();

    lifecycle.enter_shutdown_pending();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun shutdown_settled_cannot_enter_shutdown_pending() {
    let mut lifecycle = lifecycle::shutdown_settled_for_testing();

    lifecycle.enter_shutdown_pending();
}

#[test]
fun active_permits_active_operations() {
    lifecycle::active_for_testing().assert_active();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun uninitialized_rejects_active_operations() {
    lifecycle::new().assert_active();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun reduce_only_rejects_active_operations() {
    lifecycle::reduce_only_for_testing().assert_active();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun shutdown_pending_rejects_active_operations() {
    lifecycle::shutdown_pending_for_testing().assert_active();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun shutdown_settled_rejects_active_operations() {
    lifecycle::shutdown_settled_for_testing().assert_active();
}

#[test]
fun active_permits_normal_redemption() {
    lifecycle::active_for_testing().assert_normal_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun uninitialized_rejects_normal_redemption() {
    lifecycle::new().assert_normal_redemption_allowed();
}

#[test]
fun reduce_only_permits_normal_redemption() {
    lifecycle::reduce_only_for_testing().assert_normal_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun shutdown_pending_rejects_normal_redemption() {
    lifecycle::shutdown_pending_for_testing().assert_normal_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun shutdown_settled_rejects_normal_redemption() {
    lifecycle::shutdown_settled_for_testing().assert_normal_redemption_allowed();
}

#[test]
fun active_permits_risk_reduction() {
    lifecycle::active_for_testing().assert_operating_risk_reduction_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun uninitialized_rejects_operating_risk_reduction() {
    lifecycle::new().assert_operating_risk_reduction_allowed();
}

#[test]
fun reduce_only_permits_risk_reduction() {
    lifecycle::reduce_only_for_testing().assert_operating_risk_reduction_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun shutdown_pending_rejects_operating_risk_reduction() {
    lifecycle::shutdown_pending_for_testing()
        .assert_operating_risk_reduction_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun shutdown_settled_rejects_operating_risk_reduction() {
    lifecycle::shutdown_settled_for_testing()
        .assert_operating_risk_reduction_allowed();
}

#[test]
fun shutdown_pending_permits_shutdown_close() {
    lifecycle::shutdown_pending_for_testing().assert_shutdown_close_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun uninitialized_rejects_shutdown_close() {
    lifecycle::new().assert_shutdown_close_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun active_rejects_shutdown_close() {
    lifecycle::active_for_testing().assert_shutdown_close_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun reduce_only_rejects_shutdown_close() {
    lifecycle::reduce_only_for_testing().assert_shutdown_close_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun shutdown_settled_rejects_shutdown_close() {
    lifecycle::shutdown_settled_for_testing().assert_shutdown_close_allowed();
}

#[test]
fun shutdown_settled_permits_shutdown_redemption() {
    lifecycle::shutdown_settled_for_testing()
        .assert_shutdown_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun uninitialized_rejects_shutdown_redemption() {
    lifecycle::new().assert_shutdown_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun active_rejects_shutdown_redemption() {
    lifecycle::active_for_testing().assert_shutdown_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun reduce_only_rejects_shutdown_redemption() {
    lifecycle::reduce_only_for_testing().assert_shutdown_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle,
    location = blast_leverage_series_one::lifecycle,
)]
fun shutdown_pending_rejects_shutdown_redemption() {
    lifecycle::shutdown_pending_for_testing()
        .assert_shutdown_redemption_allowed();
}

// --- Idempotent degradation for the objective health transition ---

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun uninitialized_cannot_degrade_to_reduce_only() {
    let mut lifecycle = lifecycle::new();

    lifecycle.degrade_to_reduce_only();
}

#[test]
fun active_degrades_to_reduce_only() {
    let mut lifecycle = lifecycle::active_for_testing();

    lifecycle.degrade_to_reduce_only();

    assert!(lifecycle.is_reduce_only());
}

#[test]
fun degrading_an_already_reduce_only_lifecycle_is_a_no_op() {
    let mut lifecycle = lifecycle::reduce_only_for_testing();

    lifecycle.degrade_to_reduce_only();

    assert!(lifecycle.is_reduce_only());
}

#[test]
fun degrading_a_shutdown_pending_lifecycle_to_reduce_only_is_a_no_op() {
    let mut lifecycle = lifecycle::shutdown_pending_for_testing();

    lifecycle.degrade_to_reduce_only();

    assert!(lifecycle.is_shutdown_pending());
}

#[test]
fun degrading_a_settled_lifecycle_to_reduce_only_is_a_no_op() {
    let mut lifecycle = lifecycle::shutdown_settled_for_testing();

    lifecycle.degrade_to_reduce_only();

    assert!(lifecycle.is_shutdown_settled());
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun uninitialized_cannot_degrade_to_shutdown_pending() {
    let mut lifecycle = lifecycle::new();

    lifecycle.degrade_to_shutdown_pending();
}

#[test]
fun active_degrades_to_shutdown_pending() {
    let mut lifecycle = lifecycle::active_for_testing();

    lifecycle.degrade_to_shutdown_pending();

    assert!(lifecycle.is_shutdown_pending());
}

#[test]
fun reduce_only_degrades_to_shutdown_pending() {
    let mut lifecycle = lifecycle::reduce_only_for_testing();

    lifecycle.degrade_to_shutdown_pending();

    assert!(lifecycle.is_shutdown_pending());
}

#[test]
fun degrading_an_already_shutdown_pending_lifecycle_is_a_no_op() {
    let mut lifecycle = lifecycle::shutdown_pending_for_testing();

    lifecycle.degrade_to_shutdown_pending();

    assert!(lifecycle.is_shutdown_pending());
}

#[test]
fun degrading_a_settled_lifecycle_to_shutdown_pending_is_a_no_op() {
    let mut lifecycle = lifecycle::shutdown_settled_for_testing();

    lifecycle.degrade_to_shutdown_pending();

    assert!(lifecycle.is_shutdown_settled());
}

/// Degradation never resurrects: repeated degrade calls in any order end at the most degraded state reached.
#[test]
fun repeated_degradation_is_monotone() {
    let mut lifecycle = lifecycle::active_for_testing();

    lifecycle.degrade_to_reduce_only();
    lifecycle.degrade_to_reduce_only();
    lifecycle.degrade_to_shutdown_pending();
    lifecycle.degrade_to_reduce_only();
    lifecycle.degrade_to_shutdown_pending();

    assert!(lifecycle.is_shutdown_pending());
}
