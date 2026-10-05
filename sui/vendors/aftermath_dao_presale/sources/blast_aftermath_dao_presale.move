// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// A one-off `blast_presale` migrator built for a partner. A funded sale seeds a 50/50 Aftermath
/// weighted pool wrapped in Aftermath's DAO-fee pool, which pays a 2% fee on every swap, deposit,
/// and withdrawal straight to the partner treasury. The treasury also receives each sale's
/// `PresaleCap`, and each DAO-fee pool's owner cap, with which it may change that pool's fee or
/// recipient, and the sale's locked LP.
module blast_aftermath_dao_presale::blast_aftermath_dao_presale;

// === Public Types ===

/// Sealed migrator identity a sale fixes when `new` creates it. Only this module constructs it, so
/// only `migrate` can release that sale's liquidity.
public struct Witness() has drop;

/// One migrated sale's complete LP balance, sent to the treasury. The treasury may move it, but no
/// function releases the LP, so the liquidity stays in the pool.
public struct LockedLiquidity<phantom Lp> has key, store {
    id: UID,
    lp: Balance<Lp>,
}

// === Public Functions ===

/// Creates a presale that migrates through this module and sends its `PresaleCap` to the
/// treasury. Every LP fee its pool pays reaches the treasury, so the sale's LP-fee split names the
/// treasury as its only recipient; Aftermath pools have no CLMM tier, so the tick spacing and fee
/// rate are zero. The `CreationPolicy` must allow `Witness`.
public fun new<SaleToken, Quote>(
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

    transfer::public_transfer(cap, TREASURY);

    sale
}

// `dao_fee_pool::new` creates the shared pool in this transaction.
/// Anyone may migrate a funded sale `new` created: it seeds a 50/50 Aftermath pool with all of the
/// sale's LP tokens and Quote, wraps it in a DAO-fee pool paying the treasury, shares that pool,
/// and sends its owner cap and the locked LP to the treasury. `Lp` is a fresh LP coin whose
/// `CreatePoolCapV2` the caller published beforehand, as Aftermath's pool creation requires.
#[allow(lint(share_owned))]
public fun migrate<Lp, SaleToken, Quote>(
    sale: &mut Presale<SaleToken, Quote>,
    fee_policy: &FeePolicy,
    pool_registry: &mut PoolRegistry,
    create_pool_cap: CreatePoolCapV2,
    dao_fee_version: &Version,
    clock: &Clock,
    ctx: &mut TxContext,
) {
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

    let dao_fee_pool_id = object::id(&dao_fee_pool);
    let liquidity = LockedLiquidity { id: object::new(ctx), lp: lp.into_balance() };

    event::emit(Migrated<Lp, SaleToken, Quote> {
        presale_id: object::id(sale),
        pool_id,
        dao_fee_pool_id,
        owner_cap_id: object::id(&owner_cap),
        liquidity_id: object::id(&liquidity),
        lp: liquidity.lp.value(),
    });

    transfer::public_share_object(dao_fee_pool);
    transfer::public_transfer(owner_cap, TREASURY);
    transfer::public_transfer(liquidity, TREASURY);
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
public fun sorts_before_for_testing<A, B>(): bool {
    sorts_before<A, B>()
}

// === Events ===

/// A sale migrated into the Aftermath pool `pool_id`, which traders reach through the shared
/// DAO-fee pool `dao_fee_pool_id`. The treasury holds that pool's owner cap `owner_cap_id` and
/// `liquidity_id`, which locks the sale's `lp` units.
public struct Migrated<phantom Lp, phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    pool_id: ID,
    dao_fee_pool_id: ID,
    owner_cap_id: ID,
    liquidity_id: ID,
    lp: u64,
}

// === Constants ===

/// Receives every sale's `PresaleCap` and every pool's DAO fees, owner cap, and locked LP.
const TREASURY: address = @0x37cf46b499f740e653644bd2f7a8ed97f248e8b3c69d5d12c97d7845a54c0cd8;

/// The DAO fee, 2%, that Aftermath sends to the treasury from every swap, deposit, and withdrawal
/// until the owner cap changes it.
const DAO_FEE_BPS: u16 = 200;

/// Each coin's weight: half of Aftermath's `1e18` fixed-point one.
const HALF_WEIGHT: u64 = 500_000_000_000_000_000;

/// Selects Aftermath's uncorrelated weighted-product curve.
const FLATNESS: u64 = 0;

/// Aftermath's minimum base swap-in fee, 0.01% in its `1e18` unit; it rejects zero. This part
/// compounds into the locked liquidity.
const BASE_SWAP_FEE: u64 = 100_000_000_000_000;

const POOL_NAME: vector<u8> = b"Blast Presale Pool";

/// The whole LP-fee split, which the treasury takes.
const ALL_BPS: u64 = 10_000;

// === Errors ===

#[error(code = 0)]
const EPoolMismatch: vector<u8> = b"The Aftermath pool must hold every sale token and Quote unit the presale released.";

#[error(code = 1)]
const EDaoFeePoolMismatch: vector<u8> = b"The DAO-fee pool must charge this package's fee and pay the treasury.";

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
    balance::Balance,
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::Currency,
    event,
};
