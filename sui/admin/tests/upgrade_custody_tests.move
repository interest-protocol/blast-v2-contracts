// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Provenance, native-capability, policy, and atomic composition tests.
module blast_admin::upgrade_custody_tests;

// === Constants ===

const ROOT: address = @0xA11CE;
const CUSTODIAN_ID: address = @0xC0570D1A;
const OTHER_CUSTODIAN_ID: address = @0xBAD;

// === Tests ===

#[test]
fun canonical_capabilities_enter_sealed_custody_with_complete_identity() {
    let mut ctx = tx_context::dummy();
    let publisher = canonical_publisher(&mut ctx);
    let publisher_id = object::id(&publisher);
    let upgrade_cap = canonical_upgrade_cap(&mut ctx);
    let upgrade_cap_id = object::id(&upgrade_cap);

    let custody = upgrade_custody::new<package_marker::PACKAGE_MARKER>(
        CUSTODIAN_ID.to_id(),
        publisher,
        upgrade_cap,
    );

    assert!(custody.has_upgrade_cap());
    assert_eq!(custody.publisher_id_for_testing(), publisher_id);
    assert_eq!(custody.upgrade_cap_id_for_testing(), upgrade_cap_id);
    assert_eq!(custody.native_version_for_testing(), 1);
    assert_eq!(custody.policy_for_testing(), package::compatible_policy());
    let created = events::collect_one<
        events::UpgradeCustodyCreated<package_marker::PACKAGE_MARKER>,
    >(0);
    let (
        custodian_id,
        emitted_publisher_id,
        emitted_upgrade_cap_id,
        package_id,
        native_version,
        policy,
    ) = created.upgrade_custody_created_fields();
    assert_eq!(custodian_id, CUSTODIAN_ID.to_id());
    assert_eq!(emitted_publisher_id, publisher_id);
    assert_eq!(emitted_upgrade_cap_id, upgrade_cap_id);
    assert_eq!(package_id, canonical_package_id());
    assert_eq!(native_version, 1);
    assert_eq!(policy, package::compatible_policy());

    destroy(ctx);
    destroy(custody);
}

#[test]
fun sealed_publisher_still_authorizes_provenance_gated_framework_features() {
    let mut ctx = tx_context::dummy();
    let custody = canonical_custody(&mut ctx);

    let display = display::new<package_marker::Receipt>(custody.publisher(), &mut ctx);

    assert_eq!(object::id(custody.publisher()), custody.publisher_id_for_testing());
    assert!(custody.publisher().from_package<package_marker::PACKAGE_MARKER>());
    assert!(custody.has_upgrade_cap());

    destroy(ctx);
    destroy(custody);
    destroy(display);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPackagePublisher, location = blast_admin::upgrade_custody)]
fun intake_rejects_a_publisher_from_another_package_before_the_cap() {
    let mut ctx = tx_context::dummy();
    let publisher = foreign_package_marker::publisher(&mut ctx);
    let upgrade_cap = package::test_publish(@0xBAD.to_id(), &mut ctx);

    let custody = upgrade_custody::new<package_marker::PACKAGE_MARKER>(
        CUSTODIAN_ID.to_id(),
        publisher,
        upgrade_cap,
    );

    destroy(ctx);
    destroy(custody);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPackagePublisher, location = blast_admin::upgrade_fixture)]
fun consumer_wrapper_rejects_a_publisher_from_another_module() {
    let mut ctx = tx_context::dummy();
    let publisher = package::test_claim(other_package_marker::marker(), &mut ctx);
    let upgrade_cap = canonical_upgrade_cap(&mut ctx);

    let package_admin = upgrade_fixture::new(publisher, upgrade_cap, &mut ctx);

    destroy(ctx);
    destroy(package_admin);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUpgradeCap, location = blast_admin::upgrade_custody)]
fun intake_rejects_an_upgrade_cap_for_another_package() {
    let mut ctx = tx_context::dummy();
    let publisher = canonical_publisher(&mut ctx);
    let upgrade_cap = package::test_publish(@0xBAD.to_id(), &mut ctx);

    let custody = upgrade_custody::new<package_marker::PACKAGE_MARKER>(
        CUSTODIAN_ID.to_id(),
        publisher,
        upgrade_cap,
    );

    destroy(ctx);
    destroy(custody);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUpgradeCap, location = blast_admin::upgrade_custody)]
/// Native test upgrades also rewrite the package ID; the boundary gate
/// separately requires the fresh-version conjunct in production intake.
fun intake_rejects_a_cap_whose_native_version_already_advanced() {
    let mut ctx = tx_context::dummy();
    let publisher = canonical_publisher(&mut ctx);
    let mut upgrade_cap = canonical_upgrade_cap(&mut ctx);
    assert_eq!(upgrade_cap.version(), 1);
    let ticket = upgrade_cap.authorize(package::compatible_policy(), digest());
    upgrade_cap.commit(ticket.test_upgrade());
    assert_eq!(upgrade_cap.version(), 2);

    let custody = upgrade_custody::new<package_marker::PACKAGE_MARKER>(
        CUSTODIAN_ID.to_id(),
        publisher,
        upgrade_cap,
    );

    destroy(ctx);
    destroy(custody);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUpgradeCap, location = blast_admin::upgrade_custody)]
fun intake_rejects_a_cap_with_an_outstanding_authorization() {
    let mut ctx = tx_context::dummy();
    let publisher = canonical_publisher(&mut ctx);
    let mut upgrade_cap = canonical_upgrade_cap(&mut ctx);
    let ticket = upgrade_cap.authorize(package::compatible_policy(), digest());

    let custody = upgrade_custody::new<package_marker::PACKAGE_MARKER>(
        CUSTODIAN_ID.to_id(),
        publisher,
        upgrade_cap,
    );

    destroy(ctx);
    destroy(custody);
    destroy(ticket);
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPackageDigest, location = blast_admin::upgrade_custody)]
fun authorization_rejects_a_non_32_byte_digest() {
    let mut ctx = tx_context::dummy();
    let mut custody = canonical_custody(&mut ctx);

    let ticket = custody.authorize_upgrade(CUSTODIAN_ID.to_id(), vector[]);

    destroy(ctx);
    destroy(custody);
    destroy(ticket);
}

#[test]
fun authorization_and_matching_commit_emit_complete_native_facts() {
    let mut ctx = tx_context::dummy();
    let mut custody = canonical_custody(&mut ctx);
    let upgrade_cap_id = custody.upgrade_cap_id_for_testing();
    let digest = digest();

    let ticket = custody.authorize_upgrade(CUSTODIAN_ID.to_id(), digest);
    let receipt = ticket.test_upgrade();
    let new_package_id = receipt.package();
    custody.commit_upgrade(CUSTODIAN_ID.to_id(), receipt);

    assert_eq!(custody.native_version_for_testing(), 2);
    assert_eq!(custody.current_package_id_for_testing(), new_package_id);
    let authorized = events::collect_one<
        events::UpgradeAuthorized<package_marker::PACKAGE_MARKER>,
    >(0);
    let (custodian_id, emitted_cap_id, package_id, native_version, policy, emitted_digest) =
        authorized.upgrade_authorized_fields();
    assert_eq!(custodian_id, CUSTODIAN_ID.to_id());
    assert_eq!(emitted_cap_id, upgrade_cap_id);
    assert_eq!(package_id, canonical_package_id());
    assert_eq!(native_version, 1);
    assert_eq!(policy, package::compatible_policy());
    assert_eq!(emitted_digest, digest);
    let committed = events::collect_one<
        events::UpgradeCommitted<package_marker::PACKAGE_MARKER>,
    >(0);
    let (
        emitted_custodian_id,
        committed_cap_id,
        original_package_id,
        emitted_new_package_id,
        previous_native_version,
        new_native_version,
    ) = committed.upgrade_committed_fields();
    assert_eq!(emitted_custodian_id, CUSTODIAN_ID.to_id());
    assert_eq!(committed_cap_id, upgrade_cap_id);
    assert_eq!(original_package_id, type_name::original_id<package_marker::PACKAGE_MARKER>());
    assert_eq!(emitted_new_package_id, new_package_id);
    assert_eq!(previous_native_version, 1);
    assert_eq!(new_native_version, 2);

    destroy(ctx);
    destroy(custody);
}

#[test]
#[expected_failure(abort_code = 4, location = sui::package)]
fun receipt_cannot_commit_to_another_custody() {
    let mut ctx = tx_context::dummy();
    let mut custody = canonical_custody(&mut ctx);
    let ticket = custody.authorize_upgrade(CUSTODIAN_ID.to_id(), digest());
    let receipt = ticket.test_upgrade();
    let mut other = canonical_custody_with_id(OTHER_CUSTODIAN_ID.to_id(), &mut ctx);

    other.commit_upgrade(OTHER_CUSTODIAN_ID.to_id(), receipt);

    destroy(ctx);
    destroy(custody);
    destroy(other);
}

#[test]
fun policy_can_only_narrow_in_native_order() {
    let mut ctx = tx_context::dummy();
    let mut custody = canonical_custody(&mut ctx);

    custody.restrict_to_additive(CUSTODIAN_ID.to_id());
    assert_eq!(custody.policy_for_testing(), package::additive_policy());
    custody.restrict_to_dependency_only(CUSTODIAN_ID.to_id());
    assert_eq!(custody.policy_for_testing(), package::dep_only_policy());
    let mut policy_events = event::events_by_type<
        events::UpgradePolicyRestricted<package_marker::PACKAGE_MARKER>,
    >();
    assert_eq!(policy_events.length(), 2);
    let dependency_only = policy_events.pop_back();
    let additive = policy_events.pop_back();
    let (
        custodian_id,
        emitted_cap_id,
        package_id,
        native_version,
        previous_policy,
        new_policy,
    ) =
        additive.upgrade_policy_restricted_fields();
    assert_eq!(custodian_id, CUSTODIAN_ID.to_id());
    assert_eq!(emitted_cap_id, custody.upgrade_cap_id_for_testing());
    assert_eq!(package_id, type_name::original_id<package_marker::PACKAGE_MARKER>());
    assert_eq!(native_version, 1);
    assert_eq!(previous_policy, package::compatible_policy());
    assert_eq!(new_policy, package::additive_policy());
    let (
        custodian_id,
        emitted_cap_id,
        package_id,
        native_version,
        previous_policy,
        new_policy,
    ) =
        dependency_only.upgrade_policy_restricted_fields();
    assert_eq!(custodian_id, CUSTODIAN_ID.to_id());
    assert_eq!(emitted_cap_id, custody.upgrade_cap_id_for_testing());
    assert_eq!(package_id, type_name::original_id<package_marker::PACKAGE_MARKER>());
    assert_eq!(native_version, 1);
    assert_eq!(previous_policy, package::additive_policy());
    assert_eq!(new_policy, package::dep_only_policy());

    destroy(ctx);
    destroy(custody);
}

#[test]
#[expected_failure(abort_code = errors::EUpgradePolicyNotMoreRestrictive, location = blast_admin::upgrade_custody)]
fun policy_restriction_rejects_an_equal_policy() {
    let mut ctx = tx_context::dummy();
    let mut custody = canonical_custody(&mut ctx);
    custody.restrict_to_additive(CUSTODIAN_ID.to_id());

    custody.restrict_to_additive(CUSTODIAN_ID.to_id());

    destroy(ctx);
    destroy(custody);
}

#[test]
#[expected_failure(abort_code = errors::EUpgradePolicyNotMoreRestrictive, location = blast_admin::upgrade_custody)]
fun policy_restriction_rejects_a_looser_policy() {
    let mut ctx = tx_context::dummy();
    let mut custody = canonical_custody(&mut ctx);
    custody.restrict_to_dependency_only(CUSTODIAN_ID.to_id());

    custody.restrict_to_additive(CUSTODIAN_ID.to_id());

    destroy(ctx);
    destroy(custody);
}

#[test]
fun immutability_consumes_only_the_upgrade_cap_and_emits_terminal_state() {
    let mut ctx = tx_context::dummy();
    let mut custody = canonical_custody(&mut ctx);
    let publisher_id = custody.publisher_id_for_testing();
    let upgrade_cap_id = custody.upgrade_cap_id_for_testing();

    custody.make_immutable(CUSTODIAN_ID.to_id());

    assert!(!custody.has_upgrade_cap());
    assert_eq!(custody.publisher_id_for_testing(), publisher_id);
    let destroyed = events::collect_one<
        events::UpgradeCapDestroyed<package_marker::PACKAGE_MARKER>,
    >(0);
    let (custodian_id, emitted_cap_id, package_id, native_version, policy) =
        destroyed.upgrade_cap_destroyed_fields();
    assert_eq!(custodian_id, CUSTODIAN_ID.to_id());
    assert_eq!(emitted_cap_id, upgrade_cap_id);
    assert_eq!(package_id, type_name::original_id<package_marker::PACKAGE_MARKER>());
    assert_eq!(native_version, 1);
    assert_eq!(policy, package::compatible_policy());

    destroy(ctx);
    destroy(custody);
}

#[test]
#[expected_failure(abort_code = errors::EUpgradeCapUnavailable, location = blast_admin::upgrade_custody)]
fun repeated_immutability_is_rejected() {
    let mut ctx = tx_context::dummy();
    let mut custody = canonical_custody(&mut ctx);
    custody.make_immutable(CUSTODIAN_ID.to_id());

    custody.make_immutable(CUSTODIAN_ID.to_id());

    destroy(ctx);
    destroy(custody);
}

#[test]
#[expected_failure(abort_code = errors::EUpgradeCapUnavailable, location = blast_admin::upgrade_custody)]
fun authorization_is_rejected_after_immutability() {
    let mut ctx = tx_context::dummy();
    let mut custody = canonical_custody(&mut ctx);
    custody.make_immutable(CUSTODIAN_ID.to_id());

    let ticket = custody.authorize_upgrade(CUSTODIAN_ID.to_id(), digest());

    destroy(ctx);
    destroy(custody);
    destroy(ticket);
}

#[test]
#[expected_failure(abort_code = errors::EUpgradeCapUnavailable, location = blast_admin::upgrade_custody)]
fun policy_restriction_is_rejected_after_immutability() {
    let mut ctx = tx_context::dummy();
    let mut custody = canonical_custody(&mut ctx);
    custody.make_immutable(CUSTODIAN_ID.to_id());

    custody.restrict_to_additive(CUSTODIAN_ID.to_id());

    destroy(ctx);
    destroy(custody);
}

#[test]
#[expected_failure(abort_code = errors::EUpgradeCapUnavailable, location = blast_admin::upgrade_custody)]
fun commit_is_rejected_after_immutability() {
    let mut ctx = tx_context::dummy();
    let mut custody = canonical_custody(&mut ctx);
    custody.make_immutable(CUSTODIAN_ID.to_id());
    let mut other = canonical_custody_with_id(OTHER_CUSTODIAN_ID.to_id(), &mut ctx);
    let ticket = other.authorize_upgrade(OTHER_CUSTODIAN_ID.to_id(), digest());
    let receipt = ticket.test_upgrade();

    custody.commit_upgrade(CUSTODIAN_ID.to_id(), receipt);

    destroy(ctx);
    destroy(custody);
    destroy(other);
}

#[test]
#[expected_failure(abort_code = errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun consumer_wrapper_rejects_stale_pre_upgrade_generation() {
    let mut scenario = test_scenario::begin(ROOT);
    let publisher = canonical_publisher(scenario.ctx());
    let upgrade_cap = canonical_upgrade_cap(scenario.ctx());
    let mut package_admin = upgrade_fixture::new(publisher, upgrade_cap, scenario.ctx());
    package_admin.set_generation(2);
    let witness = blast_acl::witness_for_testing<UpgradeAdmin>();

    let ticket = package_admin.authorize_upgrade(&witness, digest());

    destroy(scenario);
    destroy(witness);
    destroy(package_admin);
    destroy(ticket);
}

#[test]
fun fixture_commits_native_receipt_and_advances_generation_atomically() {
    let mut scenario = test_scenario::begin(ROOT);
    let publisher = canonical_publisher(scenario.ctx());
    let upgrade_cap = canonical_upgrade_cap(scenario.ctx());
    let mut package_admin = upgrade_fixture::new(publisher, upgrade_cap, scenario.ctx());
    let witness = blast_acl::witness_for_testing<UpgradeAdmin>();
    let ticket = package_admin.authorize_upgrade(&witness, digest());
    let receipt = ticket.test_upgrade();
    let expected_package_id = receipt.package();

    package_admin.commit_and_advance(&witness, receipt, 2);

    assert_eq!(package_admin.custody().native_version_for_testing(), 2);
    assert_eq!(package_admin.custody().current_package_id_for_testing(), expected_package_id);
    assert_eq!(package_admin.generation(), 2);

    destroy(scenario);
    destroy(witness);
    destroy(package_admin);
}

#[test]
#[expected_failure(abort_code = errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun skipped_generation_rejects_before_the_fixture_commit() {
    let mut scenario = test_scenario::begin(ROOT);
    let publisher = canonical_publisher(scenario.ctx());
    let upgrade_cap = canonical_upgrade_cap(scenario.ctx());
    let mut package_admin = upgrade_fixture::new(publisher, upgrade_cap, scenario.ctx());
    let witness = blast_acl::witness_for_testing<UpgradeAdmin>();
    let ticket = package_admin.authorize_upgrade(&witness, digest());
    let receipt = ticket.test_upgrade();

    package_admin.commit_and_advance(&witness, receipt, 3);

    destroy(scenario);
    destroy(witness);
    destroy(package_admin);
}

#[test]
#[expected_failure(abort_code = errors::EOperationalVersionOverflow, location = blast_admin::operational_version)]
fun generation_overflow_rejects_before_the_fixture_commit() {
    let mut scenario = test_scenario::begin(ROOT);
    let publisher = canonical_publisher(scenario.ctx());
    let upgrade_cap = canonical_upgrade_cap(scenario.ctx());
    let mut package_admin = upgrade_fixture::new(publisher, upgrade_cap, scenario.ctx());
    let witness = blast_acl::witness_for_testing<UpgradeAdmin>();
    let ticket = package_admin.authorize_upgrade(&witness, digest());
    let receipt = ticket.test_upgrade();
    package_admin.set_generation(std::u64::max_value!());

    package_admin.commit_and_advance(&witness, receipt, 0);

    destroy(scenario);
    destroy(witness);
    destroy(package_admin);
}

// === Test Helpers ===

fun canonical_package_id(): ID {
    type_name::original_id<package_marker::PACKAGE_MARKER>().to_id()
}

fun canonical_publisher(ctx: &mut TxContext): Publisher {
    package::test_claim(package_marker::marker(), ctx)
}

fun canonical_upgrade_cap(ctx: &mut TxContext): UpgradeCap {
    package::test_publish(canonical_package_id(), ctx)
}

fun canonical_custody(
    ctx: &mut TxContext,
): upgrade_custody::UpgradeCustody<package_marker::PACKAGE_MARKER> {
    canonical_custody_with_id(CUSTODIAN_ID.to_id(), ctx)
}

fun canonical_custody_with_id(
    custodian_id: ID,
    ctx: &mut TxContext,
): upgrade_custody::UpgradeCustody<package_marker::PACKAGE_MARKER> {
    upgrade_custody::new<package_marker::PACKAGE_MARKER>(
        custodian_id,
        canonical_publisher(ctx),
        canonical_upgrade_cap(ctx),
    )
}

fun digest(): vector<u8> {
    x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
}

// === Imports ===

use 0xf::foreign_package_marker;

use 0xa::{other_package_marker, package_marker};

use blast_admin::{
    blast_acl,
    blast_admin_events as events,
    errors,
    upgrade_custody,
    upgrade_fixture::{Self, UpgradeAdmin},
};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{display, event, package::{Self, Publisher, UpgradeCap}, test_scenario};
