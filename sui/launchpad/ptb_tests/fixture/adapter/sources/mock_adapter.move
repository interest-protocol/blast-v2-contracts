// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Publishable sealed adapter for the programmable-transaction migration harness.
///
/// `bind`, `create_launch`, `create_routed_launch`, `migrate`, `collect`, `settle`, and
/// `settle_routes` are the only entry points the harness calls, so launchpad API changes stay inside
/// this module. The adapter owns the private witness, keeps principal in a mock position and
/// residuals in a mock vault, and can fail at named points.
module ptb_adapter::mock_adapter;

// === Constants ===

const CUSTODY_FAILURE: u8 = 1;

const ZERO_LIQUIDITY: u8 = 2;

const UNDERFUND_MEME: u8 = 3;

const POST_FINALIZER_FAILURE: u8 = 4;

// === Errors ===

const ECustodyFailure: u64 = 0;

const EPostFinalizerFailure: u64 = 1;

const EUnknownFailpoint: u64 = 2;

// === Public Types ===

/// Adapter identity only this module can construct.
public struct Venue() has drop;

public struct MockPool has key { id: UID }

/// Holds exactly the supplied principal.
public struct MockPosition<phantom Meme> has key, store {
    id: UID,
    pool_id: ID,
    meme: Balance<Meme>,
    quote: Balance<SUI>,
    liquidity: u128,
}

/// Permanent custody: the position plus explicit residuals.
public struct MockVault<phantom Meme> has key {
    id: UID,
    position: MockPosition<Meme>,
    residual_meme: Balance<Meme>,
    residual_quote: Balance<SUI>,
}

// === Public Functions ===

/// Binds `ticket` to this adapter for SUI, as a venue adapter's `bind` does, so one transaction can
/// open the launch itself through the public launchpad calls.
public fun bind<Meme>(ticket: &mut LaunchTicket<Meme>, config: &LaunchConfig) {
    ticket.bind_migration_witness<_, SUI, _>(config, Venue());
}

/// `create_routed_launch` with both assets routed wholly to `destination`.
public fun create_launch<Meme>(
    ticket: LaunchTicket<Meme>,
    currency: &mut Currency<Meme>,
    version: &PackageVersion,
    config: &LaunchConfig,
    clock: &Clock,
    target: u64,
    destination: address,
    protection_window_ms: u64,
    cumulative_sender_bps: u64,
    per_transaction_bps: u64,
    ctx: &mut TxContext,
) {
    let route = vector[allocation::route(destination, bps::new(10_000))];
    create_routed_launch(
        ticket,
        currency,
        version,
        config,
        clock,
        target,
        destination,
        protection_window_ms,
        cumulative_sender_bps,
        per_transaction_bps,
        allocation::routes(route, route),
        ctx,
    );
}

/// Binds the ticket to this adapter, then opens, configures, and shares one SUI-quoted launch and
/// its router with `routes` under the given purchase protection. Every non-liquidity allocation
/// pays `destination`.
public fun create_routed_launch<Meme>(
    mut ticket: LaunchTicket<Meme>,
    currency: &mut Currency<Meme>,
    version: &PackageVersion,
    config: &LaunchConfig,
    clock: &Clock,
    target: u64,
    destination: address,
    protection_window_ms: u64,
    cumulative_sender_bps: u64,
    per_transaction_bps: u64,
    routes: Routes,
    ctx: &mut TxContext,
) {
    bind(&mut ticket, config);
    let mut launch = launch::new<Meme, SUI>(
        ticket,
        currency,
        version,
        config,
        target,
        allocation::new(
            vector[
                allocation::channel(2, allocation::liquidity_role(), destination),
                allocation::channel(3, allocation::external_role(), destination),
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
        protection_window_ms,
        bps::new(cumulative_sender_bps),
        bps::new(per_transaction_bps),
        ctx,
    );
    let (router, config_cap) = launch.new_fee_router(version, routes, ctx);
    launch.share(version, config_cap, router, clock);
}

/// Runs the complete migration in one call and returns nothing. `failpoint` selects an injected
/// failure; zero completes.
public fun migrate<Meme>(
    launch: &mut Launch<Meme, SUI>,
    router: &mut FeeRouter<Meme, SUI>,
    version: &PackageVersion,
    policy: &LpFeePolicy,
    currency: &mut Currency<Meme>,
    failpoint: u8,
    ctx: &mut TxContext,
) {
    assert!(failpoint <= POST_FINALIZER_FAILURE, EUnknownFailpoint);
    let (mut meme, mut quote, migration) = launch.begin_migration(version, Venue());
    let residual_meme = meme.split(1);
    let residual_quote = quote.split(1);
    if (failpoint == UNDERFUND_MEME) {
        transfer::public_transfer(meme.split(1).into_coin(ctx), @0xDEAD);
    };
    let pool = MockPool { id: object::new(ctx) };
    let position = MockPosition {
        id: object::new(ctx),
        pool_id: object::id(&pool),
        meme,
        quote,
        liquidity: if (failpoint == ZERO_LIQUIDITY) 0 else 1,
    };
    let vault = MockVault {
        id: object::new(ctx),
        position,
        residual_meme,
        residual_quote,
    };
    assert!(failpoint != CUSTODY_FAILURE, ECustodyFailure);
    launch.complete_migration(
        version,
        router,
        policy,
        currency,
        migration,
        Venue(),
        &vault,
        object::id(&pool),
        &vault.position,
        vault.position.meme.value(),
        vault.position.quote.value(),
        &vault.residual_meme,
        &vault.residual_quote,
        vault.position.liquidity,
        ctx,
    );
    transfer::share_object(vault);
    transfer::share_object(pool);
    assert!(failpoint != POST_FINALIZER_FAILURE, EPostFinalizerFailure);
}

/// Pays one collection of the vault's position through `router`; the caller's coins stand in for
/// venue-accrued fees. `failpoint` 4 aborts after the router paid every destination.
public fun collect<Meme>(
    vault: &MockVault<Meme>,
    router: &mut FeeRouter<Meme, SUI>,
    version: &PackageVersion,
    policy: &LpFeePolicy,
    meme: Coin<Meme>,
    quote: Coin<SUI>,
    failpoint: u8,
    ctx: &mut TxContext,
) {
    assert!(failpoint == 0 || failpoint == POST_FINALIZER_FAILURE, EUnknownFailpoint);
    router.collect(
        version,
        policy,
        Venue(),
        object::id(vault),
        vault.position.pool_id,
        object::id(&vault.position),
        meme.into_balance(),
        quote.into_balance(),
        ctx,
    );
    assert!(failpoint != POST_FINALIZER_FAILURE, EPostFinalizerFailure);
}

/// `settle_routes` with both assets routed wholly to `destination`.
public fun settle<Meme>(
    vault: &MockVault<Meme>,
    router: &mut FeeRouter<Meme, SUI>,
    version: &PackageVersion,
    policy: &LpFeePolicy,
    config_cap: &RouterConfigCap<Meme, SUI>,
    meme: Coin<Meme>,
    quote: Coin<SUI>,
    destination: address,
    failpoint: u8,
    ctx: &mut TxContext,
) {
    let route = vector[allocation::route(destination, bps::new(10_000))];
    settle_routes(
        vault,
        router,
        version,
        policy,
        config_cap,
        meme,
        quote,
        allocation::routes(route, route),
        failpoint,
        ctx,
    );
}

/// Settles one collection under the current routes, then commits `routes`. `failpoint` 4 aborts
/// after the router paid and committed the new routes.
public fun settle_routes<Meme>(
    vault: &MockVault<Meme>,
    router: &mut FeeRouter<Meme, SUI>,
    version: &PackageVersion,
    policy: &LpFeePolicy,
    config_cap: &RouterConfigCap<Meme, SUI>,
    meme: Coin<Meme>,
    quote: Coin<SUI>,
    routes: Routes,
    failpoint: u8,
    ctx: &mut TxContext,
) {
    assert!(failpoint == 0 || failpoint == POST_FINALIZER_FAILURE, EUnknownFailpoint);
    router.settle_and_update_routes(
        version,
        policy,
        config_cap,
        Venue(),
        object::id(vault),
        vault.position.pool_id,
        object::id(&vault.position),
        meme.into_balance(),
        quote.into_balance(),
        routes,
        ctx,
    );
    assert!(failpoint != POST_FINALIZER_FAILURE, EPostFinalizerFailure);
}

// === Imports ===

use blast_fun::{
    allocation::{Self, Routes},
    bps,
    fee_router::{FeeRouter, RouterConfigCap},
    launch::{Self, Launch},
    launch_config::LaunchConfig,
    launch_ticket::LaunchTicket,
    lp_fee_policy::LpFeePolicy,
    package_version::PackageVersion,
};

use sui::{balance::Balance, clock::Clock, coin::Coin, coin_registry::Currency, sui::SUI};
