#[test_only]
/// Series lifecycle transitions and operation-permission matrix.
module blast_boosts_core::lifecycle_tests;

// === Tests ===

#[test]
fun unwinding_finalizes_once_to_settled() {
    let mut lifecycle = lifecycle::unwinding_for_testing();
    lifecycle.finalize_shutdown();
    assert!(lifecycle.is_settled());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle)]
fun uninitialized_cannot_finalize_shutdown() {
    let mut lifecycle = lifecycle::new();
    lifecycle.finalize_shutdown();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle)]
fun active_cannot_skip_unwinding_to_finalize() {
    let mut lifecycle = lifecycle::active_for_testing();
    lifecycle.finalize_shutdown();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle)]
fun settled_cannot_finalize_twice() {
    let mut lifecycle = lifecycle::settled_for_testing();
    lifecycle.finalize_shutdown();
}

#[test]
fun a_new_lifecycle_is_uninitialized() {
    let lifecycle = lifecycle::new();

    assert!(lifecycle.is_uninitialized());
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
    abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle,
)]
fun active_cannot_activate_again() {
    let mut lifecycle = lifecycle::active_for_testing();

    lifecycle.activate();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle,
)]
fun unwinding_cannot_activate() {
    let mut lifecycle = lifecycle::unwinding_for_testing();

    lifecycle.activate();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle,
)]
fun settled_cannot_activate() {
    let mut lifecycle = lifecycle::settled_for_testing();

    lifecycle.activate();
}

#[test]
fun active_can_begin_shutdown() {
    let mut lifecycle = lifecycle::active_for_testing();

    lifecycle.begin_shutdown();

    assert!(lifecycle.is_unwinding());
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle,
)]
fun uninitialized_cannot_begin_shutdown() {
    let mut lifecycle = lifecycle::new();

    lifecycle.begin_shutdown();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle,
)]
fun unwinding_cannot_begin_shutdown_again() {
    let mut lifecycle = lifecycle::unwinding_for_testing();

    lifecycle.begin_shutdown();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle,
)]
fun settled_cannot_begin_shutdown() {
    let mut lifecycle = lifecycle::settled_for_testing();

    lifecycle.begin_shutdown();
}

#[test]
fun active_permits_active_operations() {
    lifecycle::active_for_testing().assert_active();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun uninitialized_rejects_active_operations() {
    lifecycle::new().assert_active();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun unwinding_rejects_active_operations() {
    lifecycle::unwinding_for_testing().assert_active();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun settled_rejects_active_operations() {
    lifecycle::settled_for_testing().assert_active();
}

#[test]
fun active_permits_normal_redemption() {
    lifecycle::active_for_testing().assert_normal_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun uninitialized_rejects_normal_redemption() {
    lifecycle::new().assert_normal_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun unwinding_rejects_normal_redemption() {
    lifecycle::unwinding_for_testing().assert_normal_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun settled_rejects_normal_redemption() {
    lifecycle::settled_for_testing().assert_normal_redemption_allowed();
}

#[test]
fun active_permits_risk_reduction() {
    lifecycle::active_for_testing().assert_operating_risk_reduction_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun uninitialized_rejects_operating_risk_reduction() {
    lifecycle::new().assert_operating_risk_reduction_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun unwinding_rejects_operating_risk_reduction() {
    lifecycle::unwinding_for_testing()
        .assert_operating_risk_reduction_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun settled_rejects_operating_risk_reduction() {
    lifecycle::settled_for_testing()
        .assert_operating_risk_reduction_allowed();
}

#[test]
fun unwinding_permits_shutdown_close() {
    lifecycle::unwinding_for_testing().assert_shutdown_close_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun uninitialized_rejects_shutdown_close() {
    lifecycle::new().assert_shutdown_close_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun active_rejects_shutdown_close() {
    lifecycle::active_for_testing().assert_shutdown_close_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun settled_rejects_shutdown_close() {
    lifecycle::settled_for_testing().assert_shutdown_close_allowed();
}

#[test]
fun settled_permits_shutdown_redemption() {
    lifecycle::settled_for_testing()
        .assert_shutdown_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun uninitialized_rejects_shutdown_redemption() {
    lifecycle::new().assert_shutdown_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun active_rejects_shutdown_redemption() {
    lifecycle::active_for_testing().assert_shutdown_redemption_allowed();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun unwinding_rejects_shutdown_redemption() {
    lifecycle::unwinding_for_testing()
        .assert_shutdown_redemption_allowed();
}

// === Imports ===

use blast_boosts_core::{errors, lifecycle};
