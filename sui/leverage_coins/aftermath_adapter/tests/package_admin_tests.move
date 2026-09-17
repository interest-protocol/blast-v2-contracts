#[test_only]
/// Tests for adapter-owned Publisher and UpgradeCap custody.
///
/// The complete native authorize/commit/advance matrix belongs to
/// `blast_admin::upgrade_custody_tests`, which owns a package marker at a
/// nonzero address. Under this package's test compilation
/// `blast_leverage_aftermath` is `0x0`, and the framework refuses to authorize
/// an upgrade for the zero package id, so these tests prove this package's
/// wiring, provenance, and guard order.
module blast_leverage_aftermath::package_admin_tests;

use blast_admin::acl::{Authority, AdminCap, SuperAdminCap};
use blast_leverage_aftermath::{
    aftermath::{Self, AFTERMATH},
    domain_fixture,
    errors,
    package_admin::{Self, PackageAdmin},
    protocol::{Self, Protocol},
};
use blast_leverage_core::blast_leverage_core::{Self as domain, BLAST_LEVERAGE_CORE};
use std::unit_test::{assert_eq, destroy};
use sui::{package, test_scenario::{Self, Scenario}};

// === Constants ===

const ROOT: address = @0xA11CE;
const PACKAGE_ADMIN: address = @0xAD;

/// This package's canonical original address under test compilation.
const PACKAGE_ID: address = @0x0;
const OTHER_PACKAGE_ID: address = @0xBAD;

// === Test-Only Types ===

/// Witness from a non-canonical module used to forge a wrong-provenance Publisher.
public struct FOREIGN_PUBLISHER() has drop;

/// Bare transaction runner for provenance rejections.
public struct WrapFixture {
    scenario: Scenario,
}

public struct Fixture {
    scenario: Scenario,
    protocol: Protocol,
    authority: Authority<BLAST_LEVERAGE_CORE>,
    super_admin_cap: SuperAdminCap<BLAST_LEVERAGE_CORE>,
    admin_cap: AdminCap<BLAST_LEVERAGE_CORE>,
    package_admin: PackageAdmin,
}

// === Tests ===

#[test]
/// The sealed constructor emits the complete custody fact and holds exactly the
/// canonical capabilities it validated.
fun canonical_capabilities_enter_adapter_custody() {
    let mut scenario = test_scenario::begin(ROOT);
    let publisher = aftermath::publisher_for_testing(scenario.ctx());
    let upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), scenario.ctx());
    let publisher_id = object::id(&publisher);
    let upgrade_cap_id = object::id(&upgrade_cap);

    package_admin::wrap(publisher, upgrade_cap, scenario.ctx());

    // The creation fact belongs to the sealing transaction, so it is collected
    // before the shared object can be taken in the next one.
    let created = blast_admin::events::collect_one<
        blast_admin::events::UpgradeCustodyCreated<AFTERMATH>,
    >(0);

    scenario.next_tx(ROOT);
    let package_admin = scenario.take_shared<PackageAdmin>();
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
    assert!(package_admin.has_upgrade_cap());

    test_scenario::return_shared(package_admin);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidPackagePublisher,
    location = blast_leverage_aftermath::package_admin,
)]
/// Publisher provenance is checked in this package before the shared custody
/// constructor ever sees the capabilities.
fun a_publisher_from_another_module_is_rejected_first() {
    let mut fixture = start_wrap();

    let publisher = package::test_claim(FOREIGN_PUBLISHER(), fixture.scenario.ctx());
    let upgrade_cap = package::test_publish(
        OTHER_PACKAGE_ID.to_id(),
        fixture.scenario.ctx(),
    );

    package_admin::wrap(publisher, upgrade_cap, fixture.scenario.ctx());

    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidUpgradeCap,
    location = blast_admin::upgrade_custody,
)]
fun an_upgrade_cap_for_another_package_is_rejected() {
    let mut fixture = start_wrap();

    let publisher = aftermath::publisher_for_testing(fixture.scenario.ctx());
    let upgrade_cap = package::test_publish(
        OTHER_PACKAGE_ID.to_id(),
        fixture.scenario.ctx(),
    );

    package_admin::wrap(publisher, upgrade_cap, fixture.scenario.ctx());

    destroy(fixture);
}

#[test]
/// A package administrator irreversibly narrows the policy in two steps.
fun the_package_admin_role_can_irreversibly_restrict_the_adapter() {
    let mut fixture = start(domain::package_admin_role());

    fixture.restrict_to_additive();
    let restricted = blast_admin::events::collect_one<
        blast_admin::events::UpgradePolicyRestricted<AFTERMATH>,
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

    destroy(fixture);
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

    destroy(fixture);
}

#[test]
/// Immutability destroys native upgrade authority while the final operational
/// generation survives.
fun the_package_admin_role_can_permanently_destroy_upgrade_authority() {
    let mut fixture = start(domain::package_admin_role());
    let upgrade_cap_id = fixture.package_admin.upgrade_cap_id_for_testing();

    fixture.make_immutable();

    let destroyed = blast_admin::events::collect_one<
        blast_admin::events::UpgradeCapDestroyed<AFTERMATH>,
    >(0);
    let (custodian_id, emitted_upgrade_cap_id, _, final_native_version, final_policy) =
        destroyed.upgrade_cap_destroyed_fields();
    assert_eq!(custodian_id, fixture.package_admin.id_for_testing());
    assert_eq!(emitted_upgrade_cap_id, upgrade_cap_id);
    assert_eq!(final_native_version, 1);
    assert_eq!(final_policy, package::compatible_policy());
    assert!(!fixture.package_admin.has_upgrade_cap());
    assert_eq!(fixture.protocol.version_for_testing(), 1);

    destroy(fixture);
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

    destroy(fixture);
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

    destroy(fixture);
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
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// A stale generation aborts before the role check and before the native call.
fun a_stale_generation_rejects_old_bytecode_before_the_role_check() {
    let mut fixture = start(0);
    fixture.protocol.set_version_for_testing(2);

    let ticket = fixture.authorize_upgrade(package_digest());

    destroy(ticket);
    destroy(fixture);
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
    destroy(fixture);
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
        domain_fixture::new_authority(fixture.scenario.ctx());
    let Fixture { protocol, admin_cap, package_admin, .. } = &mut fixture;
    let admin_witness = foreign_authority.sign_in(admin_cap);
    let ticket = package_admin.authorize_upgrade(
        protocol,
        &admin_witness,
        package_digest(),
    );

    destroy(ticket);
    destroy(foreign_super_admin_cap);
    destroy(foreign_authority);
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidAdminCap,
    location = blast_admin::acl,
)]
/// One revocation in the shared Series1 registry blocks the next sign-in.
fun a_revoked_administrator_can_no_longer_sign_in() {
    let mut fixture = start(domain::package_admin_role());
    let admin_cap_id = fixture.admin_cap.admin_cap_id_for_testing();
    let Fixture { authority, super_admin_cap, .. } = &mut fixture;
    authority.revoke_admin(super_admin_cap, admin_cap_id);

    fixture.restrict_to_additive();

    destroy(fixture);
}

// === Fixture Setup ===

fun start_wrap(): WrapFixture {
    WrapFixture { scenario: test_scenario::begin(ROOT) }
}

fun start(roles: u64): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let protocol = protocol::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(&super_admin_cap, roles, PACKAGE_ADMIN, scenario.ctx());
    let package_admin = package_admin::new_for_testing(scenario.ctx());

    scenario.next_tx(PACKAGE_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_LEVERAGE_CORE>>();

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

// === Fixture Helpers ===

fun authorize_upgrade(
    self: &mut Fixture,
    digest: vector<u8>,
): sui::package::UpgradeTicket {
    let Fixture { protocol, authority, admin_cap, package_admin, .. } = self;
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
