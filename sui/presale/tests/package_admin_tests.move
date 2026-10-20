// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::package_admin_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const PROTOCOL_ADMIN: address = @0xAD;

const OTHER_PACKAGE_ID: address = @0xBAD;

/// This package's canonical original address under test compilation.
const PACKAGE_ID: address = @blast_presale;

// === Test-Only Types ===

/// Bare transaction runner for capability-provenance rejections; needs no ACL.
public struct WrapFixture {
    scenario: Scenario,
}

/// Production wrap output: the shared custody object and its creation fact.
public struct CustodyFixture {
    scenario: Scenario,
    package_admin: package_admin::PackageAdmin,
    package_version: marker::PackageVersion,
    runtime: fee_policy::FeePolicy,
    created: blast_admin_events::UpgradeCustodyCreated<BLAST_PRESALE_PACKAGE>,
}

/// Upgrade-admin-authorized upgrade and policy operations.
public struct UpgradeFixture {
    scenario: Scenario,
    package_admin: package_admin::PackageAdmin,
    package_version: marker::PackageVersion,
}

// === Tests ===

#[test]
fun publication_cannot_supply_the_version_required_to_create_presales() {
    let fixture = start_unwrapped();

    assert!(!fixture.has_shared_version());

    fixture.end();
}

#[test]
fun wrapping_enables_guarded_mutations_and_consumes_bootstrap() {
    let mut fixture = start_custody();

    fixture.next_tx!(PUBLISHER, |f| {
        f
            .runtime
            .set_destination(&f.package_version, &blast_acl::witness_for_testing(), PROTOCOL_ADMIN);

        assert_eq!(f.runtime.destination(), PROTOCOL_ADMIN);
        assert_eq!(f.package_version.version_for_testing(), 1);
        assert!(!f.has_bootstrap());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = sui::test_scenario::EEmptyInventory, location = sui::test_scenario)]
fun consumed_bootstrap_cannot_be_taken_for_another_wrap() {
    let mut fixture = start_unwrapped();

    fixture.next_tx!(PUBLISHER, |f| {
        let bootstrap = f.take_bootstrap();
        let upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), f.ctx!());

        package_admin::wrap(bootstrap, upgrade_cap, f.ctx!());
    });
    fixture.next_tx!(PUBLISHER, |f| {
        destroy(f.take_bootstrap());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = sui::test_scenario::EEmptyInventory, location = sui::test_scenario)]
fun another_sender_cannot_take_the_publication_bootstrap() {
    let mut fixture = start_unwrapped();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let bootstrap = f.take_bootstrap();
        destroy(bootstrap);
    });

    fixture.end();
}

#[test]
fun wrap_accepts_blast_capabilities_and_shares_complete_custody_fact() {
    let mut fixture = start_custody();

    fixture.next_tx!(PUBLISHER, |f| {
        let (
            emitted_custodian_id,
            emitted_publisher_id,
            emitted_upgrade_cap_id,
            emitted_package_id,
            emitted_native_version,
            emitted_policy,
        ) = f.created.upgrade_custody_created_fields();

        assert_eq!(emitted_custodian_id, object::id(&f.package_admin));
        assert_eq!(emitted_publisher_id, f.package_admin.publisher_id_for_testing());
        assert_eq!(emitted_upgrade_cap_id, f.package_admin.upgrade_cap_id_for_testing());
        assert_eq!(emitted_package_id, PACKAGE_ID.to_id());
        assert_eq!(emitted_package_id, f.package_admin.package_id_for_testing());
        assert_eq!(emitted_native_version, 1);
        assert_eq!(emitted_native_version, f.package_admin.version_for_testing());
        assert_eq!(emitted_policy, package::compatible_policy());
        assert_eq!(emitted_policy, f.package_admin.policy_for_testing());
        assert!(f.package_admin.has_upgrade_cap_for_testing());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidUpgradeCap,
    location = blast_admin::upgrade_custody,
)]
fun wrap_rejects_upgrade_cap_for_another_package() {
    let mut fixture = start_unwrapped();

    fixture.next_tx!(PUBLISHER, |f| {
        let bootstrap = f.take_bootstrap();
        let foreign_upgrade_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), f.ctx!());

        package_admin::wrap(bootstrap, foreign_upgrade_cap, f.ctx!());
    });

    fixture.end();
}

#[test]
/// The container advances to exactly the generation this bytecode hands over to.
fun the_version_container_advances_to_the_next_compiled_generation() {
    let mut ctx = tx_context::dummy();
    let mut package_version = marker::new_for_testing(&mut ctx);

    assert_eq!(package_version.version_for_testing(), 1);
    package_version.advance_for_testing();

    assert_eq!(package_version.version_for_testing(), 2);
    destroy(package_version);
    destroy(ctx);
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun the_version_container_rejects_advancing_from_a_skipped_generation() {
    let mut ctx = tx_context::dummy();
    let mut package_version = marker::new_for_testing(&mut ctx);
    package_version.set_for_testing(5);

    package_version.advance_for_testing();

    destroy(package_version);
    destroy(ctx);
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationalVersionOverflow,
    location = blast_admin::operational_version,
)]
fun the_version_container_rejects_generation_overflow() {
    let mut ctx = tx_context::dummy();
    let mut package_version = marker::new_for_testing(&mut ctx);
    package_version.set_for_testing(std::u64::max_value!());

    package_version.advance_for_testing();

    destroy(package_version);
    destroy(ctx);
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// The upgrade finalizer proves the shared generation is exactly one behind before committing.
fun commit_rejects_a_skipped_generation_before_the_native_cap_is_touched() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = upgrade_admin();
        let (receipt, foreign_cap) = f.foreign_receipt();
        f.package_version.set_for_testing(5);

        f.package_admin.commit_upgrade_and_advance(&mut f.package_version, &admin_witness, receipt);

        destroy(foreign_cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidPackageDigest,
    location = blast_admin::upgrade_custody,
)]
fun authorization_rejects_non_digest_length() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = upgrade_admin();

        let ticket = f
            .package_admin
            .authorize_upgrade(
                &f.package_version,
                &admin_witness,
                x"11223344556677889900aabbccddeeffffeeddccbbaa009988776655443322",
            );

        destroy(ticket);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_generation_rejects_package_admin_before_digest_validation() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = upgrade_admin();
        f.package_version.set_for_testing(2);

        let ticket = f
            .package_admin
            .authorize_upgrade(
                &f.package_version,
                &admin_witness,
                vector[],
            );

        destroy(ticket);
    });

    fixture.end();
}

#[test]
fun compatible_upgrade_commits_and_advances_together() {
    let mut owned = start_custody();
    let fixture = &mut owned;
    let ticket = fixture
        .package_admin
        .authorize_upgrade(
            &fixture.package_version,
            &upgrade_admin(),
            package_digest(),
        );
    assert_eq!(ticket.ticket_policy(), package::compatible_policy());
    let receipt = ticket.test_upgrade();
    fixture
        .package_admin
        .commit_upgrade_and_advance(
            &mut fixture.package_version,
            &upgrade_admin(),
            receipt,
        );
    assert_eq!(fixture.package_admin.version_for_testing(), 2);
    assert_eq!(fixture.package_version.version_for_testing(), 2);
    assert_eq!(fixture.package_admin.policy_for_testing(), package::compatible_policy());
    destroy(owned);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidUpgradeCap,
    location = blast_admin::upgrade_custody,
)]
fun wrap_rejects_an_already_upgraded_cap() {
    let mut fixture = start_unwrapped();
    let bootstrap = fixture.take_bootstrap();
    let mut cap = package::test_publish(PACKAGE_ID.to_id(), fixture.ctx!());
    let ticket = cap.authorize_upgrade(package::compatible_policy(), package_digest());
    cap.commit(ticket.test_upgrade());
    package_admin::wrap(bootstrap, cap, fixture.scenario.ctx());
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun committed_upgrade_disables_old_bytecode() {
    let mut owned = start_custody();
    let fixture = &mut owned;
    let ticket = fixture
        .package_admin
        .authorize_upgrade(
            &fixture.package_version,
            &upgrade_admin(),
            package_digest(),
        );
    let receipt = ticket.test_upgrade();
    fixture
        .package_admin
        .commit_upgrade_and_advance(
            &mut fixture.package_version,
            &upgrade_admin(),
            receipt,
        );
    fixture
        .runtime
        .set_destination(
            &fixture.package_version,
            &blast_acl::witness_for_testing(),
            PROTOCOL_ADMIN,
        );
    destroy(owned);
}

// === Test Helpers ===

macro fun wrap_next_tx($fixture: &mut WrapFixture, $sender: address, $fn: |&mut WrapFixture|) {
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

fun start_unwrapped(): WrapFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    marker::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);

    WrapFixture { scenario }
}

fun has_shared_version(_: &WrapFixture): bool {
    test_scenario::has_most_recent_shared<marker::PackageVersion>()
}

fun take_bootstrap(self: &WrapFixture): marker::Bootstrap {
    self.scenario.take_from_sender()
}

fun has_bootstrap(self: &CustodyFixture): bool {
    self.scenario.has_most_recent_for_sender<marker::Bootstrap>()
}

/// Runs the production wrap flow so the fixture custodies the real shared object.
fun start_custody(): CustodyFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    marker::init_for_testing(scenario.ctx());
    fee_policy::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let bootstrap = scenario.take_from_sender<marker::Bootstrap>();
    package_admin::wrap(
        bootstrap,
        package::test_publish(PACKAGE_ID.to_id(), scenario.ctx()),
        scenario.ctx(),
    );
    let created = blast_admin_events::collect_one<
        blast_admin_events::UpgradeCustodyCreated<BLAST_PRESALE_PACKAGE>,
    >(0);

    scenario.next_tx(PUBLISHER);
    let package_admin = scenario.take_shared<package_admin::PackageAdmin>();
    let package_version = scenario.take_shared<marker::PackageVersion>();
    let runtime = scenario.take_shared<fee_policy::FeePolicy>();

    CustodyFixture { scenario, package_admin, package_version, runtime, created }
}

fun start(): UpgradeFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = marker::new_for_testing(scenario.ctx());
    let package_admin = package_admin::new_for_testing(scenario.ctx());

    UpgradeFixture { scenario, package_admin, package_version }
}

fun upgrade_admin(): AdminWitness<UpgradeAdmin> {
    blast_acl::witness_for_testing()
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

/// A native receipt for another package, used to prove guard precedence over cap matching.
fun foreign_receipt(self: &mut UpgradeFixture): (UpgradeReceipt, UpgradeCap) {
    let mut cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), self.scenario.ctx());
    let receipt = cap
        .authorize_upgrade(package::compatible_policy(), package_digest())
        .test_upgrade();

    (receipt, cap)
}

// === Imports ===

use blast_admin::{blast_acl::{Self, AdminWitness}, blast_admin_events, errors};

use blast_presale::{
    blast_presale_domain::UpgradeAdmin,
    blast_presale_package::{Self as marker, BLAST_PRESALE_PACKAGE},
    fee_policy,
    package_admin
};

use std::unit_test::{assert_eq, destroy};

use sui::{event, package::{Self, UpgradeCap, UpgradeReceipt}, test_scenario::{Self, Scenario}};

use fun custody_end as CustodyFixture.end;

use fun custody_next_tx as CustodyFixture.next_tx;

use fun upgrade_end as UpgradeFixture.end;

use fun upgrade_next_tx as UpgradeFixture.next_tx;

use fun wrap_ctx as WrapFixture.ctx;

use fun wrap_end as WrapFixture.end;

use fun wrap_next_tx as WrapFixture.next_tx;
