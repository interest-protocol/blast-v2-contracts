#[test_only]
module blast_fun_migrators::lp_fee_authority_tests;

// === Constants ===

const CREATOR: address = @0xC0FFEE;
const ADMIN: address = @0xAD;
const NEW_CREATOR: address = @0xC7;
const ROLE_LESS_ADMIN: address = @0xBAD;
const MAX_ADMINS: u64 = 16;
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

public struct LP_FEE_AUTHORITY_TESTS() has drop;
public struct QUOTE() has drop;
public struct TestWitness() has drop;
public struct TestCustodian() has drop;
public struct OtherCustodian() has drop;

/// A migrated launch whose payload created the pending authority of one unshared vault.
public struct AuthorityFixture {
    scenario: Scenario,
    version: PackageVersion,
    migrators_version: MigratorsVersion,
    authority: Authority<LAUNCHPAD_DOMAIN>,
    admin_cap: AdminCap<LAUNCHPAD_DOMAIN>,
    launch: Launch<LP_FEE_AUTHORITY_TESTS, QUOTE>,
    curve_fee_cap: Option<CurveFeeCap<LP_FEE_AUTHORITY_TESTS>>,
    vault: LpVault<LP_FEE_AUTHORITY_TESTS, QUOTE>,
}

// === Tests ===

#[test]
fun migration_payload_creates_a_pending_authority_that_the_curve_fee_holder_claims() {
    let mut fixture = start();
    let f = &mut fixture;
    assert!(f.vault.is_lp_fee_authority_pending_for_testing());

    let lp_fee_cap = f.claim();

    let claimed = sui::event::events_by_type<events::LpFeeCapClaimed>();
    let claimant = CREATOR;
    let mut expected = bcs::to_bytes(&object::id(&f.vault));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<LP_FEE_AUTHORITY_TESTS>()));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<QUOTE>()));
    expected.append(bcs::to_bytes(&object::id(&lp_fee_cap)));
    expected.append(bcs::to_bytes(&claimant));
    assert_eq!(claimed.length(), 1);
    assert_eq!(bcs::to_bytes(&claimed[0]), expected);
    assert_eq!(f.vault.lp_fee_cap_id_for_testing(), option::some(object::id(&lp_fee_cap)));
    f.vault.assert_lp_fee_cap(&lp_fee_cap);

    destroy(lp_fee_cap);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_authority::ELpFeeAuthorityNotPending,
    location = blast_fun_migrators::lp_fee_authority,
)]
fun the_migration_born_cap_can_be_claimed_only_once() {
    let mut fixture = start();
    let f = &mut fixture;

    let first = f.claim();
    let second = f.claim();

    destroy(first);
    destroy(second);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ECurveFeeCapNotLive,
    location = blast_fun::launch,
)]
fun a_retired_curve_fee_cap_cannot_claim_the_lp_fee_cap() {
    let mut fixture = start();
    let f = &mut fixture;
    let admin_witness = f.sign_in();

    f.launch.reassign_curve_fee_cap(&f.version, &admin_witness, NEW_CREATOR, f.ctx!());
    let lp_fee_cap = f.claim();

    destroy(lp_fee_cap);
    fixture.end();
}

#[test]
fun a_launch_custodian_binds_pending_lp_fees_without_a_cap() {
    let mut fixture = start();
    let f = &mut fixture;
    let curve_fee_cap = f.take_curve_fee_cap();

    f.launch.lock_creator_fees(&f.version, curve_fee_cap, TestCustodian());
    f.vault.lock_pending_creator_fees(&f.migrators_version, &f.launch, TestCustodian());

    let locked = sui::event::events_by_type<events::LpFeesLocked>();
    let mut expected = bcs::to_bytes(&object::id(&f.vault));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<LP_FEE_AUTHORITY_TESTS>()));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<QUOTE>()));
    expected.append(bcs::to_bytes(&option::none<ID>()));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<TestCustodian>()));
    assert_eq!(locked.length(), 1);
    assert_eq!(bcs::to_bytes(&locked[0]), expected);
    assert_eq!(
        f.vault.custodian_for_testing(),
        option::some(type_name::with_original_ids<TestCustodian>()),
    );
    assert!(f.vault.lp_fee_cap_id_for_testing().is_none());

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ECreatorCustodianMismatch,
    location = blast_fun::launch,
)]
fun an_object_that_does_not_custody_curve_fees_cannot_bind_pending_lp_fees() {
    let mut fixture = start();
    let f = &mut fixture;

    f.vault.lock_pending_creator_fees(&f.migrators_version, &f.launch, OtherCustodian());

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_authority::ELpFeeAuthorityNotPending,
    location = blast_fun_migrators::lp_fee_authority,
)]
fun a_claimed_cap_prevents_binding_pending_fees_without_it() {
    let mut fixture = start();
    let f = &mut fixture;
    let lp_fee_cap = f.claim();
    let curve_fee_cap = f.take_curve_fee_cap();

    f.launch.lock_creator_fees(&f.version, curve_fee_cap, TestCustodian());
    f.vault.lock_pending_creator_fees(&f.migrators_version, &f.launch, TestCustodian());

    destroy(lp_fee_cap);
    fixture.end();
}

#[test]
fun admin_reissue_retires_the_claimed_cap() {
    let mut fixture = start();
    let f = &mut fixture;
    let claimed = f.claim();
    let admin_witness = f.sign_in();

    f.vault.issue_lp_fee_cap(
        &f.migrators_version,
        &admin_witness,
        NEW_CREATOR,
        f.ctx!(),
    );

    let issued = sui::event::events_by_type<events::LpFeeCapIssued>();
    let recipient = NEW_CREATOR;
    let mut expected = bcs::to_bytes(&object::id(&f.vault));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<LP_FEE_AUTHORITY_TESTS>()));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<QUOTE>()));
    expected.append(bcs::to_bytes(&option::some(object::id(&claimed))));
    expected.append(bcs::to_bytes(&f.vault.lp_fee_cap_id_for_testing().destroy_some()));
    expected.append(bcs::to_bytes(&recipient));
    assert_eq!(issued.length(), 1);
    assert_eq!(bcs::to_bytes(&issued[0]), expected);

    destroy(claimed);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_authority::ELpFeeCapNotLive,
    location = blast_fun_migrators::lp_fee_authority,
)]
fun a_reissue_rejects_the_previously_claimed_cap_before_the_empty_ledger_check() {
    let mut fixture = start();
    let f = &mut fixture;
    let claimed = f.claim();
    let admin_witness = f.sign_in();

    f.vault.issue_lp_fee_cap(
        &f.migrators_version,
        &admin_witness,
        NEW_CREATOR,
        f.ctx!(),
    );
    let (meme, quote) = f.vault.claim_creator_fees(
        &f.migrators_version,
        &claimed,
        f.ctx!(),
    );

    destroy(meme);
    destroy(quote);
    destroy(claimed);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::acl,
)]
fun reissue_requires_the_creator_admin_role() {
    let mut fixture = start();
    let f = &mut fixture;
    let claimed = f.claim();
    let (other, role_less_cap) = f.new_role_less_admin();
    let admin_witness = other.sign_in(&role_less_cap);
    f.vault.issue_lp_fee_cap(
        &f.migrators_version,
        &admin_witness,
        NEW_CREATOR,
        f.ctx!(),
    );

    destroy(claimed);
    destroy(other);
    destroy(role_less_cap);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_authority::ELpFeesFollowTheCurveFeeCap,
    location = blast_fun_migrators::lp_fee_authority,
)]
fun an_admin_cannot_reissue_pending_lp_fees_away_from_the_curve_fee_holder() {
    let mut fixture = start();
    let f = &mut fixture;
    let admin_witness = f.sign_in();

    f.vault.issue_lp_fee_cap(
        &f.migrators_version,
        &admin_witness,
        NEW_CREATOR,
        f.ctx!(),
    );

    fixture.end();
}

#[test]
fun a_reassigned_curve_fee_holder_claims_the_pending_lp_fee_cap() {
    let mut fixture = start();
    let f = &mut fixture;
    let stale_curve_fee_cap = f.take_curve_fee_cap();
    let admin_witness = f.sign_in();

    f.launch.reassign_curve_fee_cap(&f.version, &admin_witness, NEW_CREATOR, f.ctx!());
    f.scenario.next_tx(NEW_CREATOR);
    let curve_fee_cap = f.scenario.take_from_sender<CurveFeeCap<LP_FEE_AUTHORITY_TESTS>>();
    let lp_fee_cap = f.vault.claim_lp_fee_cap(
        &f.migrators_version,
        &f.launch,
        &curve_fee_cap,
        f.ctx!(),
    );

    assert_eq!(f.vault.lp_fee_cap_id_for_testing(), option::some(object::id(&lp_fee_cap)));

    destroy(stale_curve_fee_cap);
    destroy(curve_fee_cap);
    destroy(lp_fee_cap);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_authority::ELpFeesFollowTheCurveFeeCap,
    location = blast_fun_migrators::lp_fee_authority,
)]
fun pending_fees_of_a_custodied_launch_reject_reissue_before_the_role_check() {
    let mut fixture = start();
    let f = &mut fixture;
    let curve_fee_cap = f.take_curve_fee_cap();

    f.launch.lock_creator_fees(&f.version, curve_fee_cap, TestCustodian());
    let (other, role_less_cap) = f.new_role_less_admin();
    let admin_witness = other.sign_in(&role_less_cap);
    f.vault.issue_lp_fee_cap(
        &f.migrators_version,
        &admin_witness,
        NEW_CREATOR,
        f.ctx!(),
    );

    destroy(other);
    destroy(role_less_cap);
    fixture.end();
}

#[test]
fun a_claimed_cap_stays_reissuable_after_launch_fees_are_custodied() {
    let mut fixture = start();
    let f = &mut fixture;
    let claimed = f.claim();
    let curve_fee_cap = f.take_curve_fee_cap();
    let admin_witness = f.sign_in();

    f.launch.lock_creator_fees(&f.version, curve_fee_cap, TestCustodian());
    f.vault.issue_lp_fee_cap(
        &f.migrators_version,
        &admin_witness,
        NEW_CREATOR,
        f.ctx!(),
    );

    let live_lp_fee_cap_id = f.vault.lp_fee_cap_id_for_testing();
    assert!(live_lp_fee_cap_id.is_some());
    assert!(live_lp_fee_cap_id != option::some(object::id(&claimed)));

    destroy(claimed);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = vault::EInvalidLpFeeCapRecipient,
    location = blast_fun_migrators::vault,
)]
fun reissue_rejects_the_zero_recipient() {
    let mut fixture = start();
    let f = &mut fixture;
    let admin_witness = f.sign_in();

    f.vault.issue_lp_fee_cap(
        &f.migrators_version,
        &admin_witness,
        @0x0,
        f.ctx!(),
    );

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_authority::ELpFeesLocked,
    location = blast_fun_migrators::lp_fee_authority,
)]
fun locked_lp_fees_reject_reissue_before_the_recipient_check() {
    let mut fixture = start();
    let f = &mut fixture;
    let lp_fee_cap = f.claim();
    let admin_witness = f.sign_in();

    f.vault.lock_creator_fees(&f.migrators_version, lp_fee_cap, TestCustodian());
    f.vault.issue_lp_fee_cap(
        &f.migrators_version,
        &admin_witness,
        @0x0,
        f.ctx!(),
    );

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_authority::EInvalidLpFeeCustodian,
    location = blast_fun_migrators::lp_fee_authority,
)]
fun locking_rejects_a_primitive_custodian_witness() {
    let mut fixture = start();
    let f = &mut fixture;
    let lp_fee_cap = f.claim();

    f.vault.lock_creator_fees(&f.migrators_version, lp_fee_cap, 0u64);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_authority::EInvalidLpFeeCustodian,
    location = blast_fun_migrators::lp_fee_authority,
)]
fun locking_rejects_a_vector_custodian_witness() {
    let mut fixture = start();
    let f = &mut fixture;
    let lp_fee_cap = f.claim();

    f.vault.lock_creator_fees(&f.migrators_version, lp_fee_cap, vector[0u8]);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_authority::EInvalidLpFeeCustodian,
    location = blast_fun_migrators::lp_fee_authority,
)]
fun locking_rejects_a_publicly_constructible_framework_witness() {
    let mut fixture = start();
    let f = &mut fixture;
    let lp_fee_cap = f.claim();

    f.vault.lock_creator_fees(&f.migrators_version, lp_fee_cap, option::none<TestCustodian>());

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ECreatorCustodianMismatch,
    location = blast_fun::launch,
)]
fun a_primitive_witness_cannot_bind_pending_lp_fees() {
    let mut fixture = start();
    let f = &mut fixture;
    let curve_fee_cap = f.take_curve_fee_cap();

    f.launch.lock_creator_fees(&f.version, curve_fee_cap, TestCustodian());
    f.vault.lock_pending_creator_fees(&f.migrators_version, &f.launch, 0u64);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = vault::EInvalidLpFeeCapRecipient,
    location = blast_fun_migrators::vault,
)]
fun reissue_rejects_the_zero_recipient_before_the_pending_check() {
    let mut fixture = start();
    let f = &mut fixture;
    let curve_fee_cap = f.take_curve_fee_cap();
    let admin_witness = f.sign_in();

    f.launch.lock_creator_fees(&f.version, curve_fee_cap, TestCustodian());
    f.vault.issue_lp_fee_cap(
        &f.migrators_version,
        &admin_witness,
        @0x0,
        f.ctx!(),
    );

    fixture.end();
}

// === Private Test Helpers ===

macro fun ctx($self: &mut AuthorityFixture): &mut TxContext {
    let self = $self;

    self.scenario.ctx()
}

fun authority_take_curve_fee_cap(
    self: &mut AuthorityFixture,
): CurveFeeCap<LP_FEE_AUTHORITY_TESTS> {
    self.curve_fee_cap.extract()
}

fun start(): AuthorityFixture {
    let mut scenario = test_scenario::begin(ADMIN);
    let version = package_version::new_for_testing(scenario.ctx());
    let migrators_version = migrators_version::new_for_testing(scenario.ctx());
    let (root, mut authority) = acl::new_for_testing<LAUNCHPAD_DOMAIN>(
        MAX_ADMINS,
        ROOT_TRANSFER_DELAY_MS,
        scenario.ctx(),
    );
    authority.grant_admin(&root, launchpad_domain::creator_admin_role(), ADMIN, scenario.ctx());
    destroy(root);
    launch_config::init_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<LAUNCHPAD_DOMAIN>>();
    let admin_witness = authority.sign_in(&admin_cap);
    let mut config = scenario.take_shared<LaunchConfig>();
    config.allow_quote<QUOTE>(&version, &admin_witness, 5_000_000, 25_000_000);
    config.allow_migration_witness<TestWitness>(&version, &admin_witness);
    config.set_trade_fees(&version, &admin_witness, bps::new(100), bps::new(100));
    config.set_graduation_defaults(
        &version,
        &admin_witness,
        bps::new(0),
        bps::new(0),
        bps::new(2_000),
    );
    let runtime = runtime_config::new_disabled_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let ticket = launch_ticket::new(
        LP_FEE_AUTHORITY_TESTS(),
        b"TEST".to_string(),
        b"Test".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(CREATOR),
        false,
        0,
        scenario.ctx(),
    );
    let mut launch = launch::new<LP_FEE_AUTHORITY_TESTS, QUOTE, TestWitness>(
        ticket,
        &version,
        &config,
        scenario.ctx(),
    );
    test_scenario::return_shared(config);

    scenario.next_tx(CREATOR);
    let mut currency = scenario.take_from_address<Currency<LP_FEE_AUTHORITY_TESTS>>(@0xc);
    let (curve_fee_cap, metadata_cap) = launch.claim_creator_caps(
        &version,
        &runtime,
        option::none(),
        &clock,
        scenario.ctx(),
    );
    let quote_in = coin::mint_for_testing<QUOTE>(30_000_000, scenario.ctx());
    let (bought, refund) = launch.buy(&version, &runtime, quote_in, 1, scenario.ctx());
    let payload = launch.migrate<_, _, TestWitness>(&version, &mut currency, scenario.ctx());
    let lp_fee_authority = lp_fee_authority::new(&payload, TestWitness());
    let (meme, quote) = payload.redeem_migration(TestWitness());
    let vault = vault::prepare(lp_fee_authority, meme, quote, scenario.ctx());

    destroy(metadata_cap);
    destroy(bought);
    destroy(refund);
    destroy(currency);
    destroy(runtime);
    clock.destroy_for_testing();

    AuthorityFixture {
        scenario,
        version,
        migrators_version,
        authority,
        admin_cap,
        launch,
        curve_fee_cap: option::some(curve_fee_cap),
        vault,
    }
}

fun claim(self: &mut AuthorityFixture): LpFeeCap<LP_FEE_AUTHORITY_TESTS> {
    self.vault.claim_lp_fee_cap(
        &self.migrators_version,
        &self.launch,
        self.curve_fee_cap.borrow(),
        self.ctx!(),
    )
}

/// Separate live administration whose only admin lacks the creator-admin role.
fun new_role_less_admin(
    self: &mut AuthorityFixture,
): (Authority<LAUNCHPAD_DOMAIN>, AdminCap<LAUNCHPAD_DOMAIN>) {
    let (root, mut other) = acl::new_for_testing<LAUNCHPAD_DOMAIN>(
        MAX_ADMINS,
        ROOT_TRANSFER_DELAY_MS,
        self.ctx!(),
    );
    other.grant_admin(
        &root,
        launchpad_domain::package_admin_role(),
        ROLE_LESS_ADMIN,
        self.ctx!(),
    );
    destroy(root);
    self.scenario.next_tx(ROLE_LESS_ADMIN);
    let role_less_cap = self.scenario.take_from_sender<AdminCap<LAUNCHPAD_DOMAIN>>();

    (other, role_less_cap)
}

fun sign_in(self: &AuthorityFixture): AdminWitness<LAUNCHPAD_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun end(self: AuthorityFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap, AdminWitness};

use blast_fun::{
    bps,
    creator_authority::{Self, CurveFeeCap},
    launch::{Self, Launch},
    launch_config::{Self, LaunchConfig},
    launch_ticket,
    launchpad_domain::{Self, LAUNCHPAD_DOMAIN},
    package_version::{Self, PackageVersion},
    runtime_config,
};

use blast_fun_migrators::{
    events,
    lp_fee_authority::{Self, LpFeeCap},
    package_version::{Self as migrators_version, PackageVersion as MigratorsVersion},
    vault::{Self, LpVault},
};

use std::{bcs, type_name, unit_test::{assert_eq, destroy}};

use sui::{clock, coin, coin_registry::Currency, test_scenario::{Self, Scenario}};

use fun authority_take_curve_fee_cap as AuthorityFixture.take_curve_fee_cap;
