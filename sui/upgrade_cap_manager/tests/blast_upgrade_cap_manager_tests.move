// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_upgrade_cap_manager::blast_upgrade_cap_manager_tests;

// === Constants ===

const MAX_CAPS: u64 = 256;
const DELAY_MS: u64 = 172_800_000;
const MAX_TIMESTAMP_MS: u64 = 18_446_744_073_709_551_615 - DELAY_MS;

// === Test-Only Types ===

public struct UpgradeFixture {
    ctx: TxContext,
    clock: Clock,
    manager: UpgradeCapManager,
    controller: ManagerCap,
    upgrade_cap_id: ID,
}

// === Tests ===

#[test]
fun fresh_custody_and_exact_deadline() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(123);

    let target_cap = &manager.caps_for_testing()[upgrade_cap_id];
    assert!(target_cap.package() == object::id_from_address(@0xa));
    assert!(target_cap.version() == 1 && target_cap.policy() == package::compatible_policy());
    assert!(manager.pending_request(upgrade_cap_id).is_none());

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);

    let request = manager.pending_request(upgrade_cap_id).destroy_some();
    assert!(request.action().upgrade_digest_for_testing() == option::some(digest_a()));
    assert!(request.ready_at_ms() == 123 + DELAY_MS);

    clock.increment_for_testing(DELAY_MS);

    complete_upgrade(&mut manager, upgrade_cap_id, &clock);

    assert!(manager.pending_request(upgrade_cap_id).is_none());
    let target_cap = &manager.caps_for_testing()[upgrade_cap_id];
    assert!(target_cap.version() == 2 && target_cap.package().to_address() != @0xa);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test]
fun late_execution_and_second_upgrade_each_require_a_request() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(1_000);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);

    clock.increment_for_testing(DELAY_MS + 999);

    complete_upgrade(&mut manager, upgrade_cap_id, &clock);
    manager.request_upgrade(&controller, upgrade_cap_id, digest_b(), &clock);

    assert!(manager.pending_request(upgrade_cap_id).destroy_some().ready_at_ms() == 1_999 + DELAY_MS * 2);

    clock.increment_for_testing(DELAY_MS);

    complete_upgrade(&mut manager, upgrade_cap_id, &clock);

    let target_cap = &manager.caps_for_testing()[upgrade_cap_id];
    assert!(target_cap.version() == 3);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test]
fun cancellation_after_maturity_and_replacement_restart_delay() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);

    clock.increment_for_testing(DELAY_MS);

    manager.cancel_request(&controller, upgrade_cap_id);

    assert!(manager.pending_request(upgrade_cap_id).is_none());

    manager.request_upgrade(&controller, upgrade_cap_id, digest_b(), &clock);

    let request = manager.pending_request(upgrade_cap_id).destroy_some();
    assert!(
        request.action().upgrade_digest_for_testing() == option::some(digest_b())
            && request.ready_at_ms() == DELAY_MS * 2,
    );

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test]
fun preserves_existing_restrictive_native_policy() {
    let UpgradeFixture { mut ctx, mut clock, manager, controller, upgrade_cap_id: _ } = start_upgrade_fixture(0);
    let mut target_cap = package::test_publish(object::id_from_address(@0xb), &mut ctx);
    target_cap.only_additive_upgrades();

    destroy(manager);
    destroy(controller);

    let upgrade_cap_id = object::id(&target_cap);
    let (mut manager, controller) = cap_manager::new(target_cap, &mut ctx);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);

    clock.increment_for_testing(DELAY_MS);

    let ticket = manager.authorize_upgrade(upgrade_cap_id, &clock);

    assert!(ticket.policy() == package::additive_policy() && ticket.digest() == digest_a());

    manager.commit_upgrade(package::test_upgrade(ticket));

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test]
fun last_representable_deadline_is_allowed() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } =
        start_upgrade_fixture(MAX_TIMESTAMP_MS);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);

    clock.increment_for_testing(DELAY_MS);

    complete_upgrade(&mut manager, upgrade_cap_id, &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EAlreadyAuthorized,
    location = cap_manager,
)]
fun enrollment_rejects_an_already_issued_ticket() {
    let UpgradeFixture { mut ctx, clock, manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);
    let mut target_cap = package::test_publish(object::id_from_address(@0xb), &mut ctx);
    let ticket = target_cap.authorize(package::compatible_policy(), digest_a());
    let (new_manager, new_cap) = cap_manager::new(target_cap, &mut ctx);

    destroy(ticket);
    destroy(new_manager);
    destroy(new_cap);
    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EWrongController,
    location = cap_manager,
)]
fun wrong_controller_cannot_request() {
    let UpgradeFixture { mut ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);
    let (other_manager, wrong_controller) = new_other_manager(&mut ctx);

    destroy(other_manager);

    manager.request_upgrade(&wrong_controller, upgrade_cap_id, digest_a(), &clock);

    destroy(wrong_controller);
    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EWrongController,
    location = cap_manager,
)]
fun wrong_controller_cannot_cancel() {
    let UpgradeFixture { mut ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);

    let (other_manager, wrong_controller) = new_other_manager(&mut ctx);

    destroy(other_manager);

    manager.cancel_request(&wrong_controller, upgrade_cap_id);

    destroy(wrong_controller);
    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::ERequestPending,
    location = cap_manager,
)]
fun replacement_without_cancel_is_rejected() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);
    manager.request_upgrade(&controller, upgrade_cap_id, digest_b(), &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EInvalidDigest,
    location = cap_manager,
)]
fun short_digest_is_rejected() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_upgrade(&controller, upgrade_cap_id, vector::tabulate!(31, |_| 0u8), &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EInvalidDigest,
    location = cap_manager,
)]
fun long_digest_is_rejected() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_upgrade(&controller, upgrade_cap_id, vector::tabulate!(33, |_| 0u8), &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::ETimestampOverflow,
    location = cap_manager,
)]
fun full_delay_must_fit_timestamp_range() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } =
        start_upgrade_fixture(MAX_TIMESTAMP_MS + 1);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::ENoRequest,
    location = cap_manager,
)]
fun cannot_cancel_when_idle() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.cancel_request(&controller, upgrade_cap_id);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::ENoRequest,
    location = cap_manager,
)]
fun cannot_authorize_without_request() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(DELAY_MS);

    complete_upgrade(&mut manager, upgrade_cap_id, &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::ENoRequest,
    location = cap_manager,
)]
fun cannot_execute_cancelled_request() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);
    manager.cancel_request(&controller, upgrade_cap_id);

    clock.increment_for_testing(DELAY_MS);

    complete_upgrade(&mut manager, upgrade_cap_id, &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::ENoRequest,
    location = cap_manager,
)]
fun cannot_replay_completed_request() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);

    clock.increment_for_testing(DELAY_MS);

    complete_upgrade(&mut manager, upgrade_cap_id, &clock);
    complete_upgrade(&mut manager, upgrade_cap_id, &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::ETooEarly,
    location = cap_manager,
)]
fun one_millisecond_early_is_rejected() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(777);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);

    clock.increment_for_testing(DELAY_MS - 1);

    complete_upgrade(&mut manager, upgrade_cap_id, &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::ETooEarly,
    location = cap_manager,
)]
fun same_transaction_request_cannot_authorize() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(1_000_000_000);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);
    complete_upgrade(&mut manager, upgrade_cap_id, &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EUnknownCap,
    location = cap_manager,
)]
fun receipt_for_another_cap_is_rejected() {
    let UpgradeFixture { mut ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);

    clock.increment_for_testing(DELAY_MS);

    let ticket = manager.authorize_upgrade(upgrade_cap_id, &clock);

    let (mut other_manager, other_cap) = new_other_manager(&mut ctx);
    other_manager.commit_upgrade(package::test_upgrade(ticket));

    destroy(other_manager);
    destroy(other_cap);
    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test]
fun immutability_at_exact_deadline_preserves_manager() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(123);

    manager.request_make_immutable(&controller, upgrade_cap_id, &clock);

    let request = manager.pending_request(upgrade_cap_id).destroy_some();
    assert!(request.action().upgrade_digest_for_testing().is_none());
    assert!(request.ready_at_ms() == 123 + DELAY_MS);

    clock.increment_for_testing(DELAY_MS);

    manager.make_immutable(upgrade_cap_id, &clock);

    destroy(manager);
    cap_manager::destroy_cap(controller);
    destroy(clock);
    destroy(ctx);
}

#[test]
fun switching_actions_after_cancellation_restarts_full_delay() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);

    clock.increment_for_testing(DELAY_MS + 1);

    manager.cancel_request(&controller, upgrade_cap_id);
    manager.request_make_immutable(&controller, upgrade_cap_id, &clock);

    assert!(manager.pending_request(upgrade_cap_id).destroy_some().ready_at_ms() == DELAY_MS * 2 + 1);

    manager.cancel_request(&controller, upgrade_cap_id);

    clock.increment_for_testing(1);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_b(), &clock);

    assert!(manager.pending_request(upgrade_cap_id).destroy_some().ready_at_ms() == DELAY_MS * 2 + 2);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test]
fun destroying_controller_preserves_pending_action() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_make_immutable(&controller, upgrade_cap_id, &clock);

    cap_manager::destroy_cap(controller);

    clock.increment_for_testing(DELAY_MS);

    manager.make_immutable(upgrade_cap_id, &clock);

    destroy(manager);
    destroy(clock);
    destroy(ctx);
}

#[test]
fun immutability_at_last_representable_deadline_is_allowed() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } =
        start_upgrade_fixture(MAX_TIMESTAMP_MS);

    manager.request_make_immutable(&controller, upgrade_cap_id, &clock);

    clock.increment_for_testing(DELAY_MS);

    manager.make_immutable(upgrade_cap_id, &clock);

    destroy(manager);
    cap_manager::destroy_cap(controller);
    destroy(clock);
    destroy(ctx);
}

#[test, expected_failure(
    abort_code = cap_manager::ENoRequest,
    location = cap_manager,
)]
fun immutability_without_request_is_rejected() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.make_immutable(upgrade_cap_id, &clock);

    destroy(manager);
    cap_manager::destroy_cap(controller);
    destroy(clock);
    destroy(ctx);
}

#[test, expected_failure(
    abort_code = cap_manager::EWrongAction,
    location = cap_manager,
)]
fun upgrade_request_cannot_authorize_immutability_even_before_deadline() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);
    manager.make_immutable(upgrade_cap_id, &clock);

    destroy(manager);
    cap_manager::destroy_cap(controller);
    destroy(clock);
    destroy(ctx);
}

#[test, expected_failure(
    abort_code = cap_manager::EWrongAction,
    location = cap_manager,
)]
fun immutability_request_cannot_authorize_upgrade_even_before_deadline() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_make_immutable(&controller, upgrade_cap_id, &clock);
    complete_upgrade(&mut manager, upgrade_cap_id, &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::ETooEarly,
    location = cap_manager,
)]
fun immutability_one_millisecond_early_is_rejected() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_make_immutable(&controller, upgrade_cap_id, &clock);

    clock.increment_for_testing(DELAY_MS - 1);

    manager.make_immutable(upgrade_cap_id, &clock);

    destroy(manager);
    cap_manager::destroy_cap(controller);
    destroy(clock);
    destroy(ctx);
}

#[test, expected_failure(
    abort_code = cap_manager::ETooEarly,
    location = cap_manager,
)]
fun same_transaction_immutability_is_rejected() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_make_immutable(&controller, upgrade_cap_id, &clock);
    manager.make_immutable(upgrade_cap_id, &clock);

    destroy(manager);
    cap_manager::destroy_cap(controller);
    destroy(clock);
    destroy(ctx);
}

#[test, expected_failure(
    abort_code = cap_manager::ETimestampOverflow,
    location = cap_manager,
)]
fun immutability_delay_must_fit_timestamp_range() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } =
        start_upgrade_fixture(MAX_TIMESTAMP_MS + 1);

    manager.request_make_immutable(&controller, upgrade_cap_id, &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::ERequestPending,
    location = cap_manager,
)]
fun upgrade_request_blocks_immutability_replacement() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);
    manager.request_make_immutable(&controller, upgrade_cap_id, &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::ERequestPending,
    location = cap_manager,
)]
fun immutability_request_blocks_upgrade_before_digest_validation() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_make_immutable(&controller, upgrade_cap_id, &clock);
    manager.request_upgrade(&controller, upgrade_cap_id, vector[], &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EWrongController,
    location = cap_manager,
)]
fun wrong_controller_cannot_request_immutability() {
    let UpgradeFixture { mut ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);
    let (other_manager, wrong_controller) = new_other_manager(&mut ctx);

    manager.request_make_immutable(&wrong_controller, upgrade_cap_id, &clock);

    destroy(other_manager);
    cap_manager::destroy_cap(wrong_controller);
    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EAlreadyAuthorized,
    location = cap_manager,
)]
fun outstanding_ticket_blocks_immutability_request() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);

    clock.increment_for_testing(DELAY_MS);

    let ticket = manager.authorize_upgrade(upgrade_cap_id, &clock);
    manager.request_make_immutable(&controller, upgrade_cap_id, &clock);
    manager.commit_upgrade(package::test_upgrade(ticket));

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EAlreadyAuthorized,
    location = cap_manager,
)]
fun outstanding_ticket_blocks_upgrade_request() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);

    clock.increment_for_testing(DELAY_MS);

    let ticket = manager.authorize_upgrade(upgrade_cap_id, &clock);
    manager.request_upgrade(&controller, upgrade_cap_id, digest_b(), &clock);
    manager.commit_upgrade(package::test_upgrade(ticket));

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test]
fun different_caps_have_independent_actions_deadlines_and_cancellation() {
    let UpgradeFixture { mut ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(123);
    let second_cap_id = enroll_target(&mut manager, &controller, &mut ctx);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);

    clock.increment_for_testing(1_000);

    manager.request_make_immutable(&controller, second_cap_id, &clock);

    let second_request = manager.pending_request(second_cap_id);

    manager.cancel_request(&controller, upgrade_cap_id);

    assert!(manager.pending_request(second_cap_id) == second_request);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_b(), &clock);

    clock.increment_for_testing(DELAY_MS);

    manager.make_immutable(second_cap_id, &clock);

    assert!(!manager.caps_for_testing().contains(second_cap_id));
    assert!(manager.pending_request(second_cap_id).is_none());
    assert!(manager.pending_request(upgrade_cap_id).destroy_some().ready_at_ms() == 1_123 + DELAY_MS);

    complete_upgrade(&mut manager, upgrade_cap_id, &clock);

    assert!(manager.caps_for_testing().length() == 1);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test]
fun simultaneous_tickets_commit_in_reverse_order_to_their_native_caps() {
    let UpgradeFixture { mut ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);
    let second_cap_id = enroll_target(&mut manager, &controller, &mut ctx);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);
    manager.request_upgrade(&controller, second_cap_id, digest_b(), &clock);

    clock.increment_for_testing(DELAY_MS);

    let first_ticket = manager.authorize_upgrade(upgrade_cap_id, &clock);
    let second_ticket = manager.authorize_upgrade(second_cap_id, &clock);
    manager.commit_upgrade(package::test_upgrade(second_ticket));
    manager.commit_upgrade(package::test_upgrade(first_ticket));

    assert!(
        manager.caps_for_testing()[upgrade_cap_id].version() == 2
            && manager.caps_for_testing()[second_cap_id].version() == 2,
    );
    assert!(manager.pending_request(upgrade_cap_id).is_none() && manager.pending_request(second_cap_id).is_none());

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test]
fun outstanding_ticket_does_not_block_other_caps_requests_or_burns() {
    let UpgradeFixture { mut ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);
    let second_cap_id = enroll_target(&mut manager, &controller, &mut ctx);
    let third_cap_id = enroll_target(&mut manager, &controller, &mut ctx);

    manager.request_upgrade(&controller, upgrade_cap_id, digest_a(), &clock);
    manager.request_make_immutable(&controller, second_cap_id, &clock);

    clock.increment_for_testing(DELAY_MS);

    let ticket = manager.authorize_upgrade(upgrade_cap_id, &clock);
    manager.request_upgrade(&controller, third_cap_id, digest_b(), &clock);
    manager.make_immutable(second_cap_id, &clock);
    manager.commit_upgrade(package::test_upgrade(ticket));

    assert!(manager.pending_request(third_cap_id).destroy_some().ready_at_ms() == DELAY_MS * 2);
    assert!(manager.caps_for_testing().length() == 2 && manager.caps_for_testing()[upgrade_cap_id].version() == 2);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test]
fun full_capacity_accepts_requests_and_burning_frees_an_enrollment_slot() {
    let UpgradeFixture { mut ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    fill_manager(&mut manager, &controller, &mut ctx);

    assert!(manager.caps_for_testing().length() == MAX_CAPS);

    manager.request_make_immutable(&controller, upgrade_cap_id, &clock);

    clock.increment_for_testing(DELAY_MS);

    manager.make_immutable(upgrade_cap_id, &clock);

    assert!(manager.caps_for_testing().length() == MAX_CAPS - 1);

    let replacement_cap_id = enroll_target(&mut manager, &controller, &mut ctx);

    manager.request_upgrade(&controller, replacement_cap_id, digest_a(), &clock);

    assert!(manager.caps_for_testing().length() == MAX_CAPS);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test]
fun empty_manager_can_enroll_again_after_its_last_target_becomes_immutable() {
    let UpgradeFixture { mut ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_make_immutable(&controller, upgrade_cap_id, &clock);

    clock.increment_for_testing(DELAY_MS);

    manager.make_immutable(upgrade_cap_id, &clock);

    assert!(manager.caps_for_testing().is_empty());

    let replacement_cap_id = enroll_target(&mut manager, &controller, &mut ctx);

    manager.request_upgrade(&controller, replacement_cap_id, digest_a(), &clock);

    clock.increment_for_testing(DELAY_MS);

    complete_upgrade(&mut manager, replacement_cap_id, &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::ECapacityReached,
    location = cap_manager,
)]
fun first_enrollment_above_capacity_is_rejected() {
    let UpgradeFixture { mut ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    fill_manager(&mut manager, &controller, &mut ctx);
    enroll_target(&mut manager, &controller, &mut ctx);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EWrongController,
    location = cap_manager,
)]
fun wrong_controller_cannot_enroll_even_an_already_authorized_cap() {
    let UpgradeFixture { mut ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);
    let (other_manager, wrong_controller) = new_other_manager(&mut ctx);
    let mut target = package::test_publish(object::id_from_address(@0xc), &mut ctx);
    let ticket = target.authorize(package::compatible_policy(), digest_a());

    manager.add_upgrade_cap(&wrong_controller, target);

    destroy(ticket);
    destroy(other_manager);
    cap_manager::destroy_cap(wrong_controller);
    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EAlreadyAuthorized,
    location = cap_manager,
)]
fun additional_enrollment_rejects_an_outstanding_native_ticket() {
    let UpgradeFixture { mut ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);
    let mut target = package::test_publish(object::id_from_address(@0xc), &mut ctx);
    let ticket = target.authorize(package::compatible_policy(), digest_a());

    manager.add_upgrade_cap(&controller, target);

    destroy(ticket);
    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EUnknownCap,
    location = cap_manager,
)]
fun unknown_cap_cannot_request() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);
    let unknown_id = object::id_from_address(@0xdead);

    manager.request_upgrade(&controller, unknown_id, vector[], &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EUnknownCap,
    location = cap_manager,
)]
fun unknown_cap_cannot_cancel() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);
    let unknown_id = object::id_from_address(@0xdead);

    manager.cancel_request(&controller, unknown_id);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EUnknownCap,
    location = cap_manager,
)]
fun unknown_cap_cannot_authorize() {
    let UpgradeFixture { ctx, clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);
    let unknown_id = object::id_from_address(@0xdead);

    let ticket = manager.authorize_upgrade(unknown_id, &clock);

    destroy(ticket);
    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

#[test, expected_failure(
    abort_code = cap_manager::EUnknownCap,
    location = cap_manager,
)]
fun removed_cap_cannot_be_made_immutable_again() {
    let UpgradeFixture { ctx, mut clock, mut manager, controller, upgrade_cap_id } = start_upgrade_fixture(0);

    manager.request_make_immutable(&controller, upgrade_cap_id, &clock);

    clock.increment_for_testing(DELAY_MS);

    manager.make_immutable(upgrade_cap_id, &clock);
    manager.make_immutable(upgrade_cap_id, &clock);

    end_upgrade_fixture(UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id });
}

// === Test Helpers ===

fun enroll_target(manager: &mut UpgradeCapManager, controller: &ManagerCap, ctx: &mut TxContext): ID {
    let target = package::test_publish(object::id_from_address(@0xc), ctx);
    let target_id = object::id(&target);
    manager.add_upgrade_cap(controller, target);

    target_id
}

fun fill_manager(manager: &mut UpgradeCapManager, controller: &ManagerCap, ctx: &mut TxContext) {
    while (manager.caps_for_testing().length() < MAX_CAPS) {
        enroll_target(manager, controller, ctx);
    };
}

fun start_upgrade_fixture(now_at_ms: u64): UpgradeFixture {
    let mut ctx = tx_context::dummy();
    let mut clock = sui::clock::create_for_testing(&mut ctx);
    clock.set_for_testing(now_at_ms);

    let target_cap = package::test_publish(object::id_from_address(@0xa), &mut ctx);
    let upgrade_cap_id = object::id(&target_cap);
    let (manager, controller) = cap_manager::new(target_cap, &mut ctx);

    UpgradeFixture { ctx, clock, manager, controller, upgrade_cap_id }
}

fun new_other_manager(ctx: &mut TxContext): (UpgradeCapManager, ManagerCap) {
    let target_cap = package::test_publish(object::id_from_address(@0xb), ctx);
    cap_manager::new(target_cap, ctx)
}

fun complete_upgrade(manager: &mut UpgradeCapManager, upgrade_cap_id: ID, clock: &Clock) {
    let ticket = manager.authorize_upgrade(upgrade_cap_id, clock);
    manager.commit_upgrade(package::test_upgrade(ticket));
}

fun end_upgrade_fixture(fixture: UpgradeFixture) {
    destroy(fixture);
}

fun digest_a(): vector<u8> {
    vector::tabulate!(32, |_| 1u8)
}

fun digest_b(): vector<u8> {
    vector::tabulate!(32, |_| 2u8)
}

// === Imports ===

use std::unit_test::destroy;
use sui::{clock::Clock, package};
use blast_upgrade_cap_manager::blast_upgrade_cap_manager::{Self as cap_manager, ManagerCap, UpgradeCapManager};
