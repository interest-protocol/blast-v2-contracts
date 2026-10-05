// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// A one-off `blast_presale` migrator built for a partner. The `AdminCap` creates each sale with
/// the Aftermath pool-creation capability of its LP coin, which stays bound to that sale. Anyone
/// may then migrate the funded sale into a 50/50 Aftermath weighted pool wrapped in Aftermath's
/// DAO-fee pool, which pays a 2% fee on every swap, deposit, and withdrawal straight to the partner
/// treasury. The treasury also receives each sale's `PresaleCap` and each DAO-fee pool's owner
/// cap, with which it may change that pool's fee or recipient; the sale's LP is locked forever.
module blast_aftermath_dao_presale::blast_aftermath_dao_presale;

// === Public Types ===

/// Sealed migrator identity a sale fixes when `new` creates it. Only this module constructs it, so
/// only `migrate` can release that sale's liquidity.
public struct Witness() has drop;

/// The package's only administrator, sent to the publisher at publication. Its one power is
/// creating sales through `new`.
public struct AdminCap has key, store {
    id: UID,
}

/// Shared reservation of one sale's Aftermath pool creation: the `CreatePoolCapV2` of the fresh LP
/// coin `Lp`, which only `migrate` of the sale `presale_id` can consume.
public struct PoolCreation<phantom Lp> has key {
    id: UID,
    presale_id: ID,
    create_pool_cap: CreatePoolCapV2,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::public_transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

// === Public Functions ===

/// Creates a presale that migrates through this module, sends its `PresaleCap` to the treasury, and
/// shares a `PoolCreation` binding `create_pool_cap`, minted by the fresh LP coin `Lp`, to it.
/// Every LP fee its pool pays reaches the treasury, so the sale's LP-fee split names the treasury
/// as its only recipient; Aftermath pools have no CLMM tier, so the tick spacing and fee rate are
/// zero. The `CreationPolicy` must allow `Witness`.
public fun new<Lp, SaleToken, Quote>(
    _: &AdminCap,
    treasury_cap: TreasuryCap<SaleToken>,
    currency: &mut Currency<SaleToken>,
    token_supply: u64,
    token_allocation_bps: Bps,
    participant_vesting: Option<VestingTerms>,
    liquidity_token_allocation_bps: Bps,
    recipient_allocations: vector<RecipientShare>,
    burnable: bool,
    raise_target: u64,
    raise_allocations: vector<RecipientShare>,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    create_pool_cap: CreatePoolCapV2,
    creation_policy: &CreationPolicy,
    fee_policy: &FeePolicy,
    ctx: &mut TxContext,
): Presale<SaleToken, Quote> {
    let (sale, cap) = presale::new(
        treasury_cap,
        currency,
        token_supply,
        token_allocation_bps,
        participant_vesting,
        liquidity_token_allocation_bps,
        recipient_allocations,
        burnable,
        raise_target,
        raise_allocations,
        duration_ms,
        liquidity_window_ms,
        eligibility,
        uncapped,
        Witness(),
        0,
        0,
        vector[presale::recipient_share(TREASURY, bps::new(ALL_BPS))],
        bps::new(0),
        creation_policy,
        fee_policy,
        ctx,
    );

    let pool_creation = PoolCreation<Lp> {
        id: object::new(ctx),
        presale_id: object::id(&sale),
        create_pool_cap,
    };

    event::emit(PoolCreationReserved<Lp, SaleToken, Quote> {
        presale_id: pool_creation.presale_id,
        pool_creation_id: object::id(&pool_creation),
    });

    transfer::public_transfer(cap, TREASURY);
    transfer::share_object(pool_creation);

    sale
}

// `dao_fee_pool::new` creates the shared pool in this transaction.
/// Anyone may migrate a funded sale `new` created, consuming the `PoolCreation` bound to it: it
/// seeds a 50/50 Aftermath pool with all of the sale's LP tokens and Quote, wraps it in a DAO-fee
/// pool paying the treasury, shares that pool, sends its owner cap to the treasury, and locks the
/// LP at `BURN_ADDRESS`.
#[allow(lint(share_owned))]
public fun migrate<Lp, SaleToken, Quote>(
    sale: &mut Presale<SaleToken, Quote>,
    pool_creation: PoolCreation<Lp>,
    fee_policy: &FeePolicy,
    pool_registry: &mut PoolRegistry,
    dao_fee_version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let PoolCreation { id, presale_id, create_pool_cap } = pool_creation;
    assert!(presale_id == object::id(sale), EWrongPresale);
    id.delete();

    let (tokens, quote) = sale.migrate(fee_policy, Witness(), clock, ctx);
    let (token_amount, quote_amount) = (tokens.value(), quote.value());

    let (pool, lp) = if (sorts_before<SaleToken, Quote>()) {
        create_pool<Lp, _, _>(
            create_pool_cap,
            pool_registry,
            tokens.into_coin(ctx),
            quote.into_coin(ctx),
            ctx,
        )
    } else {
        create_pool<Lp, _, _>(
            create_pool_cap,
            pool_registry,
            quote.into_coin(ctx),
            tokens.into_coin(ctx),
            ctx,
        )
    };
    assert!(
        pool.balance_of<Lp, SaleToken>() == token_amount
            && pool.balance_of<Lp, Quote>() == quote_amount,
        EPoolMismatch,
    );

    let pool_id = object::id(&pool);
    let (dao_fee_pool, owner_cap) = dao_fee_pool::new(
        pool,
        dao_fee_version,
        DAO_FEE_BPS,
        TREASURY,
        ctx,
    );
    assert!(
        dao_fee_pool.fee_bps() == DAO_FEE_BPS && dao_fee_pool.fee_recipient() == TREASURY,
        EDaoFeePoolMismatch,
    );

    event::emit(Migrated<Lp, SaleToken, Quote> {
        presale_id: object::id(sale),
        pool_id,
        dao_fee_pool_id: object::id(&dao_fee_pool),
        owner_cap_id: object::id(&owner_cap),
        lp_coin_id: object::id(&lp),
        lp: lp.value(),
    });

    transfer::public_share_object(dao_fee_pool);
    transfer::public_transfer(owner_cap, TREASURY);
    transfer::public_transfer(lp, BURN_ADDRESS);
}

// === Private Functions ===

/// Creates the 50/50 pool from both coins, which must be in Aftermath's coin order.
fun create_pool<Lp, Coin1, Coin2>(
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
    let a = type_name::with_defining_ids<A>().into_string().into_bytes();
    let b = type_name::with_defining_ids<B>().into_string().into_bytes();
    let shared = a.length().min(b.length());
    let mut i = 0;
    while (i < shared && a[i] == b[i]) i = i + 1;

    if (i < shared) a[i] < b[i] else a.length() < b.length()
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
public fun sorts_before_for_testing<A, B>(): bool {
    sorts_before<A, B>()
}

#[test_only]
public fun pool_creation_presale_id_for_testing<Lp>(self: &PoolCreation<Lp>): ID {
    self.presale_id
}

#[test_only]
public fun pool_creation_reserved_fields<Lp, SaleToken, Quote>(
    event: &PoolCreationReserved<Lp, SaleToken, Quote>,
): (ID, ID) {
    (event.presale_id, event.pool_creation_id)
}

// === Events ===

/// `new` reserved the sale `presale_id`'s Aftermath pool creation for the LP coin `Lp` in the
/// shared `pool_creation_id`, which its migration consumes.
public struct PoolCreationReserved<phantom Lp, phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    pool_creation_id: ID,
}

/// A sale migrated into the Aftermath pool `pool_id`, which traders reach through the shared
/// DAO-fee pool `dao_fee_pool_id`. The treasury holds that pool's owner cap `owner_cap_id`, and
/// `BURN_ADDRESS` holds the LP coin `lp_coin_id`, which locks the sale's `lp` units forever.
public struct Migrated<phantom Lp, phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    pool_id: ID,
    dao_fee_pool_id: ID,
    owner_cap_id: ID,
    lp_coin_id: ID,
    lp: u64,
}

// === Constants ===

/// Receives every sale's `PresaleCap` and every pool's DAO fees and owner cap.
const TREASURY: address = @0x37cf46b499f740e653644bd2f7a8ed97f248e8b3c69d5d12c97d7845a54c0cd8;

/// Owns every pool's LP coin. No one can sign for the zero address, so nothing it owns can ever
/// be used in a transaction again.
const BURN_ADDRESS: address = @0x0;

/// The DAO fee, 2%, that Aftermath sends to the treasury from every swap, deposit, and withdrawal
/// until the owner cap changes it.
const DAO_FEE_BPS: u16 = 200;

/// Each coin's weight: half of Aftermath's `1e18` fixed-point one.
const HALF_WEIGHT: u64 = 500_000_000_000_000_000;

/// Selects Aftermath's uncorrelated weighted-product curve.
const FLATNESS: u64 = 0;

/// Aftermath's minimum base swap-in fee, 0.01% in its `1e18` unit; it rejects zero. This part
/// compounds into the locked LP.
const BASE_SWAP_FEE: u64 = 100_000_000_000_000;

const POOL_NAME: vector<u8> = b"Blast Presale Pool";

/// The whole LP-fee split, which the treasury takes.
const ALL_BPS: u64 = 10_000;

// === Errors ===

#[error(code = 0)]
const EPoolMismatch: vector<u8> = b"The Aftermath pool must hold every sale token and Quote unit the presale released.";

#[error(code = 1)]
const EDaoFeePoolMismatch: vector<u8> = b"The DAO-fee pool must charge this package's fee and pay the treasury.";

#[error(code = 2)]
const EWrongPresale: vector<u8> = b"The pool creation is bound to a different presale.";

// === Imports ===

use amm::{pool::{CreatePoolCapV2, Pool}, pool_factory, pool_registry::PoolRegistry};

use blast_presale::{
    blast_presale::{
        Self as presale,
        EligibilityPolicy,
        Presale,
        PresaleCap,
        RecipientShare,
        UncappedPhase,
        VestingTerms,
    },
    bps::{Self, Bps},
    creation_policy::CreationPolicy,
    fee_policy::FeePolicy,
};

use dao_fee_amm::{pool as dao_fee_pool, version::Version};

use std::type_name;

use sui::{
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::Currency,
    event,
};
