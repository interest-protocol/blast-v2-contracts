// Every transaction closure receives one stable mutable view of the complete fixture; individual
// cases intentionally use only the references relevant to the operation under test.
#[allow(unused_mut_ref)]
#[test_only]
module blast_fun::package_admin_tests;

use blast_fun::{acl, blast, events, package_admin};
use std::unit_test::{assert_eq, destroy};
use sui::{
    event,
    package::{Self, Publisher, UpgradeCap},
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
    scenario: Option<Scenario>,
    super_admin_cap: Option<acl::SuperAdminCap>,
    authority: Option<acl::ProtocolAuthority>,
    admin_cap: Option<acl::AdminCap>,
    package_admin: Option<package_admin::PackageAdmin>,
    other_package_admin: Option<package_admin::PackageAdmin>,
    valid_publisher: Option<Publisher>,
    foreign_publisher: Option<Publisher>,
    valid_upgrade_cap: Option<UpgradeCap>,
    foreign_upgrade_cap: Option<UpgradeCap>,
    package_admin_created: Option<events::PackageAdminCreated>,
    wrapped_package_admin: Option<package_admin::PackageAdmin>,
}

// === Tests ===

#[test]
fun wrap_accepts_blast_capabilities_and_shares_complete_custody_fact() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |_, _, _, _, _, _, _, _, _, created, wrapped_package_admin, _| {
        let (
            emitted_package_admin_id,
            emitted_publisher_id,
            emitted_upgrade_cap_id,
            emitted_package_id,
            emitted_package_version,
            emitted_policy,
            emitted_admin_authorization_enabled,
        ) = created.package_admin_created_fields();

        assert_eq!(emitted_package_admin_id, object::id(wrapped_package_admin));
        assert_eq!(emitted_publisher_id, wrapped_package_admin.publisher_id_for_testing());
        assert_eq!(emitted_upgrade_cap_id, wrapped_package_admin.upgrade_cap_id_for_testing());
        assert_eq!(emitted_package_id, @0x0.to_id());
        assert_eq!(emitted_package_id, wrapped_package_admin.package_id_for_testing());
        assert_eq!(emitted_package_version, 1);
        assert_eq!(emitted_package_version, wrapped_package_admin.version_for_testing());
        assert_eq!(emitted_policy, package::compatible_policy());
        assert_eq!(emitted_policy, wrapped_package_admin.policy_for_testing());
        assert!(emitted_admin_authorization_enabled);
        assert!(wrapped_package_admin.admin_authorization_enabled_for_testing());
        assert!(event::events_by_type<events::PackageAdminCreated>().is_empty());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 53)]
fun wrap_rejects_upgrade_cap_for_another_package() {
    let mut fixture = start();

    fixture.take_invalid_cap_inputs_next_tx!(PUBLISHER, |publisher, upgrade_cap, _, _, _, _, _, _, _, _, scenario| {
        package_admin::wrap(publisher, upgrade_cap, scenario.ctx());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 56)]
fun wrap_checks_publisher_before_upgrade_cap_provenance() {
    let mut fixture = start();

    fixture.take_invalid_publisher_inputs_next_tx!(PUBLISHER, |publisher, upgrade_cap, _, _, _, _, _, _, _, _, scenario| {
        package_admin::wrap(publisher, upgrade_cap, scenario.ctx());
    });

    fixture.end();
}

#[test]
fun active_admin_authorizes_exact_digest_and_commits_matching_receipt() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |package_admin, _, authority, _, admin_cap, _, _, _, _, _, _, _| {
        let admin_witness = authority.sign_in(admin_cap);
        let digest = package_digest();
        let ticket = package_admin.authorize_upgrade(&admin_witness, digest);
        let receipt = package::test_upgrade(ticket);
        let new_package_id = receipt.package();

        package_admin.commit_upgrade(receipt);

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
        assert_eq!(package_admin.package_id_for_testing(), new_package_id);
        assert_eq!(package_admin.version_for_testing(), 2);
        assert!(event::events_by_type<events::UpgradeAuthorized>().is_empty());
        assert!(event::events_by_type<events::UpgradeCommitted>().is_empty());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 54)]
fun authorization_rejects_non_digest_length() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |package_admin, _, authority, _, admin_cap, _, _, _, _, _, _, _| {
        let admin_witness = authority.sign_in(admin_cap);
        let ticket = package_admin.authorize_upgrade(
            &admin_witness,
            x"11223344556677889900aabbccddeeffffeeddccbbaa009988776655443322",
        );
        let receipt = package::test_upgrade(ticket);

        package_admin.commit_upgrade(receipt);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 0)]
fun revoked_admin_cannot_reach_upgrade_authorization() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |_, _, authority, super_admin_cap, admin_cap, _, _, _, _, _, _, _| {
        authority.revoke_admin(super_admin_cap, object::id(admin_cap));
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |package_admin, _, authority, _, admin_cap, _, _, _, _, _, _, _| {
        let admin_witness = authority.sign_in(admin_cap);
        let ticket = package_admin.authorize_upgrade(&admin_witness, package_digest());
        let receipt = package::test_upgrade(ticket);

        package_admin.commit_upgrade(receipt);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 4, location = sui::package)]
fun commit_rejects_receipt_bound_to_another_upgrade_cap() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |package_admin, other_package_admin, authority, _, admin_cap, _, _, _, _, _, _, _| {
        let admin_witness = authority.sign_in(admin_cap);
        let ticket = other_package_admin.authorize_upgrade(&admin_witness, package_digest());
        let receipt = package::test_upgrade(ticket);

        package_admin.commit_upgrade(receipt);
    });

    fixture.end();
}

#[test]
fun active_admin_can_irreversibly_restrict_upgrade_policy() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |package_admin, _, authority, _, admin_cap, _, _, _, _, _, _, _| {
        let admin_witness = authority.sign_in(admin_cap);

        package_admin.restrict_to_additive(&admin_witness);

        let additive = events::collect_one<events::UpgradePolicyRestricted>(0);
        let (previous_policy, new_policy) = additive.upgrade_policy_restricted_fields();
        assert_eq!(previous_policy, package::compatible_policy());
        assert_eq!(new_policy, package::additive_policy());
        assert_eq!(package_admin.policy_for_testing(), package::additive_policy());

        assert!(event::events_by_type<events::UpgradePolicyRestricted>().is_empty());
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |package_admin, _, authority, _, admin_cap, _, _, _, _, _, _, _| {
        let admin_witness = authority.sign_in(admin_cap);

        package_admin.restrict_to_dependency_only(&admin_witness);

        let dependency_only = events::collect_one<events::UpgradePolicyRestricted>(0);
        let (previous_policy, new_policy) = dependency_only.upgrade_policy_restricted_fields();
        assert_eq!(previous_policy, package::additive_policy());
        assert_eq!(new_policy, package::dep_only_policy());
        assert_eq!(package_admin.policy_for_testing(), package::dep_only_policy());
        assert!(event::events_by_type<events::UpgradePolicyRestricted>().is_empty());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 57)]
fun policy_restriction_rejects_unchanged_policy() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |package_admin, _, authority, _, admin_cap, _, _, _, _, _, _, _| {
        let admin_witness = authority.sign_in(admin_cap);
        package_admin.restrict_to_additive(&admin_witness);
        let _ = events::collect_one<events::UpgradePolicyRestricted>(0);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |package_admin, _, authority, _, admin_cap, _, _, _, _, _, _, _| {
        let admin_witness = authority.sign_in(admin_cap);
        package_admin.restrict_to_additive(&admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 57)]
fun policy_restriction_rejects_looser_policy() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |package_admin, _, authority, _, admin_cap, _, _, _, _, _, _, _| {
        let admin_witness = authority.sign_in(admin_cap);
        package_admin.restrict_to_dependency_only(&admin_witness);
        let _ = events::collect_one<events::UpgradePolicyRestricted>(0);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |package_admin, _, authority, _, admin_cap, _, _, _, _, _, _, _| {
        let admin_witness = authority.sign_in(admin_cap);
        package_admin.restrict_to_additive(&admin_witness);
    });

    fixture.end();
}

#[test]
fun governance_cutover_permanently_disables_admin_authorization() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |package_admin, _, _, _, _, _, _, _, _, _, _, _| {
        package_admin.disable_admin_authorization();
        let _ = events::collect_one<events::PackageAdminAuthorizationDisabled>(0);

        assert!(!package_admin.admin_authorization_enabled_for_testing());
        assert!(event::events_by_type<events::PackageAdminAuthorizationDisabled>().is_empty());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 55)]
fun governance_cutover_disables_original_admin_upgrade_path() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |package_admin, _, _, _, _, _, _, _, _, _, _, _| {
        package_admin.disable_admin_authorization();
        let _ = events::collect_one<events::PackageAdminAuthorizationDisabled>(0);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |package_admin, _, authority, _, admin_cap, _, _, _, _, _, _, _| {
        let admin_witness = authority.sign_in(admin_cap);
        let ticket = package_admin.authorize_upgrade(&admin_witness, package_digest());
        let receipt = package::test_upgrade(ticket);

        package_admin.commit_upgrade(receipt);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 55)]
fun governance_cutover_rejects_before_digest_validation() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |package_admin, _, _, _, _, _, _, _, _, _, _, _| {
        package_admin.disable_admin_authorization();
        let _ = events::collect_one<events::PackageAdminAuthorizationDisabled>(0);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |package_admin, _, authority, _, admin_cap, _, _, _, _, _, _, _| {
        let admin_witness = authority.sign_in(admin_cap);
        let ticket = package_admin.authorize_upgrade(&admin_witness, x"1122");
        let receipt = package::test_upgrade(ticket);

        package_admin.commit_upgrade(receipt);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 55)]
fun governance_cutover_disables_original_admin_policy_path() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |package_admin, _, authority, _, admin_cap, _, _, _, _, _, _, _| {
        let admin_witness = authority.sign_in(admin_cap);
        package_admin.restrict_to_additive(&admin_witness);
        let _ = events::collect_one<events::UpgradePolicyRestricted>(0);
    });

    fixture.next_tx!(PUBLISHER, |package_admin, _, _, _, _, _, _, _, _, _, _, _| {
        package_admin.disable_admin_authorization();
        let _ = events::collect_one<events::PackageAdminAuthorizationDisabled>(0);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |package_admin, _, authority, _, admin_cap, _, _, _, _, _, _, _| {
        let admin_witness = authority.sign_in(admin_cap);
        package_admin.restrict_to_additive(&admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 58)]
fun governance_cutover_rejects_repetition() {
    let mut fixture = start();

    fixture.next_tx!(PUBLISHER, |package_admin, _, _, _, _, _, _, _, _, _, _, _| {
        package_admin.disable_admin_authorization();
        let _ = events::collect_one<events::PackageAdminAuthorizationDisabled>(0);
    });

    fixture.next_tx!(PUBLISHER, |package_admin, _, _, _, _, _, _, _, _, _, _, _| {
        package_admin.disable_admin_authorization();
    });

    fixture.end();
}

// === Private Functions ===

macro fun next_tx(
    $fixture: &mut Fixture,
    $sender: address,
    $fn: |
        &mut package_admin::PackageAdmin,
        &mut package_admin::PackageAdmin,
        &mut acl::ProtocolAuthority,
        &mut acl::SuperAdminCap,
        &mut acl::AdminCap,
        &mut Publisher,
        &mut Publisher,
        &mut UpgradeCap,
        &mut UpgradeCap,
        &mut events::PackageAdminCreated,
        &mut package_admin::PackageAdmin,
        &mut Scenario,
    |,
) {
    let fixture = $fixture;

    let mut scenario = fixture.scenario.extract();
    let mut package_admin = fixture.package_admin.extract();
    let mut other_package_admin = fixture.other_package_admin.extract();
    let mut authority = fixture.authority.extract();
    let mut super_admin_cap = fixture.super_admin_cap.extract();
    let mut admin_cap = fixture.admin_cap.extract();
    let mut valid_publisher = fixture.valid_publisher.extract();
    let mut foreign_publisher = fixture.foreign_publisher.extract();
    let mut valid_upgrade_cap = fixture.valid_upgrade_cap.extract();
    let mut foreign_upgrade_cap = fixture.foreign_upgrade_cap.extract();
    let mut package_admin_created = fixture.package_admin_created.extract();
    let mut wrapped_package_admin = fixture.wrapped_package_admin.extract();

    scenario.next_tx($sender);

    $fn(
        &mut package_admin,
        &mut other_package_admin,
        &mut authority,
        &mut super_admin_cap,
        &mut admin_cap,
        &mut valid_publisher,
        &mut foreign_publisher,
        &mut valid_upgrade_cap,
        &mut foreign_upgrade_cap,
        &mut package_admin_created,
        &mut wrapped_package_admin,
        &mut scenario,
    );

    fixture.scenario.fill(scenario);
    fixture.package_admin.fill(package_admin);
    fixture.other_package_admin.fill(other_package_admin);
    fixture.authority.fill(authority);
    fixture.super_admin_cap.fill(super_admin_cap);
    fixture.admin_cap.fill(admin_cap);
    fixture.valid_publisher.fill(valid_publisher);
    fixture.foreign_publisher.fill(foreign_publisher);
    fixture.valid_upgrade_cap.fill(valid_upgrade_cap);
    fixture.foreign_upgrade_cap.fill(foreign_upgrade_cap);
    fixture.package_admin_created.fill(package_admin_created);
    fixture.wrapped_package_admin.fill(wrapped_package_admin);
}

macro fun take_invalid_cap_inputs_next_tx(
    $fixture: &mut Fixture,
    $sender: address,
    $fn: |
        Publisher,
        UpgradeCap,
        &mut package_admin::PackageAdmin,
        &mut package_admin::PackageAdmin,
        &mut acl::ProtocolAuthority,
        &mut acl::SuperAdminCap,
        &mut acl::AdminCap,
        &mut Publisher,
        &mut UpgradeCap,
        &mut package_admin::PackageAdmin,
        &mut Scenario,
    |,
) {
    let fixture = $fixture;

    let mut scenario = fixture.scenario.extract();
    let valid_publisher = fixture.valid_publisher.extract();
    let foreign_upgrade_cap = fixture.foreign_upgrade_cap.extract();
    let mut package_admin = fixture.package_admin.extract();
    let mut other_package_admin = fixture.other_package_admin.extract();
    let mut authority = fixture.authority.extract();
    let mut super_admin_cap = fixture.super_admin_cap.extract();
    let mut admin_cap = fixture.admin_cap.extract();
    let mut foreign_publisher = fixture.foreign_publisher.extract();
    let mut valid_upgrade_cap = fixture.valid_upgrade_cap.extract();
    let package_admin_created = fixture.package_admin_created.extract();
    let mut wrapped_package_admin = fixture.wrapped_package_admin.extract();

    scenario.next_tx($sender);

    $fn(
        valid_publisher,
        foreign_upgrade_cap,
        &mut package_admin,
        &mut other_package_admin,
        &mut authority,
        &mut super_admin_cap,
        &mut admin_cap,
        &mut foreign_publisher,
        &mut valid_upgrade_cap,
        &mut wrapped_package_admin,
        &mut scenario,
    );

    fixture.scenario.fill(scenario);
    fixture.package_admin.fill(package_admin);
    fixture.other_package_admin.fill(other_package_admin);
    fixture.authority.fill(authority);
    fixture.super_admin_cap.fill(super_admin_cap);
    fixture.admin_cap.fill(admin_cap);
    fixture.foreign_publisher.fill(foreign_publisher);
    fixture.valid_upgrade_cap.fill(valid_upgrade_cap);
    fixture.package_admin_created.fill(package_admin_created);
    fixture.wrapped_package_admin.fill(wrapped_package_admin);
}

macro fun take_invalid_publisher_inputs_next_tx(
    $fixture: &mut Fixture,
    $sender: address,
    $fn: |
        Publisher,
        UpgradeCap,
        &mut package_admin::PackageAdmin,
        &mut package_admin::PackageAdmin,
        &mut acl::ProtocolAuthority,
        &mut acl::SuperAdminCap,
        &mut acl::AdminCap,
        &mut Publisher,
        &mut UpgradeCap,
        &mut package_admin::PackageAdmin,
        &mut Scenario,
    |,
) {
    let fixture = $fixture;

    let mut scenario = fixture.scenario.extract();
    let foreign_publisher = fixture.foreign_publisher.extract();
    let foreign_upgrade_cap = fixture.foreign_upgrade_cap.extract();
    let mut package_admin = fixture.package_admin.extract();
    let mut other_package_admin = fixture.other_package_admin.extract();
    let mut authority = fixture.authority.extract();
    let mut super_admin_cap = fixture.super_admin_cap.extract();
    let mut admin_cap = fixture.admin_cap.extract();
    let mut valid_publisher = fixture.valid_publisher.extract();
    let mut valid_upgrade_cap = fixture.valid_upgrade_cap.extract();
    let package_admin_created = fixture.package_admin_created.extract();
    let mut wrapped_package_admin = fixture.wrapped_package_admin.extract();

    scenario.next_tx($sender);

    $fn(
        foreign_publisher,
        foreign_upgrade_cap,
        &mut package_admin,
        &mut other_package_admin,
        &mut authority,
        &mut super_admin_cap,
        &mut admin_cap,
        &mut valid_publisher,
        &mut valid_upgrade_cap,
        &mut wrapped_package_admin,
        &mut scenario,
    );

    fixture.scenario.fill(scenario);
    fixture.package_admin.fill(package_admin);
    fixture.other_package_admin.fill(other_package_admin);
    fixture.authority.fill(authority);
    fixture.super_admin_cap.fill(super_admin_cap);
    fixture.admin_cap.fill(admin_cap);
    fixture.valid_publisher.fill(valid_publisher);
    fixture.valid_upgrade_cap.fill(valid_upgrade_cap);
    fixture.package_admin_created.fill(package_admin_created);
    fixture.wrapped_package_admin.fill(wrapped_package_admin);
}

fun start(): Fixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority) = acl::new_protocol_for_testing(PUBLISHER, scenario.ctx());
    authority.grant_admin(&super_admin_cap, PROTOCOL_ADMIN, scenario.ctx());

    blast::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publisher = scenario.take_from_sender<Publisher>();
    package_admin::wrap(
        publisher,
        package::test_publish(@0x0.to_id(), scenario.ctx()),
        scenario.ctx(),
    );
    let package_admin_created = events::collect_one<events::PackageAdminCreated>(0);

    let package_admin = package_admin::new_for_testing(PACKAGE_ID.to_id(), scenario.ctx());
    let other_package_admin =
        package_admin::new_for_testing(OTHER_PACKAGE_ID.to_id(), scenario.ctx());
    let valid_publisher = blast::publisher_for_testing(scenario.ctx());
    let foreign_publisher = package::test_claim(FOREIGN_PUBLISHER(), scenario.ctx());
    let valid_upgrade_cap = package::test_publish(@0x0.to_id(), scenario.ctx());
    let foreign_upgrade_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let wrapped_package_admin = scenario.take_shared<package_admin::PackageAdmin>();

    Fixture {
        scenario: option::some(scenario),
        super_admin_cap: option::some(super_admin_cap),
        authority: option::some(authority),
        admin_cap: option::some(admin_cap),
        package_admin: option::some(package_admin),
        other_package_admin: option::some(other_package_admin),
        valid_publisher: option::some(valid_publisher),
        foreign_publisher: option::some(foreign_publisher),
        valid_upgrade_cap: option::some(valid_upgrade_cap),
        foreign_upgrade_cap: option::some(foreign_upgrade_cap),
        package_admin_created: option::some(package_admin_created),
        wrapped_package_admin: option::some(wrapped_package_admin),
    }
}

fun end(self: Fixture) {
    destroy(self);
}

fun package_digest(): vector<u8> {
    x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211"
}
