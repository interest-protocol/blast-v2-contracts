// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_migrators::atomic_migration_tests;

// === Constants ===

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

const TESTER: address = @0xB1A57;

const ADMIN: address = @0xAD;

const CREATOR: address = @0xC0FFEE;

const TARGET: u64 = 25_000_000;

// === Errors ===

#[error]
const EUnexpectedSuccess: vector<u8> = b"The guarded operation unexpectedly returned.";

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct ATOMIC_MIGRATION_TESTS has drop {}

public struct QUOTE() has drop;

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

/// The adapter-reported amounts core must reconcile against the handed-off principal.
public struct Failpoint has copy, drop {
    liquidity: u128,
    meme_shortfall: u64,
    quote_shortfall: u64,
}

public struct Fixture {
    scenario: Scenario,
    version: PackageVersion,
    runtime: RuntimeConfig,
    clock: Clock,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    launch_id: ID,
    router_id: ID,
}

// === Tests ===

#[test]
fun single_ptb_sealed_mock_adapter_keeps_principal_and_residuals_in_custody_and_activates_atomically() {
    let mut f = start();
    reach_migration(&mut f);

    f.scenario.next_tx(TESTER);
    let mut launch = f.scenario.take_shared_by_id<Launch<ATOMIC_MIGRATION_TESTS, QUOTE>>(f.launch_id);
    let mut router = f.scenario.take_shared_by_id<FeeRouter<ATOMIC_MIGRATION_TESTS, QUOTE>>(f.router_id);
    let mut currency = f.scenario.take_from_address<Currency<ATOMIC_MIGRATION_TESTS>>(COIN_REGISTRY);
    let policy = f.scenario.take_shared<LpFeePolicy>();
    let (_, quote_before, _, allocated_before) = launch.balances_for_testing();
    mock_adapter(&mut launch, &mut router, &f.version, &policy, &mut currency, f.scenario.ctx());

    assert!(router.is_active());
    let (settlement_witness, vault_id, pool_id, position_id) =
        router.settlement_binding().destroy_some().settlement_binding_fields();
    assert_eq!(settlement_witness, type_name::with_original_ids<Venue>());
    let (live, ready, migrated) = (launch.is_live(), launch.is_migration_ready(), launch.is_migrated());
    assert!(!live && !ready && migrated && !launch.is_migrating_for_testing());
    let (_, quote_after, _, allocated_after) = launch.balances_for_testing();
    assert_eq!(quote_after, 0);
    assert_eq!(allocated_after, 0);
    let (
        event_launch_id,
        supplied_meme,
        supplied_quote,
        residual_meme,
        residual_quote,
        liquidity,
    ) = events::collect_one<events::Migrated>(0).migrated_accounting_fields_for_testing();
    assert_eq!(event_launch_id, f.launch_id);
    // Two thirds of the pooled Meme and nine tenths of the terminal Quote are the LP principal.
    assert_eq!(supplied_meme + residual_meme, allocated_before * 2 / 3);
    assert_eq!(supplied_quote + residual_quote, quote_before * 9 / 10);
    assert_eq!(residual_meme, 1);
    assert_eq!(residual_quote, 1);
    assert_eq!(liquidity, 1);

    assert_eq!(events::collect<events::RouterActivated>().length(), 1);
    assert_eq!(events::collect<events::MigrationAllocationPaid>().length(), 1);

    test_scenario::return_shared(launch);
    test_scenario::return_shared(router);
    test_scenario::return_to_address(COIN_REGISTRY, currency);
    test_scenario::return_shared(policy);

    f.scenario.next_tx(TESTER);
    let mut vault = f.scenario.take_shared_by_id<LpVault<ATOMIC_MIGRATION_TESTS, QUOTE>>(vault_id);
    assert_eq!(vault.pool_id(), pool_id);
    assert_eq!(vault.protocol_meme_residual(), 1);
    assert_eq!(vault.protocol_quote_residual(), 1);
    let position = vault.position_mut<
        ATOMIC_MIGRATION_TESTS, QUOTE, Venue, MockPosition<ATOMIC_MIGRATION_TESTS, QUOTE>,
    >(&Venue());
    assert_eq!(object::id(position), position_id);
    assert_eq!(position.pool_id, pool_id);
    assert_eq!(position.meme.value(), supplied_meme);
    assert_eq!(position.quote.value(), supplied_quote);
    assert_eq!(position.liquidity, 1);
    test_scenario::return_shared(vault);

    f.end();
}

#[test]
fun completion_binding_settles_later_collections_and_route_updates() {
    let mut f = start();
    reach_migration(&mut f);

    f.scenario.next_tx(TESTER);
    let mut launch = f.scenario.take_shared_by_id<Launch<ATOMIC_MIGRATION_TESTS, QUOTE>>(f.launch_id);
    let mut router = f.scenario.take_shared_by_id<FeeRouter<ATOMIC_MIGRATION_TESTS, QUOTE>>(f.router_id);
    let mut currency = f.scenario.take_from_address<Currency<ATOMIC_MIGRATION_TESTS>>(COIN_REGISTRY);
    let policy = f.scenario.take_shared<LpFeePolicy>();
    mock_adapter(&mut launch, &mut router, &f.version, &policy, &mut currency, f.scenario.ctx());
    let (_, vault_id, pool_id, position_id) =
        router.settlement_binding().destroy_some().settlement_binding_fields();
    test_scenario::return_shared(launch);
    test_scenario::return_shared(router);
    test_scenario::return_to_address(COIN_REGISTRY, currency);
    test_scenario::return_shared(policy);

    f.scenario.next_tx(CREATOR);
    let mut launch = f.scenario.take_shared_by_id<Launch<ATOMIC_MIGRATION_TESTS, QUOTE>>(f.launch_id);
    let (curve_fee_cap, metadata_cap, config_cap) = launch.claim_setup_caps(
        &f.version,
        &f.runtime,
        option::none(),
        &f.clock,
        f.scenario.ctx(),
    );
    destroy(curve_fee_cap);
    destroy(metadata_cap);
    test_scenario::return_shared(launch);

    // The adapter settles exactly the position completion bound, under the frozen routes.
    f.scenario.next_tx(TESTER);
    let mut router = f.scenario.take_shared_by_id<FeeRouter<ATOMIC_MIGRATION_TESTS, QUOTE>>(f.router_id);
    let policy = f.scenario.take_shared<LpFeePolicy>();
    router.collect(
        &f.version,
        &policy,
        Venue(),
        vault_id,
        pool_id,
        position_id,
        balance::create_for_testing(100),
        balance::create_for_testing(200),
        f.scenario.ctx(),
    );
    let (_, _, meme_amounts, quote_amounts) =
        events::collect_one<events::FeesCollected>(0).fees_collected_amounts_for_testing();
    assert_eq!(meme_amounts, vector[100]);
    assert_eq!(quote_amounts, vector[200]);
    let next = vector[allocation::route(ADMIN, bps::new(10_000))];
    router.settle_and_update_routes(
        &f.version,
        &policy,
        &config_cap,
        Venue(),
        vault_id,
        pool_id,
        position_id,
        balance::create_for_testing(3),
        balance::create_for_testing(4),
        allocation::routes(next, next),
        f.scenario.ctx(),
    );
    assert_eq!(router.generation(), 1);
    assert_eq!(router.routes().meme_routes()[0].destination(), ADMIN);
    assert_eq!(events::collect<events::FeesCollected>().length(), 2);
    destroy(config_cap);
    test_scenario::return_shared(router);
    test_scenario::return_shared(policy);

    f.end();
}

#[test, expected_failure(abort_code = 31, location = blast_fun::launch)]
fun another_adapter_cannot_begin_the_migration() {
    let mut f = start();
    reach_migration(&mut f);

    f.scenario.next_tx(TESTER);
    let mut launch = f.scenario.take_shared_by_id<Launch<ATOMIC_MIGRATION_TESTS, QUOTE>>(f.launch_id);
    let (_meme, _quote, _migration) = launch.begin_migration(&f.version, OtherVenue());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = 31, location = blast_fun::launch)]
fun another_adapter_cannot_complete_the_migration() {
    let mut f = start();
    reach_migration(&mut f);

    f.scenario.next_tx(TESTER);
    let mut launch = f.scenario.take_shared_by_id<Launch<ATOMIC_MIGRATION_TESTS, QUOTE>>(f.launch_id);
    let mut router = f.scenario.take_shared_by_id<FeeRouter<ATOMIC_MIGRATION_TESTS, QUOTE>>(f.router_id);
    let mut currency = f.scenario.take_from_address<Currency<ATOMIC_MIGRATION_TESTS>>(COIN_REGISTRY);
    let policy = f.scenario.take_shared<LpFeePolicy>();
    let (meme, quote, migration) = launch.begin_migration(&f.version, Venue());
    let pool = MockPool { id: object::new(f.scenario.ctx()) };
    let position = MockPosition {
        id: object::new(f.scenario.ctx()),
        pool_id: object::id(&pool),
        meme,
        quote,
        liquidity: 1,
    };
    let residual_meme = balance::zero();
    let residual_quote = balance::zero();
    launch.complete_migration(
        &f.version,
        &mut router,
        &policy,
        &mut currency,
        migration,
        OtherVenue(),
        &pool,
        object::id(&pool),
        &position,
        position.meme.value(),
        position.quote.value(),
        &residual_meme,
        &residual_quote,
        1,
        f.scenario.ctx(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = 59, location = blast_fun::launch)]
fun zero_liquidity_aborts_before_activation_or_migration_commit() {
    run_failpoint(failpoint_with_liquidity(0))
}

#[test, expected_failure(abort_code = 59, location = blast_fun::launch)]
fun underfunded_meme_principal_rolls_back_atomic_migration() {
    let mut failpoint = failpoint_with_liquidity(1);
    failpoint.meme_shortfall = 1;
    run_failpoint(failpoint)
}

#[test, expected_failure(abort_code = 59, location = blast_fun::launch)]
fun underfunded_quote_principal_rolls_back_atomic_migration() {
    let mut failpoint = failpoint_with_liquidity(1);
    failpoint.quote_shortfall = 1;
    run_failpoint(failpoint)
}

// === Test Helpers ===

fun failpoint_with_liquidity(liquidity: u128): Failpoint {
    Failpoint { liquidity, meme_shortfall: 0, quote_shortfall: 0 }
}

fun run_failpoint(failpoint: Failpoint) {
    let mut f = start();
    reach_migration(&mut f);
    f.scenario.next_tx(TESTER);
    let mut launch = f.scenario.take_shared_by_id<Launch<ATOMIC_MIGRATION_TESTS, QUOTE>>(f.launch_id);
    let mut router = f.scenario.take_shared_by_id<FeeRouter<ATOMIC_MIGRATION_TESTS, QUOTE>>(f.router_id);
    let mut currency = f.scenario.take_from_address<Currency<ATOMIC_MIGRATION_TESTS>>(COIN_REGISTRY);
    let policy = f.scenario.take_shared<LpFeePolicy>();
    mock_adapter_with(
        &mut launch,
        &mut router,
        &f.version,
        &policy,
        &mut currency,
        failpoint,
        f.scenario.ctx(),
    );
    abort EUnexpectedSuccess
}

/// The mock adapter constructs and consumes its sealed witness and returns no protected value.
public fun mock_adapter(
    launch: &mut Launch<ATOMIC_MIGRATION_TESTS, QUOTE>,
    router: &mut FeeRouter<ATOMIC_MIGRATION_TESTS, QUOTE>,
    version: &PackageVersion,
    policy: &LpFeePolicy,
    currency: &mut Currency<ATOMIC_MIGRATION_TESTS>,
    ctx: &mut TxContext,
) {
    mock_adapter_with(launch, router, version, policy, currency, failpoint_with_liquidity(1), ctx)
}

/// Begin, seed a mock position with one residual unit per asset, attach it to the vault, complete,
/// then share the vault and pool. The failpoint changes only what the adapter reports.
fun mock_adapter_with(
    launch: &mut Launch<ATOMIC_MIGRATION_TESTS, QUOTE>,
    router: &mut FeeRouter<ATOMIC_MIGRATION_TESTS, QUOTE>,
    version: &PackageVersion,
    policy: &LpFeePolicy,
    currency: &mut Currency<ATOMIC_MIGRATION_TESTS>,
    failpoint: Failpoint,
    ctx: &mut TxContext,
) {
    let (mut meme, mut quote, migration) = launch.begin_migration(version, Venue());
    let residual_meme = meme.split(1);
    let residual_quote = quote.split(1);
    let pool = MockPool { id: object::new(ctx) };
    let pool_id = object::id(&pool);
    let position = MockPosition {
        id: object::new(ctx),
        pool_id,
        meme,
        quote,
        liquidity: failpoint.liquidity,
    };
    let mut pending_vault = vault::prepare(residual_meme, residual_quote, ctx);
    pending_vault.attach(&Venue(), pool_id, position);
    let position = pending_vault.position<
        ATOMIC_MIGRATION_TESTS, QUOTE, Venue, MockPosition<ATOMIC_MIGRATION_TESTS, QUOTE>,
    >(&Venue());
    let (residual_meme, residual_quote) = pending_vault.pending_residuals();
    assert_eq!(position.pool_id, pool_id);
    launch.complete_migration(
        version,
        router,
        policy,
        currency,
        migration,
        Venue(),
        &pending_vault,
        pool_id,
        position,
        position.meme.value() - failpoint.meme_shortfall,
        position.quote.value() - failpoint.quote_shortfall,
        residual_meme,
        residual_quote,
        position.liquidity,
        ctx,
    );
    pending_vault.share<ATOMIC_MIGRATION_TESTS, QUOTE, Venue>(&Venue());
    transfer::share_object(pool);
}

fun start(): Fixture {
    let mut scenario = test_scenario::begin(@0x0);
    let version = package_version::new_for_testing(scenario.ctx());
    let (root, mut authority) = acl::new_for_testing<BLAST_FUN_DOMAIN>(16, 1, scenario.ctx());
    authority.grant_admin(&root, blast_fun_domain::creator_admin_role(), ADMIN, scenario.ctx());
    destroy(root);
    launch_config::init_for_testing(scenario.ctx());
    lp_fee_policy::init_for_testing(scenario.ctx());
    let runtime = runtime_config::new_disabled_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    let admin = authority.sign_in(&admin_cap);
    let mut config = scenario.take_shared<LaunchConfig>();
    config.allow_quote<QUOTE>(&version, &admin, 5_000_000);
    config.allow_migration_witness<Venue>(&version, &admin);
    config.set_trade_fees(&version, &admin, bps::new(100), bps::new(100));
    config.set_protocol_allocation(&version, &admin, 1, ADMIN, bps::new(0), bps::new(0));
    let (launch_id, router_id) = share_launch(&mut scenario, &version, &config, &clock);
    test_scenario::return_shared(config);

    Fixture {
        scenario,
        version,
        runtime,
        clock,
        authority,
        admin_cap,
        launch_id,
        router_id,
    }
}

/// Creates one launch/router pair through the public constructors and shares both.
fun share_launch(
    scenario: &mut Scenario,
    version: &PackageVersion,
    config: &LaunchConfig,
    clock: &Clock,
): (ID, ID) {
    let mut ticket = launch_ticket::new(
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
    ticket.bind_migration_witness<_, QUOTE, _>(config, Venue());
    let sender = scenario.sender();
    scenario.next_tx(sender);
    let mut currency = scenario.take_from_address<Currency<ATOMIC_MIGRATION_TESTS>>(COIN_REGISTRY);
    let mut launch = launch::new<_, QUOTE>(
        ticket,
        &mut currency,
        version,
        config,
        TARGET,
        allocation::new(
            vector[
                allocation::channel(2, allocation::liquidity_role(), CREATOR),
                allocation::channel(3, allocation::external_role(), CREATOR),
            ],
            vector[
                allocation::weight(0, bps::new(7_000)),
                allocation::weight(2, bps::new(2_000)),
                allocation::weight(3, bps::new(1_000)),
            ],
            vector[
                allocation::weight(2, bps::new(9_000)),
                allocation::weight(3, bps::new(1_000)),
            ],
        ),
        0,
        bps::new(0),
        bps::new(0),
        scenario.ctx(),
    );
    let route = vector[allocation::route(CREATOR, bps::new(10_000))];
    let (router, config_cap) = launch.new_fee_router(
        version,
        allocation::routes(route, route),
        scenario.ctx(),
    );
    let launch_id = object::id(&launch);
    let router_id = object::id(&router);
    launch.share(version, config_cap, router, clock);
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    (launch_id, router_id)
}

fun reach_migration(f: &mut Fixture) {
    f.scenario.next_tx(TESTER);
    let mut launch = f.scenario.take_shared_by_id<Launch<ATOMIC_MIGRATION_TESTS, QUOTE>>(f.launch_id);
    let quote = coin::mint_for_testing<QUOTE>(30_000_000, f.scenario.ctx());
    let (meme, refund) = launch.buy(&f.version, &f.runtime, quote, 1, &f.clock, f.scenario.ctx());
    destroy(meme);
    destroy(refund);
    test_scenario::return_shared(launch);
}

fun end(f: Fixture) {
    let Fixture {
        scenario,
        version,
        runtime,
        clock,
        authority,
        admin_cap,
        launch_id: _,
        router_id: _,
    } = f;
    destroy(version);
    destroy(runtime);
    clock.destroy_for_testing();
    destroy(authority);
    destroy(admin_cap);
    scenario.end();
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap};

use blast_fun::{
    allocation,
    bps,
    creator_authority,
    events,
    fee_router::FeeRouter,
    launch::{Self, Launch},
    launch_config::{Self, LaunchConfig},
    launch_ticket,
    lp_fee_policy::{Self, LpFeePolicy},
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    package_version::{Self, PackageVersion},
    runtime_config::{Self, RuntimeConfig},
};

use blast_fun_migrators::vault::{Self, LpVault};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{
    balance::{Self, Balance},
    clock::{Self, Clock},
    coin,
    coin_registry::Currency,
    test_scenario::{Self, Scenario},
    test_utils,
};
