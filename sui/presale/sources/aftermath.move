// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Permissionless Aftermath migration and LP-fee collection for configured presales.
///
/// A funded sale migrates into a fresh 50/50 Aftermath weighted pool wrapped in Aftermath's
/// DAO-fee pool. Aftermath pays the DAO fee of every swap, deposit, and withdrawal as separate
/// coins sent straight to the fee recipient address, so `migrate` names the sale's new vault as
/// that recipient: the fee coins land owned by the vault object, and anyone may then receive them
/// into the vault, where they are split like any collection. The LP coin, the whole pool
/// liquidity, is sent to `0x0`, so the pool's liquidity is locked for good; the vault's position
/// is the DAO-fee pool's `OwnerCap`, which could otherwise change the fee or redirect it, under
/// its sealed position key with no removal path.
///
/// Aftermath creates a pool only from a `CreatePoolCapV2` minted by a freshly published LP coin,
/// so the creator publishes one per sale and hands its capability to `finalize`, which finalizes
/// the sale and returns the reservation bound to that sale's ID for `share`; only that sale's
/// migration can consume it. A sale `new` started but finalized directly in `blast_presale` has
/// no reservation, so it can never migrate and refunds after its LP deadline.
///
/// Aftermath's registry rejects a second pool with the same coins, weights, flatness, and fees. No
/// sale token circulates before migration, so nobody can create the sale's pool first, but the
/// migration still salts the base swap-in fee with its own transaction digest, as the launchpad
/// adapter must, so the two adapters create pools the same way.
module blast_presale::aftermath;

// === Public Types ===

/// Sealed Aftermath migrator identity fixed before commitments open.
public struct Witness() has drop;

/// Sealed marker for the DAO-fee pool owner cap a presale vault holds as its position.
public struct Venue() has drop;

/// Reservation of one sale's Aftermath pool creation, returned by `finalize` and shared by
/// `share`: the `CreatePoolCapV2` of the fresh LP coin `Lp`, which only the migration of the sale
/// `presale_id` can consume.
public struct PoolCreation<phantom Lp, phantom Meme, phantom Quote> has key {
    id: UID,
    presale_id: ID,
    create_pool_cap: CreatePoolCapV2,
}

// === Public Functions ===

/// Starts a presale that migrates to an Aftermath pool charging `dao_fee_bps` of every swap,
/// deposit, and withdrawal to the sale's vault. The fee is the sale's pool tier, recorded under
/// its token's type with no tick spacing; the pool's weights and base fee are this module's
/// constants. The sale is set like any other, then finalized only through this module's
/// `finalize`, which reserves its pool creation.
public fun new<Meme, Quote>(
    treasury_cap: TreasuryCap<Meme>,
    creation_policy: &CreationPolicy,
    fee_policy: &FeePolicy,
    venue_config: &mut VenueConfig,
    dao_fee_bps: u16,
): PresaleInitializer<Meme, Quote> {
    assert!(dao_fee_bps > 0 && dao_fee_bps <= MAX_DAO_FEE_BPS, EInvalidDaoFee);

    venue_config.add_pool_tier<Meme, Quote, _>(&Venue(), 0, dao_fee_bps as u64);

    presale::new(treasury_cap, Witness(), creation_policy, fee_policy)
}

/// Finalizes a sale `new` started, as `blast_presale::finalize` does, and returns it with the
/// reservation binding `create_pool_cap`, which the fresh LP coin `Lp` minted, to that sale's ID.
/// The initializer must be one `new` started: another migrator's sale could never consume the
/// reservation. The reservation has only `key`, so the PTB that creates the sale must share it
/// with `share`, as the launchpad adapter's does; a sale is never funded in that PTB.
public fun finalize<Lp, Meme, Quote>(
    initializer: PresaleInitializer<Meme, Quote>,
    currency: &mut Currency<Meme>,
    create_pool_cap: CreatePoolCapV2,
    ctx: &mut TxContext,
): (Presale<Meme, Quote>, PresaleCap, PoolCreation<Lp, Meme, Quote>) {
    assert!(initializer.migration_witness() == type_name::with_original_ids<Witness>(), EWrongMigrator);

    let (sale, cap) = initializer.finalize(currency, ctx);

    let pool_creation = PoolCreation<Lp, Meme, Quote> {
        id: object::new(ctx),
        presale_id: object::id(&sale),
        create_pool_cap,
    };

    event::emit(PoolCreationReserved<Lp, Meme, Quote> {
        presale_id: pool_creation.presale_id,
        pool_creation_id: pool_creation.id.to_inner(),
        create_pool_cap_id: object::id(&pool_creation.create_pool_cap),
    });

    (sale, cap, pool_creation)
}

/// Shares a reservation `finalize` returned, so anyone can migrate its sale once it is funded.
public fun share<Lp, Meme, Quote>(self: PoolCreation<Lp, Meme, Quote>) {
    transfer::share_object(self);
}

// `dao_fee_pool::new` creates the shared pool in this transaction.
/// Anyone may migrate a funded presale into its reserved Aftermath pool, consuming the
/// reservation bound to it: it seeds a 50/50 pool with all of the sale's LP tokens and Quote,
/// wraps it in a DAO-fee pool paying the sale's new vault at the fee `new` recorded, shares that
/// pool, locks the pool's owner cap in the vault as its position, and sends the LP coin to `0x0`.
#[allow(lint(share_owned))]
public fun migrate<Lp, Meme, Quote>(
    sale: &mut Presale<Meme, Quote>,
    pool_creation: PoolCreation<Lp, Meme, Quote>,
    fee_policy: &FeePolicy,
    venue_config: &VenueConfig,
    pool_registry: &mut PoolRegistry,
    dao_fee_version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let PoolCreation { id, presale_id, create_pool_cap } = pool_creation;
    assert!(presale_id == object::id(sale), EWrongPresale);
    id.delete();

    let (_, pool_fee_rate) = venue_config.pool_tier<Meme>();
    let dao_fee_bps = pool_fee_rate as u16;
    let (meme, quote) = sale.migrate(fee_policy, Witness(), clock, ctx);
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
    let vault = vault::new(sale, pool_id, balance::zero(), balance::zero(), ctx);
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

    event::emit(DaoFeePoolCreated<Lp, Meme, Quote> {
        vault_id: object::id(&vault),
        pool_id,
        dao_fee_pool_id: object::id(&dao_fee_pool),
        owner_cap_id: object::id(&owner_cap),
        lp_coin_id: object::id(&lp),
    });

    vault.share_with_position(&Venue(), owner_cap, lp.value() as u128);
    transfer::public_share_object(dao_fee_pool);
    transfer::public_transfer(lp, @0x0);
}

/// Anyone may receive the DAO fees Aftermath sent to an Aftermath vault's address, one
/// `Receiving` per fee coin, and split them as LP fees, paying Blast and each fee recipient and
/// accruing the holder Quote and paying holder Meme to the governed treasury. An empty collection
/// is valid. Another venue's vault aborts: its fees settle only through its own venue.
public fun collect_fees<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    fee_policy: &FeePolicy,
    meme_fees: vector<Receiving<Coin<Meme>>>,
    quote_fees: vector<Receiving<Coin<Quote>>>,
    ctx: &mut TxContext,
) {
    assert!(vault.has_position(&Venue()), EWrongVault);

    let meme = vault.receive_fees(meme_fees);
    let quote = vault.receive_fees(quote_fees);

    vault.split_fees(fee_policy, meme, quote, ctx);
}

// === Private Functions ===

/// Creates the 50/50 pool from the sale's tokens and Quote, in Aftermath's coin order.
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
        POOL_NAME,
        vector[HALF_WEIGHT, HALF_WEIGHT],
        FLATNESS,
        vector[swap_in_fee(ctx), swap_in_fee(ctx)],
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

/// Aftermath's minimum base swap-in fee plus a salt from this transaction's digest, so the pool's
/// registry hash, which covers the fees, cannot be claimed ahead of the migration. The salt is
/// below `2^32` in the fee's `1e18` unit, under five parts per billion of the swap, and keeps the
/// fee within Aftermath's bounds.
fun swap_in_fee(ctx: &TxContext): u64 {
    let digest = ctx.digest();
    let salt = ((digest[0] as u64) << 24)
        | ((digest[1] as u64) << 16)
        | ((digest[2] as u64) << 8)
        | (digest[3] as u64);

    BASE_SWAP_FEE + salt
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
    vault: &mut Vault<Meme, Quote>,
    fees: vector<Receiving<Coin<Asset>>>,
): Balance<Asset> {
    let mut received = balance::zero<Asset>();
    fees.do!(|fee| {
        received.join(vault.receive_fee(fee).into_balance());
    });

    received
}

// === Test-Only Functions ===

#[test_only]
public fun sorts_before_for_testing<A, B>(): bool {
    sorts_before<A, B>()
}

#[test_only]
public fun pool_creation_presale_id_for_testing<Lp, Meme, Quote>(
    self: &PoolCreation<Lp, Meme, Quote>,
): ID {
    self.presale_id
}

#[test_only]
public fun swap_in_fee_for_testing(ctx: &TxContext): u64 {
    swap_in_fee(ctx)
}

#[test_only]
/// Builds an unshared vault whose position sits under this venue, for collection tests.
public fun vault_for_testing<Meme, Quote, Position: key + store>(
    presale_id: ID,
    presale_cap_id: ID,
    fee_split: FeeSplit,
    protocol_fees: ProtocolFees,
    partner_id: Option<ID>,
    position: Position,
    liquidity: u128,
    ctx: &mut TxContext,
): Vault<Meme, Quote> {
    let mut vault = vault::new_for_testing(
        presale_id,
        presale_cap_id,
        fee_split,
        protocol_fees,
        partner_id,
        ctx,
    );
    vault.attach_position_for_testing(&Venue(), position, liquidity);
    vault
}

#[test_only]
public fun pool_creation_reserved_fields<Lp, Meme, Quote>(
    event: &PoolCreationReserved<Lp, Meme, Quote>,
): (ID, ID, ID) {
    (event.presale_id, event.pool_creation_id, event.create_pool_cap_id)
}

#[test_only]
public fun dao_fee_pool_created_fields<Lp, Meme, Quote>(
    event: &DaoFeePoolCreated<Lp, Meme, Quote>,
): (ID, ID, ID, ID, ID) {
    (
        event.vault_id,
        event.pool_id,
        event.dao_fee_pool_id,
        event.owner_cap_id,
        event.lp_coin_id,
    )
}

// === Events ===

/// `finalize` reserved the sale `presale_id`'s Aftermath pool creation for the LP coin `Lp` in the
/// shared `pool_creation_id`, holding the capability `create_pool_cap_id`; that sale's migration
/// consumes both.
public struct PoolCreationReserved<phantom Lp, phantom Meme, phantom Quote> has copy, drop {
    presale_id: ID,
    pool_creation_id: ID,
    create_pool_cap_id: ID,
}

/// A sale migrated into the Aftermath pool `pool_id`, which traders reach through the shared
/// DAO-fee pool `dao_fee_pool_id` paying its fees to the vault `vault_id`. The vault holds that
/// pool's owner cap `owner_cap_id` as its position, and the LP coin `lp_coin_id`, the whole pool
/// liquidity, is owned by `0x0`.
public struct DaoFeePoolCreated<phantom Lp, phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    pool_id: ID,
    dao_fee_pool_id: ID,
    owner_cap_id: ID,
    lp_coin_id: ID,
}

// === Constants ===

/// Aftermath's own bound on a DAO fee, the whole amount, which its DAO-fee pool creation asserts
/// as `fee_bps <= 10_000`.
const MAX_DAO_FEE_BPS: u16 = 10_000;

/// Each coin's weight: half of Aftermath's `1e18` fixed-point one.
const HALF_WEIGHT: u64 = 500_000_000_000_000_000;

/// Selects Aftermath's uncorrelated weighted-product curve.
const FLATNESS: u64 = 0;

/// Aftermath's minimum base swap-in fee, 0.01% in its `1e18` unit; it rejects zero. This part,
/// plus the migration's salt, compounds into the locked LP.
const BASE_SWAP_FEE: u64 = 100_000_000_000_000;

const POOL_NAME: vector<u8> = b"Blast Presale Pool";

// === Errors ===

#[error(code = 0)]
const EPoolMismatch: vector<u8> = b"The Aftermath pool must hold every sale token and Quote unit the presale released.";

#[error(code = 1)]
const EDaoFeePoolMismatch: vector<u8> = b"The DAO-fee pool must charge this module's fee and pay the vault.";

#[error(code = 2)]
const EWrongPresale: vector<u8> = b"The pool creation is bound to a different presale.";

#[error(code = 3)]
const EInvalidDaoFee: vector<u8> = b"Aftermath DAO fee needs 1..=10,000 basis points.";

#[error(code = 4)]
const EWrongMigrator: vector<u8> = b"Only a sale this module's `new` started can be finalized here.";

#[error(code = 5)]
const EWrongVault: vector<u8> = b"Only an Aftermath vault's fees are collected here.";

// === Imports ===

use amm::{pool::{CreatePoolCapV2, Pool}, pool_factory, pool_registry::PoolRegistry};

use blast_presale::{
    blast_presale::{Self as presale, Presale, PresaleCap, PresaleInitializer},
    creation_policy::CreationPolicy,
    fee_policy::FeePolicy,
    presale_vault::{Self as vault, Vault},
    venue_config::VenueConfig,
};

#[test_only]
use blast_presale::{blast_presale::FeeSplit, fee_policy::ProtocolFees};

use dao_fee_amm::{pool as dao_fee_pool, version::Version};

use std::type_name;

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::Currency,
    event,
    transfer::Receiving,
};

use fun receive_fees as Vault.receive_fees;
