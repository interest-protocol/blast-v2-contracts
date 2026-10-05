// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// A one-off `blast_presale` migrator built for a partner. A funded sale seeds a 50/50 Aftermath
/// weighted pool wrapped in Aftermath's DAO-fee pool, which pays a 2% fee on every swap, deposit,
/// and withdrawal to this package's shared `Config`. Anyone may forward those fees to the treasury
/// the `AdminCap` sets.
module blast_aftermath_dao_presale::blast_aftermath_dao_presale;

// === Public Types ===

/// Sealed migrator identity a sale fixes when `new` creates it. Only this module constructs it, so
/// only `migrate` can release that sale's liquidity.
public struct Witness() has drop;

/// Shared singleton. Its object address is every pool's DAO-fee recipient, and `claim_fees` pays
/// whatever reaches it to `treasury`.
public struct Config has key {
    id: UID,
    treasury: address,
}

/// The package's only administrator, sent to `TREASURY` at publication. Its one power is moving the
/// treasury.
public struct AdminCap has key, store {
    id: UID,
}

/// One migrated sale's complete LP balance and its DAO-fee pool's owner cap. `migrate` freezes it,
/// so the liquidity can never be withdrawn; the cap stays readable by reference, so only an upgrade
/// of this package could change the pool's DAO fee or recipient.
public struct LockedLiquidity<phantom Lp> has key {
    id: UID,
    lp: Balance<Lp>,
    owner_cap: OwnerCap<Lp>,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(Config { id: object::new(ctx), treasury: TREASURY });
    transfer::public_transfer(AdminCap { id: object::new(ctx) }, TREASURY);
}

// === Public Functions ===

/// Creates a presale that migrates through this module. Every LP fee its pool pays reaches
/// `Config`, so the sale's LP-fee split names `Config` as its only recipient; Aftermath pools have
/// no CLMM tier, so the tick spacing and fee rate are zero. The `CreationPolicy` must allow
/// `Witness`.
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
    config: &Config,
    ctx: &mut TxContext,
): (Presale<SaleToken, Quote>, PresaleCap) {
    presale::new(
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
        vector[presale::recipient_share(config.fee_recipient(), bps::new(ALL_BPS))],
        bps::new(0),
        creation_policy,
        fee_policy,
        ctx,
    )
}

// `dao_fee_pool::new` creates the shared pool in this transaction, and freezing the owner cap with
// the LP is what keeps the pool's fee and recipient fixed.
/// Anyone may migrate a funded sale `new` created: it seeds a 50/50 Aftermath pool with all of the
/// sale's LP tokens and Quote, wraps it in a DAO-fee pool paying `Config`, shares that pool, and
/// freezes the LP and the pool's owner cap. `Lp` is a fresh LP coin whose `CreatePoolCapV2` the
/// caller published beforehand, as Aftermath's pool creation requires.
#[allow(lint(share_owned, freeze_wrapped))]
public fun migrate<Lp, SaleToken, Quote>(
    sale: &mut Presale<SaleToken, Quote>,
    fee_policy: &FeePolicy,
    config: &Config,
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
    let fee_recipient = config.fee_recipient();
    let (dao_fee_pool, owner_cap) = dao_fee_pool::new(
        pool,
        dao_fee_version,
        DAO_FEE_BPS,
        fee_recipient,
        ctx,
    );
    assert!(
        dao_fee_pool.fee_bps() == DAO_FEE_BPS && dao_fee_pool.fee_recipient() == fee_recipient,
        EDaoFeePoolMismatch,
    );

    let dao_fee_pool_id = object::id(&dao_fee_pool);
    let liquidity = LockedLiquidity { id: object::new(ctx), lp: lp.into_balance(), owner_cap };

    event::emit(Migrated<Lp, SaleToken, Quote> {
        presale_id: object::id(sale),
        pool_id,
        dao_fee_pool_id,
        liquidity_id: object::id(&liquidity),
        lp: liquidity.lp.value(),
    });

    transfer::public_share_object(dao_fee_pool);
    transfer::freeze_object(liquidity);
}

/// Pays every `Coin<CoinType>` sent to `Config`, such as DAO fees, to the treasury as one coin.
/// Anyone may claim; the coins can go nowhere else.
public fun claim_fees<CoinType>(
    self: &mut Config,
    fees: vector<Receiving<Coin<CoinType>>>,
    ctx: &mut TxContext,
) {
    assert!(!fees.is_empty(), ENoFees);

    let mut claimed = balance::zero<CoinType>();
    fees.do!(|fee| claimed.join(transfer::public_receive(&mut self.id, fee).into_balance()));
    let amount = claimed.value();

    transfer::public_transfer(claimed.into_coin(ctx), self.treasury);

    event::emit(FeesClaimed<CoinType> { treasury: self.treasury, amount });
}

/// Sends every later claim, including fees already waiting at `Config`, to `treasury`.
public fun set_treasury(self: &mut Config, _: &AdminCap, treasury: address) {
    assert!(treasury != @0x0, EZeroTreasury);
    assert!(treasury != self.treasury, ETreasuryUnchanged);

    self.treasury = treasury;

    event::emit(TreasuryChanged { treasury });
}

// === Private Functions ===

/// The address every DAO-fee pool pays: `Config`'s own, so the fees wait there until claimed.
fun fee_recipient(self: &Config): address {
    self.id.to_address()
}

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
public fun treasury_for_testing(self: &Config): address {
    self.treasury
}

#[test_only]
public fun sorts_before_for_testing<A, B>(): bool {
    sorts_before<A, B>()
}

#[test_only]
public fun fees_claimed_fields<CoinType>(event: &FeesClaimed<CoinType>): (address, u64) {
    (event.treasury, event.amount)
}

#[test_only]
public fun treasury_changed_fields(event: &TreasuryChanged): address {
    event.treasury
}

// === Events ===

/// A sale migrated into the Aftermath pool `pool_id`, which traders reach through the shared
/// DAO-fee pool `dao_fee_pool_id`; its `lp` units are frozen in `liquidity_id`.
public struct Migrated<phantom Lp, phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    pool_id: ID,
    dao_fee_pool_id: ID,
    liquidity_id: ID,
    lp: u64,
}

/// Anyone forwarded `amount` of `CoinType` from `Config` to `treasury`.
public struct FeesClaimed<phantom CoinType> has copy, drop {
    treasury: address,
    amount: u64,
}

/// The `AdminCap` sent every later claim to `treasury`.
public struct TreasuryChanged has copy, drop {
    treasury: address,
}

// === Constants ===

/// Receives the `AdminCap` and, until the cap moves it, every claimed fee.
const TREASURY: address = @0x1dd93b4bb9a733c30da8a3c4a49177ab3ab4ab4a602a89a72b24f63b68e53534;

/// The DAO fee, 2%, that Aftermath sends to `Config` from every swap, deposit, and withdrawal.
const DAO_FEE_BPS: u16 = 200;

/// Each coin's weight: half of Aftermath's `1e18` fixed-point one.
const HALF_WEIGHT: u64 = 500_000_000_000_000_000;

/// Selects Aftermath's uncorrelated weighted-product curve.
const FLATNESS: u64 = 0;

/// Aftermath's minimum base swap-in fee, 0.01% in its `1e18` unit; it rejects zero. This part
/// compounds into the frozen liquidity.
const BASE_SWAP_FEE: u64 = 100_000_000_000_000;

const POOL_NAME: vector<u8> = b"Blast Presale Pool";

/// The whole LP-fee split, which `Config` takes.
const ALL_BPS: u64 = 10_000;

// === Errors ===

#[error(code = 0)]
const EPoolMismatch: vector<u8> = b"The Aftermath pool must hold every sale token and Quote unit the presale released.";

#[error(code = 1)]
const EDaoFeePoolMismatch: vector<u8> = b"The DAO-fee pool must charge this package's fee and pay Config.";

#[error(code = 2)]
const ENoFees: vector<u8> = b"A fee claim must receive at least one coin.";

#[error(code = 3)]
const EZeroTreasury: vector<u8> = b"The treasury cannot be the zero address.";

#[error(code = 4)]
const ETreasuryUnchanged: vector<u8> = b"A treasury update must change the treasury.";

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

use dao_fee_amm::{pool::{Self as dao_fee_pool, OwnerCap}, version::Version};

use std::type_name;

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::Currency,
    event,
    transfer::Receiving,
};
