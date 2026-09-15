/// Canonical full-range pools, separate LP fees and owned liquidity positions.
module blast_fun_dex::pool;

use blast_admin::{
    acl::AdminWitness,
    operational_version::{Self, OperationalVersion}
};
use blast_fun::{creator_authority::CurveFeeCap, launch::Launch};
use blast_fun_dex::{dex_domain::DEX_DOMAIN, math, package_marker::PACKAGE_MARKER};
use std::type_name::{Self, TypeName};
use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    coin_registry::Currency,
    event,
    table::{Self, Table}
};

// === Constants ===

/// Current DEX generation accepted by every economic and administrative path.
const PACKAGE_VERSION: u64 = 1;
/// The generation this bytecode hands over to in a governed upgrade.
const NEXT_PACKAGE_VERSION: u64 = 2;
const MINIMUM_SHARES: u128 = 1_000;
const DEFAULT_MAX_FEE_BPS: u64 = 200;
const MAX_FEE_BPS: u64 = 500;
const MAX_BURN_BPS: u64 = 500;
const X64: u256 = 18_446_744_073_709_551_616;

// === Errors ===

// Code 0 retired: generation checking moved to
// `blast_admin::operational_version`, which raises its own code.
#[error(code = 1)]
const EIdenticalAssets: vector<u8> = b"Meme and Quote must have different original types.";
#[error(code = 2)]
const EDuplicatePool: vector<u8> = b"A canonical pool already exists for this Meme.";
#[error(code = 3)]
const ESeedTooSmall: vector<u8> =
    b"Both seed assets and more than 1000 initial shares are required.";
#[error(code = 4)]
const EBurnPolicy: vector<u8> = b"Burn must not exceed 500 bps and requires BurnOnly currency.";
#[error(code = 5)]
const EFeeCap: vector<u8> = b"Pool maximum fee must not exceed 500 bps.";
#[error(code = 6)]
const EUnchangedFee: vector<u8> = b"Maximum fee must change.";
#[error(code = 7)]
const EExpired: vector<u8> = b"Transaction deadline has passed.";
#[error(code = 8)]
const EZeroAmount: vector<u8> = b"Swap principal and net output must be positive.";
#[error(code = 9)]
const EFeeLimit: vector<u8> = b"Rounded Quote fee exceeds the signed effective fee limit.";
#[error(code = 10)]
const EMinimumOutput: vector<u8> = b"Net received amount is below the signed minimum.";
#[error(code = 11)]
const EWrongPool: vector<u8> = b"Position must belong to the supplied pool.";
#[error(code = 12)]
const EMinimumShares: vector<u8> = b"Deposit must mint positive shares meeting the signed minimum.";
#[error(code = 13)]
const EInsufficientShares: vector<u8> =
    b"Withdrawal requires positive shares owned by the position.";
#[error(code = 14)]
const EPositionNotEmpty: vector<u8> =
    b"Position must have no principal or whole-atom fee entitlement.";
#[error(code = 15)]
const EAccountingOverflow: vector<u8> = b"Fee accounting must remain representable.";
#[error(code = 16)]
const EClockReversed: vector<u8> = b"Clock must not precede the last successful trade.";

// Code 17 retired: generation overflow is raised by
// `blast_admin::operational_version`.

// === Public Types ===

/// Publication-only uniqueness registry and operational generation authority.
public struct Factory has key {
    id: UID,
    generation: OperationalVersion<PACKAGE_MARKER>,
    pools: Table<TypeName, ID>,
}

/// Principal reserves exclude every accrued LP fee and optional native burn.
public struct Pool<phantom Meme, phantom Quote> has key {
    id: UID,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    quote_fees: Balance<Quote>,
    total_shares: u128,
    fee_growth_x64: u128,
    volume_x32: u128,
    last_trade_seconds: u64,
    volume_target: u64,
    max_fee_bps: u64,
    burn_bps: u64,
}

/// Transferable entitlement to one pool's principal and separately earned fees.
public struct Position<phantom Meme, phantom Quote> has key, store {
    id: UID,
    pool_id: ID,
    shares: u128,
    fee_checkpoint_x64: u128,
    fees_owed: u64,
    fee_fraction_x64: u64,
}

/// Immutable proposed settlement, shared by burn and ordinary swap entrypoints.
public struct Trade has copy, drop {
    quote: u64,
    meme: u64,
    fee: u64,
    burn: u64,
    next_volume: u128,
    timestamp_seconds: u64,
}

/// Initial pool seed, immutable burn policy and the original LP position.
public struct PoolCreated<phantom Meme, phantom Quote> has copy, drop {
    pool_id: ID,
    position_id: ID,
    meme: u64,
    quote: u64,
    total_shares: u128,
    burn_bps: u64,
    max_fee_bps: u64,
    timestamp_seconds: u64,
}
/// An empty owned position begins at the current pool fee checkpoint.
public struct PositionCreated has copy, drop { pool_id: ID, position_id: ID }
/// An empty position is deleted; fractional dust stays unclaimable.
public struct PositionClosed has copy, drop { pool_id: ID, position_id: ID }
/// Executed principal, fees, burn and resulting reserves and volume.
public struct Swapped has copy, drop {
    pool_id: ID,
    buy: bool,
    meme_principal: u64,
    quote_principal: u64,
    quote_fee: u64,
    meme_burn: u64,
    meme_reserve: u64,
    quote_reserve: u64,
    fee_balance: u64,
    volume_x32: u128,
    timestamp_seconds: u64,
}
/// Actual paired contribution or withdrawal and resulting share supply.
public struct LiquidityChanged has copy, drop {
    pool_id: ID,
    position_id: ID,
    added: bool,
    shares: u128,
    meme: u64,
    quote: u64,
    total_shares: u128,
}
/// A positive Quote entitlement leaves the separate fee balance.
public struct FeesClaimed has copy, drop { pool_id: ID, position_id: ID, quote: u64 }
/// Only the future marginal fee maximum changes.
public struct MaximumFeeChanged has copy, drop { pool_id: ID, previous_bps: u64, maximum_bps: u64 }
// The generation-advance fact is emitted by `blast_admin::operational_version`
// for every consumer package; no copy belongs here.

// === Private Initialization ===

fun init(ctx: &mut TxContext) { transfer::share_object(new_factory(ctx)); }

// === Public Functions ===

/// Rejects stale bytecode at every economic path, including adapter no-op paths.
public fun assert_current(self: &Factory) { self.generation.assert_current(PACKAGE_VERSION); }

// === Package Functions ===

/// Proves the cutover target is exactly next before any upgrade finalizer effect.
public(package) fun assert_next(self: &Factory) {
    self.generation.assert_next(NEXT_PACKAGE_VERSION);
}

/// Advances the generation to the exact bytecode this upgrade installs.
public(package) fun advance(self: &mut Factory) {
    let container_id = self.id.to_inner();

    self.generation.advance(container_id, NEXT_PACKAGE_VERSION);
}

// === Public Functions ===

/// Creates the post-migration fee destination under the launch's live curve-fee cap.
/// The immutable burn applies in both swap directions; fees always use Quote.
public fun create<Meme, Quote>(
    self: &mut Factory,
    curve_fee_cap: &CurveFeeCap<Meme>,
    launch: &Launch<Meme, Quote>,
    currency: &Currency<Meme>,
    meme: Coin<Meme>,
    quote: Coin<Quote>,
    burn_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Pool<Meme, Quote>, Position<Meme, Quote>) {
    self.assert_available<Meme, Quote>();
    launch.assert_migrated();
    launch.assert_curve_fee_cap(curve_fee_cap);
    assert!(
        burn_bps <= MAX_BURN_BPS && (burn_bps == 0 || currency.is_supply_burn_only()),
        EBurnPolicy,
    );
    create_from_balances(self, meme.into_balance(), quote.into_balance(), burn_bps, clock, ctx)
}

/// Publishes a constructed canonical pool into shared custody.
public fun share<Meme, Quote>(self: Pool<Meme, Quote>) { transfer::share_object(self); }

/// Creates an empty transferable position checkpointed at the current fee growth.
public fun new_position<Meme, Quote>(
    self: &Pool<Meme, Quote>,
    ctx: &mut TxContext,
): Position<Meme, Quote> {
    let position = position(self.id.to_inner(), 0, self.fee_growth_x64, ctx);
    event::emit(PositionCreated {
        pool_id: self.id.to_inner(),
        position_id: position.id.to_inner(),
    });
    position
}

/// Admins may change only future marginal rates; history and balances are untouched.
public fun set_max_fee<Meme, Quote>(
    self: &mut Pool<Meme, Quote>,
    factory: &Factory,
    _: &AdminWitness<DEX_DOMAIN>,
    maximum_bps: u64,
) {
    factory.assert_current();
    assert!(maximum_bps <= MAX_FEE_BPS, EFeeCap);
    assert!(maximum_bps != self.max_fee_bps, EUnchangedFee);
    let previous_bps = self.max_fee_bps;
    self.max_fee_bps = maximum_bps;
    event::emit(MaximumFeeChanged { pool_id: self.id.to_inner(), previous_bps, maximum_bps });
}

/// Computes an on-chain deposit bound for permissionless vault composition.
public fun deposit_amounts<Meme, Quote>(
    self: &Pool<Meme, Quote>,
    meme_max: u64,
    quote_max: u64,
): (u64, u64, u128) {
    math::deposit_amounts(
        meme_max,
        quote_max,
        self.meme.value(),
        self.quote.value(),
        self.total_shares,
    )
}

/// Deposits both supported amounts, settles prior fees and returns every excess coin.
public fun add_liquidity<Meme, Quote>(
    self: &mut Pool<Meme, Quote>,
    factory: &Factory,
    position: &mut Position<Meme, Quote>,
    mut meme: Coin<Meme>,
    mut quote: Coin<Quote>,
    min_shares: u128,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    factory.assert_current();
    self.assert_position(position);
    assert!(clock.timestamp_ms() <= deadline_ms, EExpired);
    let (meme_amount, quote_amount, shares) = self.deposit_amounts(meme.value(), quote.value());
    assert!(shares > 0 && shares >= min_shares, EMinimumShares);

    self.settle_position(position);
    self.meme.join(meme.split(meme_amount, ctx).into_balance());
    self.quote.join(quote.split(quote_amount, ctx).into_balance());
    self.total_shares = self.total_shares + shares;
    position.shares = position.shares + shares;
    self.emit_liquidity(position, true, shares, meme_amount, quote_amount);
    (meme, quote)
}

/// Redeems principal only. Earned fees stay claimable from the same position.
public fun remove_liquidity<Meme, Quote>(
    self: &mut Pool<Meme, Quote>,
    factory: &Factory,
    position: &mut Position<Meme, Quote>,
    shares: u128,
    minimum_meme: u64,
    minimum_quote: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    factory.assert_current();
    self.assert_position(position);
    assert!(clock.timestamp_ms() <= deadline_ms, EExpired);
    assert!(shares > 0 && shares <= position.shares, EInsufficientShares);
    let meme =
        ((self.meme.value() as u256) * (shares as u256) / (self.total_shares as u256)) as u64;
    let quote =
        ((self.quote.value() as u256) * (shares as u256) / (self.total_shares as u256)) as u64;
    assert!(meme > 0 && quote > 0, EZeroAmount);
    assert!(meme >= minimum_meme && quote >= minimum_quote, EMinimumOutput);

    self.settle_position(position);
    position.shares = position.shares - shares;
    self.total_shares = self.total_shares - shares;
    let meme_coin = self.meme.split(meme).into_coin(ctx);
    let quote_coin = self.quote.split(quote).into_coin(ctx);
    self.emit_liquidity(position, false, shares, meme, quote);
    (meme_coin, quote_coin)
}

/// Pays only this position's separately funded Quote entitlement; empty claims are zero.
public fun claim_fees<Meme, Quote>(
    self: &mut Pool<Meme, Quote>,
    factory: &Factory,
    position: &mut Position<Meme, Quote>,
    ctx: &mut TxContext,
): Coin<Quote> {
    factory.assert_current();
    self.assert_position(position);
    self.settle_position(position);
    let quote = position.fees_owed;
    position.fees_owed = 0;
    let result = self.quote_fees.split(quote).into_coin(ctx);
    if (quote > 0) {
        event::emit(FeesClaimed {
            pool_id: self.id.to_inner(),
            position_id: position.id.to_inner(),
            quote,
        });
    };
    result
}

/// Deletes an empty position; any sub-atom entitlement becomes unclaimable pool dust.
public fun destroy_empty<Meme, Quote>(self: Position<Meme, Quote>) {
    assert!(self.shares == 0 && self.fees_owed == 0, EPositionNotEmpty);
    let Position { id, pool_id, .. } = self;
    let position_id = id.to_inner();
    id.delete();
    event::emit(PositionClosed { pool_id, position_id });
}

/// Exact-input Quote buy for a pool whose immutable burn rate is zero.
public fun buy<Meme, Quote>(
    self: &mut Pool<Meme, Quote>,
    factory: &Factory,
    input: Coin<Quote>,
    minimum_meme: u64,
    maximum_fee_bps: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    factory.assert_current();
    assert!(self.burn_bps == 0, EBurnPolicy);
    let trade = self.prepare_buy(input.value(), minimum_meme, maximum_fee_bps, deadline_ms, clock);
    let (meme, refund, burn) = self.execute_buy(input, trade, ctx);
    burn.destroy_zero();
    self.emit_swap(true, trade);
    (meme, refund)
}

/// Exact-input Quote buy that executes native supply destruction atomically.
public fun buy_and_burn<Meme, Quote>(
    self: &mut Pool<Meme, Quote>,
    factory: &Factory,
    input: Coin<Quote>,
    currency: &mut Currency<Meme>,
    minimum_meme: u64,
    maximum_fee_bps: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    factory.assert_current();
    assert!(currency.is_supply_burn_only(), EBurnPolicy);
    let trade = self.prepare_buy(input.value(), minimum_meme, maximum_fee_bps, deadline_ms, clock);
    let (meme, refund, burn) = self.execute_buy(input, trade, ctx);
    currency.burn_balance(burn);
    self.emit_swap(true, trade);
    (meme, refund)
}

/// Exact-input Meme sell for a pool whose immutable burn rate is zero.
public fun sell<Meme, Quote>(
    self: &mut Pool<Meme, Quote>,
    factory: &Factory,
    input: Coin<Meme>,
    minimum_quote: u64,
    maximum_fee_bps: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    factory.assert_current();
    assert!(self.burn_bps == 0, EBurnPolicy);
    let trade = self.prepare_sell(
        input.value(),
        minimum_quote,
        maximum_fee_bps,
        deadline_ms,
        clock,
    );
    let (quote, burn) = self.execute_sell(input, trade, ctx);
    burn.destroy_zero();
    self.emit_swap(false, trade);
    quote
}

/// Burns incoming Meme first; Quote fee and minimum receipt use the remaining trade.
public fun sell_and_burn<Meme, Quote>(
    self: &mut Pool<Meme, Quote>,
    factory: &Factory,
    input: Coin<Meme>,
    currency: &mut Currency<Meme>,
    minimum_quote: u64,
    maximum_fee_bps: u64,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    factory.assert_current();
    assert!(currency.is_supply_burn_only(), EBurnPolicy);
    let trade = self.prepare_sell(
        input.value(),
        minimum_quote,
        maximum_fee_bps,
        deadline_ms,
        clock,
    );
    let (quote, burn) = self.execute_sell(input, trade, ctx);
    currency.burn_balance(burn);
    self.emit_swap(false, trade);
    quote
}

// === Package Functions ===

/// Sealed migration routes check availability before consuming the core handoff.
public(package) fun assert_available<Meme, Quote>(self: &Factory) {
    self.assert_current();
    let meme = type_name::with_original_ids<Meme>();
    assert!(meme != type_name::with_original_ids<Quote>(), EIdenticalAssets);
    assert!(!self.pools.contains(meme), EDuplicatePool);
}

/// Only creator-authorized construction or the sealed native route can seed a pool.
public(package) fun create_from_balances<Meme, Quote>(
    factory: &mut Factory,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    burn_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Pool<Meme, Quote>, Position<Meme, Quote>) {
    factory.assert_available<Meme, Quote>();
    assert!(burn_bps <= MAX_BURN_BPS, EBurnPolicy);
    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let shares = math::initial_shares(meme_amount, quote_amount);
    assert!(meme_amount > 0 && quote_amount > 0 && shares > MINIMUM_SHARES, ESeedTooSmall);

    let pool = Pool {
        id: object::new(ctx),
        meme,
        quote,
        quote_fees: balance::zero(),
        total_shares: shares,
        fee_growth_x64: 0,
        volume_x32: 0,
        last_trade_seconds: clock.timestamp_ms() / 1000,
        volume_target: quote_amount,
        max_fee_bps: DEFAULT_MAX_FEE_BPS,
        burn_bps,
    };
    let position = position(pool.id.to_inner(), shares - MINIMUM_SHARES, 0, ctx);
    factory.pools.add(type_name::with_original_ids<Meme>(), pool.id.to_inner());
    event::emit(PoolCreated<Meme, Quote> {
        pool_id: pool.id.to_inner(),
        position_id: position.id.to_inner(),
        meme: meme_amount,
        quote: quote_amount,
        total_shares: shares,
        burn_bps,
        max_fee_bps: DEFAULT_MAX_FEE_BPS,
        timestamp_seconds: pool.last_trade_seconds,
    });
    (pool, position)
}

// === Private Functions ===

fun new_factory(ctx: &mut TxContext): Factory {
    Factory {
        id: object::new(ctx),
        generation: operational_version::new(),
        pools: table::new(ctx),
    }
}

fun position<Meme, Quote>(
    pool_id: ID,
    shares: u128,
    checkpoint: u128,
    ctx: &mut TxContext,
): Position<Meme, Quote> {
    Position {
        id: object::new(ctx),
        pool_id,
        shares,
        fee_checkpoint_x64: checkpoint,
        fees_owed: 0,
        fee_fraction_x64: 0,
    }
}

fun assert_position<Meme, Quote>(self: &Pool<Meme, Quote>, position: &Position<Meme, Quote>) {
    assert!(position.pool_id == self.id.to_inner(), EWrongPool);
}

fun settle_position<Meme, Quote>(self: &Pool<Meme, Quote>, position: &mut Position<Meme, Quote>) {
    let earned_x64 =
        (position.shares as u256) * ((self.fee_growth_x64 - position.fee_checkpoint_x64) as u256) + (position.fee_fraction_x64 as u256);
    let earned = earned_x64 / X64;
    assert!(earned <= (std::u64::max_value!() as u256), EAccountingOverflow);
    position.fees_owed =
        position.fees_owed.checked_add(earned as u64).destroy_or!(abort EAccountingOverflow);
    position.fee_fraction_x64 = (earned_x64 % X64) as u64;
    position.fee_checkpoint_x64 = self.fee_growth_x64;
}

fun aged_volume<Meme, Quote>(
    self: &Pool<Meme, Quote>,
    deadline_ms: u64,
    clock: &Clock,
): (u128, u64) {
    assert!(clock.timestamp_ms() <= deadline_ms, EExpired);
    let timestamp = clock.timestamp_ms() / 1000;
    assert!(timestamp >= self.last_trade_seconds, EClockReversed);
    (math::decay(self.volume_x32, timestamp - self.last_trade_seconds), timestamp)
}

fun assert_fee_limit(quote: u64, fee: u64, maximum_bps: u64) {
    assert!(
        maximum_bps <= 10_000 && (fee as u128) * 10_000 <= (quote as u128) * (maximum_bps as u128),
        EFeeLimit,
    );
}

fun prepare_buy<Meme, Quote>(
    self: &Pool<Meme, Quote>,
    input: u64,
    minimum: u64,
    maximum_fee: u64,
    deadline: u64,
    clock: &Clock,
): Trade {
    let (volume, timestamp_seconds) = self.aged_volume(deadline, clock);
    assert!(input > 0, EZeroAmount);
    let (quote, fee, _) = math::buy_principal(volume, self.volume_target, input, self.max_fee_bps);
    assert!(quote > 0, EZeroAmount);
    assert_fee_limit(quote, fee, maximum_fee);
    let meme = math::amount_out(quote, self.quote.value(), self.meme.value());
    let burn = meme.mul_div_ceil(self.burn_bps, 10_000);
    assert!(meme > burn, EZeroAmount);
    assert!(meme - burn >= minimum, EMinimumOutput);
    Trade {
        quote,
        meme,
        fee,
        burn,
        next_volume: math::next_volume(volume, self.volume_target, quote),
        timestamp_seconds,
    }
}

fun prepare_sell<Meme, Quote>(
    self: &Pool<Meme, Quote>,
    input: u64,
    minimum: u64,
    maximum_fee: u64,
    deadline: u64,
    clock: &Clock,
): Trade {
    let (volume, timestamp_seconds) = self.aged_volume(deadline, clock);
    let burn = input.mul_div_ceil(self.burn_bps, 10_000);
    assert!(input > burn, EZeroAmount);
    let meme = input - burn;
    let quote = math::amount_out(meme, self.meme.value(), self.quote.value());
    let fee = math::fee_up(volume, self.volume_target, quote, self.max_fee_bps);
    assert!(quote > fee, EZeroAmount);
    assert_fee_limit(quote, fee, maximum_fee);
    assert!(quote - fee >= minimum, EMinimumOutput);
    Trade {
        quote,
        meme,
        fee,
        burn,
        next_volume: math::next_volume(volume, self.volume_target, quote),
        timestamp_seconds,
    }
}

fun accrue<Meme, Quote>(self: &mut Pool<Meme, Quote>, fee: Balance<Quote>, trade: Trade) {
    let growth = (((fee.value() as u256) * X64) / (self.total_shares as u256)) as u128;
    self.fee_growth_x64 =
        self.fee_growth_x64.checked_add(growth).destroy_or!(abort EAccountingOverflow);
    self.quote_fees.join(fee);
    self.volume_x32 = trade.next_volume;
    self.last_trade_seconds = trade.timestamp_seconds;
}

fun execute_buy<Meme, Quote>(
    self: &mut Pool<Meme, Quote>,
    mut input: Coin<Quote>,
    trade: Trade,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>, Balance<Meme>) {
    let fee = input.split(trade.fee, ctx).into_balance();
    self.quote.join(input.split(trade.quote, ctx).into_balance());
    let mut output = self.meme.split(trade.meme);
    let burn = output.split(trade.burn);
    self.accrue(fee, trade);
    (output.into_coin(ctx), input, burn)
}

fun execute_sell<Meme, Quote>(
    self: &mut Pool<Meme, Quote>,
    mut input: Coin<Meme>,
    trade: Trade,
    ctx: &mut TxContext,
): (Coin<Quote>, Balance<Meme>) {
    let burn = input.split(trade.burn, ctx).into_balance();
    self.meme.join(input.into_balance());
    let mut output = self.quote.split(trade.quote);
    self.accrue(output.split(trade.fee), trade);
    (output.into_coin(ctx), burn)
}

fun emit_swap<Meme, Quote>(self: &Pool<Meme, Quote>, buy: bool, trade: Trade) {
    event::emit(Swapped {
        pool_id: self.id.to_inner(),
        buy,
        meme_principal: trade.meme,
        quote_principal: trade.quote,
        quote_fee: trade.fee,
        meme_burn: trade.burn,
        meme_reserve: self.meme.value(),
        quote_reserve: self.quote.value(),
        fee_balance: self.quote_fees.value(),
        volume_x32: self.volume_x32,
        timestamp_seconds: trade.timestamp_seconds,
    });
}

fun emit_liquidity<Meme, Quote>(
    self: &Pool<Meme, Quote>,
    position: &Position<Meme, Quote>,
    added: bool,
    shares: u128,
    meme: u64,
    quote: u64,
) {
    event::emit(LiquidityChanged {
        pool_id: self.id.to_inner(),
        position_id: position.id.to_inner(),
        added,
        shares,
        meme,
        quote,
        total_shares: self.total_shares,
    });
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): Factory { new_factory(ctx) }
#[test_only]
public fun balances_for_testing<Meme, Quote>(self: &Pool<Meme, Quote>): (u64, u64, u64) {
    (self.meme.value(), self.quote.value(), self.quote_fees.value())
}
#[test_only]
public fun shares_for_testing<Meme, Quote>(self: &Position<Meme, Quote>): u128 { self.shares }
#[test_only]
public fun foreign_position_for_testing<Meme, Quote>(ctx: &mut TxContext): Position<Meme, Quote> {
    position(object::id_from_address(@0x99), 1, 0, ctx)
}
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }
#[test_only]
public fun set_version_for_testing(self: &mut Factory, version: u64) {
    self.generation.set_generation_for_testing(version);
}
#[test_only]
public fun version_for_testing(self: &Factory): u64 { self.generation.generation_for_testing() }
#[test_only]
/// Exercises the compiled cutover target without a native upgrade fixture.
public fun advance_for_testing(self: &mut Factory) { self.advance(); }
#[test_only]
/// Exercises the finalizer's pre-commit proof without a native upgrade fixture.
public fun assert_next_for_testing(self: &Factory) { self.assert_next(); }
#[test_only]
public fun policy_for_testing<Meme, Quote>(self: &Pool<Meme, Quote>): (u64, u64, u128, u64) {
    (self.max_fee_bps, self.burn_bps, self.volume_x32, self.last_trade_seconds)
}

#[test_only]
public fun set_fee_growth_for_testing<Meme, Quote>(self: &mut Pool<Meme, Quote>, growth: u128) {
    self.fee_growth_x64 = growth;
}
