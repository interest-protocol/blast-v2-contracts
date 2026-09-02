#[test_only]
module blast_sui::package_admin_tests;

use blast_sui::{
    acl,
    blast,
    blast_sui::{Self as blast_coin, BLAST_SUI},
    deposit_receipt::{Self, BlastSuiDepositReceipt},
    errors,
    events,
    fun_sui::{Self as fun_coin, FUN_SUI},
    package_admin,
    package_version,
};
use std::{type_name, unit_test::{assert_eq, destroy}};
use sui::{
    coin_registry::MetadataCap,
    display_registry::{DisplayCap, DisplayRegistry},
    event,
    package,
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
const ADMIN: address = @0xAD;
const PACKAGE_ID: address = @0xB1A57;
const OTHER_PACKAGE_ID: address = @0xBAD;

// === Test-Only Types ===

/// Witness from a non-canonical module used to forge a wrong-provenance Publisher.
public struct FOREIGN_PUBLISHER() has drop;

/// Future package capability used to prove the generic extension seam.
public struct TEST_CAPABILITY has key, store {
    id: UID,
}

/// Bare transaction runner for fixed-capability provenance rejections.
public struct WrapFixture {
    scenario: Scenario,
}

/// Production staged-construction output and its completed facts.
public struct CustodyFixture {
    scenario: Scenario,
    package_admin: package_admin::PackageAdmin,
    publisher_id: ID,
    upgrade_cap_id: ID,
    fun_metadata_cap_id: ID,
    blast_metadata_cap_id: ID,
    display_cap_id: ID,
    fun_metadata_added: events::PackageCapabilityAdded,
    blast_metadata_added: events::PackageCapabilityAdded,
    display_added: events::PackageCapabilityAdded,
    created: events::PackageAdminCreated,
    package_version: package_version::PackageVersion,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
}

/// Upgrade and version operations authorized by a routine admin witness.
public struct UpgradeFixture {
    scenario: Scenario,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
    package_admin: package_admin::PackageAdmin,
    package_version: package_version::PackageVersion,
}

// === Tests ===

#[test]
fun package_version_activation_emits_the_only_wrapped_cutover_fact() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        assert_eq!(f.package_version.version_for_testing(), 1);

        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(0);
        f.package_version.activate_package_version(&admin_witness);

        let advanced = events::collect_one<events::PackageVersionAdvanced>(0);
        let (previous_version, new_version) = advanced.package_version_advanced_fields();
        assert_eq!(previous_version, 0);
        assert_eq!(new_version, 1);
        assert_eq!(new_version, f.package_version.version_for_testing());
    });

    fixture.end();
}

#[test]
fun staged_construction_shares_complete_custody_without_returning_authority() {
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
        let (fun_admin_id, emitted_fun_metadata_cap_id, fun_metadata_type) =
            f.fun_metadata_added.package_capability_added_fields();
        assert_eq!(fun_admin_id, package_admin_id);
        assert_eq!(emitted_fun_metadata_cap_id, f.fun_metadata_cap_id);
        assert_eq!(
            emitted_fun_metadata_cap_id,
            f.package_admin.fun_metadata_cap_id_for_testing(),
        );
        assert_eq!(
            fun_metadata_type,
            type_name::with_original_ids<MetadataCap<FUN_SUI>>(),
        );
        let (blast_admin_id, emitted_blast_metadata_cap_id, blast_metadata_type) =
            f.blast_metadata_added.package_capability_added_fields();
        assert_eq!(blast_admin_id, package_admin_id);
        assert_eq!(emitted_blast_metadata_cap_id, f.blast_metadata_cap_id);
        assert_eq!(
            emitted_blast_metadata_cap_id,
            f.package_admin.blast_metadata_cap_id_for_testing(),
        );
        assert_eq!(
            blast_metadata_type,
            type_name::with_original_ids<MetadataCap<BLAST_SUI>>(),
        );
        let (display_admin_id, emitted_display_cap_id, display_type) =
            f.display_added.package_capability_added_fields();
        assert_eq!(display_admin_id, package_admin_id);
        assert_eq!(emitted_display_cap_id, f.display_cap_id);
        assert_eq!(emitted_display_cap_id, f.package_admin.display_cap_id_for_testing());
        assert_eq!(
            display_type,
            type_name::with_original_ids<DisplayCap<BlastSuiDepositReceipt>>(),
        );
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
fun routine_admin_attaches_a_future_capability_without_changing_parent_layout() {
    let mut fixture = start_custody();

    fixture.next_tx!(PUBLISHER, |f| {
        let admin_witness = f.authority.sign_in(&f.package_version, &f.admin_cap);
        let capability = TEST_CAPABILITY { id: object::new(f.scenario.ctx()) };
        let capability_id = object::id(&capability);
        f.package_admin.add_capability(
            &f.package_version,
            &admin_witness,
            capability,
        );

        let added = events::collect_one<events::PackageCapabilityAdded>(0);
        let (package_admin_id, emitted_capability_id, capability_type) =
            added.package_capability_added_fields();
        assert_eq!(package_admin_id, object::id(&f.package_admin));
        assert_eq!(emitted_capability_id, capability_id);
        assert_eq!(
            emitted_capability_id,
            f.package_admin.capability_id_for_testing<TEST_CAPABILITY>(),
        );
        assert_eq!(capability_type, type_name::with_original_ids<TEST_CAPABILITY>());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EMissingPackageCapability,
    location = blast_sui::package_admin,
)]
fun share_rejects_custody_without_any_required_capability() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        package_admin::new_empty_for_testing(PACKAGE_ID.to_id(), f.ctx!()).share();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EMissingPackageCapability,
    location = blast_sui::package_admin,
)]
fun share_rejects_custody_without_the_required_display_capability() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let mut package_admin =
            package_admin::new_empty_for_testing(PACKAGE_ID.to_id(), f.ctx!());
        let admin_witness = f.sign_in();
        package_admin.add_capability(
            &f.package_version,
            &admin_witness,
            new_fun_metadata_cap(f.ctx!()),
        );
        package_admin.add_capability(
            &f.package_version,
            &admin_witness,
            new_blast_metadata_cap(f.ctx!()),
        );
        package_admin.share();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EMissingPackageCapability,
    location = blast_sui::package_admin,
)]
fun share_rejects_custody_without_the_required_blast_metadata_capability() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let mut package_admin =
            package_admin::new_empty_for_testing(PACKAGE_ID.to_id(), f.ctx!());
        let admin_witness = f.sign_in();
        package_admin.add_capability(
            &f.package_version,
            &admin_witness,
            new_fun_metadata_cap(f.ctx!()),
        );
        package_admin.share();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageCapabilityAlreadyExists,
    location = blast_sui::package_admin,
)]
fun add_capability_rejects_a_duplicate_exact_type() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let mut package_admin =
            package_admin::new_empty_for_testing(PACKAGE_ID.to_id(), f.ctx!());
        let admin_witness = f.sign_in();
        package_admin.add_capability(
            &f.package_version,
            &admin_witness,
            new_blast_metadata_cap(f.ctx!()),
        );
        package_admin.add_capability(
            &f.package_version,
            &admin_witness,
            new_blast_metadata_cap(f.ctx!()),
        );
        destroy(package_admin);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidUpgradeCap, location = blast_sui::package_admin)]
fun new_rejects_an_upgrade_cap_for_another_package() {
    let mut fixture = start_wrap();

    fixture.next_tx!(PUBLISHER, |f| {
        let publisher = blast::publisher_for_testing(f.ctx!());
        let upgrade_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), f.ctx!());
        destroy(package_admin::new(publisher, upgrade_cap, f.ctx!()));
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidPackagePublisher,
    location = blast_sui::package_admin,
)]
fun new_rejects_a_publisher_from_another_module() {
    let mut fixture = start_wrap();

    fixture.next_tx!(PUBLISHER, |f| {
        let publisher = package::test_claim(FOREIGN_PUBLISHER(), f.ctx!());
        let upgrade_cap = package::test_publish(@0x0.to_id(), f.ctx!());
        destroy(package_admin::new(publisher, upgrade_cap, f.ctx!()));
    });

    fixture.end();
}

#[test]
fun routine_admin_authorization_commit_and_restriction_emit_replay_complete_facts() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = f.sign_in();
        let ticket = f
            .package_admin
            .authorize_upgrade(
                &f.package_version,
                &admin_witness,
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
            &admin_witness,
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

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_admin.restrict_to_additive(
            &f.package_version,
            &admin_witness,
        );
        f.package_admin.restrict_to_additive(
            &f.package_version,
            &admin_witness,
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

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(std::u64::max_value!());
        f.package_version.activate_package_version(&admin_witness);
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

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.activate_package_version(&admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidAdminCap, location = blast_sui::acl)]
fun admin_registered_in_another_registry_cannot_authorize_an_upgrade() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let (foreign_super_admin_cap, foreign_authority) =
            acl::new_protocol_for_testing(f.ctx!());
        let admin_witness = foreign_authority.sign_in(
            &f.package_version,
            &f.admin_cap,
        );
        let ticket = f.package_admin.authorize_upgrade(
            &f.package_version,
            &admin_witness,
            package_digest(),
        );
        destroy(package::test_upgrade(ticket));
        destroy(foreign_super_admin_cap);
        destroy(foreign_authority);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = sui::package::EWrongUpgradeCap, location = sui::package)]
fun commit_rejects_a_receipt_bound_to_another_upgrade_cap() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let mut other_upgrade_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), f.ctx!());
        let ticket = other_upgrade_cap.authorize(package::compatible_policy(), package_digest());
        let receipt = package::test_upgrade(ticket);

        f.package_admin.commit_upgrade(&f.package_version, receipt);

        destroy(other_upgrade_cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPackageDigest, location = blast_sui::package_admin)]
fun upgrade_authorization_rejects_non_digest_length() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = f.sign_in();
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
    abort_code = errors::EPackageVersionMismatch,
    location = blast_sui::package_version,
)]
fun stale_shared_version_rejects_old_bytecode() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        f.package_version.set_for_testing(2);

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

/// Runs the composable production construction flow and takes the shared result.
fun start_custody(): CustodyFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    scenario.create_system_objects();
    blast::init_for_testing(scenario.ctx());
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(scenario.ctx());
    authority.grant_admin(
        &package_version,
        &super_admin_cap,
        PUBLISHER,
        scenario.ctx(),
    );

    scenario.next_tx(PUBLISHER);
    let publisher = scenario.take_from_sender<package::Publisher>();
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let upgrade_cap = package::test_publish(@0x0.to_id(), scenario.ctx());
    let fun_metadata_cap = new_fun_metadata_cap(scenario.ctx());
    let blast_metadata_cap = new_blast_metadata_cap(scenario.ctx());
    let display_cap = new_display_cap(&mut scenario);
    let publisher_id = object::id(&publisher);
    let upgrade_cap_id = object::id(&upgrade_cap);
    let fun_metadata_cap_id = object::id(&fun_metadata_cap);
    let blast_metadata_cap_id = object::id(&blast_metadata_cap);
    let display_cap_id = object::id(&display_cap);
    let mut package_admin = package_admin::new(publisher, upgrade_cap, scenario.ctx());
    let admin_witness = authority.sign_in(&package_version, &admin_cap);
    package_admin.add_capability(
        &package_version,
        &admin_witness,
        fun_metadata_cap,
    );
    package_admin.add_capability(
        &package_version,
        &admin_witness,
        blast_metadata_cap,
    );
    package_admin.add_capability(&package_version, &admin_witness, display_cap);
    package_admin.share();
    let fun_metadata_added = events::collect<events::PackageCapabilityAdded>()[0];
    let blast_metadata_added = events::collect<events::PackageCapabilityAdded>()[1];
    let display_added = events::collect<events::PackageCapabilityAdded>()[2];
    let created = events::collect_one<events::PackageAdminCreated>(0);
    destroy(super_admin_cap);

    scenario.next_tx(PUBLISHER);
    let package_admin = scenario.take_shared<package_admin::PackageAdmin>();

    CustodyFixture {
        scenario,
        package_admin,
        publisher_id,
        upgrade_cap_id,
        fun_metadata_cap_id,
        blast_metadata_cap_id,
        display_cap_id,
        fun_metadata_added,
        blast_metadata_added,
        display_added,
        created,
        package_version,
        authority,
        admin_cap,
    }
}

/// Initializes the shared package version, test custody, and singleton authority.
fun start_upgrade(): UpgradeFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    scenario.create_system_objects();
    package_version::init_for_testing(scenario.ctx());

    assert_eq!(event::num_events(), 0);

    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(scenario.ctx());
    let auth_package_version = package_version::new_for_testing(scenario.ctx());
    authority.grant_admin(
        &auth_package_version,
        &super_admin_cap,
        ADMIN,
        scenario.ctx(),
    );
    destroy(auth_package_version);

    let fun_metadata_cap = new_fun_metadata_cap(scenario.ctx());
    let blast_metadata_cap = new_blast_metadata_cap(scenario.ctx());
    let display_cap = new_display_cap(&mut scenario);
    let package_admin = package_admin::new_for_testing(
        PACKAGE_ID.to_id(),
        fun_metadata_cap,
        blast_metadata_cap,
        display_cap,
        scenario.ctx(),
    );

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let package_version = scenario.take_shared<package_version::PackageVersion>();
    destroy(super_admin_cap);

    UpgradeFixture {
        scenario,
        authority,
        admin_cap,
        package_admin,
        package_version,
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

fun sign_in(self: &UpgradeFixture): acl::AdminWitness {
    self.authority.sign_in(&self.package_version, &self.admin_cap)
}

// === Helpers ===

fun package_digest(): vector<u8> {
    x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
}

fun new_fun_metadata_cap(ctx: &mut TxContext): MetadataCap<FUN_SUI> {
    let (treasury_cap, metadata_cap) = fun_coin::new_for_testing(ctx);
    destroy(treasury_cap);
    metadata_cap
}

fun new_blast_metadata_cap(ctx: &mut TxContext): MetadataCap<BLAST_SUI> {
    let (treasury_cap, metadata_cap) = blast_coin::new_for_testing(ctx);
    destroy(treasury_cap);
    metadata_cap
}

fun new_display_cap(
    scenario: &mut Scenario,
): DisplayCap<BlastSuiDepositReceipt> {
    let mut registry = scenario.take_shared<DisplayRegistry>();
    let package_version = package_version::new_for_testing(scenario.ctx());
    let display_cap = deposit_receipt::create_display(
        &package_version,
        &mut registry,
        scenario.ctx(),
    );
    test_scenario::return_shared(registry);
    destroy(package_version);
    display_cap
}
