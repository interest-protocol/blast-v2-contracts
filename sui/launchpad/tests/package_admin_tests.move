#[test_only]
module blast_fun::package_admin_tests;

use blast_fun::{acl, blast, events, package_admin, package_version};
use 0xf::foreign_publisher;
use std::unit_test::{assert_eq, destroy};
use sui::{
    event,
    package::{Self, Publisher},
    test_scenario::{Self, Scenario},
};

use fun custody_end as CustodyFixture.end;
use fun custody_next_tx as CustodyFixture.next_tx;
use fun package_admin::activate_package_version as package_version::PackageVersion.activate_package_version;
use fun upgrade_ctx as UpgradeFixture.ctx;
use fun upgrade_end as UpgradeFixture.end;
use fun upgrade_next_tx as UpgradeFixture.next_tx;
use fun wrap_ctx as WrapFixture.ctx;
use fun wrap_end as WrapFixture.end;
use fun wrap_next_tx as WrapFixture.next_tx;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;
const PACKAGE_ID: address = @0xB1A57;
const OTHER_PACKAGE_ID: address = @0xBAD;

/// Bare transaction runner for capability-provenance rejections; needs no ACL.
public struct WrapFixture {
    scenario: Scenario,
}

/// Production wrap output: the shared custody object and its creation fact.
public struct CustodyFixture {
    scenario: Scenario,
    package_admin: package_admin::PackageAdmin,
    created: events::PackageAdminCreated,
}

/// Admin-authorized upgrade and policy operations through the ACL sign-in seam.
public struct UpgradeFixture {
    scenario: Scenario,
    super_admin_cap: acl::SuperAdminCap,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
    package_admin: package_admin::PackageAdmin,
    package_version: package_version::PackageVersion,
}

// === Tests ===

#[test]
fun wrap_accepts_blast_capabilities_and_shares_complete_custody_fact() {
    let mut fixture = start_custody();

    fixture.next_tx!(PUBLISHER, |f| {
        let (
            emitted_package_admin_id,
            emitted_publisher_id,
            emitted_upgrade_cap_id,
            emitted_package_id,
            emitted_package_version,
            emitted_policy,
        ) = f.created.package_admin_created_fields();

        assert_eq!(emitted_package_admin_id, object::id(&f.package_admin));
        assert_eq!(emitted_publisher_id, f.package_admin.publisher_id_for_testing());
        assert_eq!(
            emitted_upgrade_cap_id,
            f.package_admin.upgrade_cap_id_for_testing(),
        );
        assert_eq!(emitted_package_id, @0x0.to_id());
        assert_eq!(emitted_package_id, f.package_admin.package_id_for_testing());
        assert_eq!(emitted_package_version, 1);
        assert_eq!(emitted_package_version, f.package_admin.version_for_testing());
        assert_eq!(emitted_policy, package::compatible_policy());
        assert_eq!(emitted_policy, f.package_admin.policy_for_testing());
        assert!(event::events_by_type<events::PackageAdminCreated>().is_empty());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidUpgradeCap,
    location = blast_fun::package_admin,
)]
fun wrap_rejects_upgrade_cap_for_another_package() {
    let mut fixture = start_wrap();

    fixture.next_tx!(PUBLISHER, |f| {
        let valid_publisher = blast::publisher_for_testing(f.ctx!());
        let foreign_upgrade_cap =
            package::test_publish(OTHER_PACKAGE_ID.to_id(), f.ctx!());

        package_admin::wrap(valid_publisher, foreign_upgrade_cap, f.ctx!());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidPackagePublisher,
    location = blast_fun::package_admin,
)]
fun wrap_checks_publisher_before_upgrade_cap_provenance() {
    let mut fixture = start_wrap();

    fixture.next_tx!(PUBLISHER, |f| {
        let foreign_publisher = foreign_publisher::new(f.ctx!());
        let foreign_upgrade_cap =
            package::test_publish(OTHER_PACKAGE_ID.to_id(), f.ctx!());

        package_admin::wrap(foreign_publisher, foreign_upgrade_cap, f.ctx!());
    });

    fixture.end();
}

#[test]
fun active_admin_explicitly_activates_the_exact_next_operational_version() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(0);

        f.package_version.activate_package_version(&admin_witness);

        let advanced = events::collect_one<events::PackageVersionAdvanced>(0);
        let (previous_version, new_version) =
            advanced.package_version_advanced_fields();
        assert_eq!(previous_version, 0);
        assert_eq!(new_version, 1);
        assert_eq!(f.package_version.version_for_testing(), 1);
        assert!(event::events_by_type<events::PackageVersionAdvanced>().is_empty());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EPackageVersionMismatch,
    location = blast_fun::package_version,
)]
fun activation_rejects_skipping_an_operational_version() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.package_version.activate_package_version(&admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EPackageVersionOverflow,
    location = blast_fun::package_version,
)]
fun activation_rejects_operational_version_overflow() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(std::u64::max_value!());

        f.package_version.activate_package_version(&admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidPackagePublisher,
    location = blast_fun::package_admin,
)]
fun wrap_rejects_a_publisher_from_another_module_in_the_blast_package() {
    let mut fixture = start_wrap();

    fixture.next_tx!(PUBLISHER, |f| {
        let publisher = package_admin::non_blast_publisher_for_testing(f.ctx!());
        let upgrade_cap = package::test_publish(@0x0.to_id(), f.ctx!());

        package_admin::wrap(publisher, upgrade_cap, f.ctx!());
    });

    fixture.end();
}

#[test]
fun active_admin_authorizes_exact_digest_and_commits_matching_receipt() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let digest = package_digest();
        let ticket = f.package_admin.authorize_upgrade(
            &f.package_version,
            &admin_witness,
            digest,
        );
        let receipt = package::test_upgrade(ticket);
        let new_package_id = receipt.package();

        f.package_admin.commit_upgrade(&f.package_version, receipt);

        let authorized = events::collect_one<events::UpgradeAuthorized>(0);
        assert_eq!(authorized.upgrade_authorized_digest(), digest);

        let committed = events::collect_one<events::UpgradeCommitted>(0);
        let (emitted_new_package_id, previous_version, new_version) =
            committed.upgrade_committed_fields();
        assert_eq!(emitted_new_package_id, new_package_id);
        assert_eq!(previous_version, 1);
        assert_eq!(new_version, 2);
        assert_eq!(f.package_admin.package_id_for_testing(), new_package_id);
        assert_eq!(f.package_admin.version_for_testing(), 2);
        assert_eq!(f.package_version.version_for_testing(), 1);
        assert!(event::events_by_type<events::PackageVersionAdvanced>().is_empty());
        assert!(event::events_by_type<events::UpgradeAuthorized>().is_empty());
        assert!(event::events_by_type<events::UpgradeCommitted>().is_empty());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidPackageDigest,
    location = blast_fun::package_admin,
)]
fun authorization_rejects_non_digest_length() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let ticket = f.package_admin.authorize_upgrade(
            &f.package_version,
            &admin_witness,
            x"11223344556677889900aabbccddeeffffeeddccbbaa009988776655443322",
        );
        let receipt = package::test_upgrade(ticket);

        f.package_admin.commit_upgrade(&f.package_version, receipt);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EPackageVersionMismatch,
    location = blast_fun::package_version,
)]
fun stale_package_version_rejects_package_admin_before_digest_validation() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(2);
        let ticket = f.package_admin.authorize_upgrade(
            &f.package_version,
            &admin_witness,
            vector[],
        );
        let receipt = package::test_upgrade(ticket);

        f.package_admin.commit_upgrade(&f.package_version, receipt);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidAdminCap,
    location = blast_fun::acl,
)]
fun revoked_admin_cannot_reach_upgrade_authorization() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.revoke_admin(
            &f.package_version,
            &f.super_admin_cap,
            object::id(&f.admin_cap),
        );
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let ticket = f.package_admin.authorize_upgrade(
            &f.package_version,
            &admin_witness,
            package_digest(),
        );
        let receipt = package::test_upgrade(ticket);

        f.package_admin.commit_upgrade(&f.package_version, receipt);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = sui::package::EWrongUpgradeCap,
    location = sui::package,
)]
fun commit_rejects_receipt_bound_to_another_upgrade_cap() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let mut other_package_admin =
            package_admin::new_for_testing(OTHER_PACKAGE_ID.to_id(), f.ctx!());
        let ticket =
            other_package_admin.authorize_upgrade(
                &f.package_version,
                &admin_witness,
                package_digest(),
            );
        let receipt = package::test_upgrade(ticket);

        f.package_admin.commit_upgrade(&f.package_version, receipt);

        destroy(other_package_admin);
    });

    fixture.end();
}

#[test]
fun active_admin_can_irreversibly_restrict_upgrade_policy() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.package_admin.restrict_to_additive(&f.package_version, &admin_witness);

        let additive = events::collect_one<events::UpgradePolicyRestricted>(0);
        let (previous_policy, new_policy) =
            additive.upgrade_policy_restricted_fields();
        assert_eq!(previous_policy, package::compatible_policy());
        assert_eq!(new_policy, package::additive_policy());
        assert_eq!(f.package_admin.policy_for_testing(), package::additive_policy());

        assert!(event::events_by_type<events::UpgradePolicyRestricted>().is_empty());
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.package_admin.restrict_to_dependency_only(
            &f.package_version,
            &admin_witness,
        );

        let dependency_only = events::collect_one<events::UpgradePolicyRestricted>(0);
        let (previous_policy, new_policy) =
            dependency_only.upgrade_policy_restricted_fields();
        assert_eq!(previous_policy, package::additive_policy());
        assert_eq!(new_policy, package::dep_only_policy());
        assert_eq!(f.package_admin.policy_for_testing(), package::dep_only_policy());
        assert!(event::events_by_type<events::UpgradePolicyRestricted>().is_empty());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EUpgradePolicyNotMoreRestrictive,
    location = blast_fun::package_admin,
)]
fun policy_restriction_rejects_unchanged_policy() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_admin.restrict_to_additive(&f.package_version, &admin_witness);
        let _ = events::collect_one<events::UpgradePolicyRestricted>(0);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_admin.restrict_to_additive(&f.package_version, &admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EUpgradePolicyNotMoreRestrictive,
    location = blast_fun::package_admin,
)]
fun policy_restriction_rejects_looser_policy() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_admin.restrict_to_dependency_only(
            &f.package_version,
            &admin_witness,
        );
        let _ = events::collect_one<events::UpgradePolicyRestricted>(0);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_admin.restrict_to_additive(&f.package_version, &admin_witness);
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

/// Runs the production wrap flow so the fixture custodies the real shared object.
fun start_custody(): CustodyFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    blast::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publisher = scenario.take_from_sender<Publisher>();
    package_admin::wrap(
        publisher,
        package::test_publish(@0x0.to_id(), scenario.ctx()),
        scenario.ctx(),
    );
    let created = events::collect_one<events::PackageAdminCreated>(0);

    scenario.next_tx(PUBLISHER);
    let package_admin = scenario.take_shared<package_admin::PackageAdmin>();

    CustodyFixture { scenario, package_admin, created }
}

fun start(): UpgradeFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(scenario.ctx());
    authority.grant_admin(
        &package_version,
        &super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );
    let package_admin =
        package_admin::new_for_testing(PACKAGE_ID.to_id(), scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();

    UpgradeFixture {
        scenario,
        super_admin_cap,
        authority,
        admin_cap,
        package_admin,
        package_version,
    }
}

fun sign_in(self: &UpgradeFixture): acl::AdminWitness {
    self.authority.sign_in(&self.package_version, &self.admin_cap)
}

fun wrap_end(self: WrapFixture) {
    destroy(self);
}

fun custody_end(self: CustodyFixture) {
    destroy(self);
}

fun upgrade_end(self: UpgradeFixture) {
    destroy(self);
}

fun package_digest(): vector<u8> {
    x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211"
}
