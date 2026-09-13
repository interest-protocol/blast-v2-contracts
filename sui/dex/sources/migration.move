/// Native migration and sealed custody of its complete issued LP position.
module blast_fun_dex::migration;

use blast_admin::acl::AdminWitness;
use blast_fun::{
    creator_authority::CreatorCap,
    fees::{Self, FeeLedger},
    launch::Launch,
    launchpad_domain::LAUNCHPAD_DOMAIN,
    package_version::PackageVersion,
    runtime_config::RuntimeConfig
};
use blast_fun_dex::pool::{Self, Factory, Pool, Position};
use sui::{balance, clock::Clock, coin::Coin, coin_registry::Currency, dynamic_object_field, event};

// === Errors ===

#[error(code = 0)]
const EWrongPool: vector<u8> = b"Native fee collection requires the locked position's pool.";

// === Public Types ===

/// Sealed launch-selected identity; only this module can redeem its migration payload.
public struct Witness() has drop;

/// Sealed name keeps the position discoverable without a public borrowing path.
public struct PositionKey() has copy, drop, store;

/// Shared fee claims with deliberately permanent principal custody.
/// Only Quote enters the ledger; the Meme side must remain zero.
public struct LockedLpVault<phantom Meme, phantom Quote> has key {
    id: UID,
    pool_id: ID,
    fees: FeeLedger<Meme, Quote>,
}

/// Binds the terminal launch to its canonical native pool and locked position.
public struct Migrated has copy, drop {
    launch_id: ID,
    pool_id: ID,
    vault_id: ID,
    position_id: ID,
    meme: u64,
    quote: u64,
}

/// Records the live split applied only to newly collected Quote fees.
public struct FeesCollected has copy, drop {
    vault_id: ID,
    quote: u64,
    protocol_share_bps: u64,
    protocol_delta: u64,
    creator_delta: u64,
}

/// Creator claims drain only accrued Quote, never the locked LP principal.
public struct CreatorFeesClaimed has copy, drop { vault_id: ID, quote: u64 }

/// Protocol claims drain only accrued Quote, never the locked LP principal.
public struct ProtocolFeesClaimed has copy, drop { vault_id: ID, quote: u64 }

// === Public Functions ===

/// Atomically completes the launch, creates its fresh zero-burn pool, and locks all issued shares.
public fun migrate<Meme, Quote>(
    launch: &mut Launch<Meme, Quote>,
    version: &PackageVersion,
    factory: &mut Factory,
    currency: &mut Currency<Meme>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    factory.assert_available<Meme, Quote>();
    let launch_id = object::id(launch);
    let payload = launch.migrate<_, _, Witness>(version, currency, ctx);
    let (meme, quote) = payload.redeem_migration(Witness());
    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let (pool, position) = pool::create_from_balances(factory, meme, quote, 0, clock, ctx);
    let pool_id = object::id(&pool);
    let position_id = object::id(&position);
    let mut vault = LockedLpVault { id: object::new(ctx), pool_id, fees: fees::new<Meme, Quote>() };
    let vault_id = vault.id.to_inner();
    dynamic_object_field::add(&mut vault.id, PositionKey(), position);
    pool.share();
    transfer::share_object(vault);

    event::emit(Migrated {
        launch_id,
        pool_id,
        vault_id,
        position_id,
        meme: meme_amount,
        quote: quote_amount,
    });
}

/// Permissionlessly claims position fees into the existing live protocol/creator split.
/// Empty collections are safe and do not attempt a zero accrual in the core ledger.
public fun collect<Meme, Quote>(
    self: &mut LockedLpVault<Meme, Quote>,
    pool: &mut Pool<Meme, Quote>,
    factory: &Factory,
    runtime: &RuntimeConfig,
    ctx: &mut TxContext,
) {
    factory.assert_current();
    assert!(self.pool_id == object::id(pool), EWrongPool);
    let position = dynamic_object_field::borrow_mut<_, Position<Meme, Quote>>(
        &mut self.id,
        PositionKey(),
    );
    let quote = pool.claim_fees(factory, position, ctx);
    let amount = quote.value();
    if (amount == 0) {
        quote.destroy_zero();
        return
    };
    let (_, _, protocol_delta, creator_delta) = self
        .fees
        .accrue_from_runtime(balance::zero(), quote.into_balance(), runtime);

    event::emit(FeesCollected {
        vault_id: self.id.to_inner(),
        quote: amount,
        protocol_share_bps: runtime.protocol_fee_share_bps(),
        protocol_delta,
        creator_delta,
    });
}

/// Returns only creator-owned fees as composable coins.
public fun claim_creator_fees<Meme, Quote>(
    self: &mut LockedLpVault<Meme, Quote>,
    creator_cap: &CreatorCap<Meme>,
    factory: &Factory,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    factory.assert_current();
    let (meme, quote) = self.fees.claim_creator_fees(creator_cap, ctx);
    event::emit(CreatorFeesClaimed { vault_id: self.id.to_inner(), quote: quote.value() });
    (meme, quote)
}

/// Returns only protocol-owned fees under a live Launchpad admin witness.
///
/// This is the single deliberate Launchpad-domain exception in this package. The
/// balances drained here live in a Launchpad-owned `FeeLedger`, so they stay
/// under Launchpad product-fee custody; DEX factory, pool-policy, and package
/// administration all use the independent DEX domain instead.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut LockedLpVault<Meme, Quote>,
    witness: &AdminWitness<LAUNCHPAD_DOMAIN>,
    factory: &Factory,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    factory.assert_current();
    let (meme, quote) = self.fees.claim_protocol_fees(witness, ctx);
    event::emit(ProtocolFeesClaimed { vault_id: self.id.to_inner(), quote: quote.value() });
    (meme, quote)
}

// === Test-Only Functions ===

#[test_only]
public fun snapshot_for_testing<Meme, Quote>(
    self: &LockedLpVault<Meme, Quote>,
): (ID, ID, u64, u64) {
    let position = dynamic_object_field::borrow<_, Position<Meme, Quote>>(&self.id, PositionKey());
    let (_, _, protocol, creator) = self.fees.totals_for_testing();
    (self.pool_id, object::id(position), protocol, creator)
}

#[test_only]
public fun shares_for_testing<Meme, Quote>(self: &LockedLpVault<Meme, Quote>): u128 {
    dynamic_object_field::borrow<_, Position<Meme, Quote>>(
        &self.id,
        PositionKey(),
    ).shares_for_testing()
}
