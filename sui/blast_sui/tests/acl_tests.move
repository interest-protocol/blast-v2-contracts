#[test_only]
module blast_sui::acl_tests;

use blast_sui::{acl, constants, errors, events, package_version::{Self, PackageVersion}};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, test_scenario::{Self, Scenario}};

use fun init_end as InitFixture.end;
use fun init_next_tx as InitFixture.next_tx;
use fun transfer_ctx as TransferFixture.ctx;
use fun transfer_end as TransferFixture.end;
use fun transfer_next_tx as TransferFixture.next_tx;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const NEW_SUPER_ADMIN: address = @0xB0B;
const OTHER: address = @0xAD;
const NOW_MS: u64 = 1_000_000;

// === Test-Only Types ===

/// Production package initialization observed through delivered objects and facts.
public struct InitFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    authority: acl::ProtocolAuthority,
    super_admin_cap: acl::SuperAdminCap,
    created: events::ProtocolAuthorityCreated,
}

/// Delayed singleton-authority transfer state and its test clock.
public struct TransferFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    authority: acl::ProtocolAuthority,
    super_admin_cap: Option<acl::SuperAdminCap>,
    clock: Clock,
}

// === Tests ===

#[test]
fun init_shares_the_authority_delivers_the_root_cap_and_emits_the_creation_fact() {
    let mut fixture = start_init();

    fixture.next_tx!(PUBLISHER, |f| {
        let (authority_id, super_admin_cap_id, recipient, delay_ms) =
            f.created.protocol_authority_created_fields();
        assert_eq!(authority_id, object::id(&f.authority));
        assert_eq!(super_admin_cap_id, object::id(&f.super_admin_cap));
        assert_eq!(super_admin_cap_id, f.authority.super_admin_cap_id_for_testing());
        assert_eq!(recipient, PUBLISHER);
        assert_eq!(delay_ms, constants::super_admin_transfer_delay_ms!());
    });

    fixture.end();
}

#[test]
fun super_admin_transfer_requires_delay_and_recipient_acceptance() {
    let mut fixture = start_transfer();
    let previous_cap_id;

    fixture.next_tx!(PUBLISHER, |f| {
        previous_cap_id = f.authority.super_admin_cap_id_for_testing();
        f.begin_transfer(NEW_SUPER_ADMIN);

        let started = events::collect_one<events::SuperAdminTransferStarted>(0);
        let (recipient, execute_after_ms) = started.super_admin_transfer_started_fields();
        assert_eq!(recipient, NEW_SUPER_ADMIN);
        assert_eq!(execute_after_ms, NOW_MS + constants::super_admin_transfer_delay_ms!());
        f.clock.set_for_testing(execute_after_ms);
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        let new_cap = f.accept_transfer();
        let new_cap_id = object::id(&new_cap);
        let transferred = events::collect_one<events::SuperAdminTransferred>(0);
        let (emitted_previous_id, emitted_new_id, recipient) =
            transferred.super_admin_transferred_fields();
        assert_eq!(emitted_previous_id, previous_cap_id);
        assert_eq!(emitted_new_id, new_cap_id);
        assert_eq!(emitted_new_id, f.authority.super_admin_cap_id_for_testing());
        assert_eq!(recipient, NEW_SUPER_ADMIN);

        let retired = f.super_admin_cap.extract();
        f.super_admin_cap.fill(new_cap);
        f.authority.assert_super_admin(f.super_admin_cap.borrow());
        f.authority.destroy_retired_super_admin_cap(retired);
    });

    fixture.end();
}

#[test]
fun returned_super_admin_cap_composes_before_keep() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.begin_transfer(NEW_SUPER_ADMIN);
        f.clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        let new_cap = f.accept_transfer();
        f.authority.begin_super_admin_transfer(
            &f.package_version,
            &new_cap,
            OTHER,
            &f.clock,
            f.ctx!(),
        );
        acl::keep(new_cap, f.ctx!());

        let started = events::collect_one<events::SuperAdminTransferStarted>(0);
        let (recipient, _) = started.super_admin_transfer_started_fields();
        assert_eq!(recipient, OTHER);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSuperAdminCap, location = blast_sui::acl)]
fun accepted_transfer_invalidates_the_previous_root_cap() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.begin_transfer(NEW_SUPER_ADMIN);
        f.clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        acl::keep(f.accept_transfer(), f.ctx!());
    });

    fixture.next_tx!(PUBLISHER, |f| {
        f.begin_transfer(OTHER);
    });

    fixture.end();
}

#[test]
fun a_new_pending_recipient_replaces_and_cancels_the_previous_one() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.begin_transfer(NEW_SUPER_ADMIN);
        f.begin_transfer(OTHER);

        let cancelled = events::collect_one<events::SuperAdminTransferCancelled>(0);
        assert_eq!(cancelled.super_admin_transfer_cancelled_fields(), NEW_SUPER_ADMIN);
        let started = events::collect<events::SuperAdminTransferStarted>();
        assert_eq!(started.length(), 2);
        let (recipient, _) = started[1].super_admin_transfer_started_fields();
        assert_eq!(recipient, OTHER);

        f.authority.cancel_super_admin_transfer(
            &f.package_version,
            f.super_admin_cap.borrow(),
        );
        let cancelled = events::collect<events::SuperAdminTransferCancelled>();
        assert_eq!(cancelled.length(), 2);
        assert_eq!(cancelled[1].super_admin_transfer_cancelled_fields(), OTHER);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ESuperAdminTransferUnchanged, location = blast_sui::acl)]
fun transfer_rejects_an_unchanged_pending_recipient() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.begin_transfer(NEW_SUPER_ADMIN);
        f.begin_transfer(NEW_SUPER_ADMIN);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSuperAdminRecipient, location = blast_sui::acl)]
fun transfer_rejects_the_zero_recipient() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| f.begin_transfer(@0x0));

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSuperAdminRecipient, location = blast_sui::acl)]
fun transfer_rejects_the_current_holder_as_recipient() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| f.begin_transfer(PUBLISHER));

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ESuperAdminTransferTimeOverflow, location = blast_sui::acl)]
fun transfer_rejects_timestamp_overflow() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.clock.set_for_testing(std::u64::max_value!());
        f.begin_transfer(NEW_SUPER_ADMIN);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ESuperAdminTransferNotReady, location = blast_sui::acl)]
fun transfer_rejects_early_acceptance() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.begin_transfer(NEW_SUPER_ADMIN);
        f.clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!() - 1);
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        destroy(f.accept_transfer());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ENotPendingSuperAdminRecipient, location = blast_sui::acl)]
fun transfer_rejects_acceptance_by_another_address() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.begin_transfer(NEW_SUPER_ADMIN);
        f.clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    });

    fixture.next_tx!(OTHER, |f| {
        destroy(f.accept_transfer());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ENoPendingSuperAdminTransfer, location = blast_sui::acl)]
fun acceptance_without_a_pending_transfer_is_rejected() {
    let mut fixture = start_transfer();

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| destroy(f.accept_transfer()));

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ENoPendingSuperAdminTransfer, location = blast_sui::acl)]
fun cancellation_without_a_pending_transfer_is_rejected() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.cancel_super_admin_transfer(
            &f.package_version,
            f.super_admin_cap.borrow(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::ESuperAdminCapStillActive, location = blast_sui::acl)]
fun the_active_root_cap_cannot_be_destroyed() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.destroy_retired_super_admin_cap(f.super_admin_cap.extract());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionMismatch,
    location = blast_sui::package_version,
)]
fun stale_package_version_rejects_root_transfer() {
    let mut fixture = start_transfer();

    fixture.next_tx!(PUBLISHER, |f| {
        f.package_version.set_for_testing(2);
        f.begin_transfer(NEW_SUPER_ADMIN);
    });

    fixture.end();
}

// === Fixture Macros ===

macro fun init_next_tx($fixture: &mut InitFixture, $sender: address, $fn: |&mut InitFixture|) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

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

fun start_init(): InitFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    acl::init_for_testing(scenario.ctx());
    package_version::init_for_testing(scenario.ctx());
    let created = events::collect_one<events::ProtocolAuthorityCreated>(0);

    scenario.next_tx(PUBLISHER);
    let authority = scenario.take_shared<acl::ProtocolAuthority>();
    let package_version = scenario.take_shared<PackageVersion>();
    let super_admin_cap = scenario.take_from_sender<acl::SuperAdminCap>();

    InitFixture { scenario, package_version, authority, super_admin_cap, created }
}

fun start_transfer(): TransferFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, authority) =
        acl::new_protocol_for_testing(PUBLISHER, scenario.ctx());
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

fun init_end(self: InitFixture) {
    let InitFixture { scenario, package_version, authority, super_admin_cap, created: _ } = self;

    test_scenario::return_shared(authority);
    test_scenario::return_shared(package_version);
    destroy(super_admin_cap);
    scenario.end();
}

fun transfer_end(self: TransferFixture) {
    destroy(self);
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

fun accept_transfer(self: &mut TransferFixture): acl::SuperAdminCap {
    self.authority.accept_super_admin_transfer(
        &self.package_version,
        &self.clock,
        self.ctx!(),
    )
}
