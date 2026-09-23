// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Cetus migration into vault custody, with pool creation reserved while binding.
///
/// Anyone holding Meme can create a Cetus pool, and Cetus allows one pool per pair and tick
/// spacing, so a buyer could pre-create the migration pool at a price of their choosing. Binding
/// therefore mints the Meme type's single Cetus `PoolCreationCap` from the ticket's treasury
/// capability, before any Meme can leave the ticket, and registers each bound Quote at the
/// effective tick spacing; afterwards only that capability or Cetus's pool-manager role can create
/// the pair's pool there. Trusting that role is a venue-operator assumption: a pool it creates
/// first makes the pair's migration abort, and only a migrators upgrade could recover the launch.
/// The capability and every reservation stay in `VenueConfig` under keys only this module
/// constructs, with no extraction or unregistration path. Cetus orders a pool's coin types by type
/// name, so migration, collection, and settled route updates each exist once per ordering.
module blast_fun_migrators::cetus;

// === Constants ===

/// The tick spacing Cetus admits for permissioned SUI and USDC pairs and its registered 1% fee
/// (1e6 denominator), read from the live mainnet registries on 2026-09-22.
const DEFAULT_TICK_SPACING: u32 = 200;

const DEFAULT_FEE_RATE: u64 = 10_000;

// === Errors ===

#[error(code = 0)]
const ETierMismatch: vector<u8> = b"Cetus must register the effective tick spacing at the effective fee rate.";

#[error(code = 1)]
const EInvalidCoinOrder: vector<u8> = b"Migration route must match the Cetus coin order of the pair.";

#[error(code = 2)]
const EPositionPoolMismatch: vector<u8> = b"Custodied position must belong to the supplied pool.";

// === Public Types ===

/// Sealed adapter identity selected by a Blast launch.
public struct Witness() has drop;

/// Sealed marker for the Cetus position attached to the common vault.
public struct Venue() has drop;

/// Sealed `VenueConfig` object-field name for the Meme type's Cetus `PoolCreationCap`.
///
/// The capability is a dynamic object field, so it keeps the ID that Cetus's permission registry
/// and every `CetusPoolReserved` event record, and stays readable by that ID.
public struct CreationCapKey<phantom Meme>() has copy, drop, store;

/// Sealed `VenueConfig` field name for one reserved pair; the value is its reserved tick spacing.
public struct ReservationKey<phantom Meme, phantom Quote>() has copy, drop, store;

// === Public Functions ===

/// Binds `ticket` to Cetus for `Quote` and reserves Cetus pool creation for the pair.
///
/// The first binding for a Meme type mints its `PoolCreationCap` from the ticket's treasury
/// capability; a binding for a Quote not yet reserved registers the pair at the effective tier's
/// tick spacing, which its migration then uses whatever the tier is later pinned to. A Quote
/// already reserved keeps its reservation. Aborts, leaving the ticket and Cetus unchanged, when
/// Cetus refuses the pair or does not register the effective tier, so the creator can bind another
/// admitted adapter instead.
public fun bind<Meme, Quote>(
    ticket: &mut LaunchTicket<Meme>,
    config: &LaunchConfig,
    migrators_version: &MigratorsVersion,
    venue_config: &mut VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    ticket.bind_migration_witness<_, Quote, _>(config, Witness());
    if (venue_config.has_policy(ReservationKey<Meme, Quote>())) return;

    let (tick_spacing, fee_rate) = venue_config.effective_tier();
    assert!(config::get_fee_rate(tick_spacing, cetus_config) == fee_rate, ETierMismatch);

    if (!venue_config.has_object(CreationCapKey<Meme>())) {
        let pool_creation_cap = factory::mint_pool_creation_cap(
            cetus_config,
            pools,
            ticket.treasury_cap_mut(config, Witness()),
            ctx,
        );
        venue_config.add_object(CreationCapKey<Meme>(), pool_creation_cap);
    };
    let pool_creation_cap = venue_config.pool_creation_cap<Meme>();
    factory::register_permission_pair<Meme, Quote>(
        cetus_config,
        pools,
        tick_spacing,
        pool_creation_cap,
        ctx,
    );
    let pool_creation_cap_id = object::id(pool_creation_cap);
    venue_config.add_policy(ReservationKey<Meme, Quote>(), tick_spacing);

    blast_events::cetus_pool_reserved<Meme, Quote>(pool_creation_cap_id, tick_spacing);
}

/// Migrates a MigrationReady launch whose Meme is Cetus coin A into vault custody.
///
/// Creates the pair's pool with the reserved capability at the reserved tick spacing, priced from
/// the handed-off balances, and seeds full-range liquidity with exactly those balances. Any Cetus
/// refusal, including a reserved tier Cetus no longer registers, aborts the whole migration and
/// leaves the launch MigrationReady.
public fun migrate_meme_a<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    router: &mut FeeRouter<Meme, Quote>,
    policy: &LpFeePolicy,
    currency: &mut Currency<Meme>,
    venue_config: &VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    assert!(factory::is_right_order<Meme, Quote>(), EInvalidCoinOrder);
    let tick_spacing = venue_config.reserved_tick_spacing<Meme, Quote>();
    let (tick_lower, tick_upper) = pool_creator::full_range_tick_range(tick_spacing);

    let (meme, quote, migration) = launch.begin_migration(package_version, Witness());
    let meme_amount = meme.value();
    let quote_amount = quote.value();

    // Meme is the fixed side when its atoms are at least the Quote atoms, and Quote otherwise: a
    // full-range seed fixed on the fewer atoms can need slightly more of the other asset than was
    // handed off. Cetus returns what it does not take as residual.
    let (position, residual_meme, residual_quote) =
        pool_creator::create_pool_v3_with_creation_cap<Meme, Quote>(
            cetus_config,
            pools,
            venue_config.pool_creation_cap<Meme>(),
            tick_spacing,
            migration_math::sqrt_price_x64(meme_amount, quote_amount, true),
            b"".to_string(),
            tick_lower,
            tick_upper,
            meme.into_coin(ctx),
            quote.into_coin(ctx),
            meme_amount >= quote_amount,
            clock,
            ctx,
        );

    launch.complete_into_vault(
        package_version,
        router,
        policy,
        currency,
        migration,
        meme_amount,
        quote_amount,
        position,
        residual_meme,
        residual_quote,
        ctx,
    );
}

/// Migrates a MigrationReady launch whose Meme is Cetus coin B into vault custody.
///
/// Identical to `migrate_meme_a` with Quote as coin A, so the price is Meme per Quote.
public fun migrate_meme_b<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    router: &mut FeeRouter<Meme, Quote>,
    policy: &LpFeePolicy,
    currency: &mut Currency<Meme>,
    venue_config: &VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    assert!(factory::is_right_order<Quote, Meme>(), EInvalidCoinOrder);
    let tick_spacing = venue_config.reserved_tick_spacing<Meme, Quote>();
    let (tick_lower, tick_upper) = pool_creator::full_range_tick_range(tick_spacing);

    let (meme, quote, migration) = launch.begin_migration(package_version, Witness());
    let meme_amount = meme.value();
    let quote_amount = quote.value();

    // Quote is coin A here, so the same rule fixes coin A exactly when Meme has fewer atoms.
    let (position, residual_quote, residual_meme) =
        pool_creator::create_pool_v3_with_creation_cap<Quote, Meme>(
            cetus_config,
            pools,
            venue_config.pool_creation_cap<Meme>(),
            tick_spacing,
            migration_math::sqrt_price_x64(meme_amount, quote_amount, false),
            b"".to_string(),
            tick_lower,
            tick_upper,
            quote.into_coin(ctx),
            meme.into_coin(ctx),
            meme_amount < quote_amount,
            clock,
            ctx,
        );

    launch.complete_into_vault(
        package_version,
        router,
        policy,
        currency,
        migration,
        meme_amount,
        quote_amount,
        position,
        residual_meme,
        residual_quote,
        ctx,
    );
}

/// Collects the vault position's fees from its Meme-A pool and pays them through the router.
public fun collect_fees_meme_a<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    router: &mut FeeRouter<Meme, Quote>,
    policy: &LpFeePolicy,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let (position_id, meme_fee, quote_fee) = self.collect_position_fees(cetus_config, pool);

    router.collect(
        package_version,
        policy,
        Witness(),
        object::id(self),
        object::id(pool),
        position_id,
        meme_fee,
        quote_fee,
        ctx,
    );
}

/// Collects the vault position's fees from its Meme-B pool and pays them through the router.
public fun collect_fees_meme_b<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    router: &mut FeeRouter<Meme, Quote>,
    policy: &LpFeePolicy,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<Quote, Meme>,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let (position_id, quote_fee, meme_fee) = self.collect_position_fees(cetus_config, pool);

    router.collect(
        package_version,
        policy,
        Witness(),
        object::id(self),
        object::id(pool),
        position_id,
        meme_fee,
        quote_fee,
        ctx,
    );
}

/// Pays the Meme-A position's accrued fees under the current routes, then commits `proposed`.
public fun settle_and_update_routes_meme_a<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    router: &mut FeeRouter<Meme, Quote>,
    policy: &LpFeePolicy,
    router_config_cap: &RouterConfigCap<Meme, Quote>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    proposed: Routes,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let (position_id, meme_fee, quote_fee) = self.collect_position_fees(cetus_config, pool);

    router.settle_and_update_routes(
        package_version,
        policy,
        router_config_cap,
        Witness(),
        object::id(self),
        object::id(pool),
        position_id,
        meme_fee,
        quote_fee,
        proposed,
        ctx,
    );
}

/// Pays the Meme-B position's accrued fees under the current routes, then commits `proposed`.
public fun settle_and_update_routes_meme_b<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    router: &mut FeeRouter<Meme, Quote>,
    policy: &LpFeePolicy,
    router_config_cap: &RouterConfigCap<Meme, Quote>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<Quote, Meme>,
    proposed: Routes,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let (position_id, quote_fee, meme_fee) = self.collect_position_fees(cetus_config, pool);

    router.settle_and_update_routes(
        package_version,
        policy,
        router_config_cap,
        Witness(),
        object::id(self),
        object::id(pool),
        position_id,
        meme_fee,
        quote_fee,
        proposed,
        ctx,
    );
}

/// Pins the Cetus tier for later bindings under a live core admin witness.
public fun set_tier(
    venue_config: &mut VenueConfig,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    tick_spacing: u32,
    fee_rate: u64,
) {
    migrators_version.assert_current();
    venue_config.set_tier(Venue(), tick_spacing, fee_rate);
}

// === Private Functions ===

/// Returns the pinned tier, or the compiled default while no pin exists.
fun effective_tier(venue_config: &VenueConfig): (u32, u64) {
    if (venue_config.has_tier<Venue>()) {
        venue_config.tier<Venue>()
    } else {
        (DEFAULT_TICK_SPACING, DEFAULT_FEE_RATE)
    }
}

fun pool_creation_cap<Meme>(venue_config: &VenueConfig): &PoolCreationCap {
    venue_config.object(CreationCapKey<Meme>())
}

fun reserved_tick_spacing<Meme, Quote>(venue_config: &VenueConfig): u32 {
    *venue_config.policy(ReservationKey<Meme, Quote>())
}

/// Locks the position and residuals in a new vault and completes the launch against them.
///
/// The supplied principal is what Cetus took from the handed-off balances: everything it did not
/// return as a residual.
fun complete_into_vault<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    router: &mut FeeRouter<Meme, Quote>,
    policy: &LpFeePolicy,
    currency: &mut Currency<Meme>,
    migration: Migration<Meme, Quote>,
    meme_amount: u64,
    quote_amount: u64,
    position: Position,
    residual_meme: Coin<Meme>,
    residual_quote: Coin<Quote>,
    ctx: &mut TxContext,
) {
    let pool_id = position.pool_id();
    let liquidity = position.liquidity();
    let mut vault = vault::prepare(residual_meme.into_balance(), residual_quote.into_balance(), ctx);
    vault.attach(&Venue(), pool_id, position);

    let (residual_meme, residual_quote) = vault.pending_residuals();
    launch.complete_migration(
        package_version,
        router,
        policy,
        currency,
        migration,
        Witness(),
        &vault,
        pool_id,
        vault.position<_, _, _, Position>(&Venue()),
        meme_amount - residual_meme.value(),
        quote_amount - residual_quote.value(),
        residual_meme,
        residual_quote,
        liquidity,
        ctx,
    );
    vault.share(&Venue());
}

/// Collects the attached position's fees from `pool`, which must be the position's own pool.
fun collect_position_fees<X, Y, Meme, Quote>(
    self: &LpVault<Meme, Quote>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<X, Y>,
): (ID, Balance<X>, Balance<Y>) {
    let position = self.position<_, _, _, Position>(&Venue());
    assert!(position.pool_id() == object::id(pool), EPositionPoolMismatch);

    let (fee_a, fee_b) = pool::collect_fee(cetus_config, pool, position, true);

    (object::id(position), fee_a, fee_b)
}

// === Test-Only Functions ===

#[test_only]
public fun effective_tier_for_testing(venue_config: &VenueConfig): (u32, u64) {
    venue_config.effective_tier()
}

/// Records a reservation without Cetus, whose capability the local link stub cannot mint.
#[test_only]
public fun reserve_for_testing<Meme, Quote>(venue_config: &mut VenueConfig, tick_spacing: u32) {
    venue_config.add_policy(ReservationKey<Meme, Quote>(), tick_spacing);
}

#[test_only]
public fun reserved_tick_spacing_for_testing<Meme, Quote>(venue_config: &VenueConfig): u32 {
    venue_config.reserved_tick_spacing<Meme, Quote>()
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::{
    allocation::Routes,
    blast_fun_domain::BLAST_FUN_DOMAIN,
    fee_router::{FeeRouter, RouterConfigCap},
    launch::{Launch, Migration},
    launch_config::LaunchConfig,
    launch_ticket::LaunchTicket,
    lp_fee_policy::LpFeePolicy,
    package_version::PackageVersion,
};

use blast_fun_migrators::{
    blast_events,
    migration_math,
    package_version::PackageVersion as MigratorsVersion,
    vault::{Self, LpVault},
    venue_config::VenueConfig,
};

use cetus_clmm::{
    config::{Self, GlobalConfig},
    factory::{Self, PoolCreationCap, Pools},
    pool::{Self, Pool},
    pool_creator,
    position::Position,
};

use sui::{balance::Balance, clock::Clock, coin::Coin, coin_registry::Currency};

use fun collect_position_fees as LpVault.collect_position_fees;

use fun complete_into_vault as Launch.complete_into_vault;

use fun effective_tier as VenueConfig.effective_tier;

use fun pool_creation_cap as VenueConfig.pool_creation_cap;

use fun reserved_tick_spacing as VenueConfig.reserved_tick_spacing;
