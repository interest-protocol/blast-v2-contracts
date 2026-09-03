#[test_only]
/// Stateful tests for delayed Series1 super-admin custody transfer.
module blast_leverage_series_one::acl_transfer_tests;

use blast_leverage_series_one::{acl, constants, errors, events, package_version::{Self, PackageVersion}};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, test_scenario::{Self, Scenario}};

use fun transfer_ctx as TransferFixture.ctx;
use fun transfer_end as TransferFixture.end;
use fun transfer_next_tx as TransferFixture.next_tx;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const NEW_SUPER_ADMIN: address = @0xB0B;
const OTHER: address = @0xDAD;
const NOW_MS: u64 = 1_000_000;

// === Test-Only Types ===

/// Root-transfer state and its deterministic test clock.
public struct TransferFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    authority: acl::ProtocolAuthority,
    super_admin_cap: Option<acl::SuperAdminCap>,
    clock: Clock,
}

// === Tests ===

#[test]
fun delayed_transfer_is_recipient_accepted_and_replay_complete() {
    let mut fixture = start_transfer();
    let previous_root_id = fixture.super_admin_cap.borrow().super_admin_cap_id_for_testing();
    let new_root_id;

    fixture.next_tx!(PUBLISHER, |f| {
        f.begin_transfer(NEW_SUPER_ADMIN);

        let started = events::collect_one<events::SuperAdminTransferStarted>(0);
        let (recipient, execute_after_ms) = started.super_admin_transfer_started_fields();
        assert_eq!(recipient, NEW_SUPER_ADMIN);
        assert_eq!(
            execute_after_ms,
            NOW_MS + constants::super_admin_transfer_delay_ms!(),
        );
        f.clock.set_for_testing(execute_after_ms);
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        f.accept_transfer();

        let transferred = events::collect_one<events::SuperAdminTransferred>(0);
        let (emitted_previous_id, emitted_new_id, recipient) =
            transferred.super_admin_transferred_fields();
        assert_eq!(emitted_previous_id, previous_root_id);
        assert_eq!(recipient, NEW_SUPER_ADMIN);
        new_root_id = emitted_new_id;
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        let new_root = f.scenario.take_from_sender<acl::SuperAdminCap>();
        assert_eq!(new_root.super_admin_cap_id_for_testing(), new_root_id);
        assert_eq!(
            f.authority.active_super_admin_cap_id_for_testing(),
            new_root_id,
        );

        let old_root = f.super_admin_cap.extract();
        f.authority.destroy_retired_super_admin_cap(old_root);
        f.super_admin_cap.fill(new_root);

        f.begin_transfer(OTHER);
    });

    fixture.end();
}

#[test]
fun current_root_can_cancel_a_pending_transfer() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.begin_transfer(NEW_SUPER_ADMIN);
        f.authority.cancel_super_admin_transfer(
            &f.package_version,
            f.super_admin_cap.borrow(),
        );

        let cancelled = events::collect_one<events::SuperAdminTransferCancelled>(0);
        assert_eq!(
            cancelled.super_admin_transfer_cancelled_fields(),
            NEW_SUPER_ADMIN,
        );
    });

    fixture.end();
}

#[test]
fun a_different_proposal_replaces_and_reports_the_old_recipient() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.begin_transfer(NEW_SUPER_ADMIN);
        f.clock.set_for_testing(NOW_MS + 1);
        f.begin_transfer(OTHER);

        let cancelled = events::collect_one<events::SuperAdminTransferCancelled>(0);
        assert_eq!(
            cancelled.super_admin_transfer_cancelled_fields(),
            NEW_SUPER_ADMIN,
        );

        let mut started = events::collect<events::SuperAdminTransferStarted>();
        assert_eq!(started.length(), 2);
        let second = started.pop_back();
        let first = started.pop_back();
        let (first_recipient, _) = first.super_admin_transfer_started_fields();
        let (second_recipient, second_execute_after_ms) =
            second.super_admin_transfer_started_fields();
        assert_eq!(first_recipient, NEW_SUPER_ADMIN);
        assert_eq!(second_recipient, OTHER);
        assert_eq!(
            second_execute_after_ms,
            NOW_MS + 1 + constants::super_admin_transfer_delay_ms!(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::ESuperAdminTransferNotReady,
    location = blast_leverage_series_one::acl,
)]
fun transfer_cannot_be_accepted_early() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| f.begin_transfer(NEW_SUPER_ADMIN));
    fixture.next_tx!(NEW_SUPER_ADMIN, |f| f.accept_transfer());

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::ENotPendingSuperAdminRecipient,
    location = blast_leverage_series_one::acl,
)]
fun transfer_rejects_the_wrong_recipient() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.begin_transfer(NEW_SUPER_ADMIN);
        f.clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    });
    fixture.next_tx!(OTHER, |f| f.accept_transfer());

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidSuperAdminRecipient,
    location = blast_leverage_series_one::acl,
)]
fun transfer_rejects_zero_recipient() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| f.begin_transfer(@0x0));

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::ESuperAdminTransferUnchanged,
    location = blast_leverage_series_one::acl,
)]
fun transfer_rejects_the_same_pending_recipient() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.begin_transfer(NEW_SUPER_ADMIN);
        f.begin_transfer(NEW_SUPER_ADMIN);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::ENoPendingSuperAdminTransfer,
    location = blast_leverage_series_one::acl,
)]
fun cancelled_transfer_cannot_be_accepted() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.begin_transfer(NEW_SUPER_ADMIN);
        f.authority.cancel_super_admin_transfer(
            &f.package_version,
            f.super_admin_cap.borrow(),
        );
        f.clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    });
    fixture.next_tx!(NEW_SUPER_ADMIN, |f| f.accept_transfer());

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::ESuperAdminCapStillActive,
    location = blast_leverage_series_one::acl,
)]
fun active_root_cap_cannot_be_destroyed() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        let root = f.super_admin_cap.extract();
        f.authority.destroy_retired_super_admin_cap(root);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::ESuperAdminTransferTimeOverflow,
    location = blast_leverage_series_one::acl,
)]
fun transfer_rejects_timestamp_overflow() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.clock.set_for_testing(std::u64::max_value!());
        f.begin_transfer(NEW_SUPER_ADMIN);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidSuperAdminCap,
    location = blast_leverage_series_one::acl,
)]
fun accepted_transfer_immediately_invalidates_the_previous_root() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.begin_transfer(NEW_SUPER_ADMIN);
        f.clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        f.accept_transfer();
        f.authority.grant_admin(
            &f.package_version,
            f.super_admin_cap.borrow(),
            constants::risk_admin_role!(),
            OTHER,
            f.ctx!(),
        );
    });

    fixture.end();
}

// === Fixture Transaction Macros ===

macro fun transfer_next_tx(
    $fixture: &mut TransferFixture,
    $sender: address,
    $fn: |&mut TransferFixture|,
) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun transfer_ctx($fixture: &mut TransferFixture): &mut TxContext {
    let fixture = $fixture;
    fixture.scenario.ctx()
}

// === Fixture Setup ===

fun start_transfer(): TransferFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, authority) = acl::new_protocol_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);

    TransferFixture {
        scenario,
        package_version,
        authority,
        super_admin_cap: option::some(super_admin_cap),
        clock,
    }
}

// === Fixture Helpers ===

fun begin_transfer(self: &mut TransferFixture, recipient: address) {
    self.authority.begin_super_admin_transfer(
        &self.package_version,
        self.super_admin_cap.borrow(),
        recipient,
        &self.clock,
        self.ctx!(),
    );
}

fun accept_transfer(self: &mut TransferFixture) {
    self.authority.accept_super_admin_transfer(
        &self.package_version,
        &self.clock,
        self.ctx!(),
    );
}

fun transfer_end(self: TransferFixture) {
    destroy(self);
}
