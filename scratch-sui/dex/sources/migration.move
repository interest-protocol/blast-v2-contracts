/// Native migration and sealed custody of its complete issued LP position.
module blast_fun_dex::migration;

use blast_admin::acl::AdminWitness;
use blast_fun::{
    creator_authority::{Self, LpFeeCap},
    fees::{Self, FeeLedger},
    launch::Launch,
    blast_fun_domain::BLAST_FUN_DOMAIN,
    lp_fee_policy::LpFeePolicy,
    package_version::PackageVersion
};
use blast_fun_dex::pool::{Self, Factory, Pool, Position};
use sui::{balance, clock::Clock, coin::Coin, coin_registry::Currency, dynamic_object_field, event};

// === Errors ===

#[error(code = 0)]
const EWrongPool: vector<u8> = b"Native fee collection requires the locked position's pool.";
#[error(code = 1)]
const ELpFeeCapNotLive: vector<u8> = b"LP-fee capability must be the one this vault currently honors.";
#[error(code = 2)]
const EInvalidLpFeeCapRecipient: vector<u8> = b"LP-fee capability recipient must be a nonzero address.";
#[error(code = 3)]
const ELpFeesLocked: vector<u8> = b"Creator LP fees are permanently bound to a custodian.";
#[error(code = 4)]
const ELpFeeCustodianMismatch: vector<u8> = b"Custodian must be the one creator LP fees are bound to.";

// === Public Types ===

/// Sealed launch-selected identity; only this module can redeem its migration payload.
public struct Witness() has drop;

/// Sealed name keeps the position discoverable without a public borrowing path.
public struct PositionKey() has copy, drop, store;

/// Who may claim creator fees: nobody until issue, the live `LpFeeCap`, or terminally
/// the custodian object a cap was destroyed to bind them to.
public enum LpFeeAuthority has copy, drop, store {
    Unassigned,
    Cap(ID),
    Custodian(ID),
}

/// Shared fee claims with deliberately permanent principal custody.
/// Only Quote enters the ledger; the Meme side must remain zero.
public struct LockedLpVault<phantom Meme, phantom Quote> has key {
    id: UID,
    pool_id: ID,
    lp_fee_authority: LpFeeAuthority,
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

/// Records the LP-fee capability the vault honors after an administrative issue.
public struct LpFeeCapIssued has copy, drop {
    vault_id: ID,
    revoked_lp_fee_cap_id: Option<ID>,
    lp_fee_cap_id: ID,
    recipient: address,
}

/// Records an LP-fee capability destroyed to bind creator fees to a custodian forever.
public struct LpFeesLocked has copy, drop {
    vault_id: ID,
    lp_fee_cap_id: ID,
    custodian_id: ID,
}

/// Creator claims take only accrued Quote, never the locked LP principal.
public struct CreatorFeesClaimed has copy, drop { vault_id: ID, quote: u64 }

/// Protocol claims take only accrued Quote, never the locked LP principal.
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
    let mut vault = LockedLpVault {
        id: object::new(ctx),
        pool_id,
        lp_fee_authority: LpFeeAuthority::Unassigned,
        fees: fees::new<Meme, Quote>(),
    };
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

/// Permissionlessly claims position fees into the live LP protocol/creator split.
///
/// The split is the Meme project's pinned LP share, or the migrator-wide LP share
/// when none is pinned; the bonding-curve trade share never applies here.
/// Empty collections are safe and do not attempt a zero accrual in the core ledger.
public fun collect<Meme, Quote>(
    self: &mut LockedLpVault<Meme, Quote>,
    pool: &mut Pool<Meme, Quote>,
    factory: &Factory,
    lp_fee_policy: &LpFeePolicy,
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
    let protocol_share = lp_fee_policy.protocol_fee_share<Meme>();
    let (_, _, protocol_delta, creator_delta) = self
        .fees
        .accrue(balance::zero(), quote.into_balance(), protocol_share);

    event::emit(FeesCollected {
        vault_id: self.id.to_inner(),
        quote: amount,
        protocol_share_bps: protocol_share.value(),
        protocol_delta,
        creator_delta,
    });
}

/// Delivers a fresh LP-fee capability to `recipient` and retires any previous one.
///
/// Migration records no capability, so creator fees accrue until the first issue. Like
/// protocol claims, this uses Launchpad-domain authority because the ledger is Launchpad-owned.
public fun issue_lp_fee_cap<Meme, Quote>(
    self: &mut LockedLpVault<Meme, Quote>,
    witness: &AdminWitness<BLAST_FUN_DOMAIN>,
    factory: &Factory,
    version: &PackageVersion,
    recipient: address,
    ctx: &mut TxContext,
) {
    factory.assert_current();
    assert!(!self.lp_fee_authority.is_custodian(), ELpFeesLocked);
    assert!(recipient != @0x0, EInvalidLpFeeCapRecipient);
    let lp_fee_cap = creator_authority::new_lp_fee_cap<Meme>(version, witness, ctx);
    let lp_fee_cap_id = object::id(&lp_fee_cap);
    let revoked_lp_fee_cap_id = match (self.lp_fee_authority) {
        LpFeeAuthority::Cap(revoked_id) => option::some(revoked_id),
        _ => option::none(),
    };
    self.lp_fee_authority = LpFeeAuthority::Cap(lp_fee_cap_id);
    transfer::public_transfer(lp_fee_cap, recipient);
    event::emit(LpFeeCapIssued {
        vault_id: self.id.to_inner(),
        revoked_lp_fee_cap_id,
        lp_fee_cap_id,
        recipient,
    });
}

/// Returns only creator-owned fees under the vault's live LP-fee capability.
public fun claim_creator_fees<Meme, Quote>(
    self: &mut LockedLpVault<Meme, Quote>,
    lp_fee_cap: &LpFeeCap<Meme>,
    factory: &Factory,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    factory.assert_current();
    self.assert_lp_fee_cap(lp_fee_cap);
    self.claim_ledger_creator_fees(ctx)
}

/// Destroys the live LP-fee capability and binds creator fees to `custodian` permanently.
/// Irreversible: `issue_lp_fee_cap` aborts afterward, and only `custodian`'s module can claim.
public fun lock_creator_fees<Meme, Quote>(
    self: &mut LockedLpVault<Meme, Quote>,
    lp_fee_cap: LpFeeCap<Meme>,
    custodian: &UID,
    factory: &Factory,
) {
    factory.assert_current();
    self.assert_lp_fee_cap(&lp_fee_cap);
    let lp_fee_cap_id = object::id(&lp_fee_cap);
    let custodian_id = custodian.to_inner();
    lp_fee_cap.destroy_lp_fee_cap();
    self.lp_fee_authority = LpFeeAuthority::Custodian(custodian_id);
    event::emit(LpFeesLocked { vault_id: self.id.to_inner(), lp_fee_cap_id, custodian_id });
}

/// Returns only creator-owned fees to the custodian they are permanently bound to.
public fun claim_custodied_creator_fees<Meme, Quote>(
    self: &mut LockedLpVault<Meme, Quote>,
    custodian: &UID,
    factory: &Factory,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    factory.assert_current();
    assert!(
        self.lp_fee_authority == LpFeeAuthority::Custodian(custodian.to_inner()),
        ELpFeeCustodianMismatch,
    );
    self.claim_ledger_creator_fees(ctx)
}

/// Returns only protocol-owned fees under a live Launchpad admin witness.
///
/// This and `issue_lp_fee_cap` are the deliberate Launchpad-domain exceptions in this
/// package. The balances they govern live in a Launchpad-owned `FeeLedger`, so they stay
/// under Launchpad product-fee custody; DEX factory, pool-policy, and package
/// administration all use the independent DEX domain instead.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut LockedLpVault<Meme, Quote>,
    witness: &AdminWitness<BLAST_FUN_DOMAIN>,
    factory: &Factory,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    factory.assert_current();
    let (meme, quote) = self.fees.claim_protocol_fees(witness, ctx);
    event::emit(ProtocolFeesClaimed { vault_id: self.id.to_inner(), quote: quote.value() });
    (meme, quote)
}

/// Aborts unless `lp_fee_cap` is the capability this vault currently honors.
public fun assert_lp_fee_cap<Meme, Quote>(
    self: &LockedLpVault<Meme, Quote>,
    lp_fee_cap: &LpFeeCap<Meme>,
) {
    assert!(self.lp_fee_authority == LpFeeAuthority::Cap(object::id(lp_fee_cap)), ELpFeeCapNotLive);
}

// === Private Functions ===

fun is_custodian(self: &LpFeeAuthority): bool {
    match (self) {
        LpFeeAuthority::Custodian(_) => true,
        _ => false,
    }
}

fun claim_ledger_creator_fees<Meme, Quote>(
    self: &mut LockedLpVault<Meme, Quote>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    let (meme, quote) = self.fees.claim_creator_fees(ctx);
    event::emit(CreatorFeesClaimed { vault_id: self.id.to_inner(), quote: quote.value() });
    (meme, quote)
}

// === Test-Only Functions ===

#[test_only]
public fun issue_lp_fee_cap_for_testing<Meme, Quote>(
    self: &mut LockedLpVault<Meme, Quote>,
    ctx: &mut TxContext,
): LpFeeCap<Meme> {
    let lp_fee_cap = creator_authority::new_lp_fee_cap_for_testing<Meme>(ctx);
    self.lp_fee_authority = LpFeeAuthority::Cap(object::id(&lp_fee_cap));
    lp_fee_cap
}

#[test_only]
public fun lp_fee_cap_id_for_testing<Meme, Quote>(self: &LockedLpVault<Meme, Quote>): Option<ID> {
    match (self.lp_fee_authority) {
        LpFeeAuthority::Cap(lp_fee_cap_id) => option::some(lp_fee_cap_id),
        _ => option::none(),
    }
}

#[test_only]
public fun custodian_id_for_testing<Meme, Quote>(self: &LockedLpVault<Meme, Quote>): Option<ID> {
    match (self.lp_fee_authority) {
        LpFeeAuthority::Custodian(custodian_id) => option::some(custodian_id),
        _ => option::none(),
    }
}

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
