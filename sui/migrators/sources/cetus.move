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
/// Cetus orders a pool's coin types by type name. Each route after `new` takes the pool's coin
/// types as `CoinA` and `CoinB` beside the launch's `Meme` and `Quote`, proves they are the same
/// pair, and retypes balances between the two orders through a checked dynamic-field round trip
/// (ADR 0100).
module blast_fun_migrators::cetus;

// === Errors ===

#[error(code = 0)]
const EInvalidCoinOrder: vector<u8> = b"CoinA and CoinB must follow the Cetus coin order.";

#[error(code = 1)]
const EPositionPoolMismatch: vector<u8> = b"Pool must be the vault's own pool.";

#[error(code = 2)]
const EWrongCoinPair: vector<u8> = b"CoinA and CoinB must be exactly the launch's Meme and Quote.";

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

/// Transient dynamic-field name `cast` uses to retype a coin or balance.
public struct CastKey() has copy, drop, store;

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

/// Migrates a MigrationReady launch into vault custody. `CoinA` and `CoinB` name the launch's
/// Meme and Quote in Cetus's canonical coin order.
///
/// Creates the pair's pool with the reserved capability at the launch's tick spacing, priced from
/// the handed-off balances, seeds full-range liquidity with exactly those balances on the side
/// `seed_fixes_a` chooses, and burns the position; Cetus returns what it does not take as
/// residual. Any Cetus refusal, including a tier Cetus no longer registers, aborts the whole
/// migration and leaves the launch MigrationReady.
public fun migrate<Meme, Quote, CoinA, CoinB>(
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
    assert!(factory::is_right_order<CoinA, CoinB>(), EInvalidCoinOrder);
    let meme_is_a = meme_is_coin_a<Meme, Quote, CoinA, CoinB>();

    let (tick_spacing, _) = launch.pool_tier();
    let (tick_lower, tick_upper) = pool_creator::full_range_tick_range(tick_spacing);
    let (meme, quote) = launch.migrate(package_version, currency, Witness(), ctx);

    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let sqrt_price = migration_math::sqrt_price_x64(meme_amount, quote_amount, meme_is_a);
    let fix_a = seed_fixes_a(
        tick_lower,
        tick_upper,
        sqrt_price,
        meme_amount,
        quote_amount,
        meme_is_a,
    );
    let (coin_a, coin_b) = reorder(meme.into_coin(ctx), quote.into_coin(ctx), meme_is_a, ctx);

    let (position, residual_a, residual_b) =
        pool_creator::create_pool_v3_with_creation_cap<CoinA, CoinB>(
            cetus_config,
            pools,
            venue_config.pool_creation_cap<Meme>(),
            tick_spacing,
            sqrt_price,
            b"".to_string(),
            tick_lower,
            tick_upper,
            coin_a,
            coin_b,
            fix_a,
            clock,
            ctx,
        );
    let (residual_meme, residual_quote) = reorder(residual_a, residual_b, meme_is_a, ctx);

    burn_into_vault(launch, burn_manager, position, residual_meme, residual_quote, ctx);
}

/// Collects the vault position's fees from its pool, splits them, burns the burn share's Meme, and
/// adds the auto-LP share back to the position. Anyone may call it. `CoinA` and `CoinB` are the
/// pool's coin order.
public fun collect_fees<Meme, Quote, CoinA, CoinB>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    policy: &LpFeePolicy,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<CoinA, CoinB>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let meme_is_a = meme_is_coin_a<Meme, Quote, CoinA, CoinB>();

    self.settle_fees(policy, currency, cetus_config, burn_manager, pool, meme_is_a, clock, ctx);
}

/// Settles the position's accrued fees under the current split, then commits `proposed`. `CoinA`
/// and `CoinB` are the pool's coin order.
public fun settle_and_update_fee_split<Meme, Quote, CoinA, CoinB>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    policy: &LpFeePolicy,
    launch: &Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<CoinA, CoinB>,
    proposed: FeeSplit,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let meme_is_a = meme_is_coin_a<Meme, Quote, CoinA, CoinB>();
    self.assert_fee_split_update(launch, curve_fee_cap, proposed);

    self.settle_fees(policy, currency, cetus_config, burn_manager, pool, meme_is_a, clock, ctx);

    self.update_fee_split(proposed);
}

/// Swaps the vault's burn Quote for Meme in its pool and burns it, under a buyback admin. Aborts
/// unless the swap returns at least `min_meme_out`; the admin sets it from an off-chain price,
/// since anyone can move the pool's price within a transaction. `CoinA` and `CoinB` are the pool's
/// coin order.
public fun buyback_and_burn<Meme, Quote, CoinA, CoinB>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    admin_witness: &AdminWitness<BuybackAdmin>,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<CoinA, CoinB>,
    min_meme_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let meme_is_a = meme_is_coin_a<Meme, Quote, CoinA, CoinB>();
    assert!(self.pool_id() == object::id(pool), EPositionPoolMismatch);

    let quote = self.take_buyback_quote(admin_witness);
    let quote_in = quote.value();
    let (meme, quote) = swap_quote_for_meme(cetus_config, pool, quote, meme_is_a, clock, ctx);

    self.burn_buyback(currency, meme, quote, quote_in, min_meme_out, ctx);
}

// === Private Functions ===

fun pool_creation_cap<Meme>(venue_config: &VenueConfig): &PoolCreationCap {
    venue_config.object(CreationCapKey<Meme>())
}

/// Whether the migration seed fixes coin A, preferring the side with more atoms, Meme on a tie: a
/// full-range position needs slightly more of the other side than the seed ratio, so that partner
/// balance covers it. When both sides are nearly equal, rounding can still overdraw by one atom,
/// so Cetus's own math decides and the other side is fixed instead. Any tick inside the full range
/// selects Cetus's in-range branch; pool creation aborts anyway if the seed price lies outside it.
fun seed_fixes_a(
    tick_lower: u32,
    tick_upper: u32,
    sqrt_price: u128,
    meme_amount: u64,
    quote_amount: u64,
    meme_is_a: bool,
): bool {
    let (amount_a, amount_b) = if (meme_is_a) (meme_amount, quote_amount)
    else (quote_amount, meme_amount);
    let prefer_a = (meme_amount >= quote_amount) == meme_is_a;
    let (_, needed_a, needed_b) = clmm_math::get_liquidity_by_amount(
        i32::from_u32(tick_lower),
        i32::from_u32(tick_upper),
        i32::zero(),
        sqrt_price,
        if (prefer_a) amount_a else amount_b,
        prefer_a,
    );

    if (needed_a <= amount_a && needed_b <= amount_b) prefer_a else !prefer_a
}

/// Burns the position and locks its burn proof and the residuals in a new vault.
fun burn_into_vault<Meme, Quote>(
    launch: &Launch<Meme, Quote>,
    burn_manager: &mut BurnManager,
    position: Position,
    residual_meme: Coin<Meme>,
    residual_quote: Coin<Quote>,
    ctx: &mut TxContext,
) {
    let pool_id = position.pool_id();
    let liquidity = position.liquidity();

    let burn_proof = lp_burn::burn_lp_v2(burn_manager, position, ctx);
    vault::create(
        launch,
        &Venue(),
        pool_id,
        burn_proof,
        liquidity,
        residual_meme.into_balance(),
        residual_quote.into_balance(),
        ctx,
    );
}

/// Collects the position's fees, splits them through the vault, and adds the auto-LP share back.
fun settle_fees<Meme, Quote, CoinA, CoinB>(
    self: &mut LpVault<Meme, Quote>,
    policy: &LpFeePolicy,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<CoinA, CoinB>,
    meme_is_a: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (meme_fee, quote_fee) = self.collect_position_fees(
        cetus_config,
        burn_manager,
        pool,
        meme_is_a,
        ctx,
    );
    self.split_fees(policy, currency, meme_fee, quote_fee, ctx);
    self.compound(cetus_config, pool, meme_is_a, clock, ctx);
}

/// Collects the burned migration position's fees and, once it exists, the auto-LP position's fees
/// from `pool`, which must be the vault's own pool, and returns them as Meme and Quote.
fun collect_position_fees<Meme, Quote, CoinA, CoinB>(
    self: &mut LpVault<Meme, Quote>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<CoinA, CoinB>,
    meme_is_a: bool,
    ctx: &mut TxContext,
): (Balance<Meme>, Balance<Quote>) {
    assert!(self.pool_id() == object::id(pool), EPositionPoolMismatch);

    let (fee_a, fee_b) = lp_burn::collect_fee(
        burn_manager,
        cetus_config,
        pool,
        self.position_mut<_, _, _, CetusLPBurnProof>(&Venue()),
        ctx,
    );
    let mut fee_a = fee_a.into_balance();
    let mut fee_b = fee_b.into_balance();

    if (self.has_auto_lp_position(&Venue())) {
        let position = self.auto_lp_position<_, _, _, Position>(&Venue());
        let (auto_lp_a, auto_lp_b) = pool::collect_fee(cetus_config, pool, position, true);
        fee_a.join(auto_lp_a);
        fee_b.join(auto_lp_b);
    };

    reorder(fee_a, fee_b, meme_is_a, ctx)
}

/// Adds the waiting auto-LP balances to the auto-LP position in the vault's pool.
fun compound<Meme, Quote, CoinA, CoinB>(
    self: &mut LpVault<Meme, Quote>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<CoinA, CoinB>,
    meme_is_a: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (meme, quote) = self.take_auto_lp();
    let (a, b) = reorder(meme, quote, meme_is_a, ctx);
    let (a, b, added_a, added_b) = self.add_liquidity(cetus_config, pool, a, b, clock, ctx);

    let (meme, quote) = reorder(a, b, meme_is_a, ctx);
    let (added_meme, added_quote) = if (meme_is_a) (added_a, added_b) else (added_b, added_a);
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
    let (fix_a, amount) = fixed_side(pool, position, a.value(), b.value());
    if (amount == 0) return (a, b, 0, 0);

    let receipt = pool::add_liquidity_fix_coin(cetus_config, pool, position, amount, fix_a, clock);
    let (paid_a, paid_b) = receipt.add_liquidity_pay_amount();
    pool::repay_add_liquidity(cetus_config, pool, a.split(paid_a), b.split(paid_b), receipt);

    (a, b, paid_a, paid_b)
}

/// Chooses the side an auto-LP add fixes, and how much: `a` when Cetus's own liquidity math says
/// `amount_b` covers it, else `b` when `amount_a` covers that. A zero amount means neither side
/// gives positive liquidity the other can cover, so nothing is added now.
fun fixed_side<A, B>(
    pool: &Pool<A, B>,
    position: &Position,
    amount_a: u64,
    amount_b: u64,
): (bool, u64) {
    let (lower, upper) = position.tick_range();
    let tick = pool.current_tick_index();
    let price = pool.current_sqrt_price();
    let (liquidity_a, _, needed_b) = clmm_math::get_liquidity_by_amount(
        lower,
        upper,
        tick,
        price,
        amount_a,
        true,
    );
    let (liquidity_b, needed_a, _) = clmm_math::get_liquidity_by_amount(
        lower,
        upper,
        tick,
        price,
        amount_b,
        false,
    );

    if (liquidity_a > 0 && needed_b <= amount_b) (true, amount_a)
    else if (liquidity_b > 0 && needed_a <= amount_a) (false, amount_b)
    else (true, 0)
}

/// Swaps all of `quote` for Meme through `pool` in the pool's coin order, returning the Meme bought
/// and the Quote the pool did not take.
fun swap_quote_for_meme<Meme, Quote, CoinA, CoinB>(
    cetus_config: &GlobalConfig,
    pool: &mut Pool<CoinA, CoinB>,
    quote: Balance<Quote>,
    meme_is_a: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (Balance<Meme>, Balance<Quote>) {
    let (a, b) = reorder(balance::zero<Meme>(), quote, meme_is_a, ctx);
    let (a, b) = swap(cetus_config, pool, a, b, !meme_is_a, clock);

    reorder(a, b, meme_is_a, ctx)
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

/// Whether Meme is `CoinA`, after proving `(CoinA, CoinB)` is exactly the launch's Meme and Quote.
fun meme_is_coin_a<Meme, Quote, CoinA, CoinB>(): bool {
    let (meme, quote) = (type_name::with_original_ids<Meme>(), type_name::with_original_ids<Quote>());
    let (a, b) = (type_name::with_original_ids<CoinA>(), type_name::with_original_ids<CoinB>());
    assert!((meme == a && quote == b) || (meme == b && quote == a), EWrongCoinPair);

    meme == a
}

/// Retypes a pair between Meme-and-Quote order and the pool's coin order: it keeps `(x, y)` in
/// place when Meme is coin A and swaps them otherwise, which maps either order onto the other.
/// Each value moves through `cast`, so the framework aborts unless its type is unchanged.
fun reorder<X: store, Y: store, First: store, Second: store>(
    x: X,
    y: Y,
    meme_is_a: bool,
    ctx: &mut TxContext,
): (First, Second) {
    let mut scratch = object::new(ctx);
    let (first, second) = if (meme_is_a) {
        (cast(&mut scratch, x), cast(&mut scratch, y))
    } else {
        (cast(&mut scratch, y), cast(&mut scratch, x))
    };
    scratch.delete();

    (first, second)
}

/// Retypes `value` as `To` through a dynamic field on `scratch`. Removal succeeds only under the
/// stored type, so this aborts with the framework's `EFieldTypeMismatch` unless `From` and `To` are
/// the same type; `meme_is_coin_a` has already proven that for every call.
fun cast<From: store, To: store>(scratch: &mut UID, value: From): To {
    dynamic_field::add(scratch, CastKey(), value);
    dynamic_field::remove(scratch, CastKey())
}

// === Test-Only Functions ===

#[test_only]
public fun meme_is_coin_a_for_testing<Meme, Quote, CoinA, CoinB>(): bool {
    meme_is_coin_a<Meme, Quote, CoinA, CoinB>()
}

#[test_only]
public fun reorder_for_testing<X: store, Y: store, First: store, Second: store>(
    x: X,
    y: Y,
    meme_is_a: bool,
    ctx: &mut TxContext,
): (First, Second) {
    reorder(x, y, meme_is_a, ctx)
}

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_fun::{
    allocation::FeeSplit,
    blast_fun_domain::BuybackAdmin,
    creator_authority::CurveFeeCap,
    launch::{Self, Launch, LaunchInitializer},
    launch_config::LaunchConfig,
    launch_ticket::LaunchTicket,
    blast_fun::PackageVersion,
};

use blast_fun_migrators::{
    blast_events,
    constants,
    lp_fee_policy::LpFeePolicy,
    migration_math,
    blast_fun_migrators::PackageVersion as MigratorsVersion,
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

use integer_mate::i32;

use lp_burn::lp_burn::{Self, BurnManager, CetusLPBurnProof};

use std::type_name;

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    coin_registry::Currency,
    dynamic_field,
};

use fun add_liquidity as LpVault.add_liquidity;
use fun collect_position_fees as LpVault.collect_position_fees;
use fun compound as LpVault.compound;
use fun settle_fees as LpVault.settle_fees;

use fun pool_creation_cap as VenueConfig.pool_creation_cap;
