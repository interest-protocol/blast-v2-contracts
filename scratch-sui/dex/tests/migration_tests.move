// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_dex::migration_tests;

use blast_admin::acl::{Authority, AdminCap};
use blast_fun::{
    bps,
    creator_authority::{Self, CurveFeeCap, LpFeeCap},
    launch::{Self, Launch},
    launch_config,
    launch_ticket,
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    lp_fee_policy::{Self, LpFeePolicy},
    package_version::{Self, PackageVersion},
    runtime_config::{Self, RuntimeConfig}
};
use blast_fun_dex::{
    domain_fixture,
    math,
    migration::{Self, LockedLpVault, Witness},
    pool::{Self, Factory, Pool, Position}
};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::{clock::{Self, Clock}, coin, coin_registry::Currency, test_scenario::{Self, Scenario}};

// === Test-Only Types ===

public struct MIGRATION_TESTS() has drop;
public struct QUOTE() has drop;
public struct OtherWitness() has drop;

public struct MigrationFixture {
    scenario: Scenario,
    version: PackageVersion,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin: AdminCap<BLAST_FUN_DOMAIN>,
    cap: CurveFeeCap<MIGRATION_TESTS>,
    launch: Launch<MIGRATION_TESTS, QUOTE>,
    factory: Factory,
    currency: Currency<MIGRATION_TESTS>,
    clock: Clock,
    runtime: RuntimeConfig,
    lp_fee_policy: LpFeePolicy,
}

// === Tests ===

#[test]
fun permissionless_native_migration_locks_complete_position_and_empty_collection_is_safe() {
    let mut f = start(true);
    let launch_id = object::id(&f.launch);
    f.migrate!();
    let (_, _, migrated) = f.launch.lifecycle_for_testing();
    assert!(migrated);
    let events = sui::event::events_by_type<migration::Migrated>();
    assert_eq!(events.length(), 1);
    f.next_tx!(@0xB, |f| {
        let mut pool = f.take_pool();
        let mut vault = f.take_vault();
        let (bound_pool, position_id, _, _) = vault.snapshot_for_testing();
        assert_eq!(bound_pool, object::id(&pool));
        let (meme, quote, fees) = pool.balances_for_testing();
        assert_eq!(meme, 200_000_000_000_000_000);
        assert_eq!(quote, 25_000_000);
        assert_eq!(fees, 0);
        assert_eq!(vault.shares_for_testing(), math::initial_shares(meme, quote) - 1_000);
        let (_, burn, volume, _) = pool.policy_for_testing();
        assert_eq!(burn, 0);
        assert_eq!(volume, 0);
        let mut expected = bcs::to_bytes(&launch_id);
        expected.append(bcs::to_bytes(&object::id(&pool)));
        expected.append(bcs::to_bytes(&object::id(&vault)));
        expected.append(bcs::to_bytes(&position_id));
        expected.append(bcs::to_bytes(&meme));
        expected.append(bcs::to_bytes(&quote));
        assert_eq!(bcs::to_bytes(&events[0]), expected);
        vault.collect(&mut pool, &f.factory, &f.lp_fee_policy, f.ctx!());
        let (_, _, protocol, creator) = vault.snapshot_for_testing();
        assert_eq!(protocol, 0);
        assert_eq!(creator, 0);
        assert!(sui::event::events_by_type<migration::FeesCollected>().is_empty());
        return_pool(pool);
        return_vault(vault);
    });
    f.end();
}

#[test]
fun collected_quote_is_split_and_claimed_without_changing_locked_principal() {
    let mut f = start(true);
    f.migrate!();
    f.next_tx!(@0xB, |f| {
        let mut pool = f.take_pool();
        let mut vault = f.take_vault();
        let shares = vault.shares_for_testing();
        let input = coin::mint_for_testing<QUOTE>(1_000_000, f.ctx!());
        let (bought, refund) = pool.buy(&f.factory, input, 1, 500, 0, &f.clock, f.ctx!());
        destroy(bought);
        destroy(refund);
        let (meme_reserve, quote_reserve, fees_before) = pool.balances_for_testing();
        vault.collect(&mut pool, &f.factory, &f.lp_fee_policy, f.ctx!());
        let (_, _, protocol, creator) = vault.snapshot_for_testing();
        let (meme_after, quote_after, fees_after) = pool.balances_for_testing();
        assert_eq!(meme_reserve, meme_after);
        assert_eq!(quote_reserve, quote_after);
        assert_eq!(protocol + creator + fees_after, fees_before);
        assert!(protocol > 0 && creator > 0);
        assert_eq!(vault.shares_for_testing(), shares);
        let events = sui::event::events_by_type<migration::FeesCollected>();
        let mut expected = bcs::to_bytes(&object::id(&vault));
        expected.append(bcs::to_bytes(&(protocol + creator)));
        expected.append(bcs::to_bytes(&f.lp_fee_policy.protocol_fee_share<MIGRATION_TESTS>().value()));
        expected.append(bcs::to_bytes(&protocol));
        expected.append(bcs::to_bytes(&creator));
        assert_eq!(bcs::to_bytes(&events[0]), expected);
        let lp_fee_cap = vault.issue_lp_fee_cap_for_testing(f.ctx!());
        let (meme, quote) = vault.claim_creator_fees(&lp_fee_cap, &f.factory, f.ctx!());
        assert_eq!(meme.value(), 0);
        assert_eq!(quote.value(), creator);
        destroy(lp_fee_cap);
        destroy(meme);
        destroy(quote);
        let witness = f.authority.sign_in(&f.admin);
        let (meme, quote) = vault.claim_protocol_fees(&witness, &f.factory, f.ctx!());
        assert_eq!(meme.value(), 0);
        assert_eq!(quote.value(), protocol);
        destroy(meme);
        destroy(quote);
        let (_, _, protocol_after, creator_after) = vault.snapshot_for_testing();
        assert_eq!(protocol_after, 0);
        assert_eq!(creator_after, 0);
        let events = sui::event::events_by_type<migration::CreatorFeesClaimed>();
        let mut expected = bcs::to_bytes(&object::id(&vault));
        expected.append(bcs::to_bytes(&creator));
        assert_eq!(bcs::to_bytes(&events[0]), expected);
        let events = sui::event::events_by_type<migration::ProtocolFeesClaimed>();
        let mut expected = bcs::to_bytes(&object::id(&vault));
        expected.append(bcs::to_bytes(&protocol));
        assert_eq!(bcs::to_bytes(&events[0]), expected);
        return_pool(pool);
        return_vault(vault);
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidLaunchLifecycle,
        location = blast_fun::launch,
    ),
]
fun native_route_cannot_migrate_a_live_launch() {
    let mut f = start(false);
    f.migrate!();
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EDuplicatePool, location = blast_fun_dex::pool)]
fun duplicate_native_migration_is_rejected_before_core_lifecycle_mutation() {
    let mut f = start(true);
    f.migrate!();
    f.migrate!();
    f.end();
}

#[test]
#[expected_failure(abort_code = migration::EWrongPool, location = blast_fun_dex::migration)]
fun locked_position_rejects_a_different_pool_before_claiming_fees() {
    let mut f = start(true);
    f.migrate!();
    f.next_tx!(@0xB, |f| {
        let mut vault = f.take_vault();
        let mut other_factory = pool::new_for_testing(f.ctx!());
        let (mut other_pool, position) = pool::create_from_balances(
            &mut other_factory,
            coin::mint_for_testing<MIGRATION_TESTS>(100_000, f.ctx!()).into_balance(),
            coin::mint_for_testing<QUOTE>(100_000, f.ctx!()).into_balance(),
            0,
            &f.clock,
            f.ctx!(),
        );
        vault.collect(&mut other_pool, &f.factory, &f.lp_fee_policy, f.ctx!());
        destroy(position);
        destroy(other_pool);
        destroy(other_factory);
        return_vault(vault);
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidMigrationWitness,
        location = blast_fun::launch,
    ),
]
fun native_route_cannot_redeem_another_selected_witness() {
    let mut f = start_with_witness<OtherWitness>(true);
    f.migrate!();
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_factory_precedes_live_launch_lifecycle_failure() {
    let mut f = start(false);
    f.factory.set_version_for_testing(2);
    f.migrate!();
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_factory_stops_native_fee_claims_before_empty_ledger_failure() {
    let mut f = start(true);
    f.migrate!();
    f.next_tx!(@0xB, |f| {
        let mut vault = f.take_vault();
        f.factory.set_version_for_testing(2);
        let lp_fee_cap = creator_authority::new_lp_fee_cap_for_testing<MIGRATION_TESTS>(f.ctx!());
        let (meme, quote) = vault.claim_creator_fees(&lp_fee_cap, &f.factory, f.ctx!());
        destroy(lp_fee_cap);
        destroy(meme);
        destroy(quote);
        return_vault(vault);
    });
    f.end();
}

#[test]
fun native_route_preserves_terminal_quote_fee_and_burn_only_disposal() {
    let mut f = start_with_policy<Witness>(true, 100, true);
    f.migrate!();
    assert!(f.currency.total_supply().destroy_some() < 1_000_000_000_000_000_000);
    f.next_tx!(@0xB, |f| {
        let pool = f.take_pool();
        let (_, quote, _) = pool.balances_for_testing();
        assert_eq!(quote, 24_750_000);
        let (_, burn, _, _) = pool.policy_for_testing();
        assert_eq!(burn, 0);
        let witness = f.authority.sign_in(&f.admin);
        let (meme_fees, quote_fees) = f.launch.claim_protocol_fees(&f.version, &witness, f.ctx!());
        // Curve fees remain in core alongside its terminal migration fee.
        assert!(quote_fees.value() >= 250_000);
        destroy(meme_fees);
        destroy(quote_fees);
        return_pool(pool);
    });
    f.end();
}

#[test]
fun changing_lp_policy_never_resplits_already_collected_native_fees() {
    let mut f = start(true);
    f.migrate!();
    f.next_tx!(@0xB, |f| {
        let mut pool = f.take_pool();
        let mut vault = f.take_vault();
        let input = coin::mint_for_testing<QUOTE>(1_000_000, f.ctx!());
        let (bought, refund) = pool.buy(&f.factory, input, 1, 500, 0, &f.clock, f.ctx!());
        destroy(bought);
        destroy(refund);
        vault.collect(&mut pool, &f.factory, &f.lp_fee_policy, f.ctx!());
        let (_, _, first_protocol, first_creator) = vault.snapshot_for_testing();
        let witness = f.authority.sign_in(&f.admin);
        f.lp_fee_policy.set_protocol_fee_share(&f.version, &witness, bps::new(10_000));
        let input = coin::mint_for_testing<QUOTE>(1_000_000, f.ctx!());
        let (bought, refund) = pool.buy(&f.factory, input, 1, 500, 0, &f.clock, f.ctx!());
        destroy(bought);
        destroy(refund);
        vault.collect(&mut pool, &f.factory, &f.lp_fee_policy, f.ctx!());
        let (_, _, second_protocol, second_creator) = vault.snapshot_for_testing();
        assert!(second_protocol > first_protocol);
        assert_eq!(second_creator, first_creator);
        return_pool(pool);
        return_vault(vault);
    });
    f.end();
}

#[test]
fun native_collection_applies_the_project_lp_share_instead_of_the_trade_share() {
    let mut f = start(true);
    f.migrate!();
    f.next_tx!(@0xB, |f| {
        let mut pool = f.take_pool();
        let mut vault = f.take_vault();
        let witness = f.authority.sign_in(&f.admin);
        f.lp_fee_policy.set_project_protocol_fee_share<MIGRATION_TESTS>(&f.version, &witness, bps::new(10_000));
        let input = coin::mint_for_testing<QUOTE>(1_000_000, f.ctx!());
        let (bought, refund) = pool.buy(&f.factory, input, 1, 500, 0, &f.clock, f.ctx!());
        destroy(bought);
        destroy(refund);
        vault.collect(&mut pool, &f.factory, &f.lp_fee_policy, f.ctx!());
        let (_, _, protocol, creator) = vault.snapshot_for_testing();
        assert!(protocol > 0);
        assert_eq!(creator, 0);
        assert_eq!(f.runtime.protocol_fee_share_bps(), 5_000);
        let events = sui::event::events_by_type<migration::FeesCollected>();
        let mut expected = bcs::to_bytes(&object::id(&vault));
        expected.append(bcs::to_bytes(&protocol));
        expected.append(bcs::to_bytes(&10_000u64));
        expected.append(bcs::to_bytes(&protocol));
        expected.append(bcs::to_bytes(&0u64));
        assert_eq!(bcs::to_bytes(&events[0]), expected);
        return_pool(pool);
        return_vault(vault);
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidLaunchLifecycle,
        location = blast_fun::launch,
    ),
]
fun creator_funded_pool_rejects_live_launch_before_invalid_burn_policy() {
    let mut f = start(false);
    let (pool, position) = f.create_pool!(501);
    destroy(pool);
    destroy(position);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EInvalidLaunchLifecycle,
        location = blast_fun::launch,
    ),
]
fun creator_cannot_preempt_native_migration_with_a_ready_launch() {
    let mut f = start(true);
    let (pool, position) = f.create_pool!(501);
    destroy(pool);
    destroy(position);
    f.end();
}

#[test]
fun creator_funds_a_fresh_native_pool_after_external_migration() {
    let mut f = start_with_witness<OtherWitness>(true);
    f.finish_external!();
    let (pool, position) = f.create_pool!(0);
    let (meme, quote, fees) = pool.balances_for_testing();
    assert_eq!(meme, 100_000);
    assert_eq!(quote, 100_000);
    assert_eq!(fees, 0);
    assert_eq!(position.shares_for_testing(), 99_000);
    let (_, burn, _, _) = pool.policy_for_testing();
    assert_eq!(burn, 0);
    pool.share();
    transfer::public_transfer(position, @0xA);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EBurnPolicy, location = blast_fun_dex::pool)]
fun creator_funded_pool_cannot_enable_burn_for_fixed_currency() {
    let mut f = start_with_witness<OtherWitness>(true);
    f.finish_external!();
    let (pool, position) = f.create_pool!(1);
    destroy(pool);
    destroy(position);
    f.end();
}

#[test]
fun creator_funded_pool_accepts_bounded_burn_only_currency_policy() {
    let mut f = start_with_policy<OtherWitness>(true, 0, true);
    f.finish_external!();
    let (pool, position) = f.create_pool!(500);
    let (_, burn, _, _) = pool.policy_for_testing();
    assert_eq!(burn, 500);
    pool.share();
    transfer::public_transfer(position, @0xA);
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun creator_constructor_checks_generation_before_live_launch_and_burn_policy() {
    let mut f = start(false);
    f.factory.set_version_for_testing(2);
    let (pool, position) = f.create_pool!(501);
    destroy(pool);
    destroy(position);
    f.end();
}


#[test]
fun admin_issues_lp_fee_caps_and_each_reissue_retires_the_previous_cap() {
    let mut f = start(true);
    f.migrate!();
    f.next_tx!(@0xA, |f| {
        let mut vault = f.take_vault();
        let witness = f.authority.sign_in(&f.admin);
        vault.issue_lp_fee_cap(&witness, &f.factory, &f.version, @0xB, f.ctx!());
        let events = sui::event::events_by_type<migration::LpFeeCapIssued>();
        let mut expected = bcs::to_bytes(&object::id(&vault));
        expected.append(bcs::to_bytes(&option::none<ID>()));
        expected.append(bcs::to_bytes(&vault.lp_fee_cap_id_for_testing().destroy_some()));
        expected.append(bcs::to_bytes(&@0xB));
        assert_eq!(events.length(), 1);
        assert_eq!(bcs::to_bytes(&events[0]), expected);
        return_vault(vault);
    });
    f.next_tx!(@0xB, |f| {
        let mut vault = f.take_vault();
        let retired = f.scenario.take_from_sender<LpFeeCap<MIGRATION_TESTS>>();
        vault.assert_lp_fee_cap(&retired);
        let witness = f.authority.sign_in(&f.admin);
        vault.issue_lp_fee_cap(&witness, &f.factory, &f.version, @0xC, f.ctx!());
        let events = sui::event::events_by_type<migration::LpFeeCapIssued>();
        let mut expected = bcs::to_bytes(&object::id(&vault));
        expected.append(bcs::to_bytes(&option::some(object::id(&retired))));
        expected.append(bcs::to_bytes(&vault.lp_fee_cap_id_for_testing().destroy_some()));
        expected.append(bcs::to_bytes(&@0xC));
        assert_eq!(bcs::to_bytes(&events[0]), expected);
        destroy(retired);
        return_vault(vault);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = migration::ELpFeeCapNotLive, location = blast_fun_dex::migration)]
fun retired_lp_fee_cap_is_rejected_before_the_empty_ledger_check() {
    let mut f = start(true);
    f.migrate!();
    f.next_tx!(@0xB, |f| {
        let mut vault = f.take_vault();
        let retired = vault.issue_lp_fee_cap_for_testing(f.ctx!());
        let live = vault.issue_lp_fee_cap_for_testing(f.ctx!());
        let (meme, quote) = vault.claim_creator_fees(&retired, &f.factory, f.ctx!());
        destroy(meme);
        destroy(quote);
        destroy(retired);
        destroy(live);
        return_vault(vault);
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = migration::EInvalidLpFeeCapRecipient,
        location = blast_fun_dex::migration,
    ),
]
fun lp_fee_cap_issue_rejects_the_zero_recipient() {
    let mut f = start(true);
    f.migrate!();
    f.next_tx!(@0xA, |f| {
        let mut vault = f.take_vault();
        let witness = f.authority.sign_in(&f.admin);
        vault.issue_lp_fee_cap(&witness, &f.factory, &f.version, @0x0, f.ctx!());
        return_vault(vault);
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::ECurveFeeCapNotLive,
        location = blast_fun::launch,
    ),
]
fun creator_funded_pool_rejects_a_retired_creator_cap() {
    let mut f = start_with_witness<OtherWitness>(true);
    f.finish_external!();
    f.next_tx!(@0xA, |f| {
        let witness = f.authority.sign_in(&f.admin);
        f.launch.reassign_curve_fee_cap(&f.version, &witness, @0xC, f.ctx!());
        let (pool, position) = f.create_pool!(0);
        destroy(pool);
        destroy(position);
    });
    f.end();
}


#[test]
fun locking_destroys_the_lp_fee_cap_and_binds_native_fees_forever() {
    let mut f = start(true);
    f.migrate!();
    f.next_tx!(@0xB, |f| {
        let mut vault = f.take_vault();
        let custodian = object::new(f.ctx!());
        let lp_fee_cap = vault.issue_lp_fee_cap_for_testing(f.ctx!());
        let lp_fee_cap_id = object::id(&lp_fee_cap);
        vault.lock_creator_fees(lp_fee_cap, &custodian, &f.factory);
        let events = sui::event::events_by_type<migration::LpFeesLocked>();
        let mut expected = bcs::to_bytes(&object::id(&vault));
        expected.append(bcs::to_bytes(&lp_fee_cap_id));
        expected.append(bcs::to_bytes(&custodian.to_inner()));
        assert_eq!(bcs::to_bytes(&events[0]), expected);
        assert_eq!(vault.custodian_id_for_testing(), option::some(custodian.to_inner()));
        assert!(vault.lp_fee_cap_id_for_testing().is_none());
        custodian.delete();
        return_vault(vault);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = migration::ELpFeesLocked, location = blast_fun_dex::migration)]
fun locked_native_fees_reject_reissue_before_the_recipient_check() {
    let mut f = start(true);
    f.migrate!();
    f.next_tx!(@0xA, |f| {
        let mut vault = f.take_vault();
        let custodian = object::new(f.ctx!());
        let lp_fee_cap = vault.issue_lp_fee_cap_for_testing(f.ctx!());
        vault.lock_creator_fees(lp_fee_cap, &custodian, &f.factory);
        let witness = f.authority.sign_in(&f.admin);
        vault.issue_lp_fee_cap(&witness, &f.factory, &f.version, @0x0, f.ctx!());
        custodian.delete();
        return_vault(vault);
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = migration::ELpFeeCustodianMismatch,
        location = blast_fun_dex::migration,
    ),
]
fun wrong_custodian_is_rejected_before_the_empty_native_ledger_check() {
    let mut f = start(true);
    f.migrate!();
    f.next_tx!(@0xB, |f| {
        let mut vault = f.take_vault();
        let custodian = object::new(f.ctx!());
        let impostor = object::new(f.ctx!());
        let lp_fee_cap = vault.issue_lp_fee_cap_for_testing(f.ctx!());
        vault.lock_creator_fees(lp_fee_cap, &custodian, &f.factory);
        let (meme, quote) = vault.claim_custodied_creator_fees(&impostor, &f.factory, f.ctx!());
        destroy(meme);
        destroy(quote);
        custodian.delete();
        impostor.delete();
        return_vault(vault);
    });
    f.end();
}

// === Private Test Helpers ===

fun return_pool(pool: Pool<MIGRATION_TESTS, QUOTE>) {
    test_scenario::return_shared(pool);
}

fun return_vault(vault: LockedLpVault<MIGRATION_TESTS, QUOTE>) {
    test_scenario::return_shared(vault);
}

macro fun ctx($f: &mut MigrationFixture): &mut TxContext { let f = $f; f.scenario.ctx() }

macro fun next_tx($f: &mut MigrationFixture, $sender: address, $fn: |&mut MigrationFixture|) {
    let f = $f;
    f.scenario.next_tx($sender);
    $fn(f);
}

macro fun finish_external($f: &mut MigrationFixture) {
    let f = $f;
    let payload = f.launch.migrate<_, _, OtherWitness>(&f.version, &mut f.currency, f.ctx!());
    let (meme, quote) = payload.redeem_migration(OtherWitness());
    destroy(meme);
    destroy(quote);
}

macro fun create_pool(
    $f: &mut MigrationFixture,
    $burn: u64,
): (Pool<MIGRATION_TESTS, QUOTE>, Position<MIGRATION_TESTS, QUOTE>) {
    let f = $f;
    let meme = coin::mint_for_testing<MIGRATION_TESTS>(100_000, f.ctx!());
    let quote = coin::mint_for_testing<QUOTE>(100_000, f.ctx!());
    f.factory.create(&f.cap, &f.launch, &f.currency, meme, quote, $burn, &f.clock, f.ctx!())
}

macro fun migrate($f: &mut MigrationFixture) {
    let f = $f;
    migration::migrate(
        &mut f.launch,
        &f.version,
        &mut f.factory,
        &mut f.currency,
        &f.clock,
        f.ctx!(),
    );
}

fun take_pool(f: &MigrationFixture): Pool<MIGRATION_TESTS, QUOTE> { f.scenario.take_shared() }

fun take_vault(f: &MigrationFixture): LockedLpVault<MIGRATION_TESTS, QUOTE> {
    f.scenario.take_shared()
}

fun start(ready: bool): MigrationFixture { start_with_witness<Witness>(ready) }

fun start_with_witness<SelectedWitness: drop>(ready: bool): MigrationFixture {
    start_with_policy<SelectedWitness>(ready, 0, false)
}

fun start_with_policy<SelectedWitness: drop>(
    ready: bool,
    migration_fee: u64,
    burnable: bool,
): MigrationFixture {
    let mut scenario = test_scenario::begin(@0xA);
    let version = package_version::new_for_testing(scenario.ctx());
    let (root, mut authority) = domain_fixture::new_launchpad_authority(scenario.ctx());
    authority.grant_admin(&root, blast_fun_domain::creator_admin_role(), @0xA, scenario.ctx());
    launch_config::init_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let admin = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    let witness = authority.sign_in(&admin);
    let mut config = scenario.take_shared<launch_config::LaunchConfig>();
    config.allow_quote<QUOTE>(&version, &witness, 5_000_000, 25_000_000);
    config.allow_migration_witness<SelectedWitness>(&version, &witness);
    config.set_trade_fees(&version, &witness, bps::new(100), bps::new(100));
    config.set_graduation_defaults(&version, &witness, bps::new(migration_fee), bps::new(0), bps::new(2_000));
    let mut runtime = runtime_config::new_disabled_for_testing(scenario.ctx());
    runtime.set_protocol_fee_share(&version, &witness, bps::new(5_000));
    let mut lp_fee_policy = lp_fee_policy::new_for_testing(scenario.ctx());
    lp_fee_policy.set_protocol_fee_share(&version, &witness, bps::new(2_500));
    let clock = clock::create_for_testing(scenario.ctx());
    let ticket = launch_ticket::new(
        MIGRATION_TESTS(),
        b"TEST".to_string(),
        b"Test".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(@0xA),
        burnable,
        0,
        scenario.ctx(),
    );
    let mut launch = launch::new<MIGRATION_TESTS, QUOTE, SelectedWitness>(
        ticket,
        &version,
        &config,
        scenario.ctx(),
    );
    let (cap, metadata_cap) = launch.claim_creator_caps(
        &version,
        &runtime,
        option::none(),
        &clock,
        scenario.ctx(),
    );
    destroy(metadata_cap);
    if (ready) {
        let quote = coin::mint_for_testing<QUOTE>(30_000_000, scenario.ctx());
        let (bought, refund) = launch.buy(&version, &runtime, quote, 1, scenario.ctx());
        destroy(bought);
        destroy(refund);
    };
    let factory = pool::new_for_testing(scenario.ctx());
    test_scenario::return_shared(config);
    destroy(root);
    scenario.next_tx(@0xB);
    let currency = scenario.take_from_address<Currency<MIGRATION_TESTS>>(@0xc);
    MigrationFixture {
        scenario,
        version,
        authority,
        admin,
        cap,
        launch,
        factory,
        currency,
        clock,
        runtime,
        lp_fee_policy,
    }
}

fun end(f: MigrationFixture) {
    let MigrationFixture {
        scenario,
        version,
        authority,
        admin,
        cap,
        launch,
        factory,
        currency,
        clock,
        runtime,
        lp_fee_policy,
    } = f;
    destroy(currency);
    destroy(factory);
    destroy(launch);
    destroy(version);
    destroy(runtime);
    destroy(lp_fee_policy);
    destroy(authority);
    destroy(admin);
    destroy(cap);
    clock.destroy_for_testing();
    scenario.end();
}
