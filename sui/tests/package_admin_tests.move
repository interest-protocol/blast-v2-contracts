#[test_only]
module blast_fun::package_admin_tests;

use blast_fun::{acl, blast, events, package_admin};
use std::unit_test::{assert_eq, destroy};
use sui::{
    event,
    package::{Self, Publisher},
    test_scenario::{Self, Scenario},
};

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;
const PACKAGE_ID: address = @0xB1A57;
const OTHER_PACKAGE_ID: address = @0xBAD;

// === Test-Only Types ===

public struct FOREIGN_PUBLISHER() has drop;

public struct Fixture {
    scenario: Scenario,
    super_admin_cap: acl::SuperAdminCap,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
    package_admin: package_admin::PackageAdmin,
}

// === Tests ===

#[test]
fun wrap_accepts_blast_capabilities_and_shares_complete_custody_fact() {
    let (mut fixture, created) = start_shared_custody();

    fixture.next_tx!(PUBLISHER, |f| {
        let (
            emitted_package_admin_id,
            emitted_publisher_id,
            emitted_upgrade_cap_id,
            emitted_package_id,
            emitted_package_version,
            emitted_policy,
        ) = created.package_admin_created_fields();

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
#[expected_failure(abort_code = 53)]
fun wrap_rejects_upgrade_cap_for_another_package() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |f| {
        let valid_publisher = blast::publisher_for_testing(f.scenario.ctx());
        let foreign_upgrade_cap =
            package::test_publish(OTHER_PACKAGE_ID.to_id(), f.scenario.ctx());

        package_admin::wrap(valid_publisher, foreign_upgrade_cap, f.scenario.ctx());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 56)]
fun wrap_checks_publisher_before_upgrade_cap_provenance() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |f| {
        let foreign_publisher =
            package::test_claim(FOREIGN_PUBLISHER(), f.scenario.ctx());
        let foreign_upgrade_cap =
            package::test_publish(OTHER_PACKAGE_ID.to_id(), f.scenario.ctx());

        package_admin::wrap(foreign_publisher, foreign_upgrade_cap, f.scenario.ctx());
    });

    fixture.end();
}

#[test]
fun active_admin_authorizes_exact_digest_and_commits_matching_receipt() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let digest = package_digest();
        let ticket = f.package_admin.authorize_upgrade(&admin_witness, digest);
        let receipt = package::test_upgrade(ticket);
        let new_package_id = receipt.package();

        f.package_admin.commit_upgrade(receipt);

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
        let (emitted_new_package_id, previous_version, new_version) =
            committed.upgrade_committed_fields();
        assert_eq!(emitted_new_package_id, new_package_id);
        assert_eq!(previous_version, 1);
        assert_eq!(new_version, 2);
        assert_eq!(f.package_admin.package_id_for_testing(), new_package_id);
        assert_eq!(f.package_admin.version_for_testing(), 2);
        assert!(event::events_by_type<events::UpgradeAuthorized>().is_empty());
        assert!(event::events_by_type<events::UpgradeCommitted>().is_empty());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 54)]
fun authorization_rejects_non_digest_length() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let ticket = f.package_admin.authorize_upgrade(
            &admin_witness,
            x"11223344556677889900aabbccddeeffffeeddccbbaa009988776655443322",
        );
        let receipt = package::test_upgrade(ticket);

        f.package_admin.commit_upgrade(receipt);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 0)]
fun revoked_admin_cannot_reach_upgrade_authorization() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |f| {
        f.authority.revoke_admin(&f.super_admin_cap, object::id(&f.admin_cap));
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let ticket = f.package_admin.authorize_upgrade(&admin_witness, package_digest());
        let receipt = package::test_upgrade(ticket);

        f.package_admin.commit_upgrade(receipt);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 4, location = sui::package)]
fun commit_rejects_receipt_bound_to_another_upgrade_cap() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let mut other_package_admin =
            package_admin::new_for_testing(OTHER_PACKAGE_ID.to_id(), f.scenario.ctx());
        let ticket =
            other_package_admin.authorize_upgrade(&admin_witness, package_digest());
        let receipt = package::test_upgrade(ticket);

        f.package_admin.commit_upgrade(receipt);

        destroy(other_package_admin);
    });

    fixture.end();
}

#[test]
fun active_admin_can_irreversibly_restrict_upgrade_policy() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.package_admin.restrict_to_additive(&admin_witness);

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

        f.package_admin.restrict_to_dependency_only(&admin_witness);

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
#[expected_failure(abort_code = 57)]
fun policy_restriction_rejects_unchanged_policy() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_admin.restrict_to_additive(&admin_witness);
        let _ = events::collect_one<events::UpgradePolicyRestricted>(0);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_admin.restrict_to_additive(&admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 57)]
fun policy_restriction_rejects_looser_policy() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_admin.restrict_to_dependency_only(&admin_witness);
        let _ = events::collect_one<events::UpgradePolicyRestricted>(0);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_admin.restrict_to_additive(&admin_witness);
    });

    fixture.end();
}

// === Private Test Helpers ===

macro fun next_tx($fixture: &mut Fixture, $sender: address, $fn: |&mut Fixture|) {
    let fixture = $fixture;

    fixture.advance($sender);
    $fn(fixture);
}

fun start(): Fixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(PUBLISHER, scenario.ctx());
    authority.grant_admin(&super_admin_cap, PROTOCOL_ADMIN, scenario.ctx());
    let package_admin =
        package_admin::new_for_testing(PACKAGE_ID.to_id(), scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();

    Fixture { scenario, super_admin_cap, authority, admin_cap, package_admin }
}

/// Runs the production wrap flow so the fixture custodies the real shared object.
fun start_shared_custody(): (Fixture, events::PackageAdminCreated) {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(PUBLISHER, scenario.ctx());
    authority.grant_admin(&super_admin_cap, PROTOCOL_ADMIN, scenario.ctx());
    blast::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publisher = scenario.take_from_sender<Publisher>();
    package_admin::wrap(
        publisher,
        package::test_publish(@0x0.to_id(), scenario.ctx()),
        scenario.ctx(),
    );
    let created = events::collect_one<events::PackageAdminCreated>(0);

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let package_admin = scenario.take_shared<package_admin::PackageAdmin>();

    (
        Fixture { scenario, super_admin_cap, authority, admin_cap, package_admin },
        created,
    )
}

fun advance(self: &mut Fixture, sender: address) {
    self.scenario.next_tx(sender);
}

fun sign_in(self: &Fixture): acl::AdminWitness {
    self.authority.sign_in(&self.admin_cap)
}

fun end(self: Fixture) {
    destroy(self);
}

fun package_digest(): vector<u8> {
    x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211"
}
