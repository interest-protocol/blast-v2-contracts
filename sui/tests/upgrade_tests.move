#[test_only]
module blast_fun::upgrade_tests;

use blast_fun::{acl, events, upgrade};
use std::unit_test::{assert_eq, destroy};
use sui::{event, package, test_scenario::{Self, Scenario}};

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;
const PACKAGE_ID: address = @0xB1A57;
const OTHER_PACKAGE_ID: address = @0xBAD;

// === Test-Only Types ===

public struct Fixture {
    scenario: Scenario,
    super_admin_cap: acl::SuperAdminCap,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
    manager: upgrade::UpgradeManager,
}

// === Tests ===

#[test]
fun wrap_accepts_blast_cap_and_shares_complete_custody_fact() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    // Test modules are compiled at 0x0, which is BLAST's original package ID here.
    let cap = package::test_publish(@0x0.to_id(), scenario.ctx());
    let upgrade_cap_id = object::id(&cap);

    upgrade::wrap(cap, scenario.ctx());

    let created = events::collect_one<events::UpgradeManagerCreated>(0);
    let (
        emitted_manager_id,
        emitted_upgrade_cap_id,
        emitted_package_id,
        emitted_package_version,
        emitted_policy,
        emitted_admin_authorization_enabled,
    ) = created.upgrade_manager_created_fields();

    scenario.next_tx(PUBLISHER);
    let manager = scenario.take_shared<upgrade::UpgradeManager>();

    assert_eq!(emitted_manager_id, object::id(&manager));
    assert_eq!(emitted_upgrade_cap_id, upgrade_cap_id);
    assert_eq!(emitted_upgrade_cap_id, manager.upgrade_cap_id_for_testing());
    assert_eq!(emitted_package_id, @0x0.to_id());
    assert_eq!(emitted_package_id, manager.package_id_for_testing());
    assert_eq!(emitted_package_version, 1);
    assert_eq!(emitted_package_version, manager.version_for_testing());
    assert_eq!(emitted_policy, package::compatible_policy());
    assert_eq!(emitted_policy, manager.policy_for_testing());
    assert!(emitted_admin_authorization_enabled);
    assert!(manager.admin_authorization_enabled_for_testing());
    assert!(event::events_by_type<events::UpgradeManagerCreated>().is_empty());

    destroy(manager);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 53)]
fun wrap_rejects_upgrade_cap_for_another_package() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), scenario.ctx());

    upgrade::wrap(cap, scenario.ctx());

    destroy(scenario);
}

#[test]
fun active_admin_authorizes_exact_digest_and_commits_matching_receipt() {
    let mut fixture = start(true);
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    let digest = package_digest();

    let ticket = fixture.manager.authorize_upgrade(&admin_witness, digest);
    let receipt = package::test_upgrade(ticket);
    let new_package_id = receipt.package();
    fixture.manager.commit_upgrade(receipt);

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
    let (
        emitted_new_package_id,
        previous_version,
        new_version,
    ) = committed.upgrade_committed_fields();
    assert_eq!(emitted_new_package_id, new_package_id);
    assert_eq!(previous_version, 1);
    assert_eq!(new_version, 2);
    assert_eq!(fixture.manager.package_id_for_testing(), new_package_id);
    assert_eq!(fixture.manager.version_for_testing(), 2);
    assert!(event::events_by_type<events::UpgradeAuthorized>().is_empty());
    assert!(event::events_by_type<events::UpgradeCommitted>().is_empty());

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 54)]
fun authorization_rejects_non_digest_length() {
    let mut fixture = start(true);
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    let ticket = fixture
        .manager
        .authorize_upgrade(
            &admin_witness,
            x"11223344556677889900aabbccddeeffffeeddccbbaa009988776655443322",
        );
    let receipt = package::test_upgrade(ticket);
    fixture.manager.commit_upgrade(receipt);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 55)]
fun durable_flag_disables_original_admin_authorization_path() {
    let mut fixture = start(false);
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    let ticket = fixture.manager.authorize_upgrade(&admin_witness, package_digest());
    let receipt = package::test_upgrade(ticket);
    fixture.manager.commit_upgrade(receipt);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 0)]
fun revoked_admin_cannot_reach_upgrade_authorization() {
    let Fixture {
        scenario,
        super_admin_cap,
        mut authority,
        admin_cap,
        mut manager,
    } = start(true);
    authority.revoke_admin(&super_admin_cap, object::id(&admin_cap));

    let admin_witness = authority.sign_in(&admin_cap);
    let ticket = manager.authorize_upgrade(&admin_witness, package_digest());
    let receipt = package::test_upgrade(ticket);
    manager.commit_upgrade(receipt);

    destroy(Fixture { scenario, super_admin_cap, authority, admin_cap, manager });
}

#[test]
#[expected_failure(abort_code = 4, location = sui::package)]
fun commit_rejects_receipt_bound_to_another_upgrade_cap() {
    let mut fixture = start(true);
    let mut other_manager = upgrade::new_for_testing(
        OTHER_PACKAGE_ID.to_id(),
        true,
        fixture.scenario.ctx(),
    );
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    let ticket = other_manager.authorize_upgrade(&admin_witness, package_digest());
    let receipt = package::test_upgrade(ticket);

    fixture.manager.commit_upgrade(receipt);

    destroy(other_manager);
    fixture.end();
}

// === Private Functions ===

fun start(admin_authorization_enabled: bool): Fixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority) = acl::new_protocol_for_testing(PUBLISHER, scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );
    let manager = upgrade::new_for_testing(
        PACKAGE_ID.to_id(),
        admin_authorization_enabled,
        scenario.ctx(),
    );

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();

    Fixture { scenario, super_admin_cap, authority, admin_cap, manager }
}

fun end(self: Fixture) {
    destroy(self);
}

fun package_digest(): vector<u8> {
    x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211"
}
