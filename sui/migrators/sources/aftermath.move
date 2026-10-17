// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Aftermath launch start, pool creation ahead of migration, migration into vault custody, and
/// fee collection from the coins Aftermath sends the vault.
///
/// A launch migrates into its own 50/50 Aftermath weighted pool wrapped in Aftermath's DAO-fee
/// pool. Aftermath pays the DAO fee of every swap, deposit, and withdrawal as separate coins sent
/// straight to the fee recipient address, so `migrate` names the launch's new vault as that
/// recipient: the fee coins land owned by the vault object, and anyone may then receive them into
/// the vault, where they are split like any collection. Every LP coin, the whole pool liquidity,
/// is sent to `0x0`, so the pool's liquidity is locked for good; the vault's position is the
/// DAO-fee pool's `OwnerCap`, which could otherwise change the fee or redirect it, under its sealed
/// position key with no removal path.
///
/// Aftermath's registry rejects a second pool with the same coins, weights, flatness, and fees,
/// and buyers hold Meme while the curve is live, so a pool created only at migration could be
/// created first by anyone to strand the launch. The creator therefore creates the pool in the
/// PTB that creates the launch: `finalize` returns a hot potato that only `create_pool` consumes,
/// with a seed the creator buys from the still-owned launch and some Quote, and the pool then
/// waits unshared inside the reservation bound to the launch's ID, where nothing can trade on it
/// or price it, until that launch's migration deposits the hand-off into it and shares it. A
/// launch `new` started but finalized directly in the core has no reservation and can never
/// migrate, so the creator must finalize here. Aftermath pools have no tick spacing, so the launch
/// records zero, and its fee rate is the creator's DAO fee in basis points.
///
/// This adapter adds no liquidity to and swaps nothing in an Aftermath pool after migration, so
/// `finalize` admits only a fee split with no auto-LP and no burn part, and it cannot settle every
/// DAO-fee coin before a split change, so an Aftermath launch's split is fixed at migration.
module blast_fun_migrators::aftermath;

// === Public Types ===

/// Sealed adapter identity selected by a Blast launch.
public struct Witness() has drop;

/// Sealed marker for the DAO-fee pool owner cap the common vault holds as its position.
public struct Venue() has drop;

/// A launch's pool creation owed in the PTB that finalized it: the `CreatePoolCapV2` of the fresh
/// LP coin `Lp`, which only `create_pool` can consume, so a launch of this adapter never leaves
/// its creation PTB without its pool.
public struct PendingPool<phantom Lp, phantom Meme, phantom Quote> {
    launch_id: ID,
    create_pool_cap: CreatePoolCapV2,
}

/// Reservation of one launch's Aftermath pool, returned by `create_pool` and shared by `share` or
/// consumed in the same PTB: the pool of the fresh LP coin `Lp`, seeded and unshared, which only
/// the migration of the launch `launch_id` can deposit into and share.
public struct PoolCreation<phantom Lp, phantom Meme, phantom Quote> has key {
    id: UID,
    launch_id: ID,
    pool: Pool<Lp>,
}

// === Public Functions ===

/// Starts an Aftermath launch in `Quote` whose pool charges `dao_fee_bps` of every swap, deposit,
/// and withdrawal to the launch's vault; the core aborts unless it admits Aftermath and the Quote.
/// The fee is the launch's tier, with no tick spacing; the pool's weights and base fee are this
/// package's constants. The creator completes the returned initializer with this module's
/// `finalize`, which binds its pool creation.
public fun new<Meme, Quote>(
    ticket: LaunchTicket<Meme>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    config: &LaunchConfig,
    dao_fee_bps: u16,
): LaunchInitializer<Meme, Quote> {
    migrators_version.assert_current();
    assert!(
        dao_fee_bps > 0 && dao_fee_bps <= constants::aftermath_max_dao_fee_bps!(),
        EInvalidDaoFee,
    );

    launch::new<Meme, Quote, _>(ticket, package_version, config, Witness(), 0, dao_fee_bps as u64)
}

/// Finalizes a launch `new` started, as `launch::finalize` does, and returns it with the pool
/// creation owed to it, binding `create_pool_cap`, which the fresh LP coin `Lp` minted, to that
/// launch's ID. The initializer must be one `new` started: another adapter's launch could never
/// consume the reservation. The launch's fee split must have no auto-LP and no burn part, since
/// neither has a route out of an Aftermath vault. The pending creation has no abilities, so the
/// same PTB must buy the seed from the returned launch and call `create_pool` before
/// `launch::share`.
public fun finalize<Lp, Meme, Quote>(
    initializer: LaunchInitializer<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    currency: &mut Currency<Meme>,
    config: &LaunchConfig,
    creation_fee: Coin<SUI>,
    create_pool_cap: CreatePoolCapV2,
    ctx: &mut TxContext,
): (Launch<Meme, Quote>, PendingPool<Lp, Meme, Quote>) {
    migrators_version.assert_current();
    assert!(
        initializer.migration_witness() == type_name::with_original_ids<Witness>(),
        EWrongMigrator,
    );

    let launch = initializer.finalize(package_version, currency, config, creation_fee, ctx);
    let (_, auto_lp_bps, _, burn_bps, _) = launch
        .lp_fee_split()
        .apportion_fee_split(constants::basis_points_denominator!());
    assert!(auto_lp_bps == 0 && burn_bps == 0, EUnsupportedFeeSplit);

    let pending = PendingPool<Lp, Meme, Quote> { launch_id: object::id(&launch), create_pool_cap };

    (launch, pending)
}

/// Creates the launch's pool from the creator's seed `meme` and `quote`, with this package's
/// fixed terms, in Aftermath's coin order, so the pool's registry slot is taken before any buyer
/// holds Meme; sends the seed's LP coin to `0x0`; and returns the reservation holding the pool,
/// bound to the launch, for `share` or for a migration in the same PTB. Aftermath mints the seed
/// LP as the geometric mean of the two amounts and needs more than its 1,000 locked units, so a
/// seed of about a thousand atomic units of each coin is enough; the migration then deposits the
/// hand-off at any ratio, in slices Aftermath's deposit math takes, so the pool opens at the
/// price of the seed plus the hand-off, which a small seed leaves where the curve ended.
public fun create_pool<Lp, Meme, Quote>(
    pending: PendingPool<Lp, Meme, Quote>,
    migrators_version: &MigratorsVersion,
    pool_registry: &mut PoolRegistry,
    meme: Coin<Meme>,
    quote: Coin<Quote>,
    ctx: &mut TxContext,
): PoolCreation<Lp, Meme, Quote> {
    migrators_version.assert_current();
    let PendingPool { launch_id, create_pool_cap } = pending;
    let (seed_meme, seed_quote) = (meme.value(), quote.value());

    let (pool, lp) = create_pool_2_coins_in_order<Lp, _, _>(
        create_pool_cap,
        pool_registry,
        meme,
        quote,
        ctx,
    );

    let pool_creation = PoolCreation<Lp, Meme, Quote> { id: object::new(ctx), launch_id, pool };
    blast_events::aftermath_pool_reserved<Lp, Meme, Quote>(
        launch_id,
        pool_creation.id.to_inner(),
        object::id(&pool_creation.pool),
        object::id(&lp),
        seed_meme,
        seed_quote,
    );
    transfer::public_transfer(lp, @0x0);

    pool_creation
}

/// Shares a reservation `create_pool` returned, so anyone can migrate its launch once it is
/// ready.
public fun share<Lp, Meme, Quote>(
    self: PoolCreation<Lp, Meme, Quote>,
    migrators_version: &MigratorsVersion,
) {
    migrators_version.assert_current();

    transfer::share_object(self);
}

// `dao_fee_pool::new` creates the shared pool in this transaction.
/// Migrates a MigrationReady launch into its reserved Aftermath pool, consuming the reservation
/// bound to it: it deposits exactly the handed-off balances into the pool, which nothing could
/// trade on or price before, in slices its deposit math takes, wraps the pool in a DAO-fee pool
/// paying the launch's new vault at the launch's fee, shares that pool, locks the pool's owner
/// cap in the vault as its position, and sends the deposit's LP coin to `0x0`. Aftermath takes
/// its protocol fee from each deposited coin at the rate `protocol_fee_vault` reports, which must
/// be within this package's cap, and pays it to its own `treasury`, `insurance_fund`, and dev
/// wallet; `referral_vault` only discounts a referred sender. The caller receives no object.
#[allow(lint(share_owned))]
public fun migrate<Lp, Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    currency: &mut Currency<Meme>,
    pool_creation: PoolCreation<Lp, Meme, Quote>,
    pool_registry: &PoolRegistry,
    protocol_fee_vault: &ProtocolFeeVault,
    treasury: &mut Treasury,
    insurance_fund: &mut InsuranceFund,
    referral_vault: &ReferralVault,
    dao_fee_version: &Version,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let PoolCreation { id, launch_id, mut pool } = pool_creation;
    assert!(launch_id == object::id(launch), EWrongLaunch);
    id.delete();

    let (_, pool_fee_rate) = launch.pool_tier();
    let dao_fee_bps = pool_fee_rate as u16;
    let (meme, quote) = launch.migrate(package_version, currency, Witness(), ctx);
    let (meme_amount, quote_amount) = (meme.value(), quote.value());
    let (meme_before, quote_before) = (pool.balance_of<Lp, Meme>(), pool.balance_of<Lp, Quote>());
    let protocol_fee_rate = protocol_fee_vault.total_protocol_fee();
    assert_protocol_fee_capped(protocol_fee_rate);

    let lp = deposit_hand_off<Lp, _, _>(
        &mut pool,
        pool_registry,
        protocol_fee_vault,
        treasury,
        insurance_fund,
        referral_vault,
        meme.into_coin(ctx),
        quote.into_coin(ctx),
        ctx,
    );
    assert!(
        pool.balance_of<Lp, Meme>() - meme_before
            >= meme_amount - protocol_fee_ceiling(meme_amount, protocol_fee_rate)
            && pool.balance_of<Lp, Quote>() - quote_before
                >= quote_amount - protocol_fee_ceiling(quote_amount, protocol_fee_rate),
        EPoolMismatch,
    );

    let pool_id = object::id(&pool);
    let vault = vault::new(launch, pool_id, balance::zero(), balance::zero(), ctx);
    let vault_address = object::id(&vault).to_address();
    let (dao_fee_pool, owner_cap) = dao_fee_pool::new(
        pool,
        dao_fee_version,
        dao_fee_bps,
        vault_address,
        ctx,
    );
    assert!(
        dao_fee_pool.fee_bps() == dao_fee_bps && dao_fee_pool.fee_recipient() == vault_address,
        EDaoFeePoolMismatch,
    );

    blast_events::aftermath_pool_created<Lp>(
        object::id(&vault),
        pool_id,
        object::id(&dao_fee_pool),
        object::id(&owner_cap),
        object::id(&lp),
    );
    vault.share_with_position(&Venue(), owner_cap, lp.value() as u128);
    transfer::public_share_object(dao_fee_pool);
    transfer::public_transfer(lp, @0x0);
}

/// Receives the DAO fees Aftermath sent to an Aftermath vault's address, one `Receiving` per fee
/// coin, and splits them. Anyone may call it; an empty collection is valid. Another venue's vault
/// aborts: its fees settle only through its own venue.
public fun collect_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    policy: &LpFeePolicy,
    currency: &mut Currency<Meme>,
    meme_fees: vector<Receiving<Coin<Meme>>>,
    quote_fees: vector<Receiving<Coin<Quote>>>,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    assert!(self.has_position(&Venue()), EWrongVault);

    let meme = self.receive_fees(meme_fees);
    let quote = self.receive_fees(quote_fees);

    self.split_fees(policy, currency, meme, quote, ctx);
}

// === Private Functions ===

/// Creates the 50/50 pool from the seed Meme and Quote, in Aftermath's coin order.
fun create_pool_2_coins_in_order<Lp, Meme, Quote>(
    create_pool_cap: CreatePoolCapV2,
    pool_registry: &mut PoolRegistry,
    meme: Coin<Meme>,
    quote: Coin<Quote>,
    ctx: &mut TxContext,
): (Pool<Lp>, Coin<Lp>) {
    if (sorts_before<Meme, Quote>()) {
        create_pool_2_coins(create_pool_cap, pool_registry, meme, quote, ctx)
    } else {
        create_pool_2_coins(create_pool_cap, pool_registry, quote, meme, ctx)
    }
}

/// Creates the pool from both coins, which must be in Aftermath's coin order.
fun create_pool_2_coins<Lp, Coin1, Coin2>(
    create_pool_cap: CreatePoolCapV2,
    pool_registry: &mut PoolRegistry,
    coin_1: Coin<Coin1>,
    coin_2: Coin<Coin2>,
    ctx: &mut TxContext,
): (Pool<Lp>, Coin<Lp>) {
    pool_factory::create_pool_2_coins_v2(
        create_pool_cap,
        pool_registry,
        constants::aftermath_pool_name!(),
        vector[constants::aftermath_half_weight!(), constants::aftermath_half_weight!()],
        constants::aftermath_flatness!(),
        vector[constants::aftermath_base_swap_fee!(), constants::aftermath_base_swap_fee!()],
        vector[0, 0],
        vector[0, 0],
        vector[0, 0],
        coin_1,
        coin_2,
        option::none(),
        false,
        ctx,
    )
}

/// Aborts unless Aftermath's live protocol-fee rate is within this package's cap, so a raised
/// rate stalls migrations instead of taking an unbounded share of the hand-off.
fun assert_protocol_fee_capped(rate: u64) {
    assert!(rate <= constants::aftermath_max_protocol_fee!(), EProtocolFeeTooHigh);
}

/// Deposits the whole hand-off into the pool in slices Aftermath's deposit math takes, joining
/// every slice's LP coin: while one coin would grow the pool's balance of it more than
/// `aftermath_max_deposit_skew` times the other coin's growth, a slice grows that coin's balance
/// by the skew alongside one atomic unit of the other, and the last slice deposits the rest.
/// Each slice multiplies the skewed coin's balance by the skew, so a hand-off needs at most ten
/// slices before the rest, and each slice needs one atomic unit of the other coin.
fun deposit_hand_off<Lp, Meme, Quote>(
    pool: &mut Pool<Lp>,
    pool_registry: &PoolRegistry,
    protocol_fee_vault: &ProtocolFeeVault,
    treasury: &mut Treasury,
    insurance_fund: &mut InsuranceFund,
    referral_vault: &ReferralVault,
    mut meme: Coin<Meme>,
    mut quote: Coin<Quote>,
    ctx: &mut TxContext,
): Coin<Lp> {
    let mut lp = coin::zero<Lp>(ctx);
    loop {
        let (meme_slice, quote_slice) = deposit_slice(
            pool.balance_of<Lp, Meme>(),
            pool.balance_of<Lp, Quote>(),
            meme.value(),
            quote.value(),
        );
        if (meme_slice == meme.value() && quote_slice == quote.value()) {
            lp.join(deposit_in_order<Lp, _, _>(
                pool,
                pool_registry,
                protocol_fee_vault,
                treasury,
                insurance_fund,
                referral_vault,
                meme,
                quote,
                ctx,
            ));
            return lp
        };
        lp.join(deposit_in_order<Lp, _, _>(
            pool,
            pool_registry,
            protocol_fee_vault,
            treasury,
            insurance_fund,
            referral_vault,
            meme.split(meme_slice, ctx),
            quote.split(quote_slice, ctx),
            ctx,
        ));
    }
}

/// The next deposit slice for a pool holding `meme_balance` and `quote_balance` with `meme_left`
/// and `quote_left` still to deposit: everything left once neither coin's growth ratio exceeds
/// the other's by more than the skew, else the skewed coin's balance times the skew less one
/// alongside one atomic unit of the other coin.
fun deposit_slice(
    meme_balance: u64,
    quote_balance: u64,
    meme_left: u64,
    quote_left: u64,
): (u64, u64) {
    let skew = constants::aftermath_max_deposit_skew!() as u256;
    // Each coin's growth ratio (balance + left) / balance, cross-multiplied so both compare
    // over the common denominator meme_balance * quote_balance.
    let meme_growth = ((meme_balance as u256) + (meme_left as u256)) * (quote_balance as u256);
    let quote_growth = ((quote_balance as u256) + (quote_left as u256)) * (meme_balance as u256);
    if (meme_growth > skew * quote_growth) {
        ((((meme_balance as u256) * (skew - 1)).min(meme_left as u256)) as u64, 1)
    } else if (quote_growth > skew * meme_growth) {
        (1, (((quote_balance as u256) * (skew - 1)).min(quote_left as u256)) as u64)
    } else {
        (meme_left, quote_left)
    }
}

/// Deposits one slice into the pool, in Aftermath's coin order. The pool is still unshared, so
/// nothing could move its price before the deposit, and no minimum LP is asked of Aftermath.
fun deposit_in_order<Lp, Meme, Quote>(
    pool: &mut Pool<Lp>,
    pool_registry: &PoolRegistry,
    protocol_fee_vault: &ProtocolFeeVault,
    treasury: &mut Treasury,
    insurance_fund: &mut InsuranceFund,
    referral_vault: &ReferralVault,
    meme: Coin<Meme>,
    quote: Coin<Quote>,
    ctx: &mut TxContext,
): Coin<Lp> {
    if (sorts_before<Meme, Quote>()) {
        deposit::deposit_2_coins_direct(
            pool,
            pool_registry,
            protocol_fee_vault,
            treasury,
            insurance_fund,
            referral_vault,
            meme,
            quote,
            0,
            ctx,
        )
    } else {
        deposit::deposit_2_coins_direct(
            pool,
            pool_registry,
            protocol_fee_vault,
            treasury,
            insurance_fund,
            referral_vault,
            quote,
            meme,
            0,
            ctx,
        )
    }
}

/// The most Aftermath's protocol fee can take from `amount` at `rate`, in Aftermath's `1e18`
/// unit: the fee rounded up, so a deposit that lands every other unit passes the check.
fun protocol_fee_ceiling(amount: u64, rate: u64): u64 {
    let one = constants::aftermath_fixed_one!() as u128;
    (((amount as u128) * (rate as u128) + one - 1) / one) as u64
}

/// Whether `A` comes before `B` in Aftermath's coin order: the byte order of their defining-ID type
/// names, which its pool registry requires.
fun sorts_before<A, B>(): bool {
    let a_name = type_name::with_defining_ids<A>().into_string().into_bytes();
    let b_name = type_name::with_defining_ids<B>().into_string().into_bytes();
    let prefix_length = a_name.length().min(b_name.length());
    let mut i = 0;
    while (i < prefix_length && a_name[i] == b_name[i]) i = i + 1;

    // The first differing byte decides; otherwise the shorter name is a prefix and comes first.
    if (i < prefix_length) return a_name[i] < b_name[i];

    a_name.length() < b_name.length()
}

/// Receives every listed fee coin into the vault and joins them into one balance.
fun receive_fees<Meme, Quote, Asset>(
    self: &mut LpVault<Meme, Quote>,
    fees: vector<Receiving<Coin<Asset>>>,
): Balance<Asset> {
    let mut received = balance::zero<Asset>();
    fees.do!(|fee| {
        received.join(self.receive_fee(fee).into_balance());
    });

    received
}

// === Test-Only Functions ===

#[test_only]
public fun sorts_before_for_testing<A, B>(): bool {
    sorts_before<A, B>()
}

#[test_only]
public fun protocol_fee_ceiling_for_testing(amount: u64, rate: u64): u64 {
    protocol_fee_ceiling(amount, rate)
}

#[test_only]
public fun assert_protocol_fee_capped_for_testing(rate: u64) {
    assert_protocol_fee_capped(rate)
}

#[test_only]
public fun deposit_slice_for_testing(
    meme_balance: u64,
    quote_balance: u64,
    meme_left: u64,
    quote_left: u64,
): (u64, u64) {
    deposit_slice(meme_balance, quote_balance, meme_left, quote_left)
}

#[test_only]
/// Unpacks a pending creation into the launch it is bound to and the capability it holds.
public fun unpack_pending_pool_for_testing<Lp, Meme, Quote>(
    pending: PendingPool<Lp, Meme, Quote>,
): (ID, CreatePoolCapV2) {
    let PendingPool { launch_id, create_pool_cap } = pending;
    (launch_id, create_pool_cap)
}

#[test_only]
/// Builds an unshared reservation bound to `launch_id` around `pool`, for binding tests.
public fun pool_creation_for_testing<Lp, Meme, Quote>(
    launch_id: ID,
    pool: Pool<Lp>,
    ctx: &mut TxContext,
): PoolCreation<Lp, Meme, Quote> {
    PoolCreation { id: object::new(ctx), launch_id, pool }
}

#[test_only]
public fun pool_creation_launch_id_for_testing<Lp, Meme, Quote>(
    self: &PoolCreation<Lp, Meme, Quote>,
): ID {
    self.launch_id
}

#[test_only]
/// Builds an unshared vault whose position sits under this venue, for collection tests.
public fun vault_for_testing<Meme, Quote, Position: key + store>(
    launch: &Launch<Meme, Quote>,
    pool_id: ID,
    position: Position,
    liquidity: u128,
    ctx: &mut TxContext,
): LpVault<Meme, Quote> {
    vault::new_for_testing(
        launch,
        &Venue(),
        pool_id,
        position,
        liquidity,
        balance::zero(),
        balance::zero(),
        ctx,
    )
}

// === Errors ===

#[error(code = 0)]
const EPoolMismatch: vector<u8> =
    b"The Aftermath pool must take every Meme and Quote unit the launch handed off, less Aftermath's protocol fee.";

#[error(code = 1)]
const EDaoFeePoolMismatch: vector<u8> = b"The DAO-fee pool must charge the launch's fee and pay the vault.";

#[error(code = 2)]
const EWrongLaunch: vector<u8> = b"The pool creation is bound to a different launch.";

#[error(code = 3)]
const EInvalidDaoFee: vector<u8> = b"Aftermath DAO fee needs 1..=10,000 basis points.";

#[error(code = 4)]
const EWrongMigrator: vector<u8> = b"Only a launch this module's `new` started can be finalized here.";

#[error(code = 5)]
const EWrongVault: vector<u8> = b"Only an Aftermath vault's fees are collected here.";

#[error(code = 6)]
const EUnsupportedFeeSplit: vector<u8> =
    b"An Aftermath launch's fee split needs no auto-LP and no burn part: this adapter adds no liquidity and has no buyback.";

#[error(code = 7)]
const EProtocolFeeTooHigh: vector<u8> =
    b"Aftermath's protocol fee is above this package's cap; the migration waits for a lower rate or an upgrade.";

// === Imports ===

use amm::{deposit, pool::{CreatePoolCapV2, Pool}, pool_factory, pool_registry::PoolRegistry};

use blast_fun::{
    launch::{Self, Launch, LaunchInitializer},
    launch_config::LaunchConfig,
    launch_ticket::LaunchTicket,
    blast_fun::PackageVersion,
};

use blast_fun_migrators::{
    blast_events,
    constants,
    lp_fee_policy::LpFeePolicy,
    blast_fun_migrators::PackageVersion as MigratorsVersion,
    vault::{Self, LpVault},
};

use dao_fee_amm::{pool as dao_fee_pool, version::Version};

use insurance_fund::insurance_fund::InsuranceFund;

use protocol_fee_vault::vault::ProtocolFeeVault;

use referral_vault::referral_vault::ReferralVault;

use std::type_name;

use sui::{
    balance::{Self, Balance},
    coin::{Self, Coin},
    coin_registry::Currency,
    sui::SUI,
    transfer::Receiving,
};

use treasury::treasury::Treasury;

use fun receive_fees as LpVault.receive_fees;
