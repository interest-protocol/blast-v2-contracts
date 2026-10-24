// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Tests for adapter-owned Publisher and UpgradeCap custody.
///
/// Native authorize/upgrade/commit and activation are exercised by the runtime
/// upgrade test at real published addresses. These tests use this build's original address to prove
/// wiring, provenance, and guard order for a fresh publication.
module blast_boosts_aftermath::package_admin_tests;

// === Constants ===

const ROOT: address = @0xA11CE;
const PACKAGE_ADMIN: address = @0xAD;

/// The original address of this build, including a fresh publication.
const PACKAGE_ID: address = @blast_boosts_aftermath;
const OTHER_PACKAGE_ID: address = @0xBAD;

// === Test-Only Types ===

/// Witness from a non-canonical module used to forge a wrong-provenance Publisher.
public struct FOREIGN_PUBLISHER() has drop;

/// Bare transaction runner for the sealing constructor and its provenance rejections.
public struct WrapFixture {
    scenario: Scenario,
}

/// Sealed adapter custody, driven by the upgrade administrator.
public struct Fixture {
    scenario: Scenario,
    protocol: Protocol,
    package_admin: PackageAdmin,
}

// === Tests ===

#[test]
/// The sealed constructor emits the complete custody fact and holds exactly the
/// canonical capabilities it validated.
fun canonical_capabilities_enter_adapter_custody() {
    let mut fixture = start_wrap();
    let publisher = marker::publisher_for_testing(fixture.ctx!());
    let upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), fixture.ctx!());
    let publisher_id = object::id(&publisher);
    let upgrade_cap_id = object::id(&upgrade_cap);

    package_admin::wrap(publisher, upgrade_cap, fixture.ctx!());

    // The creation fact belongs to the sealing transaction, so it is collected
    // before the shared object can be taken in the next one.
    let created = blast_admin::blast_admin_events::collect_one<
        blast_admin::blast_admin_events::UpgradeCustodyCreated<BLAST_BOOSTS_AFTERMATH>,
    >(0);

    fixture.next_tx!(ROOT, |fixture| {
        let package_admin = fixture.take_package_admin();
        let (
            custodian_id,
            emitted_publisher_id,
            emitted_upgrade_cap_id,
            package_id,
            native_version,
            policy,
        ) = created.upgrade_custody_created_fields();
        assert_eq!(custodian_id, package_admin.id_for_testing());
        assert_eq!(emitted_publisher_id, publisher_id);
        assert_eq!(emitted_publisher_id, package_admin.publisher_id_for_testing());
        assert_eq!(emitted_upgrade_cap_id, upgrade_cap_id);
        assert_eq!(emitted_upgrade_cap_id, package_admin.upgrade_cap_id_for_testing());
        assert_eq!(package_id, PACKAGE_ID.to_id());
        assert_eq!(package_id, package_admin.package_id_for_testing());
        assert_eq!(native_version, 1);
        assert_eq!(native_version, package_admin.version_for_testing());
        assert_eq!(policy, package::compatible_policy());
        assert_eq!(policy, package_admin.policy_for_testing());
        assert!(package_admin.has_upgrade_cap_for_testing());

        fixture.return_package_admin(package_admin);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidPackagePublisher,
    location = blast_boosts_aftermath::package_admin,
)]
/// Publisher provenance is checked in this package before the shared custody
/// constructor ever sees the capabilities.
fun a_publisher_from_another_module_is_rejected_first() {
    let mut fixture = start_wrap();

    let publisher = package::test_claim(FOREIGN_PUBLISHER(), fixture.ctx!());
    let upgrade_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), fixture.ctx!());

    package_admin::wrap(publisher, upgrade_cap, fixture.ctx!());

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidUpgradeCap,
    location = blast_admin::upgrade_custody,
)]
fun an_upgrade_cap_for_another_package_is_rejected() {
    let mut fixture = start_wrap();

    let publisher = marker::publisher_for_testing(fixture.ctx!());
    let upgrade_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), fixture.ctx!());

    package_admin::wrap(publisher, upgrade_cap, fixture.ctx!());

    fixture.end();
}

#[test]
/// Immutability destroys native upgrade authority while the final operational
/// generation survives.
fun the_upgrade_admin_can_permanently_destroy_upgrade_authority() {
    let mut fixture = start();
    let upgrade_cap_id = fixture.package_admin.upgrade_cap_id_for_testing();

    fixture.make_immutable();

    let destroyed = blast_admin::blast_admin_events::collect_one<
        blast_admin::blast_admin_events::UpgradeCapDestroyed<BLAST_BOOSTS_AFTERMATH>,
    >(0);
    let (custodian_id, emitted_upgrade_cap_id, _, final_native_version, final_policy) =
        destroyed.upgrade_cap_destroyed_fields();
    assert_eq!(custodian_id, fixture.package_admin.id_for_testing());
    assert_eq!(emitted_upgrade_cap_id, upgrade_cap_id);
    assert_eq!(final_native_version, 1);
    assert_eq!(final_policy, package::compatible_policy());
    assert!(!fixture.package_admin.has_upgrade_cap_for_testing());
    assert_eq!(fixture.protocol.version_for_testing(), 1);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EUpgradeCapUnavailable,
    location = blast_admin::upgrade_custody,
)]
/// Immutability destroys the cap, so a second application has nothing to destroy.
fun immutability_cannot_be_applied_twice() {
    let mut fixture = start();

    fixture.make_immutable();
    fixture.make_immutable();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// Immutability runs the generation guard first, so stale bytecode never
/// reaches the native call.
fun a_stale_generation_rejects_immutability() {
    let mut fixture = start();
    fixture.protocol.set_version_for_testing(3);

    fixture.make_immutable();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidPackageDigest,
    location = blast_admin::upgrade_custody,
)]
/// Repair authorization reaches custody even when this bytecode is stale.
/// Real native upgrades need a nonzero published package ID; the runtime
/// upgrade test covers successful authorization and receipt commit.
fun a_stale_generation_still_reaches_upgrade_authorization() {
    let mut fixture = start();
    fixture.protocol.set_version_for_testing(3);

    let ticket = fixture.authorize_upgrade(vector[]);

    destroy(ticket);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidPackageDigest,
    location = blast_admin::upgrade_custody,
)]
fun upgrade_authorization_rejects_a_non_digest_length() {
    let mut fixture = start();

    let ticket = fixture.authorize_upgrade(vector[]);

    destroy(ticket);
    fixture.end();
}

// === Test Helpers ===

// --- Wrap Fixture ---

macro fun wrap_ctx($self: &mut WrapFixture): &mut TxContext {
    let fixture = $self;

    fixture.scenario.ctx()
}

macro fun wrap_next_tx(
    $self: &mut WrapFixture,
    $sender: address,
    $body: |&mut WrapFixture|,
) {
    let fixture = $self;

    fixture.scenario.next_tx($sender);
    $body(fixture);
}

fun start_wrap(): WrapFixture {
    WrapFixture { scenario: test_scenario::begin(ROOT) }
}

fun wrap_take_package_admin(self: &WrapFixture): PackageAdmin {
    self.scenario.take_shared<PackageAdmin>()
}

fun wrap_return_package_admin(_self: &WrapFixture, package_admin: PackageAdmin) {
    test_scenario::return_shared(package_admin);
}

fun wrap_end(self: WrapFixture) {
    let WrapFixture { scenario } = self;

    scenario.end();
}

// --- Custody Fixture ---

fun start(): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let protocol = marker::new_for_testing(scenario.ctx());
    let package_admin = package_admin::new_for_testing(scenario.ctx());

    scenario.next_tx(PACKAGE_ADMIN);

    Fixture { scenario, protocol, package_admin }
}

fun authorize_upgrade(
    self: &mut Fixture,
    digest: vector<u8>,
): UpgradeTicket {
    self.package_admin.authorize_upgrade(&upgrade_admin(), digest)
}

fun make_immutable(self: &mut Fixture) {
    self.package_admin.make_immutable(&self.protocol, &upgrade_admin());
}

fun end(self: Fixture) {
    let Fixture { scenario, protocol, package_admin } = self;
    destroy(protocol);
    destroy(package_admin);
    scenario.end();
}

fun upgrade_admin(): AdminWitness<UpgradeAdmin> {
    blast_acl::witness_for_testing()
}

// === Imports ===

use blast_admin::blast_acl::{Self, AdminWitness};

use blast_boosts_aftermath::{
    blast_boosts_aftermath::{Self as marker, BLAST_BOOSTS_AFTERMATH, Protocol},
    errors,
    package_admin::{Self, PackageAdmin},
};

use blast_boosts_core::blast_boosts_core::UpgradeAdmin;

use std::unit_test::{assert_eq, destroy};

use sui::{package::{Self, UpgradeTicket}, test_scenario::{Self, Scenario}};

use fun wrap_ctx as WrapFixture.ctx;

use fun wrap_end as WrapFixture.end;

use fun wrap_next_tx as WrapFixture.next_tx;

use fun wrap_return_package_admin as WrapFixture.return_package_admin;

use fun wrap_take_package_admin as WrapFixture.take_package_admin;
