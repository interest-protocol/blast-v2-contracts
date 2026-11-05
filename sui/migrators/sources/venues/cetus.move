// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the venue's abort location.
#[allow(lint(abort_without_constant))]
/// Cetus coin preparation, pool-creation reservation, migration into `blast_vault` custody, and
/// collection, for launches and presales alike.
///
/// Anyone holding Meme can create a Cetus pool, and Cetus allows one pool per pair and tick
/// spacing, so a buyer could pre-create the migration pool at a price of their choosing.
/// Preparing the coin therefore mints the Meme type's single Cetus `PoolCreationCap` from its
/// treasury capability, before any Meme can leave the sale's custody, registers the pair at the
/// creator's tick spacing, and returns a `VenueTicket` for that pair the sale redeems; afterwards
/// only that capability or Cetus's pool-manager role can create the pair's pool there. Trusting
/// that role is a venue-operator assumption: a pool it creates first makes the pair's migration
/// abort, and only a migrators upgrade could recover the sale.
/// The capability stays in `VenueConfig` under a key only this module constructs, with no
/// extraction or unregistration path.
///
/// Migration redeems the `Migration` the sale's own `migrate` returned earlier in the transaction
/// and burns the full-range position through Cetus LP Burn, so Cetus itself records the sale's
/// liquidity as permanently locked; the `blast_vault` vault keeps the `CetusLPBurnProof`, which can
/// only collect fees. A burned position cannot receive liquidity, so auto-LP adds to a second
/// full-range position the vault opens on first use and keeps with no removal path.
///
/// Cetus orders a pool's coin types by type name. Each route after `prepare` takes the pool's coin
/// types as `CoinA` and `CoinB` beside the sale's `Meme` and `Quote`, proves they are the same
/// pair, and retypes balances between the two orders through a checked dynamic-field round trip
/// (ADR 0100).
module blast_migrators::cetus;

// === Public Types ===

/// The Cetus venue's sealed witness: it issues tickets, redeems migrations, and keys the position
/// in the vault, so each product's venue list and the vault registry admit this one type.
public struct Venue() has drop;

/// Sealed `VenueConfig` object-field name for the Meme type's Cetus `PoolCreationCap`.
///
/// The capability is a dynamic object field, so it keeps the ID that Cetus's permission registry
/// and every `CetusPoolReserved` event record, and stays readable by that ID.
public struct CreationCapKey<phantom Meme>() has copy, drop, store;

/// Sealed `VenueConfig` field name for the Meme type's Cetus tick spacing.
public struct PoolTierKey<phantom Meme>() has copy, drop, store;

/// Transient dynamic-field name `cast` uses to retype a coin or balance.
public struct CastKey() has copy, drop, store;

// === Public Functions ===

/// Prepares `Meme` for a Cetus sale in `Quote` at the creator's `tick_spacing`, reserving Cetus
/// pool creation for the pair, and returns the ticket the product's `new` redeems.
///
/// The Meme type's single `PoolCreationCap` is minted from `treasury_cap` before any Meme can
/// leave the sale's custody, the pair is registered at `tick_spacing`, and the spacing is recorded.
/// Aborts, leaving Cetus unchanged, when Cetus does not register the spacing or refuses the pair
/// at it, so the creator can choose another tier or venue instead.
public fun prepare<Meme, Quote>(
    migrators_version: &PackageVersion<BLAST_MIGRATORS>,
    venue_config: &mut VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    treasury_cap: &mut TreasuryCap<Meme>,
    tick_spacing: u32,
    ctx: &mut TxContext,
): VenueTicket<Meme, Quote> {
    migrators_version.assert_current(constants::version!());
    // Aborts unless Cetus registers the spacing.
    let _ = config::get_fee_rate(tick_spacing, cetus_config);

    let pool_creation_cap = factory::mint_pool_creation_cap(
        cetus_config,
        pools,
        treasury_cap,
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
    venue_config.add_value(PoolTierKey<Meme>(), tick_spacing);

    events::cetus_pool_reserved<Meme, Quote>(pool_creation_cap_id, tick_spacing);

    migration::issue_ticket(Venue())
}

/// Migrates a sale into a Cetus pool and a `blast_vault` vault: `migration` is the hand-off the
/// launch's or presale's own `migrate` returned earlier in the transaction. `CoinA` and `CoinB`
/// name the sale's Meme and Quote in Cetus's canonical coin order.
///
/// Redeems the hand-off, creates the pair's pool with the reserved capability at the recorded
/// tick spacing, priced from the handed-off balances, seeds full-range liquidity with exactly
/// those balances on the side `is_coin_a_seed_side` chooses, burns the position, and creates the
/// vault from the sale's terms with the burn proof and Cetus's residual. Any Cetus refusal,
/// including a tier Cetus no longer registers, aborts the whole transaction, the product's
/// `migrate` with it, so the sale stays ready to migrate.
public fun migrate<Meme, Quote, CoinA, CoinB>(
    migration: Migration<Meme, Quote>,
    migrators_version: &PackageVersion<BLAST_MIGRATORS>,
    venue_config: &VenueConfig,
    cetus_config: &GlobalConfig,
    pools: &mut Pools,
    burn_manager: &mut BurnManager,
    registry: &mut VaultRegistry,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current(constants::version!());
    assert!(
        factory::is_right_order<CoinA, CoinB>(),
        blast_migrators::errors::invalid_coin_order!(),
    );
    let meme_is_a = is_meme_coin_a<Meme, Quote, CoinA, CoinB>();
    let (meme, quote, terms) = migration.redeem(Venue());

    let tick_spacing = *venue_config.value(PoolTierKey<Meme>());
    let (tick_lower, tick_upper) = pool_creator::full_range_tick_range(tick_spacing);

    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let sqrt_price = migration::sqrt_price_x64(meme_amount, quote_amount, meme_is_a);
    let fix_a = is_coin_a_seed_side(
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
    let (residual_meme, residual_quote): (Coin<Meme>, Coin<Quote>) = reorder(
        residual_a,
        residual_b,
        meme_is_a,
        ctx,
    );

    let pool_id = position.pool_id();
    let liquidity = position.liquidity();
    let burn_proof = lp_burn::burn_lp_v2(burn_manager, position, ctx);
    vault::new<Meme, Quote, _>(registry, &Venue(), vault_version, terms, pool_id)
        .share_with_position(
            &Venue(),
            treasury,
            burn_proof,
            liquidity,
            residual_meme.into_balance(),
            residual_quote.into_balance(),
            ctx,
        );
}

/// Collects the vault position's fees from its pool, splits them, and burns the burn share's Meme;
/// the auto-LP share waits in the vault for `compound_auto_lp`. Anyone may call it. `CoinA` and
/// `CoinB` are the pool's coin order.
public fun collect_fees<Meme, Quote, CoinA, CoinB>(
    self: &mut Vault<Meme, Quote>,
    migrators_version: &PackageVersion<BLAST_MIGRATORS>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<CoinA, CoinB>,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current(constants::version!());
    let meme_is_a = is_meme_coin_a<Meme, Quote, CoinA, CoinB>();

    self.settle_fees(
        vault_version,
        treasury,
        currency,
        cetus_config,
        burn_manager,
        pool,
        meme_is_a,
        ctx,
    );
}

/// Anyone may settle accrued fees under the current split, then apply the stored ready proposal. `CoinA`
/// and `CoinB` are the pool's coin order.
public fun settle_and_apply_fee_split<Meme, Quote, CoinA, CoinB>(
    self: &mut Vault<Meme, Quote>,
    migrators_version: &PackageVersion<BLAST_MIGRATORS>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<CoinA, CoinB>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current(constants::version!());
    let meme_is_a = is_meme_coin_a<Meme, Quote, CoinA, CoinB>();
    self.assert_fee_split_ready(clock);

    self.settle_fees(
        vault_version,
        treasury,
        currency,
        cetus_config,
        burn_manager,
        pool,
        meme_is_a,
        ctx,
    );

    self.apply_fee_split(&Venue(), vault_version, clock);
}

/// Adds the vault's waiting auto-LP Meme and Quote to its auto-LP position in `pool` at the
/// current price and keeps the rest for the next call. Anyone may call it, apart from collection,
/// so a Cetus refusal of the add never blocks collecting fees. `CoinA` and `CoinB` are the pool's
/// coin order.
public fun compound_auto_lp<Meme, Quote, CoinA, CoinB>(
    self: &mut Vault<Meme, Quote>,
    migrators_version: &PackageVersion<BLAST_MIGRATORS>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<CoinA, CoinB>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current(constants::version!());
    let meme_is_a = is_meme_coin_a<Meme, Quote, CoinA, CoinB>();
    assert!(self.pool_id() == object::id(pool), blast_migrators::errors::position_pool_mismatch!());

    self.compound(vault_version, cetus_config, pool, meme_is_a, clock, ctx);
}

/// Swaps `quote_in` of the vault's burn Quote for Meme in its pool and burns it, under a buyback
/// admin. Aborts unless `quote_in` is positive and at most the burn Quote held, and unless the swap
/// returns at least `min_meme_out`; the admin sets it from an off-chain price, since anyone can move
/// the pool's price within a transaction. Quote the pool does not take stays for the next buyback.
/// `CoinA` and `CoinB` are the pool's coin order.
public fun buyback_and_burn<Meme, Quote, CoinA, CoinB>(
    self: &mut Vault<Meme, Quote>,
    migrators_version: &PackageVersion<BLAST_MIGRATORS>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    admin_witness: &AdminWitness<BuybackAdmin>,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<CoinA, CoinB>,
    quote_in: u64,
    min_meme_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current(constants::version!());
    let meme_is_a = is_meme_coin_a<Meme, Quote, CoinA, CoinB>();
    assert!(self.pool_id() == object::id(pool), blast_migrators::errors::position_pool_mismatch!());

    let (quote, receipt) = self.take_buyback_quote(&Venue(), admin_witness, vault_version, quote_in);
    let (meme, quote) = pool.swap_quote_for_meme(cetus_config, quote, meme_is_a, clock, ctx);

    self.burn_buyback(&Venue(), vault_version, receipt, currency, meme, quote, min_meme_out, ctx);
}

// === Private Functions ===

/// Borrows the Meme type's reserved Cetus `PoolCreationCap` from the venue config.
fun pool_creation_cap<Meme>(venue_config: &VenueConfig): &PoolCreationCap {
    venue_config.object(CreationCapKey<Meme>())
}

/// Whether coin A is the side the migration seed fixes, preferring the side with more atoms, Meme
/// on a tie: a full-range position needs slightly more of the other side than the seed ratio, so
/// that partner balance covers it. When both sides are nearly equal, rounding can still overdraw by
/// one atom, so Cetus's own math decides and the other side is fixed instead. Any tick inside the
/// full range selects Cetus's in-range branch; pool creation aborts anyway if the seed price lies
/// outside it.
fun is_coin_a_seed_side(
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

    seed_fixed_side(prefer_a, amount_a, amount_b, needed_a, needed_b)
}

/// Keeps the preferred seed side if the venue's rounded requirements fit both balances, and fixes
/// the other side otherwise.
fun seed_fixed_side(
    preferred: bool,
    available_a: u64,
    available_b: u64,
    needed_a: u64,
    needed_b: u64,
): bool {
    if (needed_a <= available_a && needed_b <= available_b) preferred else !preferred
}

/// Collects the position's fees and splits them through the vault; the auto-LP share waits for
/// `compound_auto_lp`.
fun settle_fees<Meme, Quote, CoinA, CoinB>(
    self: &mut Vault<Meme, Quote>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    treasury: &Treasury,
    currency: &mut Currency<Meme>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<CoinA, CoinB>,
    meme_is_a: bool,
    ctx: &mut TxContext,
) {
    let (meme_fee, quote_fee) = self.collect_position_fees(
        vault_version,
        cetus_config,
        burn_manager,
        pool,
        meme_is_a,
        ctx,
    );
    self.split_fees(&Venue(), vault_version, treasury, currency, meme_fee, quote_fee, ctx);
}

/// Collects the burned migration position's fees and, once it exists, the auto-LP position's fees
/// from `pool`, which must be the vault's own pool, and returns them as Meme and Quote.
fun collect_position_fees<Meme, Quote, CoinA, CoinB>(
    self: &mut Vault<Meme, Quote>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    cetus_config: &GlobalConfig,
    burn_manager: &BurnManager,
    pool: &mut Pool<CoinA, CoinB>,
    meme_is_a: bool,
    ctx: &mut TxContext,
): (Balance<Meme>, Balance<Quote>) {
    assert!(self.pool_id() == object::id(pool), blast_migrators::errors::position_pool_mismatch!());

    let (fee_a, fee_b) = lp_burn::collect_fee(
        burn_manager,
        cetus_config,
        pool,
        self.position_mut<_, _, _, CetusLPBurnProof>(&Venue(), vault_version),
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

/// Adds the waiting auto-LP balances to the auto-LP position in `pool`, already matched to the
/// vault.
fun compound<Meme, Quote, CoinA, CoinB>(
    self: &mut Vault<Meme, Quote>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<CoinA, CoinB>,
    meme_is_a: bool,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (meme, quote, receipt) = self.take_auto_lp(&Venue(), vault_version);
    let (a, b) = reorder(meme, quote, meme_is_a, ctx);
    let (a, b) = self.add_liquidity(
        vault_version,
        cetus_config,
        pool,
        a,
        b,
        clock,
        ctx,
    );

    let (meme, quote) = reorder(a, b, meme_is_a, ctx);
    self.keep_auto_lp(&Venue(), vault_version, receipt, meme, quote);
}

/// Adds as much of `a` and `b` as the auto-LP position takes at the pool's current price, fixing
/// the side Cetus's own liquidity math says the other side can cover, and returns the rest. The burned migration position cannot receive liquidity, so the first add
/// opens a full-range auto-LP position the vault keeps with no removal path. Nothing is added while
/// either side is empty or would give zero liquidity.
fun add_liquidity<A, B, Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    vault_version: &PackageVersion<BLAST_VAULT_PACKAGE>,
    cetus_config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    mut a: Balance<A>,
    mut b: Balance<B>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Balance<A>, Balance<B>) {
    if (a.value() == 0 || b.value() == 0) return (a, b);

    if (!self.has_auto_lp_position(&Venue())) {
        let (tick_lower, tick_upper) = pool_creator::full_range_tick_range(pool.tick_spacing());
        let position = pool::open_position(cetus_config, pool, tick_lower, tick_upper, ctx);
        self.attach_auto_lp_position(&Venue(), vault_version, position);
    };

    let position = self.auto_lp_position_mut<_, _, _, Position>(&Venue(), vault_version);
    let (fix_a, fixed_amount) = pool.fixed_side(position, a.value(), b.value());
    if (fixed_amount == 0) return (a, b);

    let receipt = pool::add_liquidity_fix_coin(
        cetus_config,
        pool,
        position,
        fixed_amount,
        fix_a,
        clock,
    );
    let (paid_a, paid_b) = receipt.add_liquidity_pay_amount();
    pool::repay_add_liquidity(cetus_config, pool, a.split(paid_a), b.split(paid_b), receipt);

    (a, b)
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

    if (liquidity_a > 0 && needed_b <= amount_b) return (true, amount_a);
    if (liquidity_b > 0 && needed_a <= amount_a) return (false, amount_b);

    (true, 0)
}

/// Swaps all of `quote` for Meme through `pool` in the pool's coin order, returning the Meme bought
/// and the Quote the pool did not take.
fun swap_quote_for_meme<Meme, Quote, CoinA, CoinB>(
    pool: &mut Pool<CoinA, CoinB>,
    cetus_config: &GlobalConfig,
    quote: Balance<Quote>,
    meme_is_a: bool,
    clock: &Clock,
    ctx: &mut TxContext,
): (Balance<Meme>, Balance<Quote>) {
    let (a, b) = reorder(balance::zero<Meme>(), quote, meme_is_a, ctx);
    let (a, b) = pool.swap(cetus_config, a, b, !meme_is_a, clock);

    reorder(a, b, meme_is_a, ctx)
}

/// Swaps all of the input side (`a` when `a2b`) through `pool` up to the widest price limit, pays
/// what Cetus asks, and returns both sides: the unspent input and the output.
fun swap<A, B>(
    pool: &mut Pool<A, B>,
    cetus_config: &GlobalConfig,
    mut a: Balance<A>,
    mut b: Balance<B>,
    a2b: bool,
    clock: &Clock,
): (Balance<A>, Balance<B>) {
    let (amount_in, sqrt_price_limit) = if (a2b) (a.value(), constants::min_swap_sqrt_price!())
    else (b.value(), constants::max_swap_sqrt_price!());

    let (out_a, out_b, receipt) = pool::flash_swap(
        cetus_config,
        pool,
        a2b,
        true,
        amount_in,
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

/// Whether Meme is `CoinA`, after proving `(CoinA, CoinB)` is exactly the sale's Meme and Quote.
fun is_meme_coin_a<Meme, Quote, CoinA, CoinB>(): bool {
    let (meme, quote) = (type_name::with_original_ids<Meme>(), type_name::with_original_ids<Quote>());
    let (a, b) = (type_name::with_original_ids<CoinA>(), type_name::with_original_ids<CoinB>());
    assert!(
        (meme == a && quote == b) || (meme == b && quote == a),
        blast_migrators::errors::wrong_coin_pair!(),
    );

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
        (scratch.cast(x), scratch.cast(y))
    } else {
        (scratch.cast(y), scratch.cast(x))
    };
    scratch.delete();

    (first, second)
}

/// Retypes `value` as `To` through a dynamic field on `scratch`. Removal succeeds only under the
/// stored type, so this aborts with the framework's `EFieldTypeMismatch` unless `From` and `To` are
/// the same type; `is_meme_coin_a` has already proven that for every call.
fun cast<From: store, To: store>(scratch: &mut UID, value: From): To {
    dynamic_field::add(scratch, CastKey(), value);
    dynamic_field::remove(scratch, CastKey())
}

// === Test-Only Functions ===

#[test_only]
/// Runs the seed-side rule on explicit balances and venue requirements.
public fun seed_fixed_side_for_testing(
    preferred: bool,
    available_a: u64,
    available_b: u64,
    needed_a: u64,
    needed_b: u64,
): bool {
    seed_fixed_side(preferred, available_a, available_b, needed_a, needed_b)
}

#[test_only]
/// Runs the pair proof: whether Meme is `CoinA`, aborting unless the pair is the sale's.
public fun is_meme_coin_a_for_testing<Meme, Quote, CoinA, CoinB>(): bool {
    is_meme_coin_a<Meme, Quote, CoinA, CoinB>()
}

#[test_only]
/// Runs the checked retype between Meme-and-Quote order and the pool's coin order.
public fun reorder_for_testing<X: store, Y: store, First: store, Second: store>(
    x: X,
    y: Y,
    meme_is_a: bool,
    ctx: &mut TxContext,
): (First, Second) {
    reorder(x, y, meme_is_a, ctx)
}

// === Imports ===

use blast_admin::{blast_acl::AdminWitness, package_version::PackageVersion};

use blast_core::{
    blast_domain::BuybackAdmin,
    blast_treasury::Treasury,
    migration::{Self, Migration, VenueTicket}
};

use blast_migrators::{
    blast_migrators::BLAST_MIGRATORS,
    constants,
    events,
    venue_config::VenueConfig
};

use blast_vault::{
    blast_vault_package::{BLAST_VAULT_PACKAGE, VaultRegistry},
    vault::{Self, Vault}
};

use cetus_clmm::{
    clmm_math,
    config::{Self, GlobalConfig},
    factory::{Self, PoolCreationCap, Pools},
    pool::{Self, Pool},
    pool_creator,
    position::Position
};

use integer_mate::i32;

use lp_burn::lp_burn::{Self, BurnManager, CetusLPBurnProof};

use std::type_name;

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::Currency,
    dynamic_field
};

use fun add_liquidity as Vault.add_liquidity;
use fun collect_position_fees as Vault.collect_position_fees;
use fun compound as Vault.compound;
use fun settle_fees as Vault.settle_fees;

use fun pool_creation_cap as VenueConfig.pool_creation_cap;

use fun cast as UID.cast;

use fun fixed_side as Pool.fixed_side;

use fun swap as Pool.swap;

use fun swap_quote_for_meme as Pool.swap_quote_for_meme;
