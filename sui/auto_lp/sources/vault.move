/// Irrevocable creator-cap custody, public fee collection and executor-authorized deposits.
module blast_fun_auto_lp::vault;

use blast_fun::{
    acl::AdminWitness,
    creator_authority::CreatorCap,
    launch::Launch,
    package_version::PackageVersion
};
use blast_fun_dex::{migration::LockedLpVault, pool::{Self, Factory, Pool, Position}};
use blast_fun_migrators::vault::LpVault;
use sui::{balance::{Self, Balance}, clock::Clock, coin::Coin, dynamic_object_field, event};

// === Constants ===

const PACKAGE_VERSION: u64 = 1;

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"AutoLP generation must match the active package version.";
#[error(code = 1)]
const EVersionOverflow: vector<u8> = b"AutoLP generation cannot overflow.";
#[error(code = 2)]
const EWrongPool: vector<u8> = b"AutoLP can operate only on its enrolled native pool.";
#[error(code = 3)]
const EDeadlineExpired: vector<u8> = b"AutoLP deposit deadline has expired.";
#[error(code = 4)]
const EInvalidExecutor: vector<u8> = b"AutoLP requires a nonzero immutable execution address.";
#[error(code = 5)]
const EUnauthorizedExecutor: vector<u8> =
    b"Only the enrolled executor may choose AutoLP deposit price and timing.";

#[error(code = 6)]
const EMaximumInput: vector<u8> = b"Actual paired deposit exceeds the executor maximum input.";

// === Public Types ===

/// Publication-only singleton controlling operational generation, with no pause authority.
public struct Control has key { id: UID, version: u64 }

/// Sealed child names preserve discoverability without exposing either authority.
public struct CreatorCapKey() has copy, drop, store;
public struct PositionKey() has copy, drop, store;

/// Holds one creator cap, one native position, and pending assets with no extraction path.
public struct Vault<phantom Meme, phantom Quote> has key {
    id: UID,
    pool_id: ID,
    executor: address,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
}

/// Records the one-way enrollment and both discoverable child IDs.
public struct Enrolled has copy, drop {
    vault_id: ID,
    pool_id: ID,
    creator_cap_id: ID,
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

/// Activates only the exact next compiled generation after an upgrade.
public struct VersionActivated has copy, drop { previous_version: u64, version: u64 }

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new_control(ctx));
}

// === Public Functions ===

/// Permanently consumes creator authority and pins the executor controlling deposit timing.
/// The executor receives no principal, fee, position or creator-cap withdrawal right.
public fun new<Meme, Quote>(
    control: &Control,
    creator_cap: CreatorCap<Meme>,
    pool: &Pool<Meme, Quote>,
    factory: &Factory,
    executor: address,
    ctx: &mut TxContext,
): Vault<Meme, Quote> {
    control.assert_current();
    factory.assert_current();
    assert!(executor != @0x0, EInvalidExecutor);
    let pool_id = object::id(pool);
    let creator_cap_id = object::id(&creator_cap);
    let position = pool::new_position(pool, ctx);
    let position_id = object::id(&position);
    let mut vault = Vault {
        id: object::new(ctx),
        pool_id,
        executor,
        meme: balance::zero(),
        quote: balance::zero(),
    };
    dynamic_object_field::add(&mut vault.id, CreatorCapKey(), creator_cap);
    dynamic_object_field::add(&mut vault.id, PositionKey(), position);

    event::emit(Enrolled {
        vault_id: vault.id.to_inner(),
        pool_id,
        creator_cap_id,
        position_id,
        executor,
    });
    vault
}

/// Shares enrollment for public collection and executor-authorized compounding.
public fun share<Meme, Quote>(self: Vault<Meme, Quote>) { transfer::share_object(self) }

/// Collects only the launch's creator fees; upstream version and nonempty checks apply.
public fun collect_curve<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    control: &Control,
    launch: &mut Launch<Meme, Quote>,
    version: &PackageVersion,
    ctx: &mut TxContext,
) {
    control.assert_current();
    let cap = dynamic_object_field::borrow<_, CreatorCap<Meme>>(&self.id, CreatorCapKey());
    let (meme, quote) = launch.claim_creator_fees(version, cap, ctx);
    self.accept_fees(object::id(launch), meme, quote);
}

/// Collects accrued creator fees from the existing external LP vault.
/// Venue harvesting remains upstream and may be composed before this call.
public fun collect_external_lp<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    control: &Control,
    source: &mut LpVault<Meme, Quote>,
    ctx: &mut TxContext,
) {
    control.assert_current();
    let cap = dynamic_object_field::borrow<_, CreatorCap<Meme>>(&self.id, CreatorCapKey());
    let (meme, quote) = source.claim_creator_fees(cap, ctx);
    self.accept_fees(object::id(source), meme, quote);
}

/// Collects accrued creator fees from the native migration's locked position.
public fun collect_native_lp<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    control: &Control,
    source: &mut LockedLpVault<Meme, Quote>,
    factory: &Factory,
    ctx: &mut TxContext,
) {
    control.assert_current();
    let cap = dynamic_object_field::borrow<_, CreatorCap<Meme>>(&self.id, CreatorCapKey());
    let (meme, quote) = source.claim_creator_fees(cap, factory, ctx);
    self.accept_fees(object::id(source), meme, quote);
}

/// Collects this vault's own position fees; an empty claim is a safe no-op.
public fun collect_own_lp<Meme, Quote>(
    self: &mut Vault<Meme, Quote>,
    control: &Control,
    pool: &mut Pool<Meme, Quote>,
    factory: &Factory,
    ctx: &mut TxContext,
) {
    control.assert_current();
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
    control: &Control,
    meme: Coin<Meme>,
    quote: Coin<Quote>,
) {
    control.assert_current();
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
    control: &Control,
    pool: &mut Pool<Meme, Quote>,
    factory: &Factory,
    max_meme: u64,
    max_quote: u64,
    min_shares: u128,
    deadline_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    control.assert_current();
    factory.assert_current();
    self.assert_pool(pool);
    assert!(ctx.sender() == self.executor, EUnauthorizedExecutor);
    assert!(clock.timestamp_ms() <= deadline_ms, EDeadlineExpired);
    self.collect_own_lp(control, pool, factory, ctx);
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

/// Live launchpad administration activates exactly the next generation this code implements.
public fun activate(self: &mut Control, _: &AdminWitness) {
    let previous_version = self.version;
    let version = previous_version.checked_add(1).destroy_or!(abort EVersionOverflow);
    assert!(version == PACKAGE_VERSION, EWrongVersion);
    self.version = version;
    event::emit(VersionActivated { previous_version, version });
}

// === Private Functions ===

fun assert_current(self: &Control) { assert!(self.version == PACKAGE_VERSION, EWrongVersion) }

fun new_control(ctx: &mut TxContext): Control {
    Control { id: object::new(ctx), version: PACKAGE_VERSION }
}

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
public fun new_control_for_testing(ctx: &mut TxContext): Control { new_control(ctx) }

#[test_only]
public fun set_version_for_testing(self: &mut Control, version: u64) { self.version = version }

#[test_only]
public fun snapshot_for_testing<Meme, Quote>(self: &Vault<Meme, Quote>): (ID, ID, u64, u64) {
    let cap = dynamic_object_field::borrow<_, CreatorCap<Meme>>(&self.id, CreatorCapKey());
    let position = dynamic_object_field::borrow<_, Position<Meme, Quote>>(&self.id, PositionKey());
    (object::id(cap), object::id(position), self.meme.value(), self.quote.value())
}

#[test_only]
public fun set_pool_id_for_testing<Meme, Quote>(self: &mut Vault<Meme, Quote>, pool_id: ID) {
    self.pool_id = pool_id;
}
