// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Tests for adapter-owned Publisher and UpgradeCap custody.
///
/// The complete native authorize/commit/advance matrix belongs to
/// `blast_admin::upgrade_custody_tests`, which owns a package marker at a
/// nonzero address. This package is tested at its canonical mainnet original
/// address, so these tests prove its wiring, provenance, and guard order.
module blast_boosts_aftermath::package_admin_tests;

// === Constants ===

const ROOT: address = @0xA11CE;
const PACKAGE_ADMIN: address = @0xAD;

/// This package's canonical original address from the mainnet publication.
const PACKAGE_ID: address = @0x04f46747d8cb5ea590953ff1847301dfe5a287519d32c1610b35810aab082e50;
const OTHER_PACKAGE_ID: address = @0xBAD;

// === Test-Only Types ===

/// Witness from a non-canonical module used to forge a wrong-provenance Publisher.
public struct FOREIGN_PUBLISHER() has drop;

/// Bare transaction runner for the sealing constructor and its provenance rejections.
public struct WrapFixture {
    scenario: Scenario,
}

/// Sealed adapter custody under one live Series1 administrator.
public struct Fixture {
    scenario: Scenario,
    protocol: Protocol,
    authority: Authority<BLAST_BOOSTS_CORE>,
    super_admin_cap: SuperAdminCap<BLAST_BOOSTS_CORE>,
    admin_cap: AdminCap<BLAST_BOOSTS_CORE>,
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
    let created = blast_admin::events::collect_one<
        blast_admin::events::UpgradeCustodyCreated<BLAST_BOOSTS_AFTERMATH>,
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
/// A package administrator irreversibly narrows the policy in two steps.
fun the_package_admin_role_can_irreversibly_restrict_the_adapter() {
    let mut fixture = start(domain::package_admin_role());

    fixture.restrict_to_additive();
    let restricted = blast_admin::events::collect_one<
        blast_admin::events::UpgradePolicyRestricted<BLAST_BOOSTS_AFTERMATH>,
    >(0);
    let (_, _, _, _, previous_policy, new_policy) =
        restricted.upgrade_policy_restricted_fields();
    assert_eq!(previous_policy, package::compatible_policy());
    assert_eq!(new_policy, package::additive_policy());
    assert_eq!(
        fixture.package_admin.policy_for_testing(),
        package::additive_policy(),
    );

    fixture.restrict_to_dependency_only();
    assert_eq!(
        fixture.package_admin.policy_for_testing(),
        package::dep_only_policy(),
    );

    fixture.end();
}

#[test]
/// The second narrowing step emits its own policy fact, chained from the
/// additive policy the first step installed.
fun the_dependency_only_restriction_emits_the_policy_fact() {
    let mut fixture = start(domain::package_admin_role());
    let upgrade_cap_id = fixture.package_admin.upgrade_cap_id_for_testing();

    fixture.restrict_to_additive();
    fixture.restrict_to_dependency_only();

    let mut restricted = sui::event::events_by_type<
        blast_admin::events::UpgradePolicyRestricted<BLAST_BOOSTS_AFTERMATH>,
    >();
    assert_eq!(restricted.length(), 2);
    let dependency_only = restricted.pop_back();
    let (
        custodian_id,
        emitted_upgrade_cap_id,
        package_id,
        native_version,
        previous_policy,
        new_policy,
    ) = dependency_only.upgrade_policy_restricted_fields();
    assert_eq!(custodian_id, fixture.package_admin.id_for_testing());
    assert_eq!(emitted_upgrade_cap_id, upgrade_cap_id);
    assert_eq!(package_id, PACKAGE_ID);
    assert_eq!(native_version, 1);
    assert_eq!(previous_policy, package::additive_policy());
    assert_eq!(new_policy, package::dep_only_policy());
    assert_eq!(new_policy, fixture.package_admin.policy_for_testing());

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EUpgradePolicyNotMoreRestrictive,
    location = blast_admin::upgrade_custody,
)]
fun an_equal_policy_restriction_is_rejected_before_mutation() {
    let mut fixture = start(domain::package_admin_role());

    fixture.restrict_to_additive();
    fixture.restrict_to_additive();

    fixture.end();
}

#[test]
/// Immutability destroys native upgrade authority while the final operational
/// generation survives.
fun the_package_admin_role_can_permanently_destroy_upgrade_authority() {
    let mut fixture = start(domain::package_admin_role());
    let upgrade_cap_id = fixture.package_admin.upgrade_cap_id_for_testing();

    fixture.make_immutable();

    let destroyed = blast_admin::events::collect_one<
        blast_admin::events::UpgradeCapDestroyed<BLAST_BOOSTS_AFTERMATH>,
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
fun policy_restriction_is_rejected_after_immutability() {
    let mut fixture = start(domain::package_admin_role());

    fixture.make_immutable();
    fixture.restrict_to_additive();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EUpgradeCapUnavailable,
    location = blast_admin::upgrade_custody,
)]
/// Immutability destroys the cap, so a second application has nothing to destroy.
fun immutability_cannot_be_applied_twice() {
    let mut fixture = start(domain::package_admin_role());

    fixture.make_immutable();
    fixture.make_immutable();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
/// A live zero-role administrator cannot reach adapter package custody.
fun a_zero_role_admin_cannot_restrict_upgrade_policy() {
    let mut fixture = start(0);

    fixture.restrict_to_additive();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
fun a_zero_role_admin_cannot_restrict_to_dependency_only() {
    let mut fixture = start(0);

    fixture.restrict_to_dependency_only();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
fun a_zero_role_admin_cannot_make_the_adapter_immutable() {
    let mut fixture = start(0);

    fixture.make_immutable();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// Immutability runs the generation guard before the role check, so stale
/// bytecode is refused even before a zero-role administrator is.
fun a_stale_generation_rejects_immutability_before_the_role_check() {
    let mut fixture = start(0);
    fixture.protocol.set_version_for_testing(3);

    fixture.make_immutable();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
/// Risk administration is a different Series1 role and does not reach custody.
fun a_risk_only_admin_cannot_authorize_an_upgrade() {
    let mut fixture = start(domain::risk_admin_role());

    let ticket = fixture.authorize_upgrade(package_digest());

    destroy(ticket);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// A stale generation aborts before the role check and before the native call.
fun a_stale_generation_rejects_old_bytecode_before_the_role_check() {
    let mut fixture = start(0);
    fixture.protocol.set_version_for_testing(3);

    let ticket = fixture.authorize_upgrade(package_digest());

    destroy(ticket);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidPackageDigest,
    location = blast_admin::upgrade_custody,
)]
fun upgrade_authorization_rejects_a_non_digest_length() {
    let mut fixture = start(domain::package_admin_role());

    let ticket = fixture.authorize_upgrade(vector[]);

    destroy(ticket);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidAdminCap,
    location = blast_admin::acl,
)]
/// An administrator registered in another registry cannot sign in here.
fun an_admin_from_another_registry_cannot_authorize_an_upgrade() {
    let mut fixture = start(domain::package_admin_role());
    let (foreign_super_admin_cap, foreign_authority) =
        domain_fixture::new_authority(fixture.ctx!());

    let ticket = fixture.authorize_upgrade_through(&foreign_authority, package_digest());

    destroy(ticket);
    destroy(foreign_super_admin_cap);
    destroy(foreign_authority);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidAdminCap,
    location = blast_admin::acl,
)]
/// One revocation in the shared Series1 registry blocks the next sign-in.
fun a_revoked_administrator_can_no_longer_sign_in() {
    let mut fixture = start(domain::package_admin_role());
    fixture.revoke_admin();

    fixture.restrict_to_additive();

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

macro fun ctx($self: &mut Fixture): &mut TxContext {
    let fixture = $self;

    fixture.scenario.ctx()
}

fun start(roles: u64): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let protocol = protocol::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(&super_admin_cap, roles, PACKAGE_ADMIN, scenario.ctx());
    let package_admin = package_admin::new_for_testing(scenario.ctx());

    scenario.next_tx(PACKAGE_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_BOOSTS_CORE>>();

    Fixture {
        scenario,
        protocol,
        authority,
        super_admin_cap,
        admin_cap,
        package_admin,
    }
}

fun package_digest(): vector<u8> {
    x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211"
}

fun authorize_upgrade(
    self: &mut Fixture,
    digest: vector<u8>,
): UpgradeTicket {
    let Fixture { protocol, authority, admin_cap, package_admin, .. } = self;
    let admin_witness = authority.sign_in(admin_cap);

    package_admin.authorize_upgrade(protocol, &admin_witness, digest)
}

/// Authorizes `digest` for an administrator signed in through `authority`
/// rather than the registry this fixture registered it in.
fun authorize_upgrade_through(
    self: &mut Fixture,
    authority: &Authority<BLAST_BOOSTS_CORE>,
    digest: vector<u8>,
): UpgradeTicket {
    let Fixture { protocol, admin_cap, package_admin, .. } = self;
    let admin_witness = authority.sign_in(admin_cap);

    package_admin.authorize_upgrade(protocol, &admin_witness, digest)
}

fun restrict_to_additive(self: &mut Fixture) {
    let Fixture { protocol, authority, admin_cap, package_admin, .. } = self;
    let admin_witness = authority.sign_in(admin_cap);

    package_admin.restrict_to_additive(protocol, &admin_witness);
}

fun restrict_to_dependency_only(self: &mut Fixture) {
    let Fixture { protocol, authority, admin_cap, package_admin, .. } = self;
    let admin_witness = authority.sign_in(admin_cap);

    package_admin.restrict_to_dependency_only(protocol, &admin_witness);
}

fun make_immutable(self: &mut Fixture) {
    let Fixture { protocol, authority, admin_cap, package_admin, .. } = self;
    let admin_witness = authority.sign_in(admin_cap);

    package_admin.make_immutable(protocol, &admin_witness);
}

fun revoke_admin(self: &mut Fixture) {
    let Fixture { authority, super_admin_cap, admin_cap, .. } = self;

    authority.revoke_admin(super_admin_cap, admin_cap.admin_cap_id_for_testing());
}

fun end(self: Fixture) {
    let Fixture {
        scenario,
        protocol,
        authority,
        super_admin_cap,
        admin_cap,
        package_admin,
    } = self;
    destroy(protocol);
    destroy(authority);
    destroy(super_admin_cap);
    destroy(admin_cap);
    destroy(package_admin);
    scenario.end();
}

// === Imports ===

use blast_admin::acl::{Authority, AdminCap, SuperAdminCap};

use blast_boosts_aftermath::{
    blast_boosts_aftermath::{Self as marker, BLAST_BOOSTS_AFTERMATH},
    domain_fixture,
    errors,
    package_admin::{Self, PackageAdmin},
    protocol::{Self, Protocol},
};

use blast_boosts_core::blast_boosts_core::{Self as domain, BLAST_BOOSTS_CORE};

use std::unit_test::{assert_eq, destroy};

use sui::{package::{Self, UpgradeTicket}, test_scenario::{Self, Scenario}};

use fun wrap_ctx as WrapFixture.ctx;

use fun wrap_end as WrapFixture.end;

use fun wrap_next_tx as WrapFixture.next_tx;

use fun wrap_return_package_admin as WrapFixture.return_package_admin;

use fun wrap_take_package_admin as WrapFixture.take_package_admin;
