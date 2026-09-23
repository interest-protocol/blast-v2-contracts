// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Bluefin migration, fee collection, and settled route updates over custodied
/// concentrated-liquidity principal.
///
/// Bluefin pools are keyed by their exact type-parameter order, so this module
/// always creates and expects `Pool<Meme, Quote>` with Meme as coin A.
module blast_fun_migrators::bluefin;

// === Errors ===

#[error(code = 0)]
const EPositionPoolMismatch: vector<u8> = b"Custodied position must belong to the supplied pool.";

// === Public Types ===

/// Sealed adapter identity selected by a Blast launch.
public struct Witness() has drop;

/// Sealed marker for the Bluefin position attached to the common vault.
public struct Venue() has drop;

// === Public Functions ===

/// Binds a launch ticket to Bluefin migration in `Quote`; the core aborts unless it admits Bluefin.
public fun bind<Meme, Quote>(ticket: &mut LaunchTicket<Meme>, config: &LaunchConfig) {
    ticket.bind_migration_witness<Meme, Quote, Witness>(config, Witness());
}

/// Migrates a MigrationReady launch into a new full-range pool at the admin-pinned tier.
///
/// The opening price derives from the handed-off balances. Meme is the fixed side when its atoms
/// are at least the Quote atoms, and Quote otherwise: a full-range seed fixed on the fewer atoms
/// can need slightly more of the other asset than was handed off. `creation_fee` is paid whole,
/// and Bluefin aborts unless it is exactly the configured SUI fee. The position and the venue
/// residuals stay in a shared vault with no withdrawal path. The caller receives no object;
/// Bluefin records it as the new pool's manager, a role limited to the pool's reward emissions
/// and to handing the role on (ADR 0088).
public fun migrate<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    router: &mut FeeRouter<Meme, Quote>,
    policy: &LpFeePolicy,
    currency: &mut Currency<Meme>,
    quote_currency: &Currency<Quote>,
    venue_config: &VenueConfig,
    bluefin_config: &mut GlobalConfig,
    creation_fee: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let (tick_spacing, fee_rate) = venue_config.tier<Venue>();
    let (minimum_tick, maximum_tick) = bluefin_config.get_tick_range();
    let spacing = i32::from(tick_spacing);
    let lower_tick = minimum_tick.div(spacing).mul(spacing).as_u32();
    let upper_tick = maximum_tick.div(spacing).mul(spacing).as_u32();
    let meme_icon_url = currency.icon_url().into_bytes();
    let mut pool_name = currency.symbol().into_bytes();
    pool_name.append(b"-");
    pool_name.append(quote_currency.symbol().into_bytes());

    let (meme, quote, migration) = launch.begin_migration(package_version, Witness());
    let source_meme = meme.value();
    let source_quote = quote.value();
    let fix_meme = source_meme >= source_quote;

    let mut pool = pool::create_pool_and_get_object<Meme, Quote, SUI>(
        clock,
        bluefin_config,
        pool_name,
        meme_icon_url,
        currency.symbol().into_bytes(),
        currency.decimals(),
        meme_icon_url,
        quote_currency.symbol().into_bytes(),
        quote_currency.decimals(),
        quote_currency.icon_url().into_bytes(),
        tick_spacing,
        fee_rate,
        migration_math::sqrt_price_x64(source_meme, source_quote, true),
        creation_fee.into_balance(),
        ctx,
    );
    let mut position = pool::open_position(bluefin_config, &mut pool, lower_tick, upper_tick, ctx);
    let (supplied_meme, supplied_quote, residual_meme, residual_quote) =
        pool::add_liquidity_with_fixed_amount(
            clock,
            bluefin_config,
            &mut pool,
            &mut position,
            meme,
            quote,
            if (fix_meme) source_meme else source_quote,
            fix_meme,
        );

    let mut vault = vault::prepare(residual_meme, residual_quote, ctx);
    vault.attach(&Venue(), position.pool_id(), position);
    let position = vault.position<_, _, _, Position>(&Venue());
    let (residual_meme, residual_quote) = vault.pending_residuals();
    launch.complete_migration(
        package_version,
        router,
        policy,
        currency,
        migration,
        Witness(),
        &vault,
        position.pool_id(),
        position,
        supplied_meme,
        supplied_quote,
        residual_meme,
        residual_quote,
        position.liquidity(),
        ctx,
    );
    vault.share(&Venue());
    pool.share_pool_object();
}

/// Collects the custodied position's fees and pays them by the router's current routes.
public fun collect_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    router: &mut FeeRouter<Meme, Quote>,
    policy: &LpFeePolicy,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let (position_id, meme_fee, quote_fee) = self.collect_position_fees(bluefin_config, pool, clock);

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

/// Pays the custodied position's fees by the current routes, then commits `proposed`.
public fun settle_and_update_routes<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    router: &mut FeeRouter<Meme, Quote>,
    policy: &LpFeePolicy,
    router_config_cap: &RouterConfigCap<Meme, Quote>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    proposed: Routes,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let (position_id, meme_fee, quote_fee) = self.collect_position_fees(bluefin_config, pool, clock);

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

/// Pins the Bluefin tier under a live core admin witness.
///
/// Bluefin bounds the pair itself (tick spacing at most 400, fee rate at most 20,000): pool
/// creation rejects a pin above either bound, so migration aborts until a valid pair is pinned.
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

/// Collects the attached position's fees from `pool`, which must be the position's own pool.
fun collect_position_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    bluefin_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
): (ID, Balance<Meme>, Balance<Quote>) {
    let position = self.position_mut<_, _, _, Position>(&Venue());
    assert!(position.pool_id() == object::id(pool), EPositionPoolMismatch);

    let (_, _, meme_fee, quote_fee) = pool::collect_fee(clock, bluefin_config, pool, position);

    (object::id(position), meme_fee, quote_fee)
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::{
    allocation::Routes,
    blast_fun_domain::BLAST_FUN_DOMAIN,
    fee_router::{FeeRouter, RouterConfigCap},
    launch::Launch,
    launch_config::LaunchConfig,
    launch_ticket::LaunchTicket,
    lp_fee_policy::LpFeePolicy,
    package_version::PackageVersion,
};

use blast_fun_migrators::{
    migration_math,
    package_version::PackageVersion as MigratorsVersion,
    vault::{Self, LpVault},
    venue_config::VenueConfig,
};

use bluefin_spot::{config::GlobalConfig, pool::{Self, Pool}, position::Position};

use integer_mate::i32;

use sui::{balance::Balance, clock::Clock, coin::Coin, coin_registry::Currency, sui::SUI};

use fun collect_position_fees as LpVault.collect_position_fees;
