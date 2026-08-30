#[test_only]
module blast_sui::package_admin_tests;

use blast_sui::{acl, blast, errors, events, package_admin, package_version};
use std::unit_test::{assert_eq, destroy};
use sui::{package, test_scenario::{Self, Scenario}};

use fun custody_end as CustodyFixture.end;
use fun custody_next_tx as CustodyFixture.next_tx;
use fun upgrade_ctx as UpgradeFixture.ctx;
use fun upgrade_end as UpgradeFixture.end;
use fun upgrade_next_tx as UpgradeFixture.next_tx;
use fun wrap_ctx as WrapFixture.ctx;
use fun wrap_end as WrapFixture.end;
use fun wrap_next_tx as WrapFixture.next_tx;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const SUPER_ADMIN: address = @0xAD;
const PACKAGE_ID: address = @0xB1A57;
const OTHER_PACKAGE_ID: address = @0xBAD;

// === Test-Only Types ===

/// Witness from a non-canonical module used to forge a wrong-provenance Publisher.
public struct FOREIGN_PUBLISHER() has drop;

/// Bare transaction runner for capability-provenance rejections; needs no ACL.
public struct WrapFixture {
    scenario: Scenario,
}

/// Production wrap output: the shared custody object and its creation fact.
public struct CustodyFixture {
    scenario: Scenario,
    package_admin: package_admin::PackageAdmin,
    publisher_id: ID,
    upgrade_cap_id: ID,
    created: events::PackageAdminCreated,
}

/// Upgrade and version operations authorized by the singleton super-admin.
public struct UpgradeFixture {
    scenario: Scenario,
    super_admin_cap: acl::SuperAdminCap,
    authority: acl::ProtocolAuthority,
    package_admin: package_admin::PackageAdmin,
    package_version: package_version::PackageVersion,
    version_created: events::PackageVersionCreated,
}

// === Tests ===

#[test]
fun package_version_initialization_and_activation_emit_wrapped_facts() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(SUPER_ADMIN, |f| {
        let (package_version_id, emitted_version) =
            f.version_created.package_version_created_fields();
        assert_eq!(package_version_id, object::id(&f.package_version));
        assert_eq!(emitted_version, 1);
        assert_eq!(emitted_version, f.package_version.value_for_testing());

        f.package_version.set_for_testing(0);
        package_admin::activate_package_version(
            &mut f.package_version,
            &f.authority,
            &f.super_admin_cap,
        );

        let advanced = events::collect_one<events::PackageVersionAdvanced>(0);
        let (previous_version, new_version) = advanced.package_version_advanced_fields();
        assert_eq!(previous_version, 0);
        assert_eq!(new_version, 1);
        assert_eq!(new_version, f.package_version.value_for_testing());
    });

    fixture.end();
}

#[test]
fun wrap_validates_provenance_and_shares_custody_without_returning_authority() {
    let mut fixture = start_custody();

    fixture.next_tx!(PUBLISHER, |f| {
        let (
            package_admin_id,
            emitted_publisher_id,
            emitted_upgrade_cap_id,
            package_id,
            package_version,
            policy,
        ) = f.created.package_admin_created_fields();
        assert_eq!(package_admin_id, object::id(&f.package_admin));
        assert_eq!(emitted_publisher_id, f.publisher_id);
        assert_eq!(emitted_publisher_id, f.package_admin.publisher_id_for_testing());
        assert_eq!(emitted_upgrade_cap_id, f.upgrade_cap_id);
        assert_eq!(emitted_upgrade_cap_id, f.package_admin.upgrade_cap_id_for_testing());
        assert_eq!(package_id, @0x0.to_id());
        assert_eq!(package_id, f.package_admin.package_id_for_testing());
        assert_eq!(package_version, 1);
        assert_eq!(package_version, f.package_admin.version_for_testing());
        assert_eq!(policy, package::compatible_policy());
        assert_eq!(policy, f.package_admin.policy_for_testing());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUpgradeCap, location = blast_sui::package_admin)]
fun wrap_rejects_an_upgrade_cap_for_another_package() {
    let mut fixture = start_wrap();

    fixture.next_tx!(PUBLISHER, |f| {
        let publisher = blast::publisher_for_testing(f.ctx!());
        let upgrade_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), f.ctx!());

        package_admin::wrap(publisher, upgrade_cap, f.ctx!());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidPackagePublisher,
    location = blast_sui::package_admin,
)]
fun wrap_rejects_a_publisher_from_another_module() {
    let mut fixture = start_wrap();

    fixture.next_tx!(PUBLISHER, |f| {
        let publisher = package::test_claim(FOREIGN_PUBLISHER(), f.ctx!());
        let upgrade_cap = package::test_publish(@0x0.to_id(), f.ctx!());

        package_admin::wrap(publisher, upgrade_cap, f.ctx!());
    });

    fixture.end();
}

#[test]
fun super_admin_authorization_commit_and_restriction_emit_replay_complete_facts() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(SUPER_ADMIN, |f| {
        let ticket = f
            .package_admin
            .authorize_upgrade(
                &f.package_version,
                &f.authority,
                &f.super_admin_cap,
                package_digest(),
            );
        let authorized = events::collect_one<events::UpgradeAuthorized>(0);
        let (package_id, package_version, policy, digest) =
            authorized.upgrade_authorized_fields();
        assert_eq!(package_id, PACKAGE_ID.to_id());
        assert_eq!(package_version, 1);
        assert_eq!(policy, package::compatible_policy());
        assert_eq!(digest, package_digest());

        let receipt = package::test_upgrade(ticket);
        let upgraded_package_id = receipt.package();
        f.package_admin.commit_upgrade(&f.package_version, receipt);
        let committed = events::collect_one<events::UpgradeCommitted>(0);
        let (new_package_id, previous_version, new_version) =
            committed.upgrade_committed_fields();
        assert_eq!(new_package_id, upgraded_package_id);
        assert_eq!(new_package_id, f.package_admin.package_id_for_testing());
        assert_eq!(previous_version, 1);
        assert_eq!(new_version, 2);

        f.package_admin.restrict_to_additive(
            &f.package_version,
            &f.authority,
            &f.super_admin_cap,
        );
        let restricted = events::collect_one<events::UpgradePolicyRestricted>(0);
        let (previous_policy, new_policy) = restricted.upgrade_policy_restricted_fields();
        assert_eq!(previous_policy, package::compatible_policy());
        assert_eq!(new_policy, package::additive_policy());
        assert_eq!(new_policy, f.package_admin.policy_for_testing());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EUpgradePolicyNotMoreRestrictive,
    location = blast_sui::package_admin,
)]
fun equal_policy_restriction_is_rejected_before_mutation() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(SUPER_ADMIN, |f| {
        f.package_admin.restrict_to_additive(
            &f.package_version,
            &f.authority,
            &f.super_admin_cap,
        );
        f.package_admin.restrict_to_additive(
            &f.package_version,
            &f.authority,
            &f.super_admin_cap,
        );
    });

    fixture.end();
}


#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionOverflow,
    location = blast_sui::package_version,
)]
fun activation_rejects_a_package_generation_overflow() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(SUPER_ADMIN, |f| {
        f.package_version.set_for_testing(std::u64::max_value!());
        package_admin::activate_package_version(
            &mut f.package_version,
            &f.authority,
            &f.super_admin_cap,
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionMismatch,
    location = blast_sui::package_version,
)]
fun activation_rejects_skipping_a_package_generation() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(SUPER_ADMIN, |f| {
        package_admin::activate_package_version(
            &mut f.package_version,
            &f.authority,
            &f.super_admin_cap,
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidSuperAdminCap, location = blast_sui::acl)]
fun foreign_super_admin_cap_cannot_authorize_an_upgrade() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(SUPER_ADMIN, |f| {
        let (foreign_cap, foreign_authority) =
            acl::new_protocol_for_testing(OTHER_PACKAGE_ID, f.ctx!());
        let ticket = f.package_admin.authorize_upgrade(
                &f.package_version,
                &f.authority,
                &foreign_cap,
                package_digest(),
        );
        let receipt = package::test_upgrade(ticket);
        f.package_admin.commit_upgrade(&f.package_version, receipt);
        destroy(foreign_cap);
        destroy(foreign_authority);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = sui::package::EWrongUpgradeCap, location = sui::package)]
fun commit_rejects_a_receipt_bound_to_another_upgrade_cap() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(SUPER_ADMIN, |f| {
        let mut other_package_admin =
            package_admin::new_for_testing(OTHER_PACKAGE_ID.to_id(), f.ctx!());
        let ticket = other_package_admin.authorize_upgrade(
            &f.package_version,
            &f.authority,
            &f.super_admin_cap,
            package_digest(),
        );
        let receipt = package::test_upgrade(ticket);

        f.package_admin.commit_upgrade(&f.package_version, receipt);

        destroy(other_package_admin);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPackageDigest, location = blast_sui::package_admin)]
fun upgrade_authorization_rejects_non_digest_length() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(SUPER_ADMIN, |f| {
        let ticket = f.package_admin.authorize_upgrade(
            &f.package_version,
            &f.authority,
            &f.super_admin_cap,
            vector[],
        );
        let receipt = package::test_upgrade(ticket);
        f.package_admin.commit_upgrade(&f.package_version, receipt);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionMismatch,
    location = blast_sui::package_version,
)]
fun stale_shared_version_rejects_old_bytecode() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(SUPER_ADMIN, |f| {
        f.package_version.set_for_testing(2);

        let ticket = f.package_admin.authorize_upgrade(
            &f.package_version,
            &f.authority,
            &f.super_admin_cap,
            package_digest(),
        );
        let receipt = package::test_upgrade(ticket);
        f.package_admin.commit_upgrade(&f.package_version, receipt);
    });

    fixture.end();
}

// === Fixture Macros ===

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

// === Fixture Setup ===

fun start_wrap(): WrapFixture {
    WrapFixture { scenario: test_scenario::begin(PUBLISHER) }
}

/// Runs the production claim and wrap flow so the fixture custodies the real shared object.
fun start_custody(): CustodyFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    blast::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publisher = scenario.take_from_sender<package::Publisher>();
    let upgrade_cap = package::test_publish(@0x0.to_id(), scenario.ctx());
    let publisher_id = object::id(&publisher);
    let upgrade_cap_id = object::id(&upgrade_cap);
    package_admin::wrap(publisher, upgrade_cap, scenario.ctx());
    let created = events::collect_one<events::PackageAdminCreated>(0);

    scenario.next_tx(PUBLISHER);
    let package_admin = scenario.take_shared<package_admin::PackageAdmin>();

    CustodyFixture { scenario, package_admin, publisher_id, upgrade_cap_id, created }
}

/// Initializes the shared package version, test custody, and singleton authority.
fun start_upgrade(): UpgradeFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    package_version::init_for_testing(scenario.ctx());
    let version_created = events::collect_one<events::PackageVersionCreated>(0);
    let package_admin = package_admin::new_for_testing(PACKAGE_ID.to_id(), scenario.ctx());
    let (super_admin_cap, authority) =
        acl::new_protocol_for_testing(PUBLISHER, scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let package_version = scenario.take_shared<package_version::PackageVersion>();

    UpgradeFixture {
        scenario,
        super_admin_cap,
        authority,
        package_admin,
        package_version,
        version_created,
    }
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

// === Helpers ===

fun package_digest(): vector<u8> {
    x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
}
