// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// T-010 conformance: a sealed mock adapter migrates in one transaction and locks the position and
/// the residuals in a shared vault that later splits collections under the launch's fee split.
module blast_fun_migrators::atomic_migration_tests;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct ATOMIC_MIGRATION_TESTS has drop {}

public struct QUOTE() has drop;

/// The mock adapter's sealed witness, which is also its vault venue marker.
public struct Venue() has drop;

public struct OtherVenue() has drop;

public struct MockPool has key { id: UID }

/// Venue position owns exactly the supplied principal; the vault separately owns residuals.
public struct MockPosition<phantom Meme, phantom Quote> has key, store {
    id: UID,
    pool_id: ID,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    liquidity: u128,
}

public struct Fixture {
    scenario: Scenario,
    version: PackageVersion,
    migrators_version: MigratorsVersion,
    runtime: RuntimeConfig,
    clock: Clock,
    launch_id: ID,
}

// === Tests ===

#[test]
fun single_ptb_sealed_mock_adapter_keeps_principal_and_residuals_in_vault_custody() {
    let mut f = start();
    reach_migration(&mut f);

    f.scenario.next_tx(TESTER);
    let mut launch = f.take_launch();
    let mut currency = f.take_currency();
    let (_, quote_before, _, allocated_before) = launch.balances_for_testing();
    mock_adapter(&mut launch, &f.version, &mut currency, f.scenario.ctx());

    assert!(!launch.is_live_for_testing() && !launch.is_migration_ready_for_testing());
    assert!(launch.is_migrated_for_testing());
    let (_, quote_after, _, allocated_after) = launch.balances_for_testing();
    assert_eq!(quote_after, 0);
    assert_eq!(allocated_after, 0);
    // Only project recipients are reported; Blast's zero fee remains internal to the launch.
    assert_eq!(collect<events::MigrationAllocationPaid>().length(), 1);
    assert_eq!(collect<events::Migrated>().length(), 1);
    assert_eq!(event::events_by_type<blast_events::VaultCreated>().length(), 1);

    let fee_split = launch.lp_fee_split();
    test_scenario::return_shared(launch);
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    f.scenario.next_tx(TESTER);
    let mut vault = f.scenario.take_shared<LpVault<ATOMIC_MIGRATION_TESTS, QUOTE>>();
    assert_eq!(vault.protocol_meme_residual_for_testing(), 1);
    assert_eq!(vault.protocol_quote_residual_for_testing(), 1);
    assert_eq!(vault.generation_for_testing(), 0);
    assert_eq!(vault.fee_split_for_testing(), fee_split);
    assert_eq!(fee_split, creator_split());
    let pool_id = vault.pool_id();
    let position_id = vault.position_id_for_testing<_, _, Venue>().destroy_some();
    let position = vault.position_mut<
        ATOMIC_MIGRATION_TESTS,
        QUOTE,
        Venue,
        MockPosition<ATOMIC_MIGRATION_TESTS, QUOTE>,
    >(&Venue());
    assert_eq!(object::id(position), position_id);
    assert_eq!(position.pool_id, pool_id);
    // Two thirds of the pooled Meme and nine tenths of the terminal Quote are the LP principal.
    assert_eq!(position.meme.value() + 1, allocated_before * 2 / 3);
    assert_eq!(position.quote.value() + 1, quote_before * 9 / 10);
    assert_eq!(position.liquidity, 1);
    test_scenario::return_shared(vault);

    f.end();
}

#[test]
fun the_migrated_vault_splits_later_collections_and_updates_its_split_under_the_curve_fee_cap() {
    let mut f = start();
    reach_migration(&mut f);

    f.scenario.next_tx(TESTER);
    let mut launch = f.take_launch();
    let mut currency = f.take_currency();
    mock_adapter(&mut launch, &f.version, &mut currency, f.scenario.ctx());
    test_scenario::return_shared(launch);
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    f.scenario.next_tx(CREATOR);
    let mut launch = f.take_launch();
    let (curve_fee_cap, metadata_cap) = launch.claim_creator_caps(
        &f.version,
        &f.runtime,
        option::none(),
        &f.clock,
        f.scenario.ctx(),
    );
    destroy(metadata_cap);
    test_scenario::return_shared(launch);

    // The vault splits under the fee split it copied from the launch, then commits the next one.
    f.scenario.next_tx(TESTER);
    let launch = f.take_launch();
    let mut vault = f.scenario.take_shared<LpVault<ATOMIC_MIGRATION_TESTS, QUOTE>>();
    let policy = f.scenario.take_shared<LpFeePolicy>();
    let mut currency = f.take_currency();
    vault.split_fees(
        &policy,
        &mut currency,
        balance::create_for_testing(100),
        balance::create_for_testing(200),
        f.scenario.ctx(),
    );
    let next_split = allocation::fee_split(
        bps::new(0),
        bps::new(0),
        bps::new(0),
        bps::new(0),
        vector[allocation::route(ADMIN, bps::new(10_000))],
    );
    vault.assert_fee_split_update(&launch, &curve_fee_cap, next_split);
    vault.update_fee_split(next_split);
    vault.split_fees(
        &policy,
        &mut currency,
        balance::create_for_testing(3),
        balance::create_for_testing(4),
        f.scenario.ctx(),
    );
    assert_eq!(vault.generation_for_testing(), 1);
    assert_eq!(vault.fee_split_for_testing(), next_split);
    let (creator_meme, creator_quote) = vault.creator_balances_for_testing();
    assert_eq!(creator_meme, 100);
    assert_eq!(creator_quote, 200);
    assert_eq!(event::events_by_type<blast_events::FeesCollected>().length(), 2);
    assert_eq!(event::events_by_type<blast_events::FeeSplitChanged>().length(), 1);
    let (meme, quote) = vault.claim_creator_fees(
        &f.migrators_version,
        &launch,
        &curve_fee_cap,
        f.scenario.ctx(),
    );
    assert_eq!(meme.burn_for_testing(), 100);
    assert_eq!(quote.burn_for_testing(), 200);
    destroy(curve_fee_cap);
    test_scenario::return_shared(launch);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(policy);
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    f.scenario.next_tx(ADMIN);
    assert_eq!(f.scenario.take_from_sender<Coin<ATOMIC_MIGRATION_TESTS>>().burn_for_testing(), 3);
    assert_eq!(f.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 4);

    f.end();
}

#[test, expected_failure(
    abort_code = blast_fun::errors::EInvalidMigrationWitness,
    location = blast_fun::launch,
)]
fun another_adapter_cannot_migrate() {
    let mut f = start();
    reach_migration(&mut f);

    f.scenario.next_tx(TESTER);
    let mut launch = f.take_launch();
    let mut currency = f.take_currency();
    let (_meme, _quote) = launch.migrate(&f.version, &mut currency, OtherVenue(), f.scenario.ctx());
    abort EUnexpectedSuccess
}

#[test, expected_failure(
    abort_code = blast_fun_migrators::vault::EZeroLiquidity,
    location = blast_fun_migrators::vault,
)]
fun zero_liquidity_aborts_the_migration() {
    let mut f = start();
    reach_migration(&mut f);

    f.scenario.next_tx(TESTER);
    let mut launch = f.take_launch();
    let mut currency = f.take_currency();
    mock_adapter_with(&mut launch, &f.version, &mut currency, 0, f.scenario.ctx());
    abort EUnexpectedSuccess
}

// === Test Helpers ===

/// The mock adapter constructs and consumes its sealed witness and returns no protected value.
public fun mock_adapter(
    launch: &mut Launch<ATOMIC_MIGRATION_TESTS, QUOTE>,
    version: &PackageVersion,
    currency: &mut Currency<ATOMIC_MIGRATION_TESTS>,
    ctx: &mut TxContext,
) {
    mock_adapter_with(launch, version, currency, 1, ctx)
}

/// Migrate, seed a mock position holding `liquidity` with one residual unit per asset kept in the
/// vault, attach it, then share the vault and pool.
fun mock_adapter_with(
    launch: &mut Launch<ATOMIC_MIGRATION_TESTS, QUOTE>,
    version: &PackageVersion,
    currency: &mut Currency<ATOMIC_MIGRATION_TESTS>,
    liquidity: u128,
    ctx: &mut TxContext,
) {
    let (mut meme, mut quote) = launch.migrate(version, currency, Venue(), ctx);
    let residual_meme = meme.split(1);
    let residual_quote = quote.split(1);
    let pool = MockPool { id: object::new(ctx) };
    let pool_id = object::id(&pool);
    let position = MockPosition { id: object::new(ctx), pool_id, meme, quote, liquidity };
    vault::create(
        launch,
        &Venue(),
        pool_id,
        position,
        liquidity,
        residual_meme,
        residual_quote,
        ctx,
    );
    transfer::share_object(pool);
}

fun start(): Fixture {
    let mut scenario = test_scenario::begin(@0x0);
    let version = package_version::new_for_testing(scenario.ctx());
    let migrators_version = migrators_version::new_for_testing(scenario.ctx());
    launch_config::init_for_testing(scenario.ctx());
    lp_fee_policy::init_for_testing(scenario.ctx());
    let runtime = runtime_config::new_disabled_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let mut config = scenario.take_shared<LaunchConfig>();
    config.set_quote_allowed<QUOTE>(&version, &blast_acl::witness_for_testing<ListingAdmin>(), true);
    config.set_migration_witness_allowed<Venue>(
        &version,
        &blast_acl::witness_for_testing<AdapterAdmin>(),
        true,
    );
    config.set_trade_fees(
        &version,
        &blast_acl::witness_for_testing<FeeAdmin>(),
        bps::new(100),
        bps::new(100),
    );
    let launch_id = share_launch(&mut scenario, &version, &config, &clock);
    test_scenario::return_shared(config);

    Fixture {
        scenario,
        version,
        migrators_version,
        runtime,
        clock,
        launch_id,
    }
}

/// Starts the launch for the mock adapter's witness, finalizes it once the Coin Registry holds
/// the currency, and shares it.
fun share_launch(
    scenario: &mut Scenario,
    version: &PackageVersion,
    config: &LaunchConfig,
    clock: &Clock,
): ID {
    let ticket = launch_ticket::new(
        test_utils::create_one_time_witness<ATOMIC_MIGRATION_TESTS>(),
        9,
        b"TEST".to_string(),
        b"Atomic migration".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(CREATOR),
        false,
        0,
        scenario.ctx(),
    );
    let sender = scenario.sender();
    scenario.next_tx(sender);
    let mut currency = scenario.take_from_address<Currency<_>>(COIN_REGISTRY);
    let mut initializer = launch::new<_, QUOTE, _>(
        ticket,
        version,
        config,
        Venue(),
        POOL_TICK_SPACING,
        POOL_FEE_RATE,
    );
    initializer.set_virtual_quote(5_000_000);
    initializer.set_graduation_target(TARGET);
    initializer.set_allocation_plan(
        allocation::plan(
            bps::new(7_000),
            bps::new(2_000),
            bps::new(9_000),
            vector[allocation::recipient(CREATOR, bps::new(1_000), bps::new(1_000))],
        ),
    );
    initializer.set_lp_fee_split(creator_split());
    let creation_fee = coin::zero(scenario.ctx());
    let launch = initializer.finalize(&mut currency, config, creation_fee, scenario.ctx());
    let launch_id = object::id(&launch);
    launch.share(clock);
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    launch_id
}

fun reach_migration(f: &mut Fixture) {
    f.scenario.next_tx(TESTER);
    let mut launch = f.take_launch();
    let quote = coin::mint_for_testing<QUOTE>(30_000_000, f.scenario.ctx());
    let (meme, refund) = launch.buy(&f.version, &f.runtime, quote, 1, f.scenario.ctx());
    destroy(meme);
    destroy(refund);
    test_scenario::return_shared(launch);
}

fun take_launch(f: &Fixture): Launch<ATOMIC_MIGRATION_TESTS, QUOTE> {
    f.scenario.take_shared_by_id(f.launch_id)
}

fun take_currency(f: &Fixture): Currency<ATOMIC_MIGRATION_TESTS> {
    f.scenario.take_from_address(COIN_REGISTRY)
}

/// Payloads of each `T` this transaction emitted inside the launchpad envelope.
fun collect<T: copy + drop>(): vector<T> {
    event::events_by_type<BlastEvent<T>>().map!(|envelope| envelope.unwrap())
}

/// Everything after Blast's share goes to the creator.
fun creator_split(): FeeSplit {
    allocation::fee_split(bps::new(10_000), bps::new(0), bps::new(0), bps::new(0), vector[])
}

fun end(f: Fixture) {
    let Fixture {
        scenario,
        version,
        migrators_version,
        runtime,
        clock,
        launch_id: _,
    } = f;
    destroy(version);
    destroy(migrators_version);
    destroy(runtime);
    clock.destroy_for_testing();
    scenario.end();
}

// === Constants ===

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

const TESTER: address = @0xB1A57;

const ADMIN: address = @0xAD;

const CREATOR: address = @0xC0FFEE;

const TARGET: u64 = 25_000_000;

const POOL_TICK_SPACING: u32 = 60;

const POOL_FEE_RATE: u64 = 2_500;

// === Errors ===

#[error]
const EUnexpectedSuccess: vector<u8> = b"The guarded operation unexpectedly returned.";

// === Imports ===

use blast_admin::blast_acl;

use blast_fun::{
    allocation::{Self, FeeSplit},
    blast_events::Event as BlastEvent,
    blast_fun_domain::{AdapterAdmin, FeeAdmin, ListingAdmin},
    bps,
    creator_authority,
    events,
    launch::{Self, Launch},
    launch_config::{Self, LaunchConfig},
    launch_ticket,
    blast_fun::{Self as package_version, PackageVersion},
    runtime_config::{Self, RuntimeConfig},
};

use blast_fun_migrators::{
    blast_events,
    lp_fee_policy::{Self, LpFeePolicy},
    blast_fun_migrators::{Self as migrators_version, PackageVersion as MigratorsVersion},
    vault::{Self, LpVault},
};

use std::unit_test::{assert_eq, destroy};

use sui::{
    balance::{Self, Balance},
    clock::{Self, Clock},
    coin::{Self, Coin},
    coin_registry::Currency,
    event,
    test_scenario::{Self, Scenario},
    test_utils,
};
