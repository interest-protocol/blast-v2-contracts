#[test_only]
module blast_sui::package_admin_tests;

use blast_admin::acl::{Self, Authority, SuperAdminCap, AdminCap, AdminWitness};
use blast_sui::{
    blast::{Self, BLAST},
    blast_sui::{Self as blast_coin, BLAST_SUI},
    blast_sui_domain::{Self, BLAST_SUI_DOMAIN},
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
use fun upgrade_ctx as UpgradeFixture.ctx;
use fun upgrade_end as UpgradeFixture.end;
use fun upgrade_next_tx as UpgradeFixture.next_tx;
use fun wrap_ctx as WrapFixture.ctx;
use fun wrap_end as WrapFixture.end;
use fun wrap_next_tx as WrapFixture.next_tx;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const ADMIN: address = @0xAD;
const MAX_ADMINS: u64 = 16;
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

/// This package's canonical original address under test compilation.
const PACKAGE_ID: address = @0x0;
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
    created: blast_admin::events::UpgradeCustodyCreated<BLAST>,
    package_version: package_version::PackageVersion,
    authority: Authority<BLAST_SUI_DOMAIN>,
    admin_cap: AdminCap<BLAST_SUI_DOMAIN>,
}

/// Upgrade and version operations authorized by a routine admin witness.
public struct UpgradeFixture {
    scenario: Scenario,
    authority: Authority<BLAST_SUI_DOMAIN>,
    super_admin_cap: SuperAdminCap<BLAST_SUI_DOMAIN>,
    admin_cap: AdminCap<BLAST_SUI_DOMAIN>,
    package_admin: package_admin::PackageAdmin,
    package_version: package_version::PackageVersion,
}

// === Tests ===

#[test]
/// The container advances to exactly the generation this bytecode hands over
/// to, and the shared package emits the only cutover fact.
fun the_version_container_advances_to_the_next_compiled_generation() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        assert_eq!(f.package_version.version_for_testing(), 1);

        f.package_version.advance_for_testing();

        let advanced = blast_admin::events::collect_one<
            blast_admin::events::OperationalVersionAdvanced<BLAST>,
        >(0);
        let (_, _, previous_generation, new_generation) =
            advanced.operational_version_advanced_fields();
        assert_eq!(previous_generation, 1);
        assert_eq!(new_generation, 2);
        assert_eq!(new_generation, f.package_version.version_for_testing());
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
        ) = f.created.upgrade_custody_created_fields();
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
        assert_eq!(package_id, PACKAGE_ID.to_id());
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
        let admin_witness = f.authority.sign_in(&f.admin_cap);
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
        package_admin::new_empty_for_testing(f.ctx!()).share();
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
            package_admin::new_empty_for_testing(f.ctx!());
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
            package_admin::new_empty_for_testing(f.ctx!());
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
            package_admin::new_empty_for_testing(f.ctx!());
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
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidUpgradeCap,
    location = blast_admin::upgrade_custody,
)]
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
        let upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), f.ctx!());
        destroy(package_admin::new(publisher, upgrade_cap, f.ctx!()));
    });

    fixture.end();
}

// The complete native authorize/commit/advance matrix belongs to
// `blast_admin::upgrade_custody_tests`, which owns a package marker at a nonzero
// address. Under this package's test compilation `blast_sui` is `0x0`, and the
// framework refuses to authorize an upgrade for the zero package id, so these
// focused tests prove this package's wiring, provenance, and guard order.

#[test]
/// A package administrator irreversibly narrows the policy to additive.
fun package_admin_can_irreversibly_restrict_upgrade_policy() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.package_admin.restrict_to_additive(&f.package_version, &admin_witness);

        let restricted = blast_admin::events::collect_one<
            blast_admin::events::UpgradePolicyRestricted<BLAST>,
        >(0);
        let (_, _, _, _, previous_policy, new_policy) =
            restricted.upgrade_policy_restricted_fields();
        assert_eq!(previous_policy, package::compatible_policy());
        assert_eq!(new_policy, package::additive_policy());
        assert_eq!(new_policy, f.package_admin.policy_for_testing());
    });

    fixture.end();
}

#[test]
/// Immutability destroys native upgrade authority while every sealed child
/// capability and the final operational generation survive.
fun package_admin_can_permanently_destroy_native_upgrade_authority() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = f.sign_in();
        let upgrade_cap_id = f.package_admin.upgrade_cap_id_for_testing();

        f.package_admin.make_immutable(&f.package_version, &admin_witness);

        let destroyed = blast_admin::events::collect_one<
            blast_admin::events::UpgradeCapDestroyed<BLAST>,
        >(0);
        let (custodian_id, emitted_upgrade_cap_id, _, final_native_version, final_policy) =
            destroyed.upgrade_cap_destroyed_fields();
        assert_eq!(custodian_id, f.package_admin.id_for_testing());
        assert_eq!(emitted_upgrade_cap_id, upgrade_cap_id);
        assert_eq!(final_native_version, 1);
        assert_eq!(final_policy, package::compatible_policy());
        assert!(!f.package_admin.has_upgrade_cap());
        assert_eq!(f.package_version.version_for_testing(), 1);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EUpgradeCapUnavailable,
    location = blast_admin::upgrade_custody,
)]
fun policy_restriction_is_rejected_after_immutability() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_admin.make_immutable(&f.package_version, &admin_witness);

        f.package_admin.restrict_to_additive(&f.package_version, &admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
/// A live zero-role administrator cannot reach package custody.
fun a_zero_role_admin_cannot_restrict_upgrade_policy() {
    let mut fixture = start_upgrade_with_roles(0);

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.package_admin.restrict_to_additive(&f.package_version, &admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EUpgradePolicyNotMoreRestrictive,
    location = blast_admin::upgrade_custody,
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
    abort_code = blast_admin::errors::EOperationalVersionOverflow,
    location = blast_admin::operational_version,
)]
fun the_cutover_rejects_a_generation_overflow() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        f.package_version.set_for_testing(std::u64::max_value!());

        f.package_version.advance_for_testing();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun the_cutover_rejects_a_skipped_generation() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        f.package_version.set_for_testing(5);

        f.package_version.advance_for_testing();
    });

    fixture.end();
}

#[test]
/// The finalizer proves the exact next generation before it commits a receipt.
fun the_finalizer_accepts_the_exact_next_generation_before_committing() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        f.package_version.assert_next_for_testing();

        assert_eq!(f.package_version.version_for_testing(), 1);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun the_finalizer_rejects_a_skipped_generation_before_committing() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        f.package_version.set_for_testing(5);

        f.package_version.assert_next_for_testing();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidAdminCap,
    location = blast_admin::acl,
)]
fun admin_registered_in_another_registry_cannot_authorize_an_upgrade() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let (foreign_super_admin_cap, foreign_authority) = new_authority(f.ctx!());
        let admin_witness = foreign_authority.sign_in(&f.admin_cap);
        let ticket = f.package_admin.authorize_upgrade(
            &f.package_version,
            &admin_witness,
            package_digest(),
        );
        destroy(ticket);
        destroy(foreign_super_admin_cap);
        destroy(foreign_authority);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidPackageDigest,
    location = blast_admin::upgrade_custody,
)]
fun upgrade_authorization_rejects_non_digest_length() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = f.sign_in();

        let ticket = f.package_admin.authorize_upgrade(
            &f.package_version,
            &admin_witness,
            vector[],
        );

        destroy(ticket);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidAdminCap,
    location = blast_admin::acl,
)]
/// One revocation in this package's authority blocks the next sign-in.
fun a_revoked_administrator_can_no_longer_sign_in() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(PUBLISHER, |f| {
        let admin_cap_id = f.admin_cap.admin_cap_id_for_testing();

        f.authority.revoke_admin(&f.super_admin_cap, admin_cap_id);
    });

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = f.sign_in();

        destroy(admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// A stale generation aborts before the role check and before the native call.
fun stale_shared_version_rejects_old_bytecode() {
    let mut fixture = start_upgrade_with_roles(0);

    fixture.next_tx!(ADMIN, |f| {
        f.package_version.set_for_testing(2);

        let admin_witness = f.sign_in();
        let ticket = f.package_admin.authorize_upgrade(
            &f.package_version,
            &admin_witness,
            package_digest(),
        );

        destroy(ticket);
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
    let (super_admin_cap, mut authority) = new_authority(scenario.ctx());
    authority.grant_admin(&super_admin_cap, 0, PUBLISHER, scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publisher = scenario.take_from_sender<package::Publisher>();
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_SUI_DOMAIN>>();
    let upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), scenario.ctx());
    let fun_metadata_cap = new_fun_metadata_cap(scenario.ctx());
    let blast_metadata_cap = new_blast_metadata_cap(scenario.ctx());
    let display_cap = new_display_cap(&mut scenario);
    let publisher_id = object::id(&publisher);
    let upgrade_cap_id = object::id(&upgrade_cap);
    let fun_metadata_cap_id = object::id(&fun_metadata_cap);
    let blast_metadata_cap_id = object::id(&blast_metadata_cap);
    let display_cap_id = object::id(&display_cap);
    let mut package_admin = package_admin::new(publisher, upgrade_cap, scenario.ctx());
    let admin_witness = authority.sign_in(&admin_cap);
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
    let created = blast_admin::events::collect_one<
        blast_admin::events::UpgradeCustodyCreated<BLAST>,
    >(0);
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
    start_upgrade_with_roles(blast_sui_domain::package_admin_role())
}

/// The same fixture with an administrator that holds exactly `roles`.
fun start_upgrade_with_roles(roles: u64): UpgradeFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    scenario.create_system_objects();
    package_version::init_for_testing(scenario.ctx());

    assert_eq!(event::num_events(), 0);

    let (super_admin_cap, mut authority) = new_authority(scenario.ctx());
    authority.grant_admin(&super_admin_cap, roles, ADMIN, scenario.ctx());

    let fun_metadata_cap = new_fun_metadata_cap(scenario.ctx());
    let blast_metadata_cap = new_blast_metadata_cap(scenario.ctx());
    let display_cap = new_display_cap(&mut scenario);
    let package_admin = package_admin::new_for_testing(
        fun_metadata_cap,
        blast_metadata_cap,
        display_cap,
        scenario.ctx(),
    );

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_SUI_DOMAIN>>();
    let package_version = scenario.take_shared<package_version::PackageVersion>();

    UpgradeFixture {
        scenario,
        authority,
        super_admin_cap,
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

fun sign_in(self: &UpgradeFixture): AdminWitness<BLAST_SUI_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

/// Unshared Blast SUI authority state using this package's real constants.
fun new_authority(
    ctx: &mut TxContext,
): (SuperAdminCap<BLAST_SUI_DOMAIN>, Authority<BLAST_SUI_DOMAIN>) {
    acl::new_for_testing<BLAST_SUI_DOMAIN>(MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx)
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
