// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Creator-fee custody and pushed-coin intake, authorized funded rounds and permissionless direct
/// payouts.
module blast_fun_distributor::blast_fun_distributor;

// === Constants ===

const VERSION: u64 = 1;

const MAX_LEAVES: u64 = 65_536;

/// Maximum total coin objects one intake call can receive.
const MAX_RECEIVING_COIN_BATCH_SIZE: u64 = 100;

// === Errors ===

#[error(code = 0)]
const EWrongPublisher: vector<u8> = b"Publisher capability belongs to another distributor.";

#[error(code = 1)]
const EWrongSource: vector<u8> = b"Curve must match the enrolled launch.";

#[error(code = 2)]
const EWrongRound: vector<u8> = b"Round number must match the distributor's next round.";

#[error(code = 3)]
const EInvalidInterval: vector<u8> =
    b"Checkpoint interval must be nonempty and contiguous with the previous round.";

#[error(code = 4)]
const EInvalidCommitment: vector<u8> =
    b"Root and manifest digest must each contain exactly 32 bytes.";

#[error(code = 5)]
const EInvalidLeafCount: vector<u8> = b"Round must contain between 1 and 65,536 leaves.";

#[error(code = 6)]
const EEmptyBudget: vector<u8> = b"At least one reward amount must be nonzero.";

#[error(code = 7)]
const EInsufficientFunds: vector<u8> = b"Both reward amounts must fit the available balances.";

#[error(code = 8)]
const EInvalidIndex: vector<u8> = b"Claim index must be less than the committed leaf count.";

#[error(code = 9)]
const EAlreadyClaimed: vector<u8> = b"This allocation has already been paid.";

#[error(code = 10)]
const EInvalidBeneficiary: vector<u8> = b"Beneficiary must not be the zero address.";

#[error(code = 11)]
const EInvalidProof: vector<u8> = b"Proof must match the committed recipient, amounts and domain.";

#[error(code = 12)]
const EWrongVersion: vector<u8> = b"Version object must match this package version.";

#[error(code = 13)]
const EPaused: vector<u8> = b"Holder rewards are paused.";

#[error(code = 14)]
const EUnchangedPause: vector<u8> = b"Pause status must change.";

#[error(code = 15)]
const ENotUpgrade: vector<u8> = b"Version object is already migrated.";

#[error(code = 16)]
const EInvalidReceivingCoinBatch: vector<u8> =
    b"Coin-receiving batches must contain between 1 and 100 total objects.";

// === Public Types ===

/// Proves a call originates in this module when binding or claiming custodied curve fees.
public struct Witness() has drop;

/// Singleton administrator capability created at publication.
public struct AdminCap has key, store {
    id: UID,
}

/// Shared version and pause switch for every distributor and round.
public struct Version has key {
    id: UID,
    version: u64,
    paused: bool,
}

/// Custodies the per-coin creator entitlement and unallocated fee balances.
public struct Distributor<phantom Meme, phantom Quote> has key {
    id: UID,
    launch: ID,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    next_round: u64,
    last_checkpoint: Option<u64>,
}

/// Transferable round-publication authority; ordinary Sui signatures enforce ownership.
public struct PublisherCap has key, store {
    id: UID,
    distributor: ID,
}

/// Independently funded claims that remain available without the publisher or launch.
public struct Round<phantom Meme, phantom Quote> has key {
    id: UID,
    distributor: ID,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    claimed: vector<u256>,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
}

/// Records an administrator's emergency stop or resumption.
public struct PauseChanged has copy, drop {
    paused: bool,
}

/// Native events intentionally use this independent package's direct type namespace.
public struct Enrolled has copy, drop {
    distributor: ID,
    launch: ID,

    curve_fee_cap: ID,
    publisher_cap: ID,
}

/// Collected creator fees and the resulting unallocated balances, keyed by source.
public struct FeesCollected has copy, drop {
    distributor: ID,
    source: ID,
    meme_amount: u64,
    quote_amount: u64,
    meme_total: u64,
    quote_total: u64,
}

/// Coins pushed to this distributor's address and the resulting unallocated balances.
public struct CoinsReceived has copy, drop {
    distributor: ID,
    meme_amount: u64,
    quote_amount: u64,
    meme_total: u64,
    quote_total: u64,
}

/// The authorized allocation commitment, reserved funds and remaining custody.
public struct RoundPublished has copy, drop {
    distributor: ID,
    round: ID,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    meme_unallocated: u64,
    quote_unallocated: u64,
}

/// A completed beneficiary payout and both remaining round balances.
public struct RewardPaid has copy, drop {
    round: ID,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    meme_remaining: u64,
    quote_remaining: u64,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
    transfer::share_object(Version { id: object::new(ctx), version: VERSION, paused: false });
}

// === Public Functions ===

// Admin Functions

/// Stops or resumes enrollment, collection, pushed-coin intake, publication and claims.
public fun set_paused(self: &mut Version, _: &AdminCap, paused: bool) {
    assert!(self.version == VERSION, EWrongVersion);
    assert!(self.paused != paused, EUnchangedPause);

    self.paused = paused;

    event::emit(PauseChanged { paused });
}

/// Moves the shared version to this package version after an upgrade, preserving pause.
public fun migrate(self: &mut Version, _: &AdminCap) {
    assert!(self.version < VERSION, ENotUpgrade);

    self.version = VERSION;
}

/// Destroys the curve-fee cap and binds the launch's creator fees to this distributor forever.
/// No fee capability survives, so no administrator can reassign them; metadata is untouched.
public fun new<Meme, Quote>(
    version: &Version,
    curve_fee_cap: CurveFeeCap<Meme>,
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    ctx: &mut TxContext,
): (Distributor<Meme, Quote>, PublisherCap) {
    version.assert_enabled();

    let curve_fee_cap_id = object::id(&curve_fee_cap);
    let launch_id = object::id(launch);
    launch.lock_creator_fees(package_version, curve_fee_cap, Witness());

    let distributor = Distributor {
        id: object::new(ctx),
        launch: launch_id,
        meme: balance::zero(),
        quote: balance::zero(),
        next_round: 0,
        last_checkpoint: option::none(),
    };
    let publisher = PublisherCap { id: object::new(ctx), distributor: distributor.id.to_inner() };

    event::emit(Enrolled {
        distributor: distributor.id.to_inner(),
        launch: distributor.launch,
        curve_fee_cap: curve_fee_cap_id,
        publisher_cap: publisher.id.to_inner(),
    });

    (distributor, publisher)
}

/// Publishes custody as a shared top-level object.
public fun share<Meme, Quote>(self: Distributor<Meme, Quote>) { transfer::share_object(self); }

/// Anyone can collect; the launch pays only this bound custodian and proceeds stay inside.
public fun collect_curve_fees<Meme, Quote>(
    self: &mut Distributor<Meme, Quote>,
    version: &Version,
    launch: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    ctx: &mut TxContext,
) {
    version.assert_enabled();
    assert!(object::id(launch) == self.launch, EWrongSource);

    let (meme, quote) = launch.claim_custodied_creator_fees(package_version, Witness(), ctx);
    self.accrue(object::id(launch), meme, quote);
}

/// Anyone can receive coins pushed to this distributor's address into its unallocated balances.
///
/// Fee routes and allocation channels pay a destination by transfer, so coins paid to this
/// object's ID wait there, owned by it, until a call names them here, at most 100 per call.
public fun receive_coins<Meme, Quote>(
    self: &mut Distributor<Meme, Quote>,
    version: &Version,
    meme_receivings: vector<Receiving<Coin<Meme>>>,
    quote_receivings: vector<Receiving<Coin<Quote>>>,
) {
    version.assert_enabled();
    let batch_size = meme_receivings.length() + quote_receivings.length();
    assert!(
        batch_size > 0 && batch_size <= MAX_RECEIVING_COIN_BATCH_SIZE,
        EInvalidReceivingCoinBatch,
    );

    let meme = receive_all(&mut self.id, meme_receivings);
    let quote = receive_all(&mut self.id, quote_receivings);
    let meme_amount = meme.value();
    let quote_amount = quote.value();

    let meme_total = self.meme.join(meme);
    let quote_total = self.quote.join(quote);

    event::emit(CoinsReceived {
        distributor: self.id.to_inner(),
        meme_amount,
        quote_amount,
        meme_total,
        quote_total,
    });
}

/// Reserves existing funds for an allocation authorized by this distributor's cap.
public fun publish_round<Meme, Quote>(
    self: &mut Distributor<Meme, Quote>,
    publisher: &PublisherCap,
    version: &Version,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    ctx: &mut TxContext,
): Round<Meme, Quote> {
    version.assert_enabled();
    assert!(publisher.distributor == self.id.to_inner(), EWrongPublisher);
    assert!(number == self.next_round, EWrongRound);
    assert!(
        start_checkpoint < end_checkpoint
        && (self.last_checkpoint.is_none() || *self.last_checkpoint.borrow() == start_checkpoint),
        EInvalidInterval,
    );
    assert!(root.length() == 32 && manifest_digest.length() == 32, EInvalidCommitment);
    assert!(leaf_count > 0 && leaf_count <= MAX_LEAVES, EInvalidLeafCount);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyBudget);
    assert!(
        meme_amount <= self.meme.value() && quote_amount <= self.quote.value(),
        EInsufficientFunds,
    );

    let next_round = number + 1;
    let claimed = vector::tabulate!(leaf_count.div_ceil(256), |_| 0u256);

    let round = Round {
        id: object::new(ctx),
        distributor: self.id.to_inner(),
        number,
        start_checkpoint,
        end_checkpoint,
        root,
        manifest_digest,
        leaf_count,
        claimed,
        meme: self.meme.split(meme_amount),
        quote: self.quote.split(quote_amount),
    };
    self.next_round = next_round;
    self.last_checkpoint = option::some(end_checkpoint);

    event::emit(RoundPublished {
        distributor: self.id.to_inner(),
        round: round.id.to_inner(),
        number,
        start_checkpoint,
        end_checkpoint,
        root,
        manifest_digest,
        leaf_count,
        meme_amount,
        quote_amount,
        meme_unallocated: self.meme.value(),
        quote_unallocated: self.quote.value(),
    });

    round
}

/// Keeps finalized allocations independently claimable.
public fun share_round<Meme, Quote>(self: Round<Meme, Quote>) { transfer::share_object(self); }

/// Anyone may relay a proof; delivery is only to its committed beneficiary.
public fun claim<Meme, Quote>(
    self: &mut Round<Meme, Quote>,
    version: &Version,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    proof: vector<vector<u8>>,
    ctx: &mut TxContext,
) {
    version.assert_enabled();
    assert!(index < self.leaf_count, EInvalidIndex);
    let word = index / 256;
    let bit = 1u256 << ((index % 256) as u8);
    assert!(self.claimed[word] & bit == 0, EAlreadyClaimed);
    assert!(beneficiary != @0x0, EInvalidBeneficiary);
    assert!(meme_amount > 0 || quote_amount > 0, EEmptyBudget);
    assert!(
        meme_amount <= self.meme.value() && quote_amount <= self.quote.value(),
        EInsufficientFunds,
    );

    let leaf = merkle::leaf(
        self.distributor,
        self.number,
        index,
        beneficiary,
        meme_amount,
        quote_amount,
    );
    assert!(merkle::verify(self.root, leaf, index, self.leaf_count, &proof), EInvalidProof);

    *&mut self.claimed[word] = self.claimed[word] | bit;
    if (meme_amount > 0)
        transfer::public_transfer(self.meme.split(meme_amount).into_coin(ctx), beneficiary);
    if (quote_amount > 0)
        transfer::public_transfer(self.quote.split(quote_amount).into_coin(ctx), beneficiary);

    event::emit(RewardPaid {
        round: self.id.to_inner(),
        index,
        beneficiary,
        meme_amount,
        quote_amount,
        meme_remaining: self.meme.value(),
        quote_remaining: self.quote.value(),
    });
}

// === Private Functions ===

/// Rejects retired bytecode before reporting a pause.
fun assert_enabled(self: &Version) {
    assert!(self.version == VERSION, EWrongVersion);
    assert!(!self.paused, EPaused);
}

fun accrue<Meme, Quote>(
    self: &mut Distributor<Meme, Quote>,
    source: ID,
    meme: Coin<Meme>,
    quote: Coin<Quote>,
) {
    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let meme_total = self.meme.join(meme.into_balance());
    let quote_total = self.quote.join(quote.into_balance());

    event::emit(FeesCollected {
        distributor: self.id.to_inner(),
        source,
        meme_amount,
        quote_amount,
        meme_total,
        quote_total,
    });
}

/// Receives each named coin owned by `id` into one balance.
fun receive_all<CoinType>(
    id: &mut UID,
    receivings: vector<Receiving<Coin<CoinType>>>,
): Balance<CoinType> {
    let mut received = balance::zero();
    receivings.do!(|receiving| {
        received.join(transfer::public_receive(id, receiving).into_balance());
    });
    received
}

#[test]
#[expected_failure(abort_code = EWrongPublisher, location = blast_fun_distributor::blast_fun_distributor)]
fun publisher_cap_is_bound_to_one_distributor() {
    let mut ctx = tx_context::dummy();
    let mut distributor = Distributor<sui::sui::SUI, sui::sui::SUI> {
        id: object::new(&mut ctx),
        launch: object::id_from_address(@0x1),
        meme: balance::zero(),
        quote: balance::zero(),
        next_round: 0,
        last_checkpoint: option::none(),
    };
    let publisher = PublisherCap {
        id: object::new(&mut ctx),
        distributor: object::id_from_address(@0x2),
    };
    let version = new_version_for_testing(&mut ctx);
    let round = distributor.publish_round(
        &publisher,
        &version,
        0,
        0,
        1,
        vector[],
        vector[],
        1,
        1,
        0,
        &mut ctx,
    );
    std::unit_test::destroy(version);
    std::unit_test::destroy(round);
    std::unit_test::destroy(publisher);
    std::unit_test::destroy(distributor);
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }

#[test_only]
public fun new_version_for_testing(ctx: &mut TxContext): Version {
    Version { id: object::new(ctx), version: VERSION, paused: false }
}

#[test_only]
public fun new_admin_cap_for_testing(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}

#[test_only]
public fun set_version_for_testing(self: &mut Version, version: u64) { self.version = version; }

#[test_only]
public fun version_for_testing(self: &Version): u64 { self.version }

#[test_only]
public fun paused_for_testing(self: &Version): bool { self.paused }

#[test_only]
public fun balances_for_testing<Meme, Quote>(self: &Distributor<Meme, Quote>): (u64, u64) {
    (self.meme.value(), self.quote.value())
}

#[test_only]
public fun round_balances_for_testing<Meme, Quote>(self: &Round<Meme, Quote>): (u64, u64) {
    (self.meme.value(), self.quote.value())
}

#[test_only]
public fun is_claimed_for_testing<Meme, Quote>(self: &Round<Meme, Quote>, index: u64): bool {
    self.claimed[index / 256] & (1u256 << ((index % 256) as u8)) != 0
}

// === Imports ===

#[test_only]
public use fun round_balances_for_testing as Round.balances_for_testing;

use blast_fun::{
    creator_authority::CurveFeeCap,
    launch::Launch,
    package_version::PackageVersion
};

use blast_fun_distributor::merkle;

use sui::{balance::{Self, Balance}, coin::Coin, event, transfer::Receiving};
