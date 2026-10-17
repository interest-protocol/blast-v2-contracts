// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Aftermath launch start, pool-creation reservation, migration into vault custody, fee
/// collection from the coins Aftermath sends the vault, and settled fee-split updates.
///
/// A launch migrates into a fresh 50/50 Aftermath weighted pool wrapped in Aftermath's DAO-fee
/// pool. Aftermath pays the DAO fee of every swap, deposit, and withdrawal as separate coins sent
/// straight to the fee recipient address, so `migrate` names the launch's new vault as that
/// recipient: the fee coins land owned by the vault object, and anyone may then receive them into
/// the vault, where they are split like any collection. The LP coin, the whole pool liquidity, is
/// sent to `0x0`, so the pool's liquidity is locked for good; the vault's position is the DAO-fee
/// pool's `OwnerCap`, which could otherwise change the fee or redirect it, under its sealed
/// position key with no removal path.
///
/// Aftermath creates a pool only from a `CreatePoolCapV2` minted by a freshly published LP coin,
/// so the creator publishes one per launch and hands its capability to `finalize`, which
/// finalizes the launch and shares the reservation bound to that launch's ID; only that launch's
/// migration can consume it. A launch `new` started but finalized directly in the core has no
/// reservation and can never migrate, so the creator must finalize here. Aftermath pools have no
/// tick spacing, so the launch records zero, and its fee rate is the creator's DAO fee in basis
/// points. The auto-LP and burn-Quote shares of each collection wait in the vault: this adapter
/// adds no liquidity to and swaps nothing in an Aftermath pool.
module blast_fun_migrators::aftermath;

// === Public Types ===

/// Sealed adapter identity selected by a Blast launch.
public struct Witness() has drop;

/// Sealed marker for the DAO-fee pool owner cap the common vault holds as its position.
public struct Venue() has drop;

/// Shared reservation of one launch's Aftermath pool creation: the `CreatePoolCapV2` of the fresh
/// LP coin `Lp`, which only the migration of the launch `launch_id` can consume.
public struct PoolCreation<phantom Lp, phantom Meme, phantom Quote> has key {
    id: UID,
    launch_id: ID,
    create_pool_cap: CreatePoolCapV2,
}

// === Public Functions ===

/// Starts an Aftermath launch in `Quote` whose pool charges `dao_fee_bps` of every swap, deposit,
/// and withdrawal to the launch's vault; the core aborts unless it admits Aftermath and the Quote.
/// The fee is the launch's tier, with no tick spacing; the pool's weights and base fee are this
/// package's constants. The creator completes the returned initializer with this module's
/// `finalize`, which reserves its pool creation.
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

/// Finalizes a launch `new` started, as `launch::finalize` does, and shares the reservation
/// binding `create_pool_cap`, which the fresh LP coin `Lp` minted, to that launch's ID. The
/// initializer must be one `new` started: another adapter's launch could never consume the
/// reservation. The creator shares the returned launch with `launch::share`.
public fun finalize<Lp, Meme, Quote>(
    initializer: LaunchInitializer<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    currency: &mut Currency<Meme>,
    config: &LaunchConfig,
    creation_fee: Coin<SUI>,
    create_pool_cap: CreatePoolCapV2,
    ctx: &mut TxContext,
): Launch<Meme, Quote> {
    migrators_version.assert_current();
    assert!(
        initializer.migration_witness() == type_name::with_original_ids<Witness>(),
        EWrongMigrator,
    );

    let launch = initializer.finalize(package_version, currency, config, creation_fee, ctx);

    let pool_creation = PoolCreation<Lp, Meme, Quote> {
        id: object::new(ctx),
        launch_id: object::id(&launch),
        create_pool_cap,
    };
    blast_events::aftermath_pool_reserved<Lp, Meme, Quote>(
        pool_creation.launch_id,
        pool_creation.id.to_inner(),
        object::id(&pool_creation.create_pool_cap),
    );
    transfer::share_object(pool_creation);

    launch
}

// `dao_fee_pool::new` creates the shared pool in this transaction.
/// Migrates a MigrationReady launch into its reserved Aftermath pool, consuming the reservation
/// bound to it: it seeds a 50/50 pool with exactly the handed-off balances, wraps it in a DAO-fee
/// pool paying the launch's new vault at the launch's fee, shares that pool, locks the pool's
/// owner cap in the vault as its position, and sends the LP coin to `0x0`. The caller receives no
/// object.
#[allow(lint(share_owned))]
public fun migrate<Lp, Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    package_version: &PackageVersion,
    currency: &mut Currency<Meme>,
    pool_creation: PoolCreation<Lp, Meme, Quote>,
    pool_registry: &mut PoolRegistry,
    dao_fee_version: &Version,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    let PoolCreation { id, launch_id, create_pool_cap } = pool_creation;
    assert!(launch_id == object::id(launch), EWrongLaunch);
    id.delete();

    let (_, pool_fee_rate) = launch.pool_tier();
    let dao_fee_bps = pool_fee_rate as u16;
    let (meme, quote) = launch.migrate(package_version, currency, Witness(), ctx);
    let (meme_amount, quote_amount) = (meme.value(), quote.value());

    let (pool, lp) = create_pool<Lp, _, _>(
        create_pool_cap,
        pool_registry,
        meme.into_coin(ctx),
        quote.into_coin(ctx),
        ctx,
    );
    assert!(
        pool.balance_of<Lp, Meme>() == meme_amount && pool.balance_of<Lp, Quote>() == quote_amount,
        EPoolMismatch,
    );

    let pool_id = object::id(&pool);
    let mut vault = vault::new(launch, pool_id, balance::zero(), balance::zero(), ctx);
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
    vault.attach_position(&Venue(), owner_cap, lp.value() as u128);
    vault.share();
    transfer::public_share_object(dao_fee_pool);
    transfer::public_transfer(lp, @0x0);
}

/// Receives the DAO fees Aftermath sent to the vault's address, one `Receiving` per fee coin, and
/// splits them. Anyone may call it; an empty collection is valid.
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

    self.settle_fees(policy, currency, meme_fees, quote_fees, ctx);
}

/// Settles the listed fee coins under the current split, then commits `proposed`. A fee coin the
/// caller leaves at the vault's address is split by the new split when it is received.
public fun settle_and_update_fee_split<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    policy: &LpFeePolicy,
    launch: &Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
    currency: &mut Currency<Meme>,
    meme_fees: vector<Receiving<Coin<Meme>>>,
    quote_fees: vector<Receiving<Coin<Quote>>>,
    proposed: FeeSplit,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    self.assert_fee_split_update(launch, curve_fee_cap, proposed);

    self.settle_fees(policy, currency, meme_fees, quote_fees, ctx);

    self.update_fee_split(proposed);
}

// === Private Functions ===

/// Creates the 50/50 pool from the launch's Meme and Quote, in Aftermath's coin order.
fun create_pool<Lp, Meme, Quote>(
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

/// Receives the listed fee coins into the vault and splits them through it.
fun settle_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    policy: &LpFeePolicy,
    currency: &mut Currency<Meme>,
    meme_fees: vector<Receiving<Coin<Meme>>>,
    quote_fees: vector<Receiving<Coin<Quote>>>,
    ctx: &mut TxContext,
) {
    let meme_fee = self.receive_fees(meme_fees);
    let quote_fee = self.receive_fees(quote_fees);

    self.split_fees(policy, currency, meme_fee, quote_fee, ctx);
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
/// Builds an unshared reservation bound to `launch_id`, for binding tests.
public fun pool_creation_for_testing<Lp, Meme, Quote>(
    launch_id: ID,
    create_pool_cap: CreatePoolCapV2,
    ctx: &mut TxContext,
): PoolCreation<Lp, Meme, Quote> {
    PoolCreation { id: object::new(ctx), launch_id, create_pool_cap }
}

#[test_only]
public fun pool_creation_launch_id_for_testing<Lp, Meme, Quote>(
    self: &PoolCreation<Lp, Meme, Quote>,
): ID {
    self.launch_id
}

// === Errors ===

#[error(code = 0)]
const EPoolMismatch: vector<u8> = b"The Aftermath pool must hold every Meme and Quote unit the launch handed off.";

#[error(code = 1)]
const EDaoFeePoolMismatch: vector<u8> = b"The DAO-fee pool must charge the launch's fee and pay the vault.";

#[error(code = 2)]
const EWrongLaunch: vector<u8> = b"The pool creation is bound to a different launch.";

#[error(code = 3)]
const EInvalidDaoFee: vector<u8> = b"Aftermath DAO fee needs 1..=10,000 basis points.";

#[error(code = 4)]
const EWrongMigrator: vector<u8> = b"Only a launch this module's `new` started can be finalized here.";

// === Imports ===

use amm::{pool::{CreatePoolCapV2, Pool}, pool_factory, pool_registry::PoolRegistry};

use blast_fun::{
    allocation::FeeSplit,
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
    blast_fun_migrators::PackageVersion as MigratorsVersion,
    vault::{Self, LpVault},
};

use dao_fee_amm::{pool as dao_fee_pool, version::Version};

use std::type_name;

use sui::{
    balance::{Self, Balance},
    coin::Coin,
    coin_registry::Currency,
    sui::SUI,
    transfer::Receiving,
};

use fun receive_fees as LpVault.receive_fees;
use fun settle_fees as LpVault.settle_fees;
