// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Permissionless Aftermath migration and LP-fee collection for configured presales.
///
/// A funded sale migrates into a fresh 50/50 Aftermath weighted pool wrapped in Aftermath's
/// DAO-fee pool. Aftermath pays the DAO fee of every swap, deposit, and withdrawal as separate
/// coins sent straight to the fee recipient address, so `migrate` names the sale's new vault as
/// that recipient: the fee coins land owned by the vault object, and anyone may then receive them
/// into the vault, where they are split like any collection. The vault keeps the LP coin, the whole
/// pool liquidity, under its sealed position key and the DAO-fee pool's `OwnerCap`, which could
/// otherwise change the fee or redirect it, under its sealed authority key; neither has a removal
/// path.
///
/// Aftermath creates a pool only from a `CreatePoolCapV2` minted by a freshly published LP coin,
/// so the creator publishes one per sale and binds its capability to the sale when starting it.
module blast_presale::aftermath;

// === Public Types ===

/// Sealed Aftermath migrator identity fixed before commitments open.
public struct Witness() has drop;

/// Sealed marker for the LP coin and owner cap held by a presale vault.
public struct Venue() has drop;

/// Shared reservation of the `<Meme, Quote>` sale's Aftermath pool creation: the `CreatePoolCapV2`
/// of the fresh LP coin `Lp`, which only that sale's migration can consume. Every sale token has
/// one sale, so the reservation is bound by its type.
public struct PoolCreation<phantom Lp, phantom Meme, phantom Quote> has key {
    id: UID,
    create_pool_cap: CreatePoolCapV2,
}

// === Public Functions ===

/// Starts a presale that migrates to an Aftermath pool created from `create_pool_cap`, which the
/// fresh LP coin `Lp` minted, and shares the reservation binding it to the sale. The pool's
/// weights and fees are this module's constants, so the sale carries no pool tier.
public fun new<Lp, Meme, Quote>(
    treasury_cap: TreasuryCap<Meme>,
    create_pool_cap: CreatePoolCapV2,
    creation_policy: &CreationPolicy,
    fee_policy: &FeePolicy,
    ctx: &mut TxContext,
): PresaleInitializer<Meme, Quote> {
    let initializer = presale::new(treasury_cap, Witness(), creation_policy, fee_policy);

    let pool_creation = PoolCreation<Lp, Meme, Quote> { id: object::new(ctx), create_pool_cap };

    event::emit(PoolCreationReserved<Lp, Meme, Quote> {
        pool_creation_id: pool_creation.id.to_inner(),
        create_pool_cap_id: object::id(&pool_creation.create_pool_cap),
    });

    transfer::share_object(pool_creation);

    initializer
}

// `dao_fee_pool::new` creates the shared pool in this transaction.
/// Anyone may migrate a funded presale into its reserved Aftermath pool, consuming the
/// reservation: it seeds a 50/50 pool with all of the sale's LP tokens and Quote, wraps it in a
/// DAO-fee pool paying the sale's new vault, shares that pool, and locks the LP coin and the pool's
/// owner cap in the vault.
#[allow(lint(share_owned))]
public fun migrate<Lp, Meme, Quote>(
    sale: &mut Presale<Meme, Quote>,
    pool_creation: PoolCreation<Lp, Meme, Quote>,
    fee_policy: &FeePolicy,
    pool_registry: &mut PoolRegistry,
    dao_fee_version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let PoolCreation { id, create_pool_cap } = pool_creation;
    id.delete();

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
    let liquidity = lp.value() as u128;
    let mut vault = vault::new(
        sale,
        &Venue(),
        pool_id,
        lp,
        liquidity,
        balance::zero(),
        balance::zero(),
        ctx,
    );
    let vault_address = object::id(&vault).to_address();
    let (dao_fee_pool, owner_cap) = dao_fee_pool::new(
        pool,
        dao_fee_version,
        DAO_FEE_BPS,
        vault_address,
        ctx,
    );
    assert!(
        dao_fee_pool.fee_bps() == DAO_FEE_BPS && dao_fee_pool.fee_recipient() == vault_address,
        EDaoFeePoolMismatch,
    );

    event::emit(DaoFeePoolCreated<Lp, Meme, Quote> {
        vault_id: object::id(&vault),
        pool_id,
        dao_fee_pool_id: object::id(&dao_fee_pool),
        owner_cap_id: object::id(&owner_cap),
    });

    vault.attach_pool_authority(&Venue(), owner_cap);
    vault.share();
    transfer::public_share_object(dao_fee_pool);
}

/// Anyone may receive the DAO fees Aftermath sent to the vault's address, one `Receiving` per fee
/// coin, and split them as LP fees, paying Blast and each fee recipient and accruing the holder
/// Quote and paying holder Meme to the governed treasury. An empty collection is valid.
public fun collect_fees<Meme, Quote>(
    vault: &mut Vault<Meme, Quote>,
    fee_policy: &FeePolicy,
    meme_fees: vector<Receiving<Coin<Meme>>>,
    quote_fees: vector<Receiving<Coin<Quote>>>,
    ctx: &mut TxContext,
) {
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
        vector[BASE_SWAP_FEE, BASE_SWAP_FEE],
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
public fun pool_creation_reserved_fields<Lp, Meme, Quote>(
    event: &PoolCreationReserved<Lp, Meme, Quote>,
): (ID, ID) {
    (event.pool_creation_id, event.create_pool_cap_id)
}

#[test_only]
public fun dao_fee_pool_created_fields<Lp, Meme, Quote>(
    event: &DaoFeePoolCreated<Lp, Meme, Quote>,
): (ID, ID, ID, ID) {
    (event.vault_id, event.pool_id, event.dao_fee_pool_id, event.owner_cap_id)
}

// === Events ===

/// `new` reserved the `<Meme, Quote>` sale's Aftermath pool creation for the LP coin `Lp` in the
/// shared `pool_creation_id`, holding the capability `create_pool_cap_id`; its migration consumes
/// both.
public struct PoolCreationReserved<phantom Lp, phantom Meme, phantom Quote> has copy, drop {
    pool_creation_id: ID,
    create_pool_cap_id: ID,
}

/// A sale migrated into the Aftermath pool `pool_id`, which traders reach through the shared
/// DAO-fee pool `dao_fee_pool_id` paying its fees to the vault `vault_id`. The vault holds that
/// pool's owner cap `owner_cap_id` and, as its position, the LP coin `VaultCreated` names.
public struct DaoFeePoolCreated<phantom Lp, phantom Meme, phantom Quote> has copy, drop {
    vault_id: ID,
    pool_id: ID,
    dao_fee_pool_id: ID,
    owner_cap_id: ID,
}

// === Constants ===

/// The DAO fee, 2%, that Aftermath sends to the vault from every swap, deposit, and withdrawal.
const DAO_FEE_BPS: u16 = 200;

/// Each coin's weight: half of Aftermath's `1e18` fixed-point one.
const HALF_WEIGHT: u64 = 500_000_000_000_000_000;

/// Selects Aftermath's uncorrelated weighted-product curve.
const FLATNESS: u64 = 0;

/// Aftermath's minimum base swap-in fee, 0.01% in its `1e18` unit; it rejects zero. This part
/// compounds into the locked LP.
const BASE_SWAP_FEE: u64 = 100_000_000_000_000;

const POOL_NAME: vector<u8> = b"Blast Presale Pool";

// === Errors ===

#[error(code = 0)]
const EPoolMismatch: vector<u8> = b"The Aftermath pool must hold every sale token and Quote unit the presale released.";

#[error(code = 1)]
const EDaoFeePoolMismatch: vector<u8> = b"The DAO-fee pool must charge this module's fee and pay the vault.";

// === Imports ===

use amm::{pool::{CreatePoolCapV2, Pool}, pool_factory, pool_registry::PoolRegistry};

use blast_presale::{
    blast_presale::{Self as presale, Presale, PresaleInitializer},
    creation_policy::CreationPolicy,
    fee_policy::FeePolicy,
    presale_vault::{Self as vault, Vault},
};

use dao_fee_amm::{pool as dao_fee_pool, version::Version};

use std::type_name;

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    event,
    transfer::Receiving,
};

use fun receive_fees as Vault.receive_fees;
