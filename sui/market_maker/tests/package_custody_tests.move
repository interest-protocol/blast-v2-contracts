// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_market_maker::package_custody_tests;

// === Constants ===

const ROOT: address = @0xA;

// === Test-Only Types ===

public struct FOREIGN has drop {}
public struct Fixture {
    scenario: Scenario,
    root: SuperAdminCap,
    acl: ACL,
    admin: AdminCap,
    version: PackageVersion,
    custody: PackageAdmin,
}

// === Tests ===

#[test]
fun authentic_production_wrap_activates_usable_local_generation() {
    let f = start();
    f.version.assert_current();
    f.end();
}

#[test]
fun native_commit_preserves_active_generation_and_repair_authority() {
    let mut f = start_with_nonzero_native_cap();
    f.grant_upgrade_role();
    f.commit_native_upgrade(1);
    f.version.assert_current();
    // A wrong new build has not changed operational generation. Old code can commit a repair.
    f.commit_native_upgrade(2);
    f.version.assert_current();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = package_version::EVersionMismatch,
        location = blast_market_maker::package_version,
    ),
]
fun next_generation_activation_rejects_old_generation_bytecode_after_cutover() {
    let mut f = start_with_nonzero_native_cap();
    f.grant_upgrade_role();
    f.commit_native_upgrade(1);
    f.activate_fixture_generation(2);
    f.version.assert_current();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = package_version::EVersionMismatch,
        location = blast_market_maker::package_version,
    ),
]
fun activation_rejects_skipped_compiled_generation() {
    let mut f = start_with_nonzero_native_cap();
    f.grant_upgrade_role();
    f.commit_native_upgrade(1);
    f.activate_fixture_generation(3);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = package_version::EVersionMismatch,
        location = blast_market_maker::package_version,
    ),
]
fun active_old_bytecode_cannot_activate_a_new_generation() {
    let mut f = start_with_nonzero_native_cap();
    f.grant_upgrade_role();
    f.commit_native_upgrade(1);
    f.activate_production_generation();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = package_admin::ENoCommittedUpgrade,
        location = blast_market_maker::package_admin,
    ),
]
fun next_generation_requires_committed_native_upgrade() {
    let mut f = start_with_nonzero_native_cap();
    f.grant_upgrade_role();
    f.activate_fixture_generation(2);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = package_admin::ENoCommittedUpgrade,
        location = blast_market_maker::package_admin,
    ),
]
fun operational_activation_cannot_reuse_same_committed_native_revision() {
    let mut f = start_with_nonzero_native_cap();
    f.grant_upgrade_role();
    f.commit_native_upgrade(1);
    f.activate_fixture_generation(2);
    f.activate_fixture_generation(2);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = package_admin::EInvalidDigest,
        location = blast_market_maker::package_admin,
    ),
]
fun upgrade_digest_must_be_exactly_32_bytes() {
    let mut f = start();
    f.grant_upgrade_role();
    f.authorize_fixture_digest(vector[1]);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = package_admin::EWrongPublisher,
        location = blast_market_maker::package_admin,
    ),
]
fun publisher_from_another_module_cannot_activate_protocol() {
    publisher_from_another_module_cannot_activate_protocol_setup();
}

#[test]
#[
    expected_failure(
        abort_code = package_admin::EWrongUpgradeCap,
        location = blast_market_maker::package_admin,
    ),
]
fun foreign_native_upgrade_cap_cannot_activate_protocol() {
    foreign_native_upgrade_cap_cannot_activate_protocol_setup();
}

#[test]
#[
    expected_failure(
        abort_code = package_admin::ERestrictedUpgradePolicy,
        location = blast_market_maker::package_admin,
    ),
]
fun additive_only_cap_cannot_activate_operational_cutover_protocol() {
    additive_only_cap_cannot_activate_operational_cutover_protocol_setup();
}

#[test]
#[
    expected_failure(
        abort_code = package_version::ENotOneTimeWitness,
        location = blast_market_maker::package_version,
    ),
]
fun ordinary_drop_type_cannot_seed_initial_generation() {
    let seed = package_version::initial_generation(&FOREIGN {});
    destroy(seed);
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EInvalidAdminCap,
        location = blast_admin::blast_acl,
    ),
]
fun revoked_blast_admin_cannot_authorize_a_native_upgrade() {
    let mut f = start_with_nonzero_native_cap();
    f.grant_upgrade_role();
    f.revoke_fixture_admin();
    f.authorize_fixture_digest(vector::tabulate!(32, |_| 1));
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EAdminRoleNotGranted,
        location = blast_admin::blast_acl,
    ),
]
fun blast_fee_role_does_not_authorize_native_upgrades() {
    let mut f = start_with_nonzero_native_cap();
    f.grant_fee_role();
    f.authorize_fixture_digest(vector::tabulate!(32, |_| 1));
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = package_version::ECanonicalObjectMismatch,
        location = blast_market_maker::package_version,
    ),
]
fun upgrade_witness_cannot_substitute_another_custody_object() {
    let mut f = start_with_nonzero_native_cap();
    f.grant_upgrade_role();
    f.authorize_foreign_custody();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = package_version::EVersionMismatch,
        location = blast_market_maker::package_version,
    ),
]
fun witness_signed_in_before_cutover_cannot_bypass_old_bytecode_gate() {
    let mut f = start_with_nonzero_native_cap();
    f.grant_upgrade_role();
    f.stale_witness_after_cutover();
    f.end();
}

// === Test Helpers ===

fun revoke_fixture_admin(f: &mut Fixture) {
    f.acl.revoke_admin(&f.root, object::id(&f.admin));
}

fun grant_fee_role(f: &mut Fixture) {
    f.acl.grant_role<FeeAdmin>(&f.root, object::id(&f.admin));
}

fun authorize_foreign_custody(f: &mut Fixture) {
    let cap = package::test_publish(object::id_from_address(@0xB01), f.scenario.ctx());
    let mut foreign = package_admin::new_for_testing(cap, f.scenario.ctx());
    let witness = f.upgrade_witness();
    destroy(
        foreign.authorize_upgrade(&f.version, &witness, vector::tabulate!(32, |_| 1)),
    );
    destroy(foreign);
}

fun stale_witness_after_cutover(f: &mut Fixture) {
    let witness = f.upgrade_witness();
    f.commit_native_upgrade(1);
    f.activate_fixture_generation(2);
    destroy(
        f.custody.authorize_upgrade(&f.version, &witness, vector::tabulate!(32, |_| 2)),
    );
}

fun grant_upgrade_role(f: &mut Fixture) {
    f.acl.grant_role<UpgradeAdmin>(&f.root, object::id(&f.admin));
}

fun upgrade_witness(f: &Fixture): AdminWitness<UpgradeAdmin> {
    f.acl.sign_in<UpgradeAdmin>(&f.admin)
}

fun authorize_fixture_digest(f: &mut Fixture, digest: vector<u8>) {
    let witness = f.upgrade_witness();
    destroy(f.custody.authorize_upgrade(&f.version, &witness, digest));
}

fun commit_native_upgrade(f: &mut Fixture, digest_byte: u8) {
    let witness = f.upgrade_witness();
    let ticket = f.custody.authorize_upgrade(
        &f.version,
        &witness,
        vector::tabulate!(32, |_| digest_byte),
    );
    f.custody.commit_upgrade(&f.version, &witness, package::test_upgrade(ticket));
}

// The parameterized compiled-generation seam uses the production custody/fresh-native guard.
// It does not claim two separately compiled Move packages ran in one unit-test module.
fun activate_fixture_generation(f: &mut Fixture, compiled_generation: u64) {
    let witness = f.upgrade_witness();
    f.custody.activate_generation_for_testing(&mut f.version, &witness, compiled_generation);
}

fun activate_production_generation(f: &mut Fixture) {
    let witness = f.upgrade_witness();
    f.custody.activate_generation(&mut f.version, &witness);
}

fun additive_only_cap_cannot_activate_operational_cutover_protocol_setup() {
    let mut scenario = test_scenario::begin(ROOT);
    let publisher = authentic_publisher(scenario.ctx());
    seed_bootstrap(publisher, scenario.ctx());
    scenario.next_tx(ROOT);
    let bootstrap = scenario.take_from_sender<Bootstrap>();
    let mut cap = package::test_publish(
        object::id_from_address(@blast_market_maker),
        scenario.ctx(),
    );
    package::only_additive_upgrades(&mut cap);
    bootstrap.wrap(cap, scenario.ctx());
    scenario.end();
}

fun foreign_native_upgrade_cap_cannot_activate_protocol_setup() {
    let mut scenario = test_scenario::begin(ROOT);
    let publisher = authentic_publisher(scenario.ctx());
    seed_bootstrap(publisher, scenario.ctx());
    scenario.next_tx(ROOT);
    let bootstrap = scenario.take_from_sender<Bootstrap>();
    let cap = package::test_publish(object::id_from_address(@0xCAFE), scenario.ctx());
    bootstrap.wrap(cap, scenario.ctx());
    scenario.end();
}

fun publisher_from_another_module_cannot_activate_protocol_setup() {
    let mut scenario = test_scenario::begin(ROOT);
    let publisher = package::test_claim(FOREIGN {}, scenario.ctx());
    seed_bootstrap(publisher, scenario.ctx());
    scenario.next_tx(ROOT);
    let bootstrap = scenario.take_from_sender<Bootstrap>();
    let cap = package::test_publish(object::id_from_address(@blast_market_maker), scenario.ctx());
    bootstrap.wrap(cap, scenario.ctx());
    scenario.end();
}

fun start(): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let (root, mut acl) = blast_acl::new_for_testing(scenario.ctx());
    acl.grant_admin(&root, ROOT, scenario.ctx());
    let publisher = authentic_publisher(scenario.ctx());
    let marker = test_utils::create_one_time_witness<BLAST_MARKET_MAKER>();
    let seed = package_version::initial_generation(&marker);
    package_version::new_bootstrap(
        publisher,
        seed,
        object::id_from_address(@0xD),
        object::id_from_address(@0xE),
        scenario.ctx(),
    );
    scenario.next_tx(ROOT);
    let admin = scenario.take_from_sender<AdminCap>();
    let bootstrap = scenario.take_from_sender<Bootstrap>();
    let cap = package::test_publish(object::id_from_address(@blast_market_maker), scenario.ctx());
    bootstrap.wrap(cap, scenario.ctx());
    scenario.next_tx(ROOT);
    let version = scenario.take_shared<PackageVersion>();
    let custody = scenario.take_shared<PackageAdmin>();
    Fixture { scenario, root, acl, admin, version, custody }
}

/// The zero unit-test package is the framework pending-ticket sentinel and cannot upgrade.
/// Wrap is tested independently; native cutover fixtures use a real nonzero test cap and bind
/// their version to that exact custody ID without claiming a second production bootstrap.
fun start_with_nonzero_native_cap(): Fixture {
    let Fixture { mut scenario, root, acl, admin, version, custody } = start();
    destroy(custody);
    destroy(version);
    let cap = package::test_publish(object::id_from_address(@0xB00), scenario.ctx());
    let custody = package_admin::new_for_testing(cap, scenario.ctx());
    let version = package_version::new_for_custody_testing(
        object::id_from_address(@0xD),
        object::id_from_address(@0xE),
        object::id(&custody),
        scenario.ctx(),
    );
    Fixture { scenario, root, acl, admin, version, custody }
}

fun authentic_publisher(ctx: &mut TxContext): Publisher {
    package::claim(test_utils::create_one_time_witness<BLAST_MARKET_MAKER>(), ctx)
}

fun seed_bootstrap(publisher: Publisher, ctx: &mut TxContext) {
    let marker = test_utils::create_one_time_witness<BLAST_MARKET_MAKER>();
    let seed = package_version::initial_generation(&marker);
    package_version::new_bootstrap(
        publisher,
        seed,
        object::id_from_address(@0xD),
        object::id_from_address(@0xE),
        ctx,
    );
}

fun end(f: Fixture) {
    let Fixture { scenario, root, acl, admin, version, custody } = f;
    destroy(admin);
    destroy(root);
    destroy(acl);
    destroy(version);
    destroy(custody);
    scenario.end();
}

// === Imports ===

use blast_admin::blast_acl::{Self, ACL, AdminCap, AdminWitness, SuperAdminCap};
use blast_market_maker::{
    blast_market_maker::BLAST_MARKET_MAKER,
    package_admin::{Self, BlastMarketMakerAdmin as PackageAdmin},
    package_version::{
        Self,
        BlastMarketMakerBootstrap as Bootstrap,
        BlastMarketMakerVersion as PackageVersion,
    },
    blast_market_maker_domain::{FeeAdmin, UpgradeAdmin},
};
use std::unit_test::destroy;
use sui::{package::{Self, Publisher}, test_scenario::{Self, Scenario}, test_utils};

use fun package_admin::wrap as Bootstrap.wrap;
