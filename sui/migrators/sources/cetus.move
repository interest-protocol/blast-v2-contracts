// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Cetus launch start, pool-creation reservation, migration into vault custody, and collection.
///
/// Anyone holding Meme can create a Cetus pool, and Cetus allows one pool per pair and tick
/// spacing, so a buyer could pre-create the migration pool at a price of their choosing. Starting
/// the launch therefore mints the Meme type's single Cetus `PoolCreationCap` from the ticket's
/// treasury capability, before any Meme can leave the ticket, and registers the pair at the
/// creator's tick spacing; afterwards only that capability or Cetus's pool-manager role can create
/// the pair's pool there. Trusting that role is a venue-operator assumption: a pool it creates
/// first makes the pair's migration abort, and only a migrators upgrade could recover the launch.
/// The capability stays in `VenueConfig` under a key only this module constructs, with no
/// extraction or unregistration path.
///
/// Migration burns the full-range position through Cetus LP Burn, so Cetus itself records the
/// launch liquidity as permanently locked; the vault keeps the `CetusLPBurnProof`, which can only
/// collect fees. A burned position cannot receive liquidity, so auto-LP adds to a second full-range
/// position the vault opens on first use and keeps with no removal path.
///
/// Cetus orders a pool's coin types by type name, so migration, collection, settled fee-split
/// updates, and buybacks each exist once per ordering.
module blast_fun_migrators::cetus;

// === Errors ===

#[error(code = 0)]
const EInvalidCoinOrder: vector<u8> = b"Migration route must match the Cetus coin order of the pair.";

#[error(code = 1)]
const EPositionPoolMismatch: vector<u8> = b"Pool must be the vault's own pool.";

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

// === Public Functions ===

/// Starts a Cetus launch in `Quote` at the creator's `tick_spacing` and reserves Cetus pool
/// creation for the pair.
///
/// Cetus fixes the fee rate of each registered tick spacing, and the launch records both. The
/// Meme type's single `PoolCreationCap` is minted from the ticket's treasury capability before
/// any Meme can leave it, and the pair is registered at `tick_spacing`. Aborts, leaving Cetus
/// unchanged, when Cetus does not register the spacing or refuses the pair at it, so the creator
/// can choose another tier or adapter instead. The creator completes the returned initializer
/// with `launch::finalize`.
public fun new<Meme, Quote>(
    ticket: LaunchTicket<Meme>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    config: &LaunchConfig,
    venue_config: &mut VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    tick_spacing: u32,
    ctx: &mut TxContext,
): LaunchInitializer<Meme, Quote> {
    migrators_version.assert_current();
    let fee_rate = config::get_fee_rate(tick_spacing, cetus_config);

    let mut launch = launch::new<Meme, Quote, _>(
        ticket,
        package_version,
        config,
        Witness(),
        tick_spacing,
        fee_rate,
    );
    let pool_creation_cap = factory::mint_pool_creation_cap(
        cetus_config,
        pools,
        launch.treasury_cap_mut(Witness()),
        ctx,
    );
    factory::register_permission_pair<Meme, Quote>(
        cetus_config,
        pools,
        tick_spacing,
        &pool_creation_cap,
        ctx,
    );
    let pool_creation_cap_id = object::id(&pool_creation_cap);
    venue_config.add_object(CreationCapKey<Meme>(), pool_creation_cap);

    blast_events::cetus_pool_reserved<Meme, Quote>(pool_creation_cap_id, tick_spacing);

    launch
}

/// Migrates a MigrationReady launch whose Meme is Cetus coin A into vault custody.
///
/// Creates the pair's pool with the reserved capability at the launch's tick spacing, priced from
/// the handed-off balances, seeds full-range liquidity with exactly those balances, and burns the
/// position. Any Cetus refusal, including a tier Cetus no longer registers, aborts the whole
/// migration and leaves the launch MigrationReady.
public fun migrate_meme_a<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    currency: &mut Currency<Meme>,
    venue_config: &VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    burn_manager: &mut BurnManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    assert!(factory::is_right_order<Meme, Quote>(), EInvalidCoinOrder);
    let (tick_spacing, _) = launch.pool_tier();
    let (tick_lower, tick_upper) = pool_creator::full_range_tick_range(tick_spacing);

    let (meme, quote, protocol_fees) = launch
        .migrate(package_version, currency, Witness(), ctx);
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

    burn_into_vault(
        launch,
        package_version,
        protocol_fees,
        burn_manager,
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
    currency: &mut Currency<Meme>,
    venue_config: &VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    burn_manager: &mut BurnManager,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    assert!(factory::is_right_order<Quote, Meme>(), EInvalidCoinOrder);
    let (tick_spacing, _) = launch.pool_tier();
    let (tick_lower, tick_upper) = pool_creator::full_range_tick_range(tick_spacing);

    let (meme, quote, protocol_fees) = launch
        .migrate(package_version, currency, Witness(), ctx);
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

    burn_into_vault(
        launch,
        package_version,
        protocol_fees,
        burn_manager,
        position,
        residual_meme,
        residual_quote,
        ctx,
    );
}

/// Collects the vault position's fees from its Meme-A pool, splits them, burns the burn share's
/// Meme, and adds the auto-LP share back to the position. Anyone may call it.
public fun collect_fees_meme_a<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    policy: &LpFeePolicy,
    launch: &mut Launch<Meme, Quote>,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let mut protocol_fees = launch.begin_protocol_fee_accrual(package_version, Witness());
    let (meme_fee, quote_fee) = self.collect_position_fees(cetus_config, burn_manager, pool, ctx);

    let (protocol_meme, protocol_quote) = self
        .split_fees(policy, currency, meme_fee, quote_fee, ctx);
    protocol_fees.add_protocol_fees(protocol_meme, protocol_quote);
    launch.settle_protocol_fee_accrual(package_version, protocol_fees);
    self.compound_meme_a(cetus_config, pool, clock, ctx);
}

/// Collects the vault position's fees from its Meme-B pool, splits them, burns the burn share's
/// Meme, and adds the auto-LP share back to the position. Anyone may call it.
public fun collect_fees_meme_b<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    policy: &LpFeePolicy,
    launch: &mut Launch<Meme, Quote>,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<Quote, Meme>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let mut protocol_fees = launch.begin_protocol_fee_accrual(package_version, Witness());
    let (quote_fee, meme_fee) = self.collect_position_fees(cetus_config, burn_manager, pool, ctx);

    let (protocol_meme, protocol_quote) = self
        .split_fees(policy, currency, meme_fee, quote_fee, ctx);
    protocol_fees.add_protocol_fees(protocol_meme, protocol_quote);
    launch.settle_protocol_fee_accrual(package_version, protocol_fees);
    self.compound_meme_b(cetus_config, pool, clock, ctx);
}

/// Settles the Meme-A position's accrued fees under the current split, then commits `proposed`.
public fun settle_and_update_fee_split_meme_a<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    policy: &LpFeePolicy,
    launch: &mut Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<Meme, Quote>,
    proposed: FeeSplit,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let mut protocol_fees = launch.begin_protocol_fee_accrual(package_version, Witness());
    self.assert_fee_split_update(launch, curve_fee_cap, proposed);
    let (meme_fee, quote_fee) = self.collect_position_fees(cetus_config, burn_manager, pool, ctx);

    let (protocol_meme, protocol_quote) = self
        .split_fees(policy, currency, meme_fee, quote_fee, ctx);
    protocol_fees.add_protocol_fees(protocol_meme, protocol_quote);
    launch.settle_protocol_fee_accrual(package_version, protocol_fees);
    self.compound_meme_a(cetus_config, pool, clock, ctx);
    self.update_fee_split(proposed);
}

/// Settles the Meme-B position's accrued fees under the current split, then commits `proposed`.
public fun settle_and_update_fee_split_meme_b<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    policy: &LpFeePolicy,
    launch: &mut Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<Quote, Meme>,
    proposed: FeeSplit,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let mut protocol_fees = launch.begin_protocol_fee_accrual(package_version, Witness());
    self.assert_fee_split_update(launch, curve_fee_cap, proposed);
    let (quote_fee, meme_fee) = self.collect_position_fees(cetus_config, burn_manager, pool, ctx);

    let (protocol_meme, protocol_quote) = self
        .split_fees(policy, currency, meme_fee, quote_fee, ctx);
    protocol_fees.add_protocol_fees(protocol_meme, protocol_quote);
    launch.settle_protocol_fee_accrual(package_version, protocol_fees);
    self.compound_meme_b(cetus_config, pool, clock, ctx);
    self.update_fee_split(proposed);
}

/// Swaps the vault's burn Quote for Meme in its Meme-A pool and burns it, under a buyback admin.
/// Aborts unless the swap returns at least `min_meme_out`; the admin sets it from an off-chain
/// price, since anyone can move the pool's price within a transaction.
public fun buyback_and_burn_meme_a<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    admin_witness: &AdminWitness<BuybackAdmin>,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    min_meme_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    assert!(self.pool_id() == object::id(pool), EPositionPoolMismatch);
    let quote = self.take_buyback_quote(admin_witness);
    let quote_in = quote.value();

    let (meme, quote) = swap(cetus_config, pool, balance::zero(), quote, false, clock);

    self.burn_buyback(currency, meme, quote, quote_in, min_meme_out, ctx);
}

/// Swaps the vault's burn Quote for Meme in its Meme-B pool and burns it, under a buyback admin.
///
/// Identical to `buyback_and_burn_meme_a` with Quote as coin A.
public fun buyback_and_burn_meme_b<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    admin_witness: &AdminWitness<BuybackAdmin>,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<Quote, Meme>,
    min_meme_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    assert!(self.pool_id() == object::id(pool), EPositionPoolMismatch);
    let quote = self.take_buyback_quote(admin_witness);
    let quote_in = quote.value();

    let (quote, meme) = swap(cetus_config, pool, quote, balance::zero(), true, clock);

    self.burn_buyback(currency, meme, quote, quote_in, min_meme_out, ctx);
}

// === Private Functions ===

fun pool_creation_cap<Meme>(venue_config: &VenueConfig): &PoolCreationCap {
    venue_config.object(CreationCapKey<Meme>())
}

/// Burns the position, settles Blast's migration allocation and venue residuals into the launch
/// ledger, and locks the burn proof in a new vault.
fun burn_into_vault<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    mut protocol_fees: ProtocolFeeAccrual<Meme, Quote, Witness>,
    burn_manager: &mut BurnManager,
    position: Position,
    residual_meme: Coin<Meme>,
    residual_quote: Coin<Quote>,
    ctx: &mut TxContext,
) {
    let pool_id = position.pool_id();
    let liquidity = position.liquidity();
    let burn_proof = lp_burn::burn_lp_v2(burn_manager, position, ctx);
    protocol_fees.add_protocol_fees(residual_meme.into_balance(), residual_quote.into_balance());
    launch.settle_protocol_fee_accrual(package_version, protocol_fees);
    vault::create(launch, &Venue(), pool_id, burn_proof, liquidity, ctx);
}

/// Collects the burned migration position's fees and, once it exists, the auto-LP position's fees
/// from `pool`, which must be the vault's own pool.
fun collect_position_fees<X, Y, Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<X, Y>,
    ctx: &mut TxContext,
): (Balance<X>, Balance<Y>) {
    assert!(self.pool_id() == object::id(pool), EPositionPoolMismatch);

    let burn_proof = self.position_mut<_, _, _, CetusLPBurnProof>(&Venue());
    let (fee_x, fee_y) = lp_burn::collect_fee(burn_manager, cetus_config, pool, burn_proof, ctx);
    let mut fee_x = fee_x.into_balance();
    let mut fee_y = fee_y.into_balance();
    if (self.has_auto_lp_position(&Venue())) {
        let position = self.auto_lp_position<_, _, _, Position>(&Venue());
        let (auto_lp_x, auto_lp_y) = pool::collect_fee(cetus_config, pool, position, true);
        fee_x.join(auto_lp_x);
        fee_y.join(auto_lp_y);
    };

    (fee_x, fee_y)
}

/// Adds the waiting auto-LP balances to the position in its Meme-A pool.
fun compound_meme_a<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<Meme, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (meme, quote) = self.take_auto_lp();
    let (meme, quote, added_meme, added_quote) = self.add_liquidity(
        cetus_config,
        pool,
        meme,
        quote,
        clock,
        ctx,
    );

    self.keep_auto_lp(added_meme, added_quote, meme, quote);
}

/// Adds the waiting auto-LP balances to the position in its Meme-B pool.
fun compound_meme_b<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<Quote, Meme>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (meme, quote) = self.take_auto_lp();
    let (quote, meme, added_quote, added_meme) = self.add_liquidity(
        cetus_config,
        pool,
        quote,
        meme,
        clock,
        ctx,
    );

    self.keep_auto_lp(added_meme, added_quote, meme, quote);
}

/// Adds as much of `a` and `b` as the auto-LP position takes at the pool's current price, fixing
/// the side Cetus's own liquidity math says the other side can cover, and returns the rest with
/// the amounts added. The burned migration position cannot receive liquidity, so the first add
/// opens a full-range auto-LP position the vault keeps with no removal path. Nothing is added while
/// either side is empty or would give zero liquidity.
fun add_liquidity<A, B, Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    mut a: Balance<A>,
    mut b: Balance<B>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Balance<A>, Balance<B>, u64, u64) {
    if (a.value() == 0 || b.value() == 0) return (a, b, 0, 0);
    if (!self.has_auto_lp_position(&Venue())) {
        let (tick_lower, tick_upper) = pool_creator::full_range_tick_range(pool.tick_spacing());
        let position = pool::open_position(cetus_config, pool, tick_lower, tick_upper, ctx);
        self.attach_auto_lp_position(&Venue(), position);
    };
    let position = self.auto_lp_position_mut<_, _, _, Position>(&Venue());
    let (lower, upper) = position.tick_range();
    let tick = pool.current_tick_index();
    let price = pool.current_sqrt_price();
    let (liquidity_a, _, needed_b) = clmm_math::get_liquidity_by_amount(
        lower,
        upper,
        tick,
        price,
        a.value(),
        true,
    );
    let (liquidity_b, needed_a, _) = clmm_math::get_liquidity_by_amount(
        lower,
        upper,
        tick,
        price,
        b.value(),
        false,
    );
    let (fix_a, amount) = if (liquidity_a > 0 && needed_b <= b.value()) {
        (true, a.value())
    } else if (liquidity_b > 0 && needed_a <= a.value()) {
        (false, b.value())
    } else {
        return (a, b, 0, 0)
    };

    let receipt = pool::add_liquidity_fix_coin(cetus_config, pool, position, amount, fix_a, clock);
    let (paid_a, paid_b) = receipt.add_liquidity_pay_amount();
    pool::repay_add_liquidity(cetus_config, pool, a.split(paid_a), b.split(paid_b), receipt);

    (a, b, paid_a, paid_b)
}

/// Swaps all of the input side (`a` when `a2b`) through `pool` up to the widest price limit, pays
/// what Cetus asks, and returns both sides: the unspent input and the output.
fun swap<A, B>(
    cetus_config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    mut a: Balance<A>,
    mut b: Balance<B>,
    a2b: bool,
    clock: &Clock,
): (Balance<A>, Balance<B>) {
    let (amount, sqrt_price_limit) = if (a2b) (a.value(), constants::min_swap_sqrt_price!())
    else (b.value(), constants::max_swap_sqrt_price!());
    let (out_a, out_b, receipt) = pool::flash_swap(
        cetus_config,
        pool,
        a2b,
        true,
        amount,
        sqrt_price_limit,
        clock,
    );
    let paid = receipt.swap_pay_amount();
    let (pay_a, pay_b) = if (a2b) (a.split(paid), balance::zero())
    else (balance::zero(), b.split(paid));

    pool::repay_flash_swap(cetus_config, pool, pay_a, pay_b, receipt);
    a.join(out_a);
    b.join(out_b);

    (a, b)
}

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_fun::{
    allocation::FeeSplit,
    blast_fun_domain::BuybackAdmin,
    creator_authority::CurveFeeCap,
    launch::{Self, Launch, LaunchInitializer, ProtocolFeeAccrual},
    launch_config::LaunchConfig,
    launch_ticket::LaunchTicket,
    package_version::PackageVersion,
};

use blast_fun_migrators::{
    blast_events,
    constants,
    lp_fee_policy::LpFeePolicy,
    migration_math,
    package_version::PackageVersion as MigratorsVersion,
    vault::{Self, LpVault},
    venue_config::VenueConfig,
};

use cetus_clmm::{
    clmm_math,
    config::{Self, GlobalConfig},
    factory::{Self, PoolCreationCap, Pools},
    pool::{Self, Pool},
    pool_creator,
    position::Position,
};

use lp_burn::lp_burn::{Self, BurnManager, CetusLPBurnProof};

use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, coin_registry::Currency};

use fun add_liquidity as LpVault.add_liquidity;

use fun collect_position_fees as LpVault.collect_position_fees;

use fun compound_meme_a as LpVault.compound_meme_a;

use fun compound_meme_b as LpVault.compound_meme_b;

use fun pool_creation_cap as VenueConfig.pool_creation_cap;
