// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_sui::package_admin_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const ADMIN: address = @0xAD;

/// This package's canonical original address under test compilation.
const PACKAGE_ID: address = @0x0;

const OTHER_PACKAGE_ID: address = @0xBAD;

/// The 48-hour notice every upgrade action waits from wrap.
const INITIAL_NOTICE_MS: u64 = 172_800_000;

// === Test-Only Types ===

/// The completed production intake and the facts it emitted.
public struct WrapFixture {
    scenario: Scenario,
    package_admin: package_admin::PackageAdmin,
    package_version: blast_sui_package::PackageVersion,
    publisher_id: ID,
    upgrade_cap_id: ID,
    fun_metadata_cap_id: ID,
    blast_metadata_cap_id: ID,
    created: blast_admin::blast_admin_events::UpgradeCustodyCreated<BLAST_SUI_PACKAGE>,
}

/// Upgrade and version operations authorized by a routine admin witness.
public struct UpgradeFixture {
    scenario: Scenario,
    package_admin: package_admin::PackageAdmin,
    package_version: blast_sui_package::PackageVersion,
    clock: Clock,
}

// === Tests ===

#[test]
/// Publication keeps the canonical Publisher and generation in an owned proof and shares
/// no usable package version, so no vault operation can run before custody is sealed.
fun publication_shares_no_package_version() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    blast_sui_package::init_for_testing(scenario.ctx());

    let effects = scenario.next_tx(PUBLISHER);
    assert_eq!(effects.shared().length(), 0);
    let publication = scenario.take_from_sender<blast_sui_package::Publication>();
    assert!(publication.publisher_for_publication_testing().from_module<BLAST_SUI_PACKAGE>());
    assert!(!test_scenario::has_most_recent_shared<blast_sui_package::PackageVersion>());

    scenario.return_to_sender(publication);
    scenario.end();
}

#[test]
/// Wrap consumes the publication, seals every package capability and shares custody with
/// a fully paused current generation and the 48-hour upgrade notice.
fun wrap_seals_custody_and_shares_a_paused_version() {
    let mut fixture = start_wrap();

    fixture.wrap_next_tx!(PUBLISHER, |f| {
        let (
            package_admin_id,
            emitted_publisher_id,
            emitted_upgrade_cap_id,
            package_id,
            native_version,
            policy,
        ) = f.created.upgrade_custody_created_fields();
        assert_eq!(package_admin_id, object::id(&f.package_admin));
        assert_eq!(emitted_publisher_id, f.publisher_id);
        assert_eq!(emitted_publisher_id, f.package_admin.publisher_id_for_testing());
        assert_eq!(emitted_upgrade_cap_id, f.upgrade_cap_id);
        assert_eq!(emitted_upgrade_cap_id, f.package_admin.upgrade_cap_id_for_testing());
        assert_eq!(f.package_admin.fun_metadata_cap_id_for_testing(), f.fun_metadata_cap_id);
        assert_eq!(f.package_admin.blast_metadata_cap_id_for_testing(), f.blast_metadata_cap_id);
        f.package_admin.display_cap_id_for_testing();
        assert_eq!(package_id, PACKAGE_ID.to_id());
        assert_eq!(native_version, 1);
        assert_eq!(policy, package::compatible_policy());
        assert!(f.package_admin.has_upgrade_cap());
        assert_eq!(f.package_admin.upgrade_delay_ms(), INITIAL_NOTICE_MS);
        assert!(f.package_admin.upgrade_for_testing().pending().is_none());
        assert_eq!(f.package_version.version_for_testing(), 1);
        assert_eq!(f.package_version.paused_for_testing(), 7);
        assert!(!f.scenario.has_most_recent_for_sender<blast_sui_package::Publication>());
        assert!(test_scenario::has_most_recent_shared<Display<BlastSuiDepositReceipt>>());
    });

    fixture.wrap_end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidUpgradeCap,
    location = blast_admin::upgrade_custody,
)]
fun wrap_rejects_an_upgrade_cap_for_another_package() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    scenario.create_system_objects();

    scenario.next_tx(PUBLISHER);
    let publication = blast_sui_package::publication_for_testing(scenario.ctx());
    let upgrade_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), scenario.ctx());
    wrap(&mut scenario, publication, upgrade_cap);

    scenario.end();
}

#[test]
/// The container advances to exactly the generation this bytecode hands over
/// to, and the shared package emits the only cutover fact.
fun the_version_container_advances_to_the_next_compiled_generation() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        assert_eq!(f.package_version.version_for_testing(), 1);

        f.package_version.advance_for_testing();

        let advanced = blast_admin::blast_admin_events::collect_one<
            blast_admin::blast_admin_events::OperationalVersionAdvanced<BLAST_SUI_PACKAGE>,
        >(0);
        let (_, _, previous_generation, new_generation) =
            advanced.operational_version_advanced_fields();
        assert_eq!(previous_generation, 1);
        assert_eq!(new_generation, 2);
        assert_eq!(new_generation, f.package_version.version_for_testing());
    });

    fixture.end();
}

// The complete native authorize/commit/advance matrix belongs to
// `blast_admin::upgrade_custody_tests`, which owns a package marker at a nonzero
// address. Under this package's test compilation `blast_sui` is `0x0`, and the
// framework refuses to authorize an upgrade for the zero package id, so these
// focused tests prove this package's wiring, notice, provenance, and guard order.

#[test]
/// Immutability, after its full notice, destroys native upgrade authority while every
/// sealed child capability and the final operational generation survive.
fun immutability_after_notice_destroys_native_upgrade_authority() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = upgrade_admin();
        let upgrade_cap_id = f.package_admin.upgrade_cap_id_for_testing();

        f.package_admin.schedule_make_immutable(&f.package_version, &admin_witness, &f.clock);
        f.clock.set_for_testing(INITIAL_NOTICE_MS);
        f.package_admin.make_immutable(&f.package_version, &admin_witness, &f.clock);

        let destroyed = blast_admin::blast_admin_events::collect_one<
            blast_admin::blast_admin_events::UpgradeCapDestroyed<BLAST_SUI_PACKAGE>,
        >(0);
        let (custodian_id, emitted_upgrade_cap_id, _, final_native_version, final_policy) =
            destroyed.upgrade_cap_destroyed_fields();
        assert_eq!(custodian_id, f.package_admin.id_for_testing());
        assert_eq!(emitted_upgrade_cap_id, upgrade_cap_id);
        assert_eq!(final_native_version, 1);
        assert_eq!(final_policy, package::compatible_policy());
        assert!(!f.package_admin.has_upgrade_cap());
        f.package_admin.fun_metadata_cap_id_for_testing();
        f.package_admin.blast_metadata_cap_id_for_testing();
        f.package_admin.display_cap_id_for_testing();
        assert_eq!(f.package_version.version_for_testing(), 1);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun immutability_waits_the_full_notice() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = upgrade_admin();
        f.package_admin.schedule_make_immutable(&f.package_version, &admin_witness, &f.clock);
        f.clock.set_for_testing(INITIAL_NOTICE_MS - 1);

        f.package_admin.make_immutable(&f.package_version, &admin_witness, &f.clock);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun upgrade_authorization_waits_the_full_notice() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = upgrade_admin();
        f.package_admin.schedule_upgrade(
            &f.package_version,
            &admin_witness,
            package_digest(),
            &f.clock,
        );
        f.clock.set_for_testing(INITIAL_NOTICE_MS - 1);

        destroy(f.package_admin.authorize_upgrade(
            &f.package_version,
            &admin_witness,
            package_digest(),
            &f.clock,
        ));
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDigest, location = blast_sui::package_admin)]
fun upgrade_scheduling_rejects_a_non_digest_length() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = upgrade_admin();

        f.package_admin.schedule_upgrade(&f.package_version, &admin_witness, vector[0], &f.clock);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongUpgradeAction, location = blast_sui::package_admin)]
fun upgrade_authorization_rejects_a_digest_other_than_the_scheduled_one() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = upgrade_admin();
        f.package_admin.schedule_upgrade(
            &f.package_version,
            &admin_witness,
            package_digest(),
            &f.clock,
        );
        f.clock.set_for_testing(INITIAL_NOTICE_MS);

        destroy(f.package_admin.authorize_upgrade(
            &f.package_version,
            &admin_witness,
            x"ff0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
            &f.clock,
        ));
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongUpgradeAction, location = blast_sui::package_admin)]
fun upgrade_authorization_cannot_consume_an_immutability_action() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = upgrade_admin();
        f.package_admin.schedule_make_immutable(&f.package_version, &admin_witness, &f.clock);
        f.clock.set_for_testing(INITIAL_NOTICE_MS);

        destroy(f.package_admin.authorize_upgrade(
            &f.package_version,
            &admin_witness,
            package_digest(),
            &f.clock,
        ));
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongUpgradeAction, location = blast_sui::package_admin)]
fun immutability_cannot_consume_an_upgrade_action() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = upgrade_admin();
        f.package_admin.schedule_upgrade(
            &f.package_version,
            &admin_witness,
            package_digest(),
            &f.clock,
        );
        f.clock.set_for_testing(INITIAL_NOTICE_MS);

        f.package_admin.make_immutable(&f.package_version, &admin_witness, &f.clock);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_action)]
/// Cancellation discards even a ready action, so it can no longer run.
fun cancellation_discards_a_ready_action() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = upgrade_admin();
        f.package_admin.schedule_make_immutable(&f.package_version, &admin_witness, &f.clock);
        f.clock.set_for_testing(INITIAL_NOTICE_MS);
        f.package_admin.cancel_upgrade_action(&cancel_admin());
        assert!(f.package_admin.upgrade_for_testing().pending().is_none());
        assert_eq!(f.package_admin.upgrade_delay_ms(), INITIAL_NOTICE_MS);

        f.package_admin.make_immutable(&f.package_version, &admin_witness, &f.clock);
    });

    fixture.end();
}

#[test]
/// A notice change waits the old notice, then later actions wait the new one.
fun notice_change_waits_the_old_notice_and_governs_later_actions() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = upgrade_admin();
        let next_notice_ms = 2 * INITIAL_NOTICE_MS;
        f.package_admin.schedule_upgrade_delay(
            &f.package_version,
            &admin_witness,
            next_notice_ms,
            &f.clock,
        );
        f.clock.set_for_testing(INITIAL_NOTICE_MS);
        f.package_admin.apply_upgrade_delay(&f.package_version, &f.clock);
        assert_eq!(f.package_admin.upgrade_delay_ms(), next_notice_ms);

        f.package_admin.schedule_make_immutable(&f.package_version, &admin_witness, &f.clock);
        let ready_at_ms = f.package_admin.upgrade_for_testing().pending().borrow().ready_at_ms();
        assert_eq!(ready_at_ms, INITIAL_NOTICE_MS + next_notice_ms);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EWrongChange, location = blast_admin::delayed_action)]
fun a_notice_change_cannot_authorize_an_action() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = upgrade_admin();
        f.package_admin.schedule_upgrade_delay(&f.package_version, &admin_witness, 1, &f.clock);
        f.clock.set_for_testing(INITIAL_NOTICE_MS);

        f.package_admin.make_immutable(&f.package_version, &admin_witness, &f.clock);
    });

    fixture.end();
}

#[test]
/// When no bytecode matches the stored generation, every gated call is closed, but a
/// repair still schedules, waits its full notice, and stays cancellable.
fun a_repair_stays_reachable_when_every_bytecode_is_stale() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        // A committed upgrade advanced the generation past this bytecode's constant.
        f.package_version.set_for_testing(2);
        let admin_witness = upgrade_admin();

        f.package_admin.schedule_repair(&admin_witness, package_digest(), &f.clock);
        let pending = f.package_admin.upgrade_for_testing().pending();
        assert_eq!(pending.borrow().ready_at_ms(), INITIAL_NOTICE_MS);

        f.package_admin.cancel_upgrade_action(&cancel_admin());
        assert!(f.package_admin.upgrade_for_testing().pending().is_none());

        f.package_admin.schedule_repair(&admin_witness, package_digest(), &f.clock);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun repair_authorization_waits_the_full_notice() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        f.package_version.set_for_testing(2);
        let admin_witness = upgrade_admin();
        f.package_admin.schedule_repair(&admin_witness, package_digest(), &f.clock);
        f.clock.set_for_testing(INITIAL_NOTICE_MS - 1);

        destroy(f.package_admin.authorize_repair(&admin_witness, package_digest(), &f.clock));
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidDigest, location = blast_sui::package_admin)]
fun repair_scheduling_rejects_a_non_digest_length() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        f.package_admin.schedule_repair(&upgrade_admin(), vector[0], &f.clock);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongUpgradeAction, location = blast_sui::package_admin)]
fun repair_authorization_cannot_consume_an_upgrade_action() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = upgrade_admin();
        f.package_admin.schedule_upgrade(
            &f.package_version,
            &admin_witness,
            package_digest(),
            &f.clock,
        );
        f.clock.set_for_testing(INITIAL_NOTICE_MS);

        destroy(f.package_admin.authorize_repair(&admin_witness, package_digest(), &f.clock));
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongUpgradeAction, location = blast_sui::package_admin)]
fun upgrade_authorization_cannot_consume_a_repair_action() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let admin_witness = upgrade_admin();
        f.package_admin.schedule_repair(&admin_witness, package_digest(), &f.clock);
        f.clock.set_for_testing(INITIAL_NOTICE_MS);

        destroy(f.package_admin.authorize_upgrade(
            &f.package_version,
            &admin_witness,
            package_digest(),
            &f.clock,
        ));
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = package::EWrongUpgradeCap, location = sui::package)]
/// Outside a repair, the advancing finalizer passes its generation and repair guards and
/// reaches native custody, which rejects a receipt from another package's cap.
fun the_advancing_finalizer_reaches_custody_only_outside_a_repair() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let mut foreign_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), f.scenario.ctx());
        let ticket = foreign_cap.authorize_upgrade(package::compatible_policy(), package_digest());
        let receipt = ticket.test_upgrade();

        f.package_admin.commit_upgrade_and_advance(&mut f.package_version, &upgrade_admin(), receipt);
        destroy(foreign_cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EWrongUpgradeAction, location = blast_sui::package_admin)]
/// A receipt that `authorize_repair` did not authorize cannot commit without advancing.
fun repair_commit_rejects_a_receipt_without_repair_authorization() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        let mut foreign_cap = package::test_publish(OTHER_PACKAGE_ID.to_id(), f.scenario.ctx());
        let ticket = foreign_cap.authorize_upgrade(package::compatible_policy(), package_digest());
        let receipt = ticket.test_upgrade();

        f.package_admin.commit_repair(&upgrade_admin(), receipt);
        destroy(foreign_cap);
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
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
/// A stale generation aborts before any notice state changes.
fun stale_shared_version_rejects_old_bytecode() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        f.package_version.set_for_testing(2);

        f.package_admin.schedule_upgrade(
            &f.package_version,
            &upgrade_admin(),
            package_digest(),
            &f.clock,
        );
    });

    fixture.end();
}

#[test]
/// Pausing sets only the requested deposit flags and reports the resulting mask.
fun pause_sets_the_requested_flags() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        f.package_version.pause(&pause_admin(), 2);

        let (bits, paused) = events::collect_one<events::Paused>(0).paused_fields();
        assert_eq!(bits, 2);
        assert_eq!(paused, 2);
        assert_eq!(f.package_version.paused_for_testing(), 2);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPauseBits, location = blast_sui::blast_sui_package)]
fun pause_rejects_an_unsupported_flag() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| f.package_version.pause(&pause_admin(), 8));

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EInvalidPauseBits, location = blast_sui::blast_sui_package)]
fun pause_rejects_an_empty_mask() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| f.package_version.pause(&pause_admin(), 0));

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EPauseUnchanged, location = blast_sui::blast_sui_package)]
fun pause_rejects_flags_already_set() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        f.package_version.pause(&pause_admin(), 1);
        f.package_version.pause(&pause_admin(), 1);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun pause_rejects_a_stale_generation() {
    let mut fixture = start_upgrade();

    fixture.next_tx!(ADMIN, |f| {
        f.package_version.set_for_testing(2);
        f.package_version.pause(&pause_admin(), 1);
    });

    fixture.end();
}

// === Test Helpers ===

macro fun wrap_next_tx(
    $fixture: &mut WrapFixture,
    $sender: address,
    $fn: |&mut WrapFixture|,
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

/// Runs the production publication and intake flow and takes the shared results.
fun start_wrap(): WrapFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    scenario.create_system_objects();
    blast_sui_package::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publication = scenario.take_from_sender<blast_sui_package::Publication>();
    let publisher_id = object::id(publication.publisher_for_publication_testing());
    let upgrade_cap = package::test_publish(PACKAGE_ID.to_id(), scenario.ctx());
    let upgrade_cap_id = object::id(&upgrade_cap);
    let (fun_metadata_cap_id, blast_metadata_cap_id) = wrap(
        &mut scenario,
        publication,
        upgrade_cap,
    );
    let created = blast_admin::blast_admin_events::collect_one<
        blast_admin::blast_admin_events::UpgradeCustodyCreated<BLAST_SUI_PACKAGE>,
    >(0);

    scenario.next_tx(PUBLISHER);
    let package_admin = scenario.take_shared<package_admin::PackageAdmin>();
    let package_version = scenario.take_shared<blast_sui_package::PackageVersion>();

    WrapFixture {
        scenario,
        package_admin,
        package_version,
        publisher_id,
        upgrade_cap_id,
        fun_metadata_cap_id,
        blast_metadata_cap_id,
        created,
    }
}

/// Calls the production intake with fresh coin metadata caps and returns their IDs.
fun wrap(scenario: &mut Scenario, publication: Publication, upgrade_cap: UpgradeCap): (ID, ID) {
    let fun_metadata_cap = new_fun_metadata_cap(scenario.ctx());
    let blast_metadata_cap = new_blast_metadata_cap(scenario.ctx());
    let fun_metadata_cap_id = object::id(&fun_metadata_cap);
    let blast_metadata_cap_id = object::id(&blast_metadata_cap);
    let mut registry = scenario.take_shared<DisplayRegistry>();
    package_admin::wrap(
        publication,
        upgrade_cap,
        fun_metadata_cap,
        blast_metadata_cap,
        &mut registry,
        scenario.ctx(),
    );
    test_scenario::return_shared(registry);

    (fun_metadata_cap_id, blast_metadata_cap_id)
}

/// Builds unpaused test custody around a current package version and a zero clock.
fun start_upgrade(): UpgradeFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    scenario.create_system_objects();

    scenario.next_tx(ADMIN);
    let package_admin = package_admin::new_for_testing(
        new_fun_metadata_cap(scenario.ctx()),
        new_blast_metadata_cap(scenario.ctx()),
        new_display_cap(&mut scenario),
        scenario.ctx(),
    );
    let package_version = blast_sui_package::new_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    UpgradeFixture { scenario, package_admin, package_version, clock }
}

fun wrap_end(self: WrapFixture) {
    destroy(self);
}

fun upgrade_end(self: UpgradeFixture) {
    destroy(self);
}

fun upgrade_admin(): AdminWitness<UpgradeAdmin> {
    blast_acl::witness_for_testing()
}

fun cancel_admin(): AdminWitness<CancelAdmin> {
    blast_acl::witness_for_testing()
}

fun pause_admin(): AdminWitness<PauseAdmin> {
    blast_acl::witness_for_testing()
}

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

fun new_display_cap(scenario: &mut Scenario): DisplayCap<BlastSuiDepositReceipt> {
    let mut registry = scenario.take_shared<DisplayRegistry>();
    let display_cap = deposit_receipt::new_display(&mut registry, scenario.ctx());
    test_scenario::return_shared(registry);
    display_cap
}

// === Imports ===

use blast_admin::blast_acl::{Self, AdminWitness};

use blast_sui::{
    blast_sui::{Self as blast_coin, BLAST_SUI},
    blast_sui_domain::{CancelAdmin, PauseAdmin, UpgradeAdmin},
    blast_sui_package::{Self, BLAST_SUI_PACKAGE, Publication},
    deposit_receipt::{Self, BlastSuiDepositReceipt},
    errors,
    events,
    fun_sui::{Self as fun_coin, FUN_SUI},
    package_admin,
};

use std::unit_test::{assert_eq, destroy};

use sui::{
    clock::{Self, Clock},
    coin_registry::MetadataCap,
    display_registry::{Display, DisplayCap, DisplayRegistry},
    package::{Self, UpgradeCap},
    test_scenario::{Self, Scenario},
};

use fun upgrade_end as UpgradeFixture.end;

use fun upgrade_next_tx as UpgradeFixture.next_tx;
