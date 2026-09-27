// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Stateful tests for the singleton ACL's delayed root-capability transfer.
module blast_admin::acl_transfer_tests;

// === Constants ===

const ROOT: address = @0xA11CE;

const NEW_ROOT: address = @0xB0B;

const OTHER: address = @0xDAD;

const NOW_MS: u64 = 1_000;

const DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

public struct Fixture {
    scenario: Scenario,
    acl: ACL,
    root: Option<SuperAdminCap>,
    clock: Clock,
}

// === Tests ===

#[test]
fun the_root_transfer_delay_is_seven_days() {
    assert_eq!(blast_acl::root_transfer_delay_ms_for_testing(), DELAY_MS);
}

#[test]
fun transfer_accepts_at_the_exact_deadline_and_old_root_can_then_be_destroyed() {
    let mut fixture = start();
    let previous_root_id = fixture.root.borrow().super_admin_cap_id_for_testing();

    fixture.begin_transfer(NEW_ROOT);
    let started = events::collect_one<events::SuperAdminTransferStarted>(0);
    let (recipient, execute_after_ms) = started.super_admin_transfer_started_fields();
    assert_eq!(recipient, NEW_ROOT);
    assert_eq!(execute_after_ms, NOW_MS + DELAY_MS);

    fixture.clock.set_for_testing(execute_after_ms);
    fixture.scenario.next_tx(NEW_ROOT);
    fixture.accept_transfer();

    let transferred = events::collect_one<events::SuperAdminTransferred>(0);
    let (emitted_previous_id, new_root_id, emitted_recipient) =
        transferred.super_admin_transferred_fields();
    assert_eq!(emitted_previous_id, previous_root_id);
    assert_eq!(emitted_recipient, NEW_ROOT);

    fixture.scenario.next_tx(NEW_ROOT);
    let new_root = fixture.scenario.take_from_sender<SuperAdminCap>();
    assert_eq!(new_root.super_admin_cap_id_for_testing(), new_root_id);
    assert_eq!(fixture.acl.active_super_admin_cap_id_for_testing(), new_root_id);
    fixture.acl.destroy_retired_super_admin_cap(fixture.root.extract());
    let destroyed = events::collect_one<events::SuperAdminCapDestroyed>(0);
    assert_eq!(destroyed.super_admin_cap_destroyed_fields(), previous_root_id);
    fixture.root.fill(new_root);

    destroy(fixture);
}

#[test]
fun replacement_cancels_the_previous_recipient_and_restarts_the_delay() {
    let mut fixture = start();

    fixture.begin_transfer(NEW_ROOT);
    fixture.clock.set_for_testing(NOW_MS + 10);
    fixture.begin_transfer(OTHER);

    let cancelled = events::collect_one<events::SuperAdminTransferCancelled>(0);
    let (recipient, execute_after_ms) = cancelled.super_admin_transfer_cancelled_fields();
    assert_eq!(recipient, NEW_ROOT);
    assert_eq!(execute_after_ms, NOW_MS + DELAY_MS);
    assert_eq!(fixture.acl.pending_recipient_for_testing(), OTHER);
    assert_eq!(fixture.acl.pending_execute_after_ms_for_testing(), NOW_MS + 10 + DELAY_MS);

    destroy(fixture);
}

#[test]
fun current_root_can_cancel_a_pending_transfer() {
    let mut fixture = start();

    fixture.begin_transfer(NEW_ROOT);
    fixture.cancel_transfer();

    let cancelled = events::collect_one<events::SuperAdminTransferCancelled>(0);
    let (recipient, execute_after_ms) = cancelled.super_admin_transfer_cancelled_fields();
    assert_eq!(recipient, NEW_ROOT);
    assert_eq!(execute_after_ms, NOW_MS + DELAY_MS);
    assert!(!fixture.acl.has_pending_transfer_for_testing());

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSuperAdminRecipient, location = blast_admin::blast_acl)]
fun transfer_rejects_zero_recipient() {
    let mut fixture = start();

    fixture.begin_transfer(@0x0);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSuperAdminRecipient, location = blast_admin::blast_acl)]
fun transfer_rejects_the_current_sender() {
    let mut fixture = start();

    fixture.begin_transfer(ROOT);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::ESuperAdminTransferUnchanged, location = blast_admin::blast_acl)]
fun transfer_rejects_an_unchanged_pending_recipient() {
    let mut fixture = start();

    fixture.begin_transfer(NEW_ROOT);
    fixture.begin_transfer(NEW_ROOT);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::ESuperAdminTransferNotReady, location = blast_admin::blast_acl)]
fun transfer_cannot_be_accepted_early() {
    let mut fixture = start();

    fixture.begin_transfer(NEW_ROOT);
    fixture.scenario.next_tx(NEW_ROOT);
    fixture.accept_transfer();

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::ENotPendingSuperAdminRecipient, location = blast_admin::blast_acl)]
fun transfer_rejects_the_wrong_sender_before_time_check() {
    let mut fixture = start();

    fixture.begin_transfer(NEW_ROOT);
    fixture.scenario.next_tx(OTHER);
    fixture.accept_transfer();

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::ENoPendingSuperAdminTransfer, location = blast_admin::blast_acl)]
fun cancellation_requires_a_pending_transfer() {
    let mut fixture = start();

    fixture.cancel_transfer();

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::ESuperAdminTransferTimeOverflow, location = blast_admin::blast_acl)]
fun transfer_deadline_overflow_aborts_before_pending_state_changes() {
    let mut fixture = start();
    fixture.clock.set_for_testing(std::u64::max_value!());

    fixture.begin_transfer(NEW_ROOT);

    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = errors::ESuperAdminCapStillActive, location = blast_admin::blast_acl)]
fun active_root_cap_cannot_be_destroyed() {
    let mut fixture = start();

    fixture.acl.destroy_retired_super_admin_cap(fixture.root.extract());

    destroy(fixture);
}

// === Test Helpers ===

fun start(): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let (root, acl) = blast_acl::new_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);

    Fixture {
        scenario,
        acl,
        root: option::some(root),
        clock,
    }
}

fun begin_transfer(self: &mut Fixture, recipient: address) {
    let Fixture { scenario, acl, root, clock } = self;
    acl.begin_super_admin_transfer(root.borrow(), recipient, clock, scenario.ctx());
}

fun accept_transfer(self: &mut Fixture) {
    let Fixture { scenario, acl, clock, .. } = self;
    acl.accept_super_admin_transfer(clock, scenario.ctx());
}

fun cancel_transfer(self: &mut Fixture) {
    let Fixture { acl, root, .. } = self;
    acl.cancel_super_admin_transfer(root.borrow());
}

// === Imports ===

use blast_admin::{
    blast_acl::{Self, ACL, SuperAdminCap},
    blast_admin_events as events,
    errors,
};

use std::unit_test::{assert_eq, destroy};

use sui::{clock::{Self, Clock}, test_scenario::{Self, Scenario}};
