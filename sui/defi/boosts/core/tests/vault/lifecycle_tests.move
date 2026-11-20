// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Series lifecycle transitions and operation-permission matrix.
module blast_boosts_core::lifecycle_tests;

// === Constants ===

const SHUTDOWN_AT_MS: u64 = 1_000;

// === Tests ===

#[test]
fun unwinding_finalizes_once_to_settled() {
    let mut lifecycle = lifecycle::unwinding_for_testing();
    lifecycle.finalize_shutdown();
    assert!(lifecycle.is_settled());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle)]
fun active_cannot_skip_unwinding_to_finalize() {
    let mut lifecycle = lifecycle::active();
    lifecycle.finalize_shutdown();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle)]
fun settled_cannot_finalize_twice() {
    let mut lifecycle = lifecycle::settled_for_testing();
    lifecycle.finalize_shutdown();
}

#[test]
fun a_lifecycle_is_born_active() {
    assert!(lifecycle::active().is_active());
}

#[test]
fun active_can_begin_shutdown() {
    let mut lifecycle = lifecycle::active();

    lifecycle.begin_shutdown(SHUTDOWN_AT_MS);

    assert!(lifecycle.is_unwinding());
    assert_eq!(lifecycle.shutdown_began_at_ms(), SHUTDOWN_AT_MS);
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun an_active_lifecycle_has_no_shutdown_start() {
    lifecycle::active().shutdown_began_at_ms();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun a_settled_lifecycle_has_no_shutdown_start() {
    lifecycle::settled_for_testing().shutdown_began_at_ms();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle,
)]
fun unwinding_cannot_begin_shutdown_again() {
    let mut lifecycle = lifecycle::unwinding_for_testing();

    lifecycle.begin_shutdown(SHUTDOWN_AT_MS);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition, location = blast_boosts_core::lifecycle,
)]
fun settled_cannot_begin_shutdown() {
    let mut lifecycle = lifecycle::settled_for_testing();

    lifecycle.begin_shutdown(SHUTDOWN_AT_MS);
}

#[test]
fun active_permits_active_operations() {
    lifecycle::active().assert_active();
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
fun unwinding_permits_shutdown_close() {
    lifecycle::unwinding_for_testing().assert_unwinding();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun active_rejects_shutdown_close() {
    lifecycle::active().assert_unwinding();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun settled_rejects_shutdown_close() {
    lifecycle::settled_for_testing().assert_unwinding();
}

#[test]
fun settled_permits_shutdown_redemption() {
    lifecycle::settled_for_testing()
        .assert_settled();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun active_rejects_shutdown_redemption() {
    lifecycle::active().assert_settled();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun unwinding_rejects_shutdown_redemption() {
    lifecycle::unwinding_for_testing()
        .assert_settled();
}

#[test]
fun active_permits_synchronization() {
    lifecycle::active().assert_can_sync();
}

#[test]
fun unwinding_permits_synchronization() {
    lifecycle::unwinding_for_testing().assert_can_sync();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationNotPermittedInLifecycle, location = blast_boosts_core::lifecycle,
)]
fun settled_rejects_synchronization() {
    lifecycle::settled_for_testing().assert_can_sync();
}

#[test]
fun shutdown_reasons_are_distinct_declared_values() {
    assert!(lifecycle::emergency_reason() != lifecycle::observed_venue_change_reason());
    assert_eq!(lifecycle::emergency_reason(), lifecycle::emergency_reason());
    assert_eq!(lifecycle::observed_venue_change_reason(), lifecycle::observed_venue_change_reason());
}

// === Imports ===

use std::unit_test::assert_eq;

use blast_boosts_core::{errors, lifecycle};
