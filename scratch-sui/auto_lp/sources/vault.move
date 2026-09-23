// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Irrevocable creator-fee binding, public fee collection and executor-authorized deposits.
///
/// Enrollment destroys the curve-fee cap and binds the launch's creator fees to this vault
/// forever; LP-fee caps are destroyed the same way. No fee capability survives, so no
/// administrator can reassign these fee streams. Metadata authority is untouched.
///
/// This package has no administration of its own. It is published immutably in
/// one transaction that consumes its `UpgradeCap`, so there is no local
/// generation to advance, no control object, and no witness that reaches
/// anything here. Every version input is the external package's own: each
/// upstream package still refuses to serve stale bytecode.
module blast_fun_auto_lp::vault;

// === Errors ===

#[error(code = 0)]
const EWrongPool: vector<u8> = b"AutoLP can operate only on its enrolled native pool.";

#[error(code = 1)]
const EDeadlineExpired: vector<u8> = b"AutoLP deposit deadline has expired.";

#[error(code = 2)]
const EInvalidExecutor: vector<u8> = b"AutoLP requires a nonzero immutable execution address.";

#[error(code = 3)]
const EUnauthorizedExecutor: vector<u8> =
    b"Only the enrolled executor may choose AutoLP deposit price and timing.";

#[error(code = 4)]
const EMaximumInput: vector<u8> = b"Actual paired deposit exceeds the executor maximum input.";

// === Public Types ===

/// Sealed child name preserves discoverability without a public borrowing path.
public struct PositionKey() has copy, drop, store;

/// Receives bound creator fees and holds one native position and pending assets with no
/// extraction path.
public struct Vault<phantom Meme, phantom Quote> has key {
    id: UID,
    pool_id: ID,
    executor: address,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
}

/// Records the one-way enrollment, the destroyed curve-fee cap and the discoverable position.
public struct Enrolled has copy, drop {
    vault_id: ID,
    pool_id: ID,
    curve_fee_cap_id: ID,
    position_id: ID,
    executor: address,
}

/// Records a source claim and the resulting pending balances.
public struct FeesCollected has copy, drop {
    vault_id: ID,
    source_id: ID,
    meme: u64,
    quote: u64,
    meme_total: u64,
    quote_total: u64,
}

/// Records contributed assets that become subject to the same permanent custody.
public struct Contributed has copy, drop {
    vault_id: ID,
    meme: u64,
    quote: u64,
    meme_total: u64,
    quote_total: u64,
}

/// Records actual deposits, minted shares and pending refunds.
public struct Compounded has copy, drop {
    vault_id: ID,
    meme: u64,
    quote: u64,
    shares: u128,
    meme_total: u64,
    quote_total: u64,
}

// === Public Functions ===

/// Destroys the curve-fee cap, binds the launch's creator fees to this vault forever, and pins
/// the executor controlling deposit timing.
/// The executor receives no principal, fee or position withdrawal right.
public fun new<Meme, Quote>(
    curve_fee_cap: CurveFeeCap<Meme>,
    launch: &mut Launch<Meme, Quote>,
    version: &PackageVersion,
    pool: &Pool<Meme, Quote>,
    factory: &Factory,
    executor: address,
    ctx: &mut TxContext,
): Vault<Meme, Quote> {
    factory.assert_current();
    assert!(executor != @0x0, EInvalidExecutor);
    let pool_id = object::id(pool);
    let curve_fee_cap_id = object::id(&curve_fee_cap);
    let mut vault = Vault {
        id: object::new(ctx),
        pool_id,
        executor,
        meme: balance::zero(),
        quote: balance::zero(),
    };
    launch.lock_creator_fees(version, curve_fee_cap, &vault.id);
    let position = pool::new_position(pool, ctx);
    let position_id = object::id(&position);
    dynamic_object_field::add(&mut vault.id, PositionKey(), position);

    event::emit(Enrolled {
        vault_id: vault.id.to_inner(),
        pool_id,
        curve_fee_cap_id,
        position_id,
        executor,
    });
    vault
}

/// Shares enrollment for public collection and executor-authorized compounding.
public fun share<Meme, Quote>(self: Vault<Meme, Quote>) { transfer::share_object(self) }

/// Collects only the launch's bound creator fees; upstream version and nonempty checks apply.
public fun collect_curve<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    launch: &mut Launch<Meme, Quote>,
    version: &PackageVersion,
    ctx: &mut TxContext,
) {
    let (meme, quote) = launch.claim_custodied_creator_fees(version, &self.id, ctx);
    self.accept_fees(object::id(launch), meme, quote);
}

/// Destroys the external LP vault's live LP-fee cap and binds its creator fees here forever.
public fun lock_external_lp_fees<Meme, Quote>(
    self: &Vault<Meme, Quote>,
    source: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    lp_fee_cap: LpFeeCap<Meme>,
) {
    source.lock_creator_fees(migrators_version, lp_fee_cap, &self.id);
}

/// Destroys the native locked vault's live LP-fee cap and binds its creator fees here forever.
public fun lock_native_lp_fees<Meme, Quote>(
    self: &Vault<Meme, Quote>,
    source: &mut LockedLpVault<Meme, Quote>,
    factory: &Factory,
    lp_fee_cap: LpFeeCap<Meme>,
) {
    source.lock_creator_fees(lp_fee_cap, &self.id, factory);
}

/// Collects accrued creator fees from the existing external LP vault.
/// Venue harvesting remains upstream and may be composed before this call.
/// The Migrators generation is that package's own, checked by that package.
public fun collect_external_lp<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    source: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    ctx: &mut TxContext,
) {
    let (meme, quote) = source.claim_custodied_creator_fees(migrators_version, &self.id, ctx);
    self.accept_fees(object::id(source), meme, quote);
}

/// Collects accrued creator fees from the native migration's locked position.
public fun collect_native_lp<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    source: &mut LockedLpVault<Meme, Quote>,
    factory: &Factory,
    ctx: &mut TxContext,
) {
    let (meme, quote) = source.claim_custodied_creator_fees(&self.id, factory, ctx);
    self.accept_fees(object::id(source), meme, quote);
}

/// Collects this vault's own position fees; an empty claim is a safe no-op.
public fun collect_own_lp<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    pool: &mut Pool<Meme, Quote>,
    factory: &Factory,
    ctx: &mut TxContext,
) {
    factory.assert_current();
    self.assert_pool(pool);
    let position = dynamic_object_field::borrow_mut<_, Position<Meme, Quote>>(
        &mut self.id,
        PositionKey(),
    );
    let quote = pool.claim_fees(factory, position, ctx);
    self.accept_fees(object::id(pool), sui::coin::zero(ctx), quote);
}

/// Contributes either asset without creating a withdrawal right.
public fun contribute<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    meme: Coin<Meme>,
    quote: Coin<Quote>,
) {
    let meme_amount = meme.value();
    let quote_amount = quote.value();
    self.meme.join(meme.into_balance());
    self.quote.join(quote.into_balance());
    if (meme_amount > 0 || quote_amount > 0) {
        event::emit(Contributed {
            vault_id: self.id.to_inner(),
            meme: meme_amount,
            quote: quote_amount,
            meme_total: self.meme.value(),
            quote_total: self.quote.value(),
        });
    };
}

/// The immutable executor bounds both consumed assets, minted shares and execution time.
/// Reserve-ratio execution needs authorized timing to prevent public sandwich deposits.
/// One-sided and sub-share balances stay in custody. No balancing swap is performed.
public fun compound<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    pool: &mut Pool<Meme, Quote>,
    factory: &Factory,
    max_meme: u64,
    max_quote: u64,
    min_shares: u128,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    factory.assert_current();
    self.assert_pool(pool);
    assert!(ctx.sender() == self.executor, EUnauthorizedExecutor);
    assert!(clock.timestamp_ms() <= deadline_ms, EDeadlineExpired);
    self.collect_own_lp(pool, factory, ctx);
    let (meme_used, quote_used, shares) = pool.deposit_amounts(
        self.meme.value(),
        self.quote.value(),
    );
    if (shares == 0) return;
    assert!(meme_used <= max_meme && quote_used <= max_quote, EMaximumInput);
    let position = dynamic_object_field::borrow_mut<_, Position<Meme, Quote>>(
        &mut self.id,
        PositionKey(),
    );
    let (meme_refund, quote_refund) = pool.add_liquidity(
        factory,
        position,
        self.meme.withdraw_all().into_coin(ctx),
        self.quote.withdraw_all().into_coin(ctx),
        min_shares,
        deadline_ms,
        clock,
        ctx,
    );
    self.meme.join(meme_refund.into_balance());
    self.quote.join(quote_refund.into_balance());

    event::emit(Compounded {
        vault_id: self.id.to_inner(),
        meme: meme_used,
        quote: quote_used,
        shares,
        meme_total: self.meme.value(),
        quote_total: self.quote.value(),
    });
}

// === Private Functions ===

fun assert_pool<Meme, Quote>(self: &Vault<Meme, Quote>, pool: &Pool<Meme, Quote>) {
    assert!(self.pool_id == object::id(pool), EWrongPool);
}

fun accept_fees<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    source_id: ID,
    meme: Coin<Meme>,
    quote: Coin<Quote>,
) {
    let meme_amount = meme.value();
    let quote_amount = quote.value();
    self.meme.join(meme.into_balance());
    self.quote.join(quote.into_balance());
    if (meme_amount > 0 || quote_amount > 0) {
        event::emit(FeesCollected {
            vault_id: self.id.to_inner(),
            source_id,
            meme: meme_amount,
            quote: quote_amount,
            meme_total: self.meme.value(),
            quote_total: self.quote.value(),
        });
    };
}

// === Test-Only Functions ===

#[test_only]
public fun snapshot_for_testing<Meme, Quote>(self: &Vault<Meme, Quote>): (ID, ID, u64, u64) {
    let position = dynamic_object_field::borrow<_, Position<Meme, Quote>>(&self.id, PositionKey());
    (self.pool_id, object::id(position), self.meme.value(), self.quote.value())
}

#[test_only]
public fun set_pool_id_for_testing<Meme, Quote>(self: &mut Vault<Meme, Quote>, pool_id: ID) {
    self.pool_id = pool_id;
}

// === Imports ===

use blast_fun::{
    creator_authority::{CurveFeeCap, LpFeeCap},
    launch::Launch,
    package_version::PackageVersion
};

use blast_fun_dex::{migration::LockedLpVault, pool::{Self, Factory, Pool, Position}};

use blast_fun_migrators::{package_version::PackageVersion as MigratorsVersion, vault::LpVault};

use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, dynamic_object_field, event};
