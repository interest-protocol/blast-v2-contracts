// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Sealed provider-conformance fixture for pushed fee collection and settled route updates.
module blast_fun_migrators::route_update_adapter_tests;

// === Constants ===

const OWNER: address = @0xA;

const NEXT_OWNER: address = @0xB;

const LAUNCH: address = @0x1A;

// === Test-Only Types ===

public struct MEME has drop {}

public struct QUOTE has drop {}

/// Only this adapter module can construct it, and the value has no `store` ability.
public struct AdapterSettlementWitness() has drop;

public struct MockPool has key, store { id: UID }

public struct MockPosition<phantom M, phantom Q> has key, store {
    id: UID,
    meme: Balance<M>,
    quote: Balance<Q>,
}

public struct MockVault<phantom M, phantom Q> has key {
    id: UID,
    pool: MockPool,
    position: MockPosition<M, Q>,
}

// === Tests ===

#[test]
fun sealed_wrapper_collects_and_pays_the_current_routes() {
    let mut scenario = test_scenario::begin(OWNER);
    let version = package_version::new_for_testing(scenario.ctx());
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());
    let mut vault = mock_vault(10, 20, scenario.ctx());
    let (mut router, config_cap) = fee_router::new_for_testing<MEME, QUOTE>(
        object::id_from_address(LAUNCH),
        single_route(OWNER),
        scenario.ctx(),
    );
    activate_adapter(&mut router, &policy, &vault);

    collect_exact_position(&mut vault, &mut router, &version, &policy, scenario.ctx());
    assert_eq!(router.generation(), 0);

    scenario.next_tx(OWNER);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 10);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 20);
    destroy_vault(vault);
    destroy(router);
    destroy(config_cap);
    destroy(version);
    destroy(policy);
    scenario.end();
}

#[test]
fun sealed_wrapper_settles_nonzero_and_zero_collections_prospectively() {
    let mut scenario = test_scenario::begin(OWNER);
    let version = package_version::new_for_testing(scenario.ctx());
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());
    let mut vault = mock_vault(10, 20, scenario.ctx());
    let (mut router, config_cap) = fee_router::new_for_testing<MEME, QUOTE>(
        object::id_from_address(LAUNCH),
        single_route(OWNER),
        scenario.ctx(),
    );
    activate_adapter(&mut router, &policy, &vault);

    settle_exact_position(
        &mut vault,
        &mut router,
        &version,
        &policy,
        &config_cap,
        single_route(NEXT_OWNER),
        scenario.ctx(),
    );
    assert_eq!(router.generation(), 1);
    assert_eq!(router.routes().meme_routes()[0].destination(), NEXT_OWNER);

    // The same wrapper must still produce explicit authorization when the exact position is zero.
    settle_exact_position(
        &mut vault,
        &mut router,
        &version,
        &policy,
        &config_cap,
        single_route(OWNER),
        scenario.ctx(),
    );
    assert_eq!(router.generation(), 2);

    // Fees collected inside the first update paid the routes that were live before it.
    scenario.next_tx(OWNER);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 10);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 20);
    scenario.next_tx(NEXT_OWNER);
    assert!(!scenario.has_most_recent_for_sender<Coin<MEME>>());
    assert!(!scenario.has_most_recent_for_sender<Coin<QUOTE>>());
    destroy_vault(vault);
    destroy(router);
    destroy(config_cap);
    destroy(version);
    destroy(policy);
    scenario.end();
}

#[test, expected_failure(abort_code = 68, location = blast_fun::fee_router)]
fun another_vault_cannot_settle_the_bound_router() {
    attempt_substitution(
        object::id_from_address(@0xBAD),
        object::id_from_address(@0xA2),
        object::id_from_address(@0xA3),
    );
}

#[test, expected_failure(abort_code = 68, location = blast_fun::fee_router)]
fun another_pool_cannot_settle_the_bound_router() {
    attempt_substitution(
        object::id_from_address(@0xA1),
        object::id_from_address(@0xBAE),
        object::id_from_address(@0xA3),
    );
}

#[test, expected_failure(abort_code = 68, location = blast_fun::fee_router)]
fun another_child_position_cannot_settle_the_bound_router() {
    attempt_substitution(
        object::id_from_address(@0xA1),
        object::id_from_address(@0xA2),
        object::id_from_address(@0xBAF),
    );
}

// === Test Helpers ===

fun attempt_substitution(vault_id: ID, pool_id: ID, position_id: ID) {
    let mut scenario = test_scenario::begin(OWNER);
    let version = package_version::new_for_testing(scenario.ctx());
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());
    let bound = mock_vault(0, 0, scenario.ctx());
    let mut substitute = mock_vault(10, 20, scenario.ctx());
    let (mut router, config_cap) = fee_router::new_for_testing<MEME, QUOTE>(
        object::id_from_address(LAUNCH),
        single_route(OWNER),
        scenario.ctx(),
    );
    let binding_vault_id = if (vault_id == object::id_from_address(@0xBAD)) object::id(&bound)
        else object::id(&substitute);
    let binding_pool_id = if (pool_id == object::id_from_address(@0xBAE)) object::id(&bound.pool)
        else object::id(&substitute.pool);
    let binding_position_id = if (position_id == object::id_from_address(@0xBAF)) {
        object::id(&bound.position)
    } else {
        object::id(&substitute.position)
    };
    router.activate_for_testing<_, _, AdapterSettlementWitness>(
        &policy,
        binding_vault_id,
        binding_pool_id,
        binding_position_id,
    );
    settle_exact_position(
        &mut substitute,
        &mut router,
        &version,
        &policy,
        &config_cap,
        single_route(NEXT_OWNER),
        scenario.ctx(),
    );
    destroy_vault(bound);
    destroy_vault(substitute);
    destroy(router);
    destroy(config_cap);
    destroy(version);
    destroy(policy);
    scenario.end();
}

/// Adapter-only wrapper: collect the child position, construct the private no-store witness, and
/// immediately consume everything in core without returning proof.
fun collect_exact_position(
    vault: &mut MockVault<MEME, QUOTE>,
    router: &mut FeeRouter<MEME, QUOTE>,
    version: &PackageVersion,
    policy: &LpFeePolicy,
    ctx: &mut TxContext,
) {
    let meme = vault.position.meme.withdraw_all();
    let quote = vault.position.quote.withdraw_all();
    router.collect(
        version,
        policy,
        AdapterSettlementWitness(),
        object::id(vault),
        object::id(&vault.pool),
        object::id(&vault.position),
        meme,
        quote,
        ctx,
    );
}

/// Adapter-only wrapper: read exact stored identities, collect the child position, construct the
/// private no-store witness, and immediately consume everything in core without returning proof.
fun settle_exact_position(
    vault: &mut MockVault<MEME, QUOTE>,
    router: &mut FeeRouter<MEME, QUOTE>,
    version: &PackageVersion,
    policy: &LpFeePolicy,
    config_cap: &RouterConfigCap<MEME, QUOTE>,
    proposed: Routes,
    ctx: &mut TxContext,
) {
    let meme = vault.position.meme.withdraw_all();
    let quote = vault.position.quote.withdraw_all();
    router.settle_and_update_routes(
        version,
        policy,
        config_cap,
        AdapterSettlementWitness(),
        object::id(vault),
        object::id(&vault.pool),
        object::id(&vault.position),
        meme,
        quote,
        proposed,
        ctx,
    );
}

fun activate_adapter(
    router: &mut FeeRouter<MEME, QUOTE>,
    policy: &LpFeePolicy,
    vault: &MockVault<MEME, QUOTE>,
) {
    router.activate_for_testing<_, _, AdapterSettlementWitness>(
        policy,
        object::id(vault),
        object::id(&vault.pool),
        object::id(&vault.position),
    );
}

fun mock_vault(meme: u64, quote: u64, ctx: &mut TxContext): MockVault<MEME, QUOTE> {
    MockVault {
        id: object::new(ctx),
        pool: MockPool { id: object::new(ctx) },
        position: MockPosition {
            id: object::new(ctx),
            meme: balance::create_for_testing(meme),
            quote: balance::create_for_testing(quote),
        },
    }
}

fun destroy_vault<M, Q>(vault: MockVault<M, Q>) {
    let MockVault { id, pool, position } = vault;
    let MockPool { id: pool_id } = pool;
    let MockPosition { id: position_id, meme, quote } = position;
    meme.destroy_zero();
    quote.destroy_zero();
    position_id.delete();
    pool_id.delete();
    id.delete();
}

fun single_route(destination: address): Routes {
    let route = vector[allocation::route(destination, bps::new(10_000))];
    allocation::routes(route, route)
}

// === Imports ===

use blast_fun::{
    allocation::{Self, Routes},
    bps,
    fee_router::{Self, FeeRouter, RouterConfigCap},
    lp_fee_policy::{Self, LpFeePolicy},
    package_version::{Self, PackageVersion},
};

use std::unit_test::{assert_eq, destroy};

use sui::{balance::{Self, Balance}, coin::Coin, test_scenario};
