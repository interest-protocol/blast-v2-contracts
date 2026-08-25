#[test_only]
module blast_fun::launch_config_tests;

use blast_fun::{acl, constants, events, launch_config};
use std::unit_test::{assert_eq, destroy};
use sui::{
    event,
    test_scenario::{Self, Scenario},
};

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;
const MIGRATION_QUOTE_TARGET: u64 = 25_000_000;
const UPDATED_MIGRATION_QUOTE_TARGET: u64 = 40_000_000;
const QUOTE_MIGRATION_FEE_BPS: u64 = 250;
const MEME_GRADUATION_ALLOCATION_BPS: u64 = 750;

// === Test-Only Types ===

public struct TEST_QUOTE() has drop;
public struct TEST_MIGRATION_WITNESS() has drop;

public struct QUOTE<phantom Marker>() has drop;
public struct Q0() has drop;
public struct Q1() has drop;
public struct Q2() has drop;
public struct Q3() has drop;
public struct Q4() has drop;
public struct Q5() has drop;
public struct Q6() has drop;
public struct Q7() has drop;
public struct Q8() has drop;
public struct Q9() has drop;
public struct Q10() has drop;
public struct Q11() has drop;
public struct Q12() has drop;
public struct Q13() has drop;
public struct Q14() has drop;
public struct Q15() has drop;
public struct Q16() has drop;

public struct Fixture {
    scenario: Scenario,
    super_admin_cap: acl::SuperAdminCap,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
    config: launch_config::LaunchConfig,
}

// === Tests ===

#[test]
fun admin_allows_migration_witness_for_launch_snapshot() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    fixture.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);

    let (_, _, _, migration_witness) =
        fixture.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();

    assert_eq!(
        migration_witness,
        std::type_name::with_original_ids<TEST_MIGRATION_WITNESS>(),
    );

    fixture.end();
}

#[test]
fun package_init_creates_safe_bounded_launch_config() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    launch_config::init_for_testing(scenario.ctx());
    let created = events::collect_one<events::LaunchConfigCreated>(0);
    let (
        emitted_config_id,
        max_quote_assets,
        max_migration_witnesses,
        quote_migration_fee_bps,
        meme_graduation_allocation_bps,
    ) =
        created.launch_config_created_fields();

    scenario.next_tx(PUBLISHER);
    let init_config = scenario.take_shared<launch_config::LaunchConfig>();

    assert_eq!(emitted_config_id, object::id(&init_config));
    assert_eq!(max_quote_assets, constants::max_quote_assets!());
    assert_eq!(
        max_migration_witnesses,
        constants::max_migration_witnesses!(),
    );
    assert_eq!(quote_migration_fee_bps, 0);
    assert_eq!(meme_graduation_allocation_bps, 0);
    assert_eq!(init_config.allowed_quote_count_for_testing(), 0);
    assert_eq!(init_config.allowed_migration_witness_count_for_testing(), 0);
    assert!(event::events_by_type<events::LaunchConfigCreated>().is_empty());

    destroy(init_config);
    destroy(scenario);
}

#[test]
fun admin_allows_quote_and_launch_snapshot_uses_its_target() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    fixture.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);

    let (target, _, _, _) =
        fixture.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
    let allowed = events::collect_one<events::QuoteAllowed>(0);
    let (quote, migration_quote_target) = allowed.quote_allowed_fields();

    assert_eq!(target, MIGRATION_QUOTE_TARGET);
    assert_eq!(
        quote,
        std::type_name::with_original_ids<TEST_QUOTE>(),
    );
    assert_eq!(migration_quote_target, MIGRATION_QUOTE_TARGET);
    assert!(event::events_by_type<events::QuoteAllowed>().is_empty());

    fixture.end();
}

#[test]
fun allowing_an_existing_quote_updates_only_the_next_launch_snapshot() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    fixture.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);
    let _ = events::collect_one<events::QuoteAllowed>(0);
    let (first_snapshot, _, _, _) =
        fixture.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();

    fixture.config.allow_quote<TEST_QUOTE>(
        &admin_witness,
        UPDATED_MIGRATION_QUOTE_TARGET,
    );

    let (next_snapshot, _, _, _) =
        fixture.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
    let changed = events::collect_one<events::QuoteMigrationTargetChanged>(0);
    let (quote, old_target, new_target) =
        changed.quote_migration_target_changed_fields();

    assert_eq!(first_snapshot, MIGRATION_QUOTE_TARGET);
    assert_eq!(next_snapshot, UPDATED_MIGRATION_QUOTE_TARGET);
    assert_eq!(
        quote,
        std::type_name::with_original_ids<TEST_QUOTE>(),
    );
    assert_eq!(old_target, MIGRATION_QUOTE_TARGET);
    assert_eq!(new_target, UPDATED_MIGRATION_QUOTE_TARGET);

    fixture.end();
}

#[test]
fun admin_disallows_quote_from_future_launch_admission() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    fixture.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);
    let _ = events::collect_one<events::QuoteAllowed>(0);

    fixture.config.disallow_quote<TEST_QUOTE>(&admin_witness);

    let disallowed = events::collect_one<events::QuoteDisallowed>(0);
    let (quote, previous_target) = disallowed.quote_disallowed_fields();

    assert_eq!(fixture.config.allowed_quote_count_for_testing(), 0);
    assert_eq!(
        quote,
        std::type_name::with_original_ids<TEST_QUOTE>(),
    );
    assert_eq!(previous_target, MIGRATION_QUOTE_TARGET);

    fixture.end();
}

#[test]
fun admin_sets_graduation_defaults_for_future_launch_snapshots() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    fixture.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);
    let _ = events::collect_one<events::QuoteAllowed>(0);
    let (
        _,
        initial_quote_migration_fee_bps,
        initial_meme_graduation_allocation_bps,
        initial_migration_witness,
    ) = fixture.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();

    fixture.config.set_graduation_defaults(
        &admin_witness,
        QUOTE_MIGRATION_FEE_BPS,
        MEME_GRADUATION_ALLOCATION_BPS,
    );

    let (
        migration_quote_target,
        quote_migration_fee_bps,
        meme_graduation_allocation_bps,
        migration_witness,
    ) = fixture.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
    let changed = events::collect_one<events::GraduationDefaultsChanged>(0);
    let (
        old_quote_migration_fee_bps,
        old_meme_graduation_allocation_bps,
        new_quote_migration_fee_bps,
        new_meme_graduation_allocation_bps,
    ) = changed.graduation_defaults_changed_fields();

    assert_eq!(migration_quote_target, MIGRATION_QUOTE_TARGET);
    assert_eq!(initial_quote_migration_fee_bps, 0);
    assert_eq!(initial_meme_graduation_allocation_bps, 0);
    assert_eq!(quote_migration_fee_bps, QUOTE_MIGRATION_FEE_BPS);
    assert_eq!(
        meme_graduation_allocation_bps,
        MEME_GRADUATION_ALLOCATION_BPS,
    );
    assert_eq!(initial_migration_witness, migration_witness);
    assert_eq!(
        migration_witness,
        std::type_name::with_original_ids<TEST_MIGRATION_WITNESS>(),
    );
    assert_eq!(old_quote_migration_fee_bps, 0);
    assert_eq!(old_meme_graduation_allocation_bps, 0);
    assert_eq!(new_quote_migration_fee_bps, QUOTE_MIGRATION_FEE_BPS);
    assert_eq!(
        new_meme_graduation_allocation_bps,
        MEME_GRADUATION_ALLOCATION_BPS,
    );

    fixture.end();
}

#[test]
fun admin_allows_migration_witness_and_emits_its_original_type_name() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);

    let allowed = events::collect_one<events::MigrationWitnessAllowed>(0);
    let emitted_migration_witness = allowed.migration_witness_allowed_fields();
    let migration_witness =
        std::type_name::with_original_ids<TEST_MIGRATION_WITNESS>();

    assert_eq!(fixture.config.allowed_migration_witness_count_for_testing(), 1);
    assert_eq!(emitted_migration_witness, migration_witness);

    fixture.end();
}

#[test]
fun graduation_defaults_accept_ceilings_and_independent_zero_values() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    fixture.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);
    let _ = events::collect_one<events::QuoteAllowed>(0);

    fixture.config.set_graduation_defaults(
        &admin_witness,
        constants::max_quote_migration_fee_bps!(),
        constants::max_meme_graduation_allocation_bps!(),
    );
    fixture.config.set_graduation_defaults(
        &admin_witness,
        0,
        constants::max_meme_graduation_allocation_bps!(),
    );
    fixture.config.set_graduation_defaults(
        &admin_witness,
        constants::max_quote_migration_fee_bps!(),
        0,
    );
    fixture.config.set_graduation_defaults(&admin_witness, 0, 0);

    let (_, quote_migration_fee_bps, meme_graduation_allocation_bps, _) =
        fixture.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
    let changes = events::collect<events::GraduationDefaultsChanged>();

    assert_eq!(quote_migration_fee_bps, 0);
    assert_eq!(meme_graduation_allocation_bps, 0);
    assert_eq!(changes.length(), 4);

    fixture.end();
}

#[test]
fun disallowing_migration_witness_does_not_change_an_existing_launch_snapshot() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    fixture.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);
    let (_, _, _, snapshotted_migration_witness) =
        fixture.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
    let _ = events::collect_one<events::MigrationWitnessAllowed>(0);

    fixture.config.disallow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);

    let disallowed = events::collect_one<events::MigrationWitnessDisallowed>(0);
    let emitted_migration_witness = disallowed.migration_witness_disallowed_fields();

    assert_eq!(fixture.config.allowed_migration_witness_count_for_testing(), 0);
    assert_eq!(
        emitted_migration_witness,
        snapshotted_migration_witness,
    );

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 47)]
fun graduation_defaults_reject_quote_rate_above_ceiling_first() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.set_graduation_defaults(
        &admin_witness,
        constants::max_quote_migration_fee_bps!() + 1,
        constants::max_meme_graduation_allocation_bps!() + 1,
    );

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 48)]
fun graduation_defaults_reject_meme_rate_above_ceiling() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.set_graduation_defaults(
        &admin_witness,
        0,
        constants::max_meme_graduation_allocation_bps!() + 1,
    );

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 49)]
fun graduation_defaults_reject_unchanged_pair() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.set_graduation_defaults(&admin_witness, 0, 0);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 52)]
fun disallowing_migration_witness_rejects_unlisted_type() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.disallow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 50)]
fun allowing_migration_witness_rejects_duplicate_type() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);
    fixture.config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 42)]
fun allowing_quote_rejects_zero_target_before_type_lookup() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.allow_quote<TEST_QUOTE>(&admin_witness, 0);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 44)]
fun quote_allowlist_is_bounded() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.allow_quote<QUOTE<Q0>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q1>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q2>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q3>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q4>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q5>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q6>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q7>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q8>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q9>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q10>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q11>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q12>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q13>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q14>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q15>>(&admin_witness, 1);
    fixture.config.allow_quote<QUOTE<Q16>>(&admin_witness, 1);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 46)]
fun allowing_quote_rejects_unchanged_target() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    fixture.config.allow_quote<TEST_QUOTE>(
        &admin_witness,
        MIGRATION_QUOTE_TARGET,
    );

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 45)]
fun disallowing_quote_rejects_quote_that_is_not_allowed() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.disallow_quote<TEST_QUOTE>(&admin_witness);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 45)]
fun launch_snapshot_rejects_disallowed_quote() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    fixture.config.disallow_quote<TEST_QUOTE>(&admin_witness);
    let (_, _, _, _) =
        fixture.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 52)]
fun launch_snapshot_rejects_unlisted_migration_witness() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    let (_, _, _, _) =
        fixture.config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();

    fixture.end();
}

// === Private Test Helpers ===

fun start(): Fixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(PUBLISHER, scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );
    launch_config::init_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let fixture_config = scenario.take_shared<launch_config::LaunchConfig>();

    Fixture {
        scenario,
        super_admin_cap,
        authority,
        admin_cap,
        config: fixture_config,
    }
}

fun end(self: Fixture) {
    destroy(self);
}
