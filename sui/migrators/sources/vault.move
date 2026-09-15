/// Shared fee accounting and sealed dynamic-object custody for migration positions.
module blast_fun_migrators::vault;

use blast_admin::acl::AdminWitness;
use blast_fun::{
    creator_authority::CurveFeeCap,
    fees::{Self, FeeLedger},
    launch::Launch,
    launchpad_domain::LAUNCHPAD_DOMAIN,
};
use blast_fun_migrators::{
    events,
    lp_fee_authority::{LpFeeAuthority, LpFeeCap},
    lp_fee_policy::LpFeePolicy,
    package_version::PackageVersion as MigratorsVersion,
};
use sui::{
    balance::{Self, Balance},
    coin::Coin,
    dynamic_object_field,
    transfer::Receiving,
};

use fun dynamic_object_field::add as UID.add_dynamic_object_field;
use fun dynamic_object_field::borrow_mut as UID.dynamic_object_field_mut;
use fun dynamic_object_field::exists as UID.has_dynamic_object_field;

// === Constants ===

/// Maximum total child coin objects one receiving call can consume.
const MAX_RECEIVING_COIN_BATCH_SIZE: u64 = 100;

// === Errors ===

#[error(code = 0)]
const EWrongVenue: vector<u8> = b"Venue witness must match the vault's attached position marker.";
#[error(code = 1)]
const ENothingClaimable: vector<u8> = b"No protocol fees or migration residuals are available to claim.";
#[error(code = 2)]
const EVaultAlreadyInitialized: vector<u8> = b"Prepared vault must not already contain a pool.";
#[error(code = 3)]
const EInvalidReceivingCoinBatch: vector<u8> = b"Coin-receiving batches must contain between 1 and 100 total objects.";
// Code 4 retired: LP-fee capability liveness moved to `lp_fee_authority`.
#[error(code = 5)]
const EInvalidLpFeeCapRecipient: vector<u8> = b"LP-fee capability recipient must be a nonzero address.";
// Codes 6 and 7 retired: LP-fee lock and custodian checks moved to `lp_fee_authority`.

// === Public Structs ===

/// A sealed field name that binds one venue position type to one vault.
public struct PositionKey<phantom Venue>() has copy, drop, store;

/// Shared per-launch custody for one position, protocol residuals, and LP fees.
///
/// Migration embeds a pending `LpFeeAuthority` born from the launch payload. Creator LP fees
/// accrue until the launch's curve-fee cap holder claims the `LpFeeCap`, a launch custodian
/// binds them, or a creator administrator reissues the cap.
public struct LpVault<phantom Meme, phantom Quote> has key {
    id: UID,
    pool_id: ID,
    lp_fee_authority: LpFeeAuthority<Meme>,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    fee_ledger: FeeLedger<Meme, Quote>,
}

// === Public Functions ===

/// Mints the migration-born LP-fee capability once for the launch's live curve-fee cap holder.
public fun claim_lp_fee_cap<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    launch: &Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
    ctx: &mut TxContext,
): LpFeeCap<Meme> {
    migrators_version.assert_current();

    let lp_fee_cap = self.lp_fee_authority.claim(launch, curve_fee_cap, ctx);

    events::lp_fee_cap_claimed<Meme, Quote>(
        self.id.to_inner(),
        object::id(&lp_fee_cap),
        ctx.sender(),
    );

    lp_fee_cap
}

/// Delivers a replacement LP-fee capability to `recipient` and retires any previous one.
///
/// Community takeovers use this path under creator-admin authority. It aborts once fees
/// are permanently bound to a custodian, and while pending fees are reserved for the launch's
/// creator-fee custodian.
public fun issue_lp_fee_cap<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    launch: &Launch<Meme, Quote>,
    admin_witness: &AdminWitness<LAUNCHPAD_DOMAIN>,
    recipient: address,
    ctx: &mut TxContext,
) {
    migrators_version.assert_current();
    self.lp_fee_authority.assert_not_locked();
    assert!(recipient != @0x0, EInvalidLpFeeCapRecipient);

    let (revoked_lp_fee_cap_id, lp_fee_cap) =
        self.lp_fee_authority.reissue(launch, admin_witness, ctx);
    let lp_fee_cap_id = object::id(&lp_fee_cap);
    transfer::public_transfer(lp_fee_cap, recipient);

    events::lp_fee_cap_issued<Meme, Quote>(
        self.id.to_inner(),
        revoked_lp_fee_cap_id,
        lp_fee_cap_id,
        recipient,
    );
}

/// Binds pending creator LP fees forever to the launch's creator-fee custodian.
///
/// No capability is ever minted. Claims require `custodian`'s `&UID`, so custodians must never
/// expose it.
public fun lock_pending_creator_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    launch: &Launch<Meme, Quote>,
    custodian: &UID,
) {
    migrators_version.assert_current();

    let custodian_id = self.lp_fee_authority.lock_pending(launch, custodian);

    events::lp_fees_locked<Meme, Quote>(self.id.to_inner(), option::none(), custodian_id);
}

/// Destroys the live LP-fee capability and binds creator LP fees to `custodian` permanently.
///
/// Irreversible: `issue_lp_fee_cap` aborts afterward. Claims require `custodian`'s `&UID`, so
/// lock only to objects whose module never exposes it.
public fun lock_creator_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    lp_fee_cap: LpFeeCap<Meme>,
    custodian: &UID,
) {
    migrators_version.assert_current();

    let (lp_fee_cap_id, custodian_id) = self.lp_fee_authority.lock(lp_fee_cap, custodian);

    events::lp_fees_locked<Meme, Quote>(
        self.id.to_inner(),
        option::some(lp_fee_cap_id),
        custodian_id,
    );
}

/// Drains only creator-owned LP fees under the vault's live LP-fee capability.
public fun claim_creator_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    lp_fee_cap: &LpFeeCap<Meme>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    migrators_version.assert_current();
    self.lp_fee_authority.assert_cap(lp_fee_cap);
    self.drain_creator_fees(ctx)
}

/// Drains creator LP fees for the custodian they are permanently bound to.
public fun claim_custodied_creator_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    custodian: &UID,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    migrators_version.assert_current();
    self.lp_fee_authority.assert_custodian(custodian);
    self.drain_creator_fees(ctx)
}

/// Drains protocol-owned migration residuals and LP fees under a live admin witness.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    admin_witness: &AdminWitness<LAUNCHPAD_DOMAIN>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    migrators_version.assert_current();
    let has_protocol_fees = self.fee_ledger.has_protocol_fees();
    let has_residuals =
        self.protocol_meme_residual.value() > 0
            || self.protocol_quote_residual.value() > 0;
    assert!(
        has_protocol_fees || has_residuals,
        ENothingClaimable,
    );

    let (mut meme, mut quote) = if (has_protocol_fees) {
        let (meme_fees, quote_fees) =
            self.fee_ledger.claim_protocol_fees(admin_witness, ctx);
        (meme_fees.into_balance(), quote_fees.into_balance())
    } else {
        (balance::zero(), balance::zero())
    };
    meme.join(self.protocol_meme_residual.withdraw_all());
    quote.join(self.protocol_quote_residual.withdraw_all());
    let meme = meme.into_coin(ctx);
    let quote = quote.into_coin(ctx);
    let meme_amount = meme.value();
    let quote_amount = quote.value();

    events::protocol_fees_claimed<Meme, Quote>(
        self.id.to_inner(),
        ctx.sender(),
        meme_amount,
        quote_amount,
    );

    (meme, quote)
}

/// Aborts unless `lp_fee_cap` is the capability this vault currently honors.
public fun assert_lp_fee_cap<Meme, Quote>(
    self: &LpVault<Meme, Quote>,
    lp_fee_cap: &LpFeeCap<Meme>,
) {
    self.lp_fee_authority.assert_cap(lp_fee_cap);
}

// === Package Functions ===

/// Creates and shares one vault with its only venue position as a child object.
public(package) fun new<Meme, Quote, Venue: drop, Position: key + store>(
    _venue: Venue,
    lp_fee_authority: LpFeeAuthority<Meme>,
    pool_id: ID,
    position: Position,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
): ID {
    let pending_vault = prepare(
        lp_fee_authority,
        protocol_meme_residual,
        protocol_quote_residual,
        ctx,
    );
    pending_vault.finish(_venue, pool_id, position)
}

/// Creates unshared vault state whose address can be bound into an external position.
public(package) fun prepare<Meme, Quote>(
    lp_fee_authority: LpFeeAuthority<Meme>,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
): LpVault<Meme, Quote> {
    LpVault {
        id: object::new(ctx),
        pool_id: object::id_from_address(@0x0),
        lp_fee_authority,
        protocol_meme_residual,
        protocol_quote_residual,
        fee_ledger: fees::new(),
    }
}

/// Returns the final vault ID without sharing its construction state.
public(package) fun pending_id<Meme, Quote>(
    self: &LpVault<Meme, Quote>,
): ID {
    self.id.to_inner()
}

/// Attaches the complete venue position and shares a prepared vault atomically.
public(package) fun finish<Meme, Quote, Venue: drop, Position: key + store>(
    mut self: LpVault<Meme, Quote>,
    _venue: Venue,
    pool_id: ID,
    position: Position,
): ID {
    assert!(
        self.pool_id == object::id_from_address(@0x0),
        EVaultAlreadyInitialized,
    );
    let position_id = object::id(&position);
    self.pool_id = pool_id;
    let vault_id = self.id.to_inner();
    self.id.add_dynamic_object_field(PositionKey<Venue>(), position);
    transfer::share_object(self);
    events::vault_created<Meme, Quote, Venue>(
        vault_id,
        pool_id,
        position_id,
    );
    vault_id
}

/// Receives and merges at most 100 total Meme and Quote coins owned by this vault.
public(package) fun receive_coins<Meme, Quote, Venue>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
    meme_receivings: vector<Receiving<Coin<Meme>>>,
    quote_receivings: vector<Receiving<Coin<Quote>>>,
): (Balance<Meme>, Balance<Quote>) {
    assert_valid_receiving_coin_batch_size(
        meme_receivings.length(),
        quote_receivings.length(),
    );
    assert!(
        self.id.has_dynamic_object_field(PositionKey<Venue>()),
        EWrongVenue,
    );

    let meme = receive_coin_batch(&mut self.id, meme_receivings);
    let quote = receive_coin_batch(&mut self.id, quote_receivings);
    (meme, quote)
}

/// Mutably borrows the venue position without providing a removal path.
public(package) fun position_mut<
    Meme,
    Quote,
    Venue,
    Position: key + store,
>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
): &mut Position {
    assert!(
        self.id.has_dynamic_object_field(PositionKey<Venue>()),
        EWrongVenue,
    );

    self.id.dynamic_object_field_mut(PositionKey<Venue>())
}

/// Returns the venue pool associated with the locked position.
public(package) fun pool_id<Meme, Quote>(
    self: &LpVault<Meme, Quote>,
): ID {
    self.pool_id
}

/// Accrues one completed venue collection and emits its replay snapshot.
public(package) fun accrue_fees<Meme, Quote, Venue>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
    position_id: ID,
    meme_fee: Balance<Meme>,
    quote_fee: Balance<Quote>,
    principal_liquidity: u128,
    lp_fee_policy: &LpFeePolicy,
    ctx: &TxContext,
) {
    assert!(
        self.id.has_dynamic_object_field(PositionKey<Venue>()),
        EWrongVenue,
    );

    let gross_meme_fee = meme_fee.value();
    let gross_quote_fee = quote_fee.value();
    let protocol_fee_share = lp_fee_policy.protocol_fee_share<Meme>();
    let (
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
    ) = self.fee_ledger.accrue(
        meme_fee,
        quote_fee,
        protocol_fee_share,
    );
    let protocol_fee_share_bps = protocol_fee_share.value();

    events::lp_fees_collected<Meme, Quote, Venue>(
        self.id.to_inner(),
        self.pool_id,
        position_id,
        ctx.sender(),
        gross_meme_fee,
        gross_quote_fee,
        protocol_fee_share_bps,
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
        principal_liquidity,
    );
}

// === Private Functions ===

fun drain_creator_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    let (meme, quote) = self.fee_ledger.claim_creator_fees(ctx);
    let meme_amount = meme.value();
    let quote_amount = quote.value();

    events::creator_fees_claimed<Meme, Quote>(
        self.id.to_inner(),
        ctx.sender(),
        meme_amount,
        quote_amount,
    );

    (meme, quote)
}

fun receive_coin_batch<CoinType>(
    uid: &mut UID,
    mut receivings: vector<Receiving<Coin<CoinType>>>,
): Balance<CoinType> {
    let mut received = balance::zero();
    while (!receivings.is_empty()) {
        received.join(
            transfer::public_receive(
                uid,
                receivings.pop_back(),
            ).into_balance(),
        );
    };
    received
}

fun assert_valid_receiving_coin_batch_size(meme_size: u64, quote_size: u64) {
    assert!(
        meme_size <= MAX_RECEIVING_COIN_BATCH_SIZE
            && quote_size <= MAX_RECEIVING_COIN_BATCH_SIZE - meme_size
            && meme_size + quote_size > 0,
        EInvalidReceivingCoinBatch,
    );
}

// === Test-Only Functions ===

#[test_only]
/// Records and returns a fresh live LP-fee capability without administrative authority.
public fun issue_lp_fee_cap_for_testing<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    ctx: &mut TxContext,
): LpFeeCap<Meme> {
    self.lp_fee_authority.issue_for_testing(ctx)
}

#[test_only]
public fun lp_fee_cap_id_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): Option<ID> {
    self.lp_fee_authority.cap_id_for_testing()
}

#[test_only]
public fun is_lp_fee_authority_pending_for_testing<Meme, Quote>(
    self: &LpVault<Meme, Quote>,
): bool {
    self.lp_fee_authority.is_pending_for_testing()
}

#[test_only]
public fun custodian_id_for_testing<Meme, Quote>(self: &LpVault<Meme, Quote>): Option<ID> {
    self.lp_fee_authority.custodian_id_for_testing()
}

#[test_only]
public fun assert_valid_receiving_coin_batch_size_for_testing(
    meme_size: u64,
    quote_size: u64,
) {
    assert_valid_receiving_coin_batch_size(meme_size, quote_size);
}

/// Creates a funded ledger fixture without introducing a production custody entrypoint.
#[test_only]
public fun funded_for_testing<Meme, Quote>(
    pool_id: ID,
    meme_fee: Balance<Meme>,
    quote_fee: Balance<Quote>,
    lp_fee_policy: &LpFeePolicy,
    ctx: &mut TxContext,
): LpVault<Meme, Quote> {
    let mut vault = prepare(
        blast_fun_migrators::lp_fee_authority::new_for_testing(),
        balance::zero(),
        balance::zero(),
        ctx,
    );
    vault.pool_id = pool_id;
    vault.fee_ledger.accrue(
        meme_fee,
        quote_fee,
        lp_fee_policy.protocol_fee_share<Meme>(),
    );
    vault
}
