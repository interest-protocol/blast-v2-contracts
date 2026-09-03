#[test_only]
/// Stateful tests for permanent Series1 package-capability custody.
module blast_leverage_series_one::package_admin_tests;

use blast_leverage_series_one::{
    acl,
    constants,
    errors,
    events,
    package_admin,
    package_version::{Self, PackageVersion},
    series_one,
};
use std::unit_test::{assert_eq, destroy};
use sui::{
    event,
    package::{Self, Publisher},
    test_scenario::{Self, Scenario},
};

use fun custody_end as CustodyFixture.end;
use fun custody_next_tx as CustodyFixture.next_tx;
use fun package_admin::activate_package_version as PackageVersion.activate_package_version;
use fun upgrade_ctx as UpgradeFixture.ctx;
use fun upgrade_end as UpgradeFixture.end;
use fun upgrade_next_tx as UpgradeFixture.next_tx;
use fun wrap_ctx as WrapFixture.ctx;
use fun wrap_end as WrapFixture.end;
use fun wrap_next_tx as WrapFixture.next_tx;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PACKAGE_ADMIN: address = @0xAD;
const PACKAGE_ID: address = @0xB1A57;
const OTHER_PACKAGE_ID: address = @0xBAD;

// === Test-Only Types ===

/// Witness from a noncanonical module used to forge a foreign Publisher.
public struct FOREIGN_PUBLISHER() has drop;

/// Bare transaction runner for package-capability provenance rejections.
public struct WrapFixture {
    scenario: Scenario,
}

/// Shared production custody and its creation event.
public struct CustodyFixture {
    scenario: Scenario,
    package_admin: package_admin::PackageAdmin,
    created: events::PackageAdminCreated,
}

/// Role-authenticated upgrade and operational-version state.
public struct UpgradeFixture {
    scenario: Scenario,
    authority: acl::ProtocolAuthority,
    super_admin_cap: acl::SuperAdminCap,
    admin_cap: acl::AdminCap,
    package_admin: package_admin::PackageAdmin,
    package_version: PackageVersion,
}

// === Tests ===

#[test]
fun new_and_share_create_permanent_replay_complete_custody() {
    let mut fixture = start_custody();

    fixture.next_tx!(PUBLISHER, |f| {
        let (
            package_admin_id,
            publisher_id,
            upgrade_cap_id,
            package_id,
            package_version,
            policy,
        ) = f.created.package_admin_created_fields();

        assert_eq!(package_admin_id, object::id(&f.package_admin));
        assert_eq!(publisher_id, f.package_admin.publisher_id_for_testing());
        assert_eq!(upgrade_cap_id, f.package_admin.upgrade_cap_id_for_testing());
        assert_eq!(package_id, @0x0.to_id());
        assert_eq!(package_id, f.package_admin.package_id_for_testing());
        assert_eq!(package_version, 1);
        assert_eq!(package_version, f.package_admin.version_for_testing());
        assert_eq!(policy, package::compatible_policy());
        assert_eq!(policy, f.package_admin.policy_for_testing());
        assert!(event::events_by_type<events::PackageAdminCreated>().is_empty());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidPackagePublisher,
    location = blast_leverage_series_one::package_admin,
)]
fun new_checks_publisher_before_upgrade_cap_provenance() {
    let mut fixture = start_wrap();

    fixture.next_tx!(PUBLISHER, |f| {
        let publisher = package::test_claim(FOREIGN_PUBLISHER(), f.ctx!());
        let upgrade_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), f.ctx!());

        destroy(package_admin::new(publisher, upgrade_cap, f.ctx!()));
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidUpgradeCap,
    location = blast_leverage_series_one::package_admin,
)]
fun new_rejects_an_upgrade_cap_for_another_package() {
    let mut fixture = start_wrap();

    fixture.next_tx!(PUBLISHER, |f| {
        let publisher = series_one::publisher_for_testing(f.ctx!());
        let upgrade_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), f.ctx!());

        destroy(package_admin::new(publisher, upgrade_cap, f.ctx!()));
    });

    fixture.end();
}

#[test]
fun package_admin_role_authorizes_commit_and_replay_complete_events() {
    let mut fixture = start_upgrade(constants::package_admin_role!());

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        let digest = package_digest();
        let ticket = f.package_admin.authorize_upgrade(
            &f.package_version,
            &witness,
            digest,
        );
        let receipt = ticket.test_upgrade();
        let new_package_id = receipt.package();

        f.package_admin.commit_upgrade(&f.package_version, receipt);

        let authorized = events::collect_one<events::UpgradeAuthorized>(0);
        let (
            authorized_package_id,
            authorized_package_version,
            authorized_policy,
            authorized_digest,
        ) = authorized.upgrade_authorized_fields();
        assert_eq!(authorized_package_id, PACKAGE_ID.to_id());
        assert_eq!(authorized_package_version, 1);
        assert_eq!(authorized_policy, package::compatible_policy());
        assert_eq!(authorized_digest, digest);

        let committed = events::collect_one<events::UpgradeCommitted>(0);
        let (emitted_package_id, previous_version, new_version) =
            committed.upgrade_committed_fields();
        assert_eq!(emitted_package_id, new_package_id);
        assert_eq!(emitted_package_id, f.package_admin.package_id_for_testing());
        assert_eq!(previous_version, 1);
        assert_eq!(new_version, 2);
        assert_eq!(new_version, f.package_admin.version_for_testing());
        assert_eq!(f.package_version.version_for_testing(), 1);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionMismatch,
    location = blast_leverage_series_one::package_version,
)]
fun stale_version_precedes_package_role_and_digest_validation() {
    let mut fixture = start_upgrade(constants::risk_admin_role!());

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        f.package_version.set_for_testing(2);
        let ticket = f.package_admin.authorize_upgrade(
            &f.package_version,
            &witness,
            vector[],
        );
        let receipt = ticket.test_upgrade();

        f.package_admin.commit_upgrade(&f.package_version, receipt);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionMismatch,
    location = blast_leverage_series_one::package_version,
)]
fun stale_version_precedes_upgrade_receipt_binding() {
    let mut fixture = start_upgrade(constants::package_admin_role!());

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        let mut other_package_admin =
            package_admin::new_for_testing(OTHER_PACKAGE_ID.to_id(), f.ctx!());
        let ticket = other_package_admin.authorize_upgrade(
            &f.package_version,
            &witness,
            package_digest(),
        );
        let receipt = ticket.test_upgrade();
        f.package_version.set_for_testing(2);

        f.package_admin.commit_upgrade(&f.package_version, receipt);
        destroy(other_package_admin);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EAdminRoleNotGranted,
    location = blast_leverage_series_one::acl,
)]
fun package_role_precedes_digest_validation() {
    let mut fixture = start_upgrade(constants::risk_admin_role!());

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        let ticket = f.package_admin.authorize_upgrade(
            &f.package_version,
            &witness,
            vector[],
        );
        let receipt = ticket.test_upgrade();

        f.package_admin.commit_upgrade(&f.package_version, receipt);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidPackageDigest,
    location = blast_leverage_series_one::package_admin,
)]
fun authorization_rejects_a_non_digest_length() {
    let mut fixture = start_upgrade(constants::package_admin_role!());

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        let ticket = f.package_admin.authorize_upgrade(
            &f.package_version,
            &witness,
            x"11223344556677889900aabbccddeeffffeeddccbbaa009988776655443322",
        );
        let receipt = ticket.test_upgrade();

        f.package_admin.commit_upgrade(&f.package_version, receipt);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = sui::package::EWrongUpgradeCap,
    location = sui::package,
)]
fun commit_rejects_a_receipt_bound_to_another_upgrade_cap() {
    let mut fixture = start_upgrade(constants::package_admin_role!());

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        let mut other_package_admin =
            package_admin::new_for_testing(OTHER_PACKAGE_ID.to_id(), f.ctx!());
        let ticket = other_package_admin.authorize_upgrade(
            &f.package_version,
            &witness,
            package_digest(),
        );
        let receipt = ticket.test_upgrade();

        f.package_admin.commit_upgrade(&f.package_version, receipt);
        destroy(other_package_admin);
    });

    fixture.end();
}

#[test]
fun package_admin_role_can_irreversibly_narrow_upgrade_policy() {
    let mut fixture = start_upgrade(constants::package_admin_role!());

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        f.package_admin.restrict_to_additive(&f.package_version, &witness);

        let restricted = events::collect_one<events::UpgradePolicyRestricted>(0);
        let (previous_policy, new_policy) = restricted.upgrade_policy_restricted_fields();
        assert_eq!(previous_policy, package::compatible_policy());
        assert_eq!(new_policy, package::additive_policy());
        assert_eq!(new_policy, f.package_admin.policy_for_testing());
    });

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        f.package_admin.restrict_to_dependency_only(
            &f.package_version,
            &witness,
        );

        let restricted = events::collect_one<events::UpgradePolicyRestricted>(0);
        let (previous_policy, new_policy) = restricted.upgrade_policy_restricted_fields();
        assert_eq!(previous_policy, package::additive_policy());
        assert_eq!(new_policy, package::dep_only_policy());
        assert_eq!(new_policy, f.package_admin.policy_for_testing());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EAdminRoleNotGranted,
    location = blast_leverage_series_one::acl,
)]
fun additive_policy_restriction_requires_the_package_admin_role() {
    let mut fixture = start_upgrade(constants::risk_admin_role!());

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        f.package_admin.restrict_to_additive(&f.package_version, &witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EAdminRoleNotGranted,
    location = blast_leverage_series_one::acl,
)]
fun dependency_only_policy_restriction_requires_the_package_admin_role() {
    let mut fixture = start_upgrade(constants::risk_admin_role!());

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        f.package_admin.restrict_to_dependency_only(
            &f.package_version,
            &witness,
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionMismatch,
    location = blast_leverage_series_one::package_version,
)]
fun stale_version_precedes_policy_role_validation() {
    let mut fixture = start_upgrade(constants::risk_admin_role!());

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        f.package_version.set_for_testing(2);

        f.package_admin.restrict_to_additive(&f.package_version, &witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EUpgradePolicyNotMoreRestrictive,
    location = blast_leverage_series_one::package_admin,
)]
fun policy_restriction_rejects_an_unchanged_policy() {
    let mut fixture = start_upgrade(constants::package_admin_role!());

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        f.package_admin.restrict_to_additive(&f.package_version, &witness);
        let _ = events::collect_one<events::UpgradePolicyRestricted>(0);
        f.package_admin.restrict_to_additive(&f.package_version, &witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EUpgradePolicyNotMoreRestrictive,
    location = blast_leverage_series_one::package_admin,
)]
fun policy_restriction_rejects_a_looser_policy() {
    let mut fixture = start_upgrade(constants::package_admin_role!());

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        f.package_admin.restrict_to_dependency_only(
            &f.package_version,
            &witness,
        );
        let _ = events::collect_one<events::UpgradePolicyRestricted>(0);
        f.package_admin.restrict_to_additive(&f.package_version, &witness);
    });

    fixture.end();
}

#[test]
fun package_admin_role_activates_the_exact_next_operational_version() {
    let mut fixture = start_upgrade(constants::package_admin_role!());

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        f.package_version.set_for_testing(0);

        f.package_version.activate_package_version(&witness);

        let advanced = events::collect_one<events::PackageVersionAdvanced>(0);
        let (previous_version, new_version) = advanced.package_version_advanced_fields();
        assert_eq!(previous_version, 0);
        assert_eq!(new_version, 1);
        assert_eq!(new_version, f.package_version.version_for_testing());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EAdminRoleNotGranted,
    location = blast_leverage_series_one::acl,
)]
fun operational_activation_requires_the_package_admin_role() {
    let mut fixture = start_upgrade(constants::risk_admin_role!());

    fixture.next_tx!(PACKAGE_ADMIN, |f| {
        let witness = f.sign_in();
        f.package_version.set_for_testing(0);

        f.package_version.activate_package_version(&witness);
    });

    fixture.end();
}

// === Private Test Helpers ===

macro fun wrap_next_tx(
    $fixture: &mut WrapFixture,
    $sender: address,
    $fn: |&mut WrapFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun custody_next_tx(
    $fixture: &mut CustodyFixture,
    $sender: address,
    $fn: |&mut CustodyFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun upgrade_next_tx(
    $fixture: &mut UpgradeFixture,
    $sender: address,
    $fn: |&mut UpgradeFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun wrap_ctx($fixture: &mut WrapFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

macro fun upgrade_ctx($fixture: &mut UpgradeFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun start_wrap(): WrapFixture {
    WrapFixture { scenario: test_scenario::begin(PUBLISHER) }
}

fun start_custody(): CustodyFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    series_one::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publisher = scenario.take_from_sender<Publisher>();
    let package_admin = package_admin::new(
        publisher,
        package::test_publish(@0x0.to_id(), scenario.ctx()),
        scenario.ctx(),
    );
    package_admin.share();
    let created = events::collect_one<events::PackageAdminCreated>(0);

    scenario.next_tx(PUBLISHER);
    let package_admin = scenario.take_shared<package_admin::PackageAdmin>();

    CustodyFixture { scenario, package_admin, created }
}

fun start_upgrade(roles: u8): UpgradeFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = acl::new_protocol_for_testing(scenario.ctx());
    authority.grant_admin(
        &package_version,
        &super_admin_cap,
        roles,
        PACKAGE_ADMIN,
        scenario.ctx(),
    );
    let package_admin =
        package_admin::new_for_testing(PACKAGE_ID.to_id(), scenario.ctx());

    scenario.next_tx(PACKAGE_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();

    UpgradeFixture {
        scenario,
        authority,
        super_admin_cap,
        admin_cap,
        package_admin,
        package_version,
    }
}

fun sign_in(self: &UpgradeFixture): acl::AdminWitness {
    self.authority.sign_in(&self.package_version, &self.admin_cap)
}

fun package_digest(): vector<u8> {
    x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211"
}

fun wrap_end(self: WrapFixture) {
    destroy(self)
}

fun custody_end(self: CustodyFixture) {
    destroy(self)
}

fun upgrade_end(self: UpgradeFixture) {
    destroy(self)
}
