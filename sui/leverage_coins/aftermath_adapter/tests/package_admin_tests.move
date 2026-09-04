#[test_only]
/// Tests for adapter-owned Publisher and UpgradeCap custody.
module blast_leverage_aftermath::package_admin_tests;

use blast_leverage_aftermath::{aftermath, events, package_admin, protocol::{Self, Protocol}};
use blast_leverage_series_one::acl::{Self, AdminCap, ProtocolAuthority, SuperAdminCap};
use std::unit_test::{assert_eq, destroy};
use sui::{package, test_scenario::{Self, Scenario}};

// === Constants ===

const ROOT: address = @0xA11CE;
const PACKAGE_ADMIN: address = @0xAD;
const PACKAGE_ID: address = @0xB1A57;
const OTHER_PACKAGE_ID: address = @0xBAD;

// === Test-Only Types ===

public struct ForeignPublisher() has drop;

public struct CustodyFixture {
    scenario: Scenario,
    package_admin: package_admin::PackageAdmin,
}

public struct Fixture {
    scenario: Scenario,
    protocol: Protocol,
    authority: ProtocolAuthority,
    super_admin_cap: SuperAdminCap,
    admin_cap: AdminCap,
    package_admin: package_admin::PackageAdmin,
}

// === Tests ===

#[test]
fun canonical_capabilities_enter_adapter_custody() {
    let mut scenario = test_scenario::begin(ROOT);
    let publisher = aftermath::publisher_for_testing(scenario.ctx());
    let upgrade_cap = package::test_publish(@0x0.to_id(), scenario.ctx());
    let package_admin = package_admin::new(publisher, upgrade_cap, scenario.ctx());

    assert_eq!(package_admin.package_id_for_testing(), @0x0.to_id());
    assert_eq!(package_admin.version_for_testing(), 1);
    assert_eq!(package_admin.policy_for_testing(), package::compatible_policy());

    destroy(CustodyFixture { scenario, package_admin });
}

#[test]
fun package_admin_role_authorizes_and_commits_an_upgrade() {
    let mut fixture = start(16);
    let digest = package_digest();
    let ticket = fixture.authorize_upgrade(digest);
    let receipt = ticket.test_upgrade();
    let expected_package_id = receipt.package();

    fixture.commit_upgrade(receipt);

    assert_eq!(fixture.package_admin.version_for_testing(), 2);
    assert_eq!(fixture.package_admin.package_id_for_testing(), expected_package_id);
    let authorized = events::collect_one<events::UpgradeAuthorized>(0);
    let (package_id, version, policy, emitted_digest) =
        authorized.upgrade_authorized_fields();
    assert_eq!(package_id, PACKAGE_ID.to_id());
    assert_eq!(version, 1);
    assert_eq!(policy, package::compatible_policy());
    assert_eq!(emitted_digest, digest);
    let committed = events::collect_one<events::UpgradeCommitted>(0);
    let (new_package_id, previous_version, new_version) =
        committed.upgrade_committed_fields();
    assert_eq!(new_package_id, expected_package_id);
    assert_eq!(previous_version, 1);
    assert_eq!(new_version, 2);

    destroy(fixture);
}

#[test]
fun global_series_package_admin_can_irreversibly_restrict_the_adapter() {
    let mut fixture = start(16);

    fixture.restrict_to_additive();
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
    abort_code = 4,
    location = blast_leverage_aftermath::package_admin,
)]
fun foreign_publisher_is_rejected_before_upgrade_cap_origin() {
    let mut scenario = test_scenario::begin(ROOT);
    let publisher = package::test_claim(ForeignPublisher(), scenario.ctx());
    let upgrade_cap = package::test_publish(
        OTHER_PACKAGE_ID.to_id(),
        scenario.ctx(),
    );

    let package_admin = package_admin::new(publisher, upgrade_cap, scenario.ctx());

    destroy(CustodyFixture { scenario, package_admin });
}

#[test]
#[expected_failure(
    abort_code = 6,
    location = blast_leverage_aftermath::package_admin,
)]
fun upgrade_digest_must_be_exactly_32_bytes() {
    let mut fixture = start(16);

    let ticket = fixture.authorize_upgrade(vector[]);
    let receipt = ticket.test_upgrade();
    fixture.commit_upgrade(receipt);

    destroy(fixture);
}

// === Fixture Setup ===

fun start(roles: u8): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let protocol = protocol::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        roles,
        PACKAGE_ADMIN,
        scenario.ctx(),
    );
    let package_admin =
        package_admin::new_for_testing(PACKAGE_ID.to_id(), scenario.ctx());

    scenario.next_tx(PACKAGE_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap>();

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

fun commit_upgrade(
    self: &mut Fixture,
    receipt: sui::package::UpgradeReceipt,
) {
    let Fixture { protocol, package_admin, .. } = self;
    package_admin.commit_upgrade(protocol, receipt);
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
