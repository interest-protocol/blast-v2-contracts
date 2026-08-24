#[test_only]
module blast_fun::launch_config_tests;

use blast_fun::{acl, constants, events, launch_config};
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

// === Tests ===

#[test]
fun admin_allows_migration_witness_for_launch_snapshot() {
    let mut scenario = test_scenario::begin(@0x0);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);

    let (_, _, _, migration_witness) =
        config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();

    std::unit_test::assert_eq!(
        migration_witness,
        std::type_name::with_original_ids<TEST_MIGRATION_WITNESS>(),
    );

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
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
    let config = scenario.take_shared<launch_config::LaunchConfig>();

    std::unit_test::assert_eq!(emitted_config_id, object::id(&config));
    std::unit_test::assert_eq!(max_quote_assets, constants::max_quote_assets!());
    std::unit_test::assert_eq!(
        max_migration_witnesses,
        constants::max_migration_witnesses!(),
    );
    std::unit_test::assert_eq!(quote_migration_fee_bps, 0);
    std::unit_test::assert_eq!(meme_graduation_allocation_bps, 0);
    std::unit_test::assert_eq!(config.active_quote_count_for_testing(), 0);
    std::unit_test::assert_eq!(config.migration_witness_count_for_testing(), 0);
    assert!(event::events_by_type<events::LaunchConfigCreated>().is_empty());

    config.destroy_for_testing();
    scenario.end();
}

#[test]
fun admin_allows_quote_and_launch_snapshot_uses_its_target() {
    let mut scenario = test_scenario::begin(@0x0);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
    let config_id = object::id(&config);

    config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);

    let (target, _, _, _) =
        config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
    let allowed = events::collect_one<events::QuoteAllowed>(0);
    let (emitted_config_id, quote, migration_quote_target) =
        allowed.quote_allowed_fields();

    std::unit_test::assert_eq!(target, MIGRATION_QUOTE_TARGET);
    std::unit_test::assert_eq!(emitted_config_id, config_id);
    std::unit_test::assert_eq!(
        quote,
        std::type_name::with_original_ids<TEST_QUOTE>(),
    );
    std::unit_test::assert_eq!(migration_quote_target, MIGRATION_QUOTE_TARGET);
    assert!(event::events_by_type<events::QuoteAllowed>().is_empty());

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
fun admin_update_changes_only_the_next_launch_snapshot() {
    let mut scenario = test_scenario::begin(@0x0);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
    let config_id = object::id(&config);

    config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);
    let _ = events::collect_one<events::QuoteAllowed>(0);
    let (first_snapshot, _, _, _) =
        config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();

    config.set_migration_quote_target<TEST_QUOTE>(
        &admin_witness,
        UPDATED_MIGRATION_QUOTE_TARGET,
    );

    let (next_snapshot, _, _, _) =
        config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
    let changed = events::collect_one<events::QuoteMigrationTargetChanged>(0);
    let (emitted_config_id, quote, old_target, new_target) =
        changed.quote_migration_target_changed_fields();

    std::unit_test::assert_eq!(first_snapshot, MIGRATION_QUOTE_TARGET);
    std::unit_test::assert_eq!(next_snapshot, UPDATED_MIGRATION_QUOTE_TARGET);
    std::unit_test::assert_eq!(emitted_config_id, config_id);
    std::unit_test::assert_eq!(
        quote,
        std::type_name::with_original_ids<TEST_QUOTE>(),
    );
    std::unit_test::assert_eq!(old_target, MIGRATION_QUOTE_TARGET);
    std::unit_test::assert_eq!(new_target, UPDATED_MIGRATION_QUOTE_TARGET);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
fun admin_removes_quote_from_future_launch_admission() {
    let mut scenario = test_scenario::begin(@0x0);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
    let config_id = object::id(&config);

    config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);
    let _ = events::collect_one<events::QuoteAllowed>(0);

    config.remove_quote<TEST_QUOTE>(&admin_witness);

    let removed = events::collect_one<events::QuoteRemoved>(0);
    let (emitted_config_id, quote, previous_target) =
        removed.quote_removed_fields();

    std::unit_test::assert_eq!(config.active_quote_count_for_testing(), 0);
    std::unit_test::assert_eq!(emitted_config_id, config_id);
    std::unit_test::assert_eq!(
        quote,
        std::type_name::with_original_ids<TEST_QUOTE>(),
    );
    std::unit_test::assert_eq!(previous_target, MIGRATION_QUOTE_TARGET);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
fun admin_sets_graduation_defaults_for_future_launch_snapshots() {
    let mut scenario = test_scenario::begin(@0x0);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
    let config_id = object::id(&config);

    config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);
    let _ = events::collect_one<events::QuoteAllowed>(0);
    let (
        _,
        initial_quote_migration_fee_bps,
        initial_meme_graduation_allocation_bps,
        initial_migration_witness,
    ) = config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();

    config.set_graduation_defaults(
        &admin_witness,
        QUOTE_MIGRATION_FEE_BPS,
        MEME_GRADUATION_ALLOCATION_BPS,
    );

    let (
        migration_quote_target,
        quote_migration_fee_bps,
        meme_graduation_allocation_bps,
        migration_witness,
    ) = config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
    let changed = events::collect_one<events::GraduationDefaultsChanged>(0);
    let (
        emitted_config_id,
        old_quote_migration_fee_bps,
        old_meme_graduation_allocation_bps,
        new_quote_migration_fee_bps,
        new_meme_graduation_allocation_bps,
    ) = changed.graduation_defaults_changed_fields();

    std::unit_test::assert_eq!(migration_quote_target, MIGRATION_QUOTE_TARGET);
    std::unit_test::assert_eq!(initial_quote_migration_fee_bps, 0);
    std::unit_test::assert_eq!(initial_meme_graduation_allocation_bps, 0);
    std::unit_test::assert_eq!(quote_migration_fee_bps, QUOTE_MIGRATION_FEE_BPS);
    std::unit_test::assert_eq!(
        meme_graduation_allocation_bps,
        MEME_GRADUATION_ALLOCATION_BPS,
    );
    std::unit_test::assert_eq!(initial_migration_witness, migration_witness);
    std::unit_test::assert_eq!(
        migration_witness,
        std::type_name::with_original_ids<TEST_MIGRATION_WITNESS>(),
    );
    std::unit_test::assert_eq!(emitted_config_id, config_id);
    std::unit_test::assert_eq!(old_quote_migration_fee_bps, 0);
    std::unit_test::assert_eq!(old_meme_graduation_allocation_bps, 0);
    std::unit_test::assert_eq!(new_quote_migration_fee_bps, QUOTE_MIGRATION_FEE_BPS);
    std::unit_test::assert_eq!(
        new_meme_graduation_allocation_bps,
        MEME_GRADUATION_ALLOCATION_BPS,
    );

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
fun admin_allows_migration_witness_and_emits_its_original_type_name() {
    let mut scenario = test_scenario::begin(@0x0);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
    let config_id = object::id(&config);

    config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);

    let allowed = events::collect_one<events::MigrationWitnessAllowed>(0);
    let (emitted_config_id, emitted_migration_witness) =
        allowed.migration_witness_allowed_fields();
    let migration_witness =
        std::type_name::with_original_ids<TEST_MIGRATION_WITNESS>();

    std::unit_test::assert_eq!(config.migration_witness_count_for_testing(), 1);
    std::unit_test::assert_eq!(emitted_config_id, config_id);
    std::unit_test::assert_eq!(emitted_migration_witness, migration_witness);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
fun graduation_defaults_accept_ceilings_and_independent_zero_values() {
    let mut scenario = test_scenario::begin(@0x0);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);
    let _ = events::collect_one<events::QuoteAllowed>(0);

    config.set_graduation_defaults(
        &admin_witness,
        constants::max_quote_migration_fee_bps!(),
        constants::max_meme_graduation_allocation_bps!(),
    );
    config.set_graduation_defaults(
        &admin_witness,
        0,
        constants::max_meme_graduation_allocation_bps!(),
    );
    config.set_graduation_defaults(
        &admin_witness,
        constants::max_quote_migration_fee_bps!(),
        0,
    );
    config.set_graduation_defaults(&admin_witness, 0, 0);

    let (_, quote_migration_fee_bps, meme_graduation_allocation_bps, _) =
        config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
    let changes = events::collect<events::GraduationDefaultsChanged>();

    std::unit_test::assert_eq!(quote_migration_fee_bps, 0);
    std::unit_test::assert_eq!(meme_graduation_allocation_bps, 0);
    std::unit_test::assert_eq!(changes.length(), 4);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
fun migration_witness_removal_does_not_change_an_existing_launch_snapshot() {
    let mut scenario = test_scenario::begin(@0x0);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
    let config_id = object::id(&config);

    config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);
    let (_, _, _, snapshotted_migration_witness) =
        config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();
    let _ = events::collect_one<events::MigrationWitnessAllowed>(0);

    config.remove_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);

    let removed = events::collect_one<events::MigrationWitnessRemoved>(0);
    let (emitted_config_id, emitted_migration_witness) =
        removed.migration_witness_removed_fields();

    std::unit_test::assert_eq!(config.migration_witness_count_for_testing(), 0);
    std::unit_test::assert_eq!(emitted_config_id, config_id);
    std::unit_test::assert_eq!(
        emitted_migration_witness,
        snapshotted_migration_witness,
    );

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 47)]
fun graduation_defaults_reject_quote_rate_above_ceiling_first() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.set_graduation_defaults(
        &admin_witness,
        constants::max_quote_migration_fee_bps!() + 1,
        constants::max_meme_graduation_allocation_bps!() + 1,
    );

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 48)]
fun graduation_defaults_reject_meme_rate_above_ceiling() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.set_graduation_defaults(
        &admin_witness,
        0,
        constants::max_meme_graduation_allocation_bps!() + 1,
    );

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 49)]
fun graduation_defaults_reject_unchanged_pair() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.set_graduation_defaults(&admin_witness, 0, 0);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 52)]
fun migration_witness_removal_rejects_unlisted_type() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.remove_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 50)]
fun migration_witness_admission_rejects_duplicate_type() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);
    config.allow_migration_witness<TEST_MIGRATION_WITNESS>(&admin_witness);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 42)]
fun quote_admission_rejects_zero_target_before_type_lookup() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.allow_quote<TEST_QUOTE>(&admin_witness, 0);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 43)]
fun quote_admission_rejects_duplicate_type() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    config.allow_quote<TEST_QUOTE>(&admin_witness, UPDATED_MIGRATION_QUOTE_TARGET);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 44)]
fun quote_admission_registry_is_bounded() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.allow_quote<QUOTE<Q0>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q1>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q2>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q3>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q4>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q5>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q6>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q7>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q8>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q9>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q10>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q11>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q12>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q13>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q14>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q15>>(&admin_witness, 1);
    config.allow_quote<QUOTE<Q16>>(&admin_witness, 1);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 45)]
fun target_update_rejects_quote_that_is_not_allowed() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.set_migration_quote_target<TEST_QUOTE>(
        &admin_witness,
        MIGRATION_QUOTE_TARGET,
    );

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 42)]
fun target_update_rejects_zero_before_missing_quote() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.set_migration_quote_target<TEST_QUOTE>(&admin_witness, 0);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 46)]
fun target_update_rejects_unchanged_value() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    config.set_migration_quote_target<TEST_QUOTE>(
        &admin_witness,
        MIGRATION_QUOTE_TARGET,
    );

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 45)]
fun removal_rejects_quote_that_is_not_allowed() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.remove_quote<TEST_QUOTE>(&admin_witness);

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 45)]
fun launch_snapshot_rejects_removed_quote() {
    let mut scenario = test_scenario::begin(@0x0);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    config.remove_quote<TEST_QUOTE>(&admin_witness);
    let (_, _, _, _) =
        config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 52)]
fun launch_snapshot_rejects_unlisted_migration_witness() {
    let mut scenario = test_scenario::begin(@0x0);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_config_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.allow_quote<TEST_QUOTE>(&admin_witness, MIGRATION_QUOTE_TARGET);
    let (_, _, _, _) =
        config.snapshot_for_launch<TEST_QUOTE, TEST_MIGRATION_WITNESS>();

    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

// === Private Test Helpers ===

fun new_config_with_admin(
    scenario: &mut Scenario,
): (
    acl::SuperAdminCap,
    acl::ProtocolAuthority,
    acl::AdminCap,
    launch_config::LaunchConfig,
) {
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(PUBLISHER, scenario.ctx());
    authority.add_admin(
        &super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );
    launch_config::init_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let config = scenario.take_shared<launch_config::LaunchConfig>();

    (super_admin_cap, authority, admin_cap, config)
}
