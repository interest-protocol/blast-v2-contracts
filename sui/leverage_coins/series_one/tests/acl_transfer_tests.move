#[test_only]
/// Stateful tests for delayed Series1 super-admin custody transfer.
module blast_leverage_series_one::acl_transfer_tests;

use blast_leverage_series_one::{acl, constants, errors, events};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, test_scenario::{Self, Scenario}};

// === Constants ===

const ROOT: address = @0xA11CE;
const NEW_ROOT: address = @0xB0B;
const OTHER: address = @0xDAD;
const NOW_MS: u64 = 1_000_000;

// === Test-Only Types ===

public struct Fixture {
    scenario: Scenario,
    authority: acl::ProtocolAuthority,
    super_admin_cap: Option<acl::SuperAdminCap>,
    clock: Clock,
}

// === Tests ===

#[test]
fun delayed_transfer_is_recipient_accepted_and_replay_complete() {
    let mut fixture = start();
    let previous_id = fixture.super_admin_cap.borrow().super_admin_cap_id_for_testing();

    fixture.begin_transfer(NEW_ROOT);
    let started =
        events::collect_one<events::SuperAdminTransferStarted>(0);
    let (recipient, execute_after_ms) = started.super_admin_transfer_started_fields();
    assert_eq!(recipient, NEW_ROOT);
    assert_eq!(
        execute_after_ms,
        NOW_MS + constants::super_admin_transfer_delay_ms!(),
    );

    fixture.clock.set_for_testing(execute_after_ms);
    fixture.scenario.next_tx(NEW_ROOT);
    fixture.accept_transfer();

    let transferred =
        events::collect_one<events::SuperAdminTransferred>(0);
    let (emitted_previous_id, new_id, emitted_recipient) =
        transferred.super_admin_transferred_fields();
    assert_eq!(emitted_previous_id, previous_id);
    assert_eq!(emitted_recipient, NEW_ROOT);

    fixture.scenario.next_tx(NEW_ROOT);
    let new_root = fixture
        .scenario
        .take_from_sender<acl::SuperAdminCap>();
    assert_eq!(new_root.super_admin_cap_id_for_testing(), new_id);
    assert_eq!(fixture.authority.active_super_admin_cap_id_for_testing(), new_id);

    let retired_root = fixture.super_admin_cap.extract();
    fixture.authority.destroy_retired_super_admin_cap(retired_root);
    fixture.super_admin_cap.fill(new_root);

    destroy(fixture);
}

#[test]
fun current_root_can_cancel_a_pending_transfer() {
    let mut fixture = start();

    fixture.begin_transfer(NEW_ROOT);
    fixture.cancel_transfer();

    let cancelled =
        events::collect_one<events::SuperAdminTransferCancelled>(0);
    assert_eq!(cancelled.super_admin_transfer_cancelled_fields(), NEW_ROOT);

    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::ESuperAdminTransferNotReady,
    location = blast_leverage_series_one::acl,
)]
fun transfer_cannot_be_accepted_early() {
    let mut fixture = start();

    fixture.begin_transfer(NEW_ROOT);
    fixture.scenario.next_tx(NEW_ROOT);
    fixture.accept_transfer();

    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::ENotPendingSuperAdminRecipient,
    location = blast_leverage_series_one::acl,
)]
fun transfer_rejects_a_different_sender() {
    let mut fixture = start();

    fixture.begin_transfer(NEW_ROOT);
    fixture.clock.set_for_testing(
        NOW_MS + constants::super_admin_transfer_delay_ms!(),
    );
    fixture.scenario.next_tx(OTHER);
    fixture.accept_transfer();

    destroy(fixture);
}

// === Fixture Setup ===

fun start(): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let (super_admin_cap, authority) =
        acl::new_protocol_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);

    Fixture {
        scenario,
        authority,
        super_admin_cap: option::some(super_admin_cap),
        clock,
    }
}

// === Fixture Helpers ===

fun begin_transfer(self: &mut Fixture, recipient: address) {
    let Fixture { scenario, authority, super_admin_cap, clock } = self;
    authority.begin_super_admin_transfer(
        super_admin_cap.borrow(),
        recipient,
        clock,
        scenario.ctx(),
    );
}

fun accept_transfer(self: &mut Fixture) {
    let Fixture { scenario, authority, clock, .. } = self;
    authority.accept_super_admin_transfer(clock, scenario.ctx());
}

fun cancel_transfer(self: &mut Fixture) {
    let Fixture { authority, super_admin_cap, .. } = self;
    authority.cancel_super_admin_transfer(super_admin_cap.borrow());
}
