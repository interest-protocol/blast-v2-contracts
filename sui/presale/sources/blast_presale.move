// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Standalone overflow presales with capped commitments, proportional fills,
/// migration-gated claims, and full refunds when a sale does not migrate.
module blast_presale::blast_presale;

// === Public Types ===

/// Who may commit and the maximum Quote each wallet may commit.
///
/// `Open` gives every wallet the same cap. `Allowlisted` commits one cap per
/// wallet in a positional Blake2b-256 Merkle tree, supporting equal, tiered,
/// or fully custom caps.
public enum EligibilityPolicy has copy, drop, store {
    Open { wallet_cap: u64, max_participants: u64 },
    Allowlisted { root: vector<u8>, leaf_count: u64 },
}

/// The presale's one-way lifecycle.
public enum Lifecycle has copy, drop, store {
    Pending,
    Open,
    Funded,
    Migrated,
    Cancelled,
}

/// One creator's authority over one presale.
public struct PresaleCap has key, store {
    id: UID,
    presale_id: ID,
}

/// Dynamic-field name for one wallet's undelivered commitment.
public struct CommitmentKey(address) has copy, drop, store;

/// Type-derived name for the discoverable TreasuryCap held by one presale.
public struct TreasuryCapKey() has copy, drop, store;

/// One wallet's Quote commitment and immutable cap.
public struct Commitment has copy, drop, store {
    quote: u64,
    wallet_cap: u64,
}

/// One standalone presale and its complete custody until migration or refund.
///
/// The minted presale and LP allocations, the SaleToken TreasuryCap, and every
/// commitment are escrowed. A funded migration releases exactly `raise_target`
/// Quote and the LP allocation to the configured venue adapter, then opens
/// proportional token and overflow-refund claims. If the raise is missed, or LP
/// is not migrated by its deadline, every commitment is refunded.
public struct Presale<phantom SaleToken, phantom Quote> has key {
    id: UID,
    presale_cap_id: ID,
    lifecycle: Lifecycle,
    duration_ms: u64,
    liquidity_window_ms: u64,
    end_ms: u64,
    liquidity_deadline_ms: u64,
    raise_target: u64,
    eligibility: EligibilityPolicy,
    migration_witness: TypeName,
    tick_spacing: u32,
    fee_rate: u64,
    creator_fee_bps: u64,
    rewards_fee_bps: u64,
    total_commitments: u64,
    remaining_commitments: u64,
    participants: u64,
    quote: Balance<Quote>,
    token_allocation: u64,
    sale_tokens: Balance<SaleToken>,
    liquidity_tokens: Balance<SaleToken>,
}

// === Public Functions ===

/// Creates one equal-cap policy with a bounded number of distinct wallets.
public fun open_eligibility(wallet_cap: u64, max_participants: u64): EligibilityPolicy {
    assert!(
        wallet_cap > 0
            && max_participants > 0
            && max_participants <= MAX_PARTICIPANTS,
        EInvalidEligibilityPolicy,
    );

    EligibilityPolicy::Open { wallet_cap, max_participants }
}

/// Creates one allowlist policy whose leaves are `(index, wallet, wallet_cap)`.
public fun allowlisted_eligibility(root: vector<u8>, leaf_count: u64): EligibilityPolicy {
    assert!(
        root.length() == DIGEST_LENGTH
            && leaf_count > 0
            && leaf_count <= MAX_PARTICIPANTS,
        EInvalidEligibilityPolicy,
    );

    EligibilityPolicy::Allowlisted { root, leaf_count }
}

/// Shares a newly created presale and starts its fixed public window now.
public fun share<SaleToken, Quote>(mut self: Presale<SaleToken, Quote>, clock: &Clock) {
    assert!(self.lifecycle == Lifecycle::Pending, EInvalidLifecycle);
    let start_ms = clock.timestamp_ms();
    let end_ms = start_ms.checked_add(self.duration_ms);
    assert!(end_ms.is_some(), EInvalidWindow);
    let end_ms = end_ms.destroy_some();
    let liquidity_deadline_ms = end_ms.checked_add(self.liquidity_window_ms);
    assert!(liquidity_deadline_ms.is_some(), EInvalidWindow);
    let liquidity_deadline_ms = liquidity_deadline_ms.destroy_some();

    self.lifecycle = Lifecycle::Open;
    self.end_ms = end_ms;
    self.liquidity_deadline_ms = liquidity_deadline_ms;

    event::emit(PresaleOpened<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        start_ms,
        end_ms,
        liquidity_deadline_ms,
    });
    transfer::share_object(self);
}

/// Consumes and locks the supplied `Coin<Quote>` in this presale under an
/// equal-cap, open eligibility policy.
public fun commit_open<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    quote_in: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.assert_open(clock);
    let quote = quote_in.value();
    assert!(quote > 0, EZeroCommitment);
    let (wallet_cap, max_participants) = open_limits(self.eligibility);

    self.record_commitment(quote_in, wallet_cap, max_participants, ctx);
}

/// Consumes and locks the supplied `Coin<Quote>` in this presale after
/// verifying the sender's Merkle-committed wallet cap.
public fun commit_allowlisted<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    quote_in: Coin<Quote>,
    index: u64,
    wallet_cap: u64,
    proof: vector<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.assert_open(clock);
    assert!(quote_in.value() > 0, EZeroCommitment);
    let max_participants = verify_allowlisted(
        self.eligibility,
        index,
        ctx.sender(),
        wallet_cap,
        &proof,
    );

    self.record_commitment(quote_in, wallet_cap, max_participants, ctx);
}

/// Fixes the fill after the commitment window. Underfunded sales, and sales
/// first settled after their LP deadline, become fully refundable. Anyone may settle.
public fun settle<SaleToken, Quote>(self: &mut Presale<SaleToken, Quote>, clock: &Clock) {
    assert!(self.lifecycle == Lifecycle::Open, EInvalidLifecycle);
    let now_ms = clock.timestamp_ms();
    assert!(now_ms >= self.end_ms, EPresaleNotEnded);

    if (
        self.total_commitments < self.raise_target
            || now_ms >= self.liquidity_deadline_ms
    ) {
        self.cancel();
    } else {
        self.lifecycle = Lifecycle::Funded;

        event::emit(PresaleFunded<SaleToken, Quote> {
            presale_id: self.id.to_inner(),
            commitments: self.total_commitments,
            accepted_quote: self.raise_target,
            refundable_quote: self.total_commitments - self.raise_target,
            token_allocation: self.token_allocation,
        });
    };
}

/// Cancels a funded presale whose LP deadline passed, preserving all Quote for refunds.
public fun cancel_unlaunched<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    clock: &Clock,
) {
    assert!(self.lifecycle == Lifecycle::Funded, EInvalidLifecycle);
    assert!(
        clock.timestamp_ms() >= self.liquidity_deadline_ms,
        ELiquidityDeadlineNotReached,
    );

    self.cancel();
}

/// Delivers one participant's pro-rata tokens and overflow Quote after migration,
/// or its full Quote after cancellation. Anyone may relay; the final claim
/// receives the bounded integer-rounding remainder.
public fun claim<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    participant: address,
    ctx: &mut TxContext,
) {
    assert!(
        self.lifecycle == Lifecycle::Migrated || self.lifecycle == Lifecycle::Cancelled,
        EInvalidLifecycle,
    );
    let key = CommitmentKey(participant);
    assert!(self.id.has_dynamic_field(key), ENoCommitment);

    let Commitment { quote: commitment, wallet_cap: _ } = self
        .id
        .remove_dynamic_field<_, Commitment>(key);
    let last = self.remaining_commitments == commitment;
    let tokens = if (self.lifecycle == Lifecycle::Migrated) {
        if (last) {
            self.sale_tokens.value()
        } else {
            self.token_allocation.mul_div(commitment, self.total_commitments)
        }
    } else 0;
    let refund_total = if (self.lifecycle == Lifecycle::Cancelled) {
        self.total_commitments
    } else {
        self.total_commitments - self.raise_target
    };
    let quote_refund = if (last) {
        self.quote.value()
    } else {
        refund_total.mul_div(commitment, self.total_commitments)
    };

    self.remaining_commitments = self.remaining_commitments - commitment;
    if (tokens > 0) {
        transfer::public_transfer(self.sale_tokens.split(tokens).into_coin(ctx), participant);
    };
    if (quote_refund > 0) {
        transfer::public_transfer(self.quote.split(quote_refund).into_coin(ctx), participant);
    };

    event::emit(Claimed<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        participant,
        commitment,
        tokens,
        quote_refund,
        remaining_commitments: self.remaining_commitments,
    });
}

/// Returns the TreasuryCap to the creator authority after successful migration.
public fun claim_treasury_cap<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    cap: &PresaleCap,
): TreasuryCap<SaleToken> {
    assert!(self.lifecycle == Lifecycle::Migrated, EInvalidLifecycle);
    self.assert_cap(cap);
    let treasury_cap = self.remove_treasury_cap();

    event::emit(TreasuryCapClaimed<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        treasury_cap_id: object::id(&treasury_cap),
    });

    treasury_cap
}

/// Recovers the TreasuryCap and every minted token allocation after
/// cancellation. Quote is never returned here and remains reserved for refunds.
public fun reclaim_cancelled_assets<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    cap: &PresaleCap,
    ctx: &mut TxContext,
): (TreasuryCap<SaleToken>, Coin<SaleToken>, Coin<SaleToken>) {
    assert!(self.lifecycle == Lifecycle::Cancelled, EInvalidLifecycle);
    self.assert_cap(cap);
    assert!(
        self.sale_tokens.value() > 0
            || self.liquidity_tokens.value() > 0,
        ENothingToReclaim,
    );

    let treasury_cap = self.remove_treasury_cap();
    let sale_tokens = self.sale_tokens.withdraw_all().into_coin(ctx);
    let liquidity_tokens = self.liquidity_tokens.withdraw_all().into_coin(ctx);

    event::emit(CancelledAssetsReclaimed<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        treasury_cap_id: object::id(&treasury_cap),
        sale_tokens: sale_tokens.value(),
        liquidity_tokens: liquidity_tokens.value(),
    });

    (treasury_cap, sale_tokens, liquidity_tokens)
}

/// Destroys the creator capability after a cancelled sale has returned every creator asset.
public fun destroy_cap<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, cap: PresaleCap) {
    self.assert_cap(&cap);
    assert!(
        self.lifecycle == Lifecycle::Cancelled
            && self.sale_tokens.value() == 0
            && self.liquidity_tokens.value() == 0,
        EInvalidLifecycle,
    );

    let PresaleCap { id, presale_id: _ } = cap;
    id.delete();
}

// === Package Functions ===

/// Requires a zero-supply SaleToken TreasuryCap, derives the presale and LP
/// allocations from the configured token supply and BPS, and mints only those
/// allocations into escrow.
public(package) fun new<SaleToken, Quote, MigrationWitness: drop>(
    mut treasury_cap: TreasuryCap<SaleToken>,
    token_supply: u64,
    token_allocation_bps: u64,
    liquidity_token_allocation_bps: u64,
    raise_target: u64,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
    _: MigrationWitness,
    tick_spacing: u32,
    fee_rate: u64,
    creator_fee_bps: u64,
    rewards_fee_bps: u64,
    ctx: &mut TxContext,
): (Presale<SaleToken, Quote>, PresaleCap) {
    assert!(
        type_name::with_original_ids<SaleToken>() != type_name::with_original_ids<Quote>(),
        EInvalidAssetPair,
    );
    assert!(treasury_cap.total_supply() == 0, EInitialSupplyNotZero);
    assert!(raise_target > 0, EInvalidRaiseTarget);
    assert!(
        token_supply > 0
            && token_allocation_bps > 0
            && token_allocation_bps <= BASIS_POINTS
            && liquidity_token_allocation_bps > 0
            && liquidity_token_allocation_bps <= BASIS_POINTS - token_allocation_bps,
        EInvalidTokenAllocation,
    );
    assert!(creator_fee_bps <= BASIS_POINTS, EInvalidFeeSplit);
    assert!(rewards_fee_bps == BASIS_POINTS - creator_fee_bps, EInvalidFeeSplit);
    assert!(duration_ms > 0 && liquidity_window_ms > 0, EInvalidWindow);

    let token_allocation = token_supply.mul_div(token_allocation_bps, BASIS_POINTS);
    let liquidity_token_allocation = token_supply.mul_div(
        liquidity_token_allocation_bps,
        BASIS_POINTS,
    );
    assert!(token_allocation > 0 && liquidity_token_allocation > 0, EInvalidTokenAllocation);
    let sale_tokens = treasury_cap.mint_balance(token_allocation);
    let liquidity_tokens = treasury_cap.mint_balance(liquidity_token_allocation);
    let treasury_cap_id = object::id(&treasury_cap);
    let id = object::new(ctx);
    let presale_id = id.to_inner();
    let cap = PresaleCap { id: object::new(ctx), presale_id };
    let presale_cap_id = cap.id.to_inner();
    let migration_witness = type_name::with_original_ids<MigrationWitness>();
    let mut presale = Presale {
        id,
        presale_cap_id,
        lifecycle: Lifecycle::Pending,
        duration_ms,
        liquidity_window_ms,
        end_ms: 0,
        liquidity_deadline_ms: 0,
        raise_target,
        eligibility,
        migration_witness,
        tick_spacing,
        fee_rate,
        creator_fee_bps,
        rewards_fee_bps,
        total_commitments: 0,
        remaining_commitments: 0,
        participants: 0,
        quote: balance::zero(),
        token_allocation,
        sale_tokens,
        liquidity_tokens,
    };
    presale.id.add_dynamic_object_field(TreasuryCapKey(), treasury_cap);

    event::emit(PresaleCreated<SaleToken, Quote> {
        presale_id,
        presale_cap_id,
        treasury_cap_id,
        token_supply,
        token_allocation_bps,
        liquidity_token_allocation_bps,
        raise_target,
        duration_ms,
        liquidity_window_ms,
        eligibility,
        migration_witness,
        tick_spacing,
        fee_rate,
        creator_fee_bps,
        rewards_fee_bps,
    });

    (presale, cap)
}

/// Releases the exact raise and LP-token allocation only to the configured
/// migrator. Anyone may call that migrator; its pool creation remains atomic
/// with this state transition.
public(package) fun migrate<SaleToken, Quote, MigrationWitness: drop>(
    self: &mut Presale<SaleToken, Quote>,
    _: MigrationWitness,
    clock: &Clock,
): (Balance<SaleToken>, Balance<Quote>) {
    assert!(self.lifecycle == Lifecycle::Funded, EInvalidLifecycle);
    assert!(clock.timestamp_ms() < self.liquidity_deadline_ms, ELiquidityDeadlinePassed);
    assert!(
        self.migration_witness == type_name::with_original_ids<MigrationWitness>(),
        EWrongMigrationWitness,
    );

    let quote = self.quote.split(self.raise_target);
    let liquidity_tokens = self.liquidity_tokens.withdraw_all();
    self.lifecycle = Lifecycle::Migrated;

    event::emit(PresaleMigrated<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        migration_witness: self.migration_witness,
        quote: self.raise_target,
        liquidity_tokens: liquidity_tokens.value(),
    });

    (liquidity_tokens, quote)
}

public(package) fun assert_cap<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    cap: &PresaleCap,
) {
    assert!(object::id(cap) == self.presale_cap_id, EWrongPresaleCap);
}

public(package) fun migration_config<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
): (ID, ID, u32, u64, u64, u64) {
    (
        self.id.to_inner(),
        self.presale_cap_id,
        self.tick_spacing,
        self.fee_rate,
        self.creator_fee_bps,
        self.rewards_fee_bps,
    )
}

// === Private Functions ===

fun assert_open<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, clock: &Clock) {
    assert!(self.lifecycle == Lifecycle::Open, EInvalidLifecycle);
    assert!(clock.timestamp_ms() < self.end_ms, EPresaleEnded);
}

fun remove_treasury_cap<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
): TreasuryCap<SaleToken> {
    self.id.remove_dynamic_object_field(TreasuryCapKey())
}

fun record_commitment<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    quote_in: Coin<Quote>,
    wallet_cap: u64,
    max_participants: u64,
    ctx: &TxContext,
) {
    let quote = quote_in.value();
    let key = CommitmentKey(ctx.sender());
    let exists = self.id.has_dynamic_field(key);
    let current = if (exists) {
        *dynamic_field::borrow<_, Commitment>(&self.id, key)
    } else {
        Commitment { quote: 0, wallet_cap }
    };
    assert!(current.wallet_cap == wallet_cap, EInvalidEligibilityProof);
    let wallet_commitment = current.quote.checked_add(quote);
    assert!(wallet_commitment.is_some(), EWalletCapExceeded);
    let wallet_commitment = wallet_commitment.destroy_some();
    assert!(wallet_commitment <= wallet_cap, EWalletCapExceeded);
    if (!exists) {
        assert!(self.participants < max_participants, EParticipantCapacityReached);
    };
    let total_commitments = self.total_commitments.checked_add(quote);
    assert!(total_commitments.is_some(), ETotalCommitmentOverflow);
    let total_commitments = total_commitments.destroy_some();

    if (exists) {
        self.id.dynamic_field_mut<_, Commitment>(key).quote = wallet_commitment;
    } else {
        self.id.add_dynamic_field(key, Commitment { quote: wallet_commitment, wallet_cap });
        self.participants = self.participants + 1;
    };
    self.total_commitments = total_commitments;
    self.remaining_commitments = total_commitments;
    self.quote.join(quote_in.into_balance());

    event::emit(Committed<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        quote,
        wallet_commitment,
        total_commitments,
        participants: self.participants,
    });
}

fun open_limits(policy: EligibilityPolicy): (u64, u64) {
    match (policy) {
        EligibilityPolicy::Open { wallet_cap, max_participants } => {
            (wallet_cap, max_participants)
        },
        EligibilityPolicy::Allowlisted { .. } => abort EWrongEligibilityPolicy,
    }
}

fun verify_allowlisted(
    policy: EligibilityPolicy,
    index: u64,
    wallet: address,
    wallet_cap: u64,
    proof: &vector<vector<u8>>,
): u64 {
    match (policy) {
        EligibilityPolicy::Open { .. } => abort EWrongEligibilityPolicy,
        EligibilityPolicy::Allowlisted { root, leaf_count } => {
            assert!(index < leaf_count && wallet_cap > 0, EInvalidEligibilityProof);
            let digest = allowlist_leaf(index, wallet, wallet_cap);
            assert!(merkle_tree::verify(root, digest, index, leaf_count, proof), EInvalidEligibilityProof);

            leaf_count
        },
    }
}

fun allowlist_leaf(index: u64, wallet: address, wallet_cap: u64): vector<u8> {
    let mut bytes = b"\x00blast-presale-v1";
    bytes.append(bcs::to_bytes(&index));
    bytes.append(bcs::to_bytes(&wallet));
    bytes.append(bcs::to_bytes(&wallet_cap));
    hash::blake2b256(&bytes)
}

fun cancel<SaleToken, Quote>(self: &mut Presale<SaleToken, Quote>) {
    self.lifecycle = Lifecycle::Cancelled;

    event::emit(PresaleCancelled<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        commitments: self.total_commitments,
        refundable_quote: self.quote.value(),
    });
}

// === Test-Only Functions ===

#[test_only]
public fun cap_for_testing(presale_id: ID, ctx: &mut TxContext): PresaleCap {
    PresaleCap { id: object::new(ctx), presale_id }
}

#[test_only]
public fun allowlist_leaf_for_testing(
    index: u64,
    wallet: address,
    wallet_cap: u64,
): vector<u8> {
    allowlist_leaf(index, wallet, wallet_cap)
}

#[test_only]
public fun merkle_node_for_testing(left: vector<u8>, right: vector<u8>): vector<u8> {
    merkle_tree::node(left, right)
}

#[test_only]
public fun is_funded_for_testing<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): bool {
    self.lifecycle == Lifecycle::Funded
}

#[test_only]
public fun is_migrated_for_testing<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): bool {
    self.lifecycle == Lifecycle::Migrated
}

#[test_only]
public fun is_cancelled_for_testing<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): bool {
    self.lifecycle == Lifecycle::Cancelled
}

#[test_only]
public fun custody_for_testing<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
): (u64, u64, u64, u64, u64, u64) {
    (
        self.total_commitments,
        self.remaining_commitments,
        self.participants,
        self.quote.value(),
        self.sale_tokens.value(),
        self.liquidity_tokens.value(),
    )
}

#[test_only]
public fun treasury_cap_fields_for_testing<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
): (ID, u64) {
    let treasury_cap: &TreasuryCap<SaleToken> = dynamic_object_field::borrow(
        &self.id,
        TreasuryCapKey(),
    );

    (object::id(treasury_cap), treasury_cap.total_supply())
}

#[test_only]
public fun commitment_for_testing<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    participant: address,
): u64 {
    let key = CommitmentKey(participant);

    if (self.id.has_dynamic_field(key)) {
        dynamic_field::borrow<_, Commitment>(&self.id, key).quote
    } else 0
}

#[test_only]
public fun created_fields<SaleToken, Quote>(
    event: &PresaleCreated<SaleToken, Quote>,
): (ID, ID, ID, u64, u64, u64, u64, u64, u64, EligibilityPolicy) {
    (
        event.presale_id,
        event.presale_cap_id,
        event.treasury_cap_id,
        event.token_supply,
        event.token_allocation_bps,
        event.liquidity_token_allocation_bps,
        event.raise_target,
        event.duration_ms,
        event.liquidity_window_ms,
        event.eligibility,
    )
}

#[test_only]
public fun created_migration_fields<SaleToken, Quote>(
    event: &PresaleCreated<SaleToken, Quote>,
): (TypeName, u32, u64, u64, u64) {
    (
        event.migration_witness,
        event.tick_spacing,
        event.fee_rate,
        event.creator_fee_bps,
        event.rewards_fee_bps,
    )
}

#[test_only]
public fun opened_fields<SaleToken, Quote>(
    event: &PresaleOpened<SaleToken, Quote>,
): (ID, u64, u64, u64) {
    (event.presale_id, event.start_ms, event.end_ms, event.liquidity_deadline_ms)
}

#[test_only]
public fun committed_fields<SaleToken, Quote>(
    event: &Committed<SaleToken, Quote>,
): (ID, u64, u64, u64, u64) {
    (
        event.presale_id,
        event.quote,
        event.wallet_commitment,
        event.total_commitments,
        event.participants,
    )
}

#[test_only]
public fun funded_fields<SaleToken, Quote>(
    event: &PresaleFunded<SaleToken, Quote>,
): (ID, u64, u64, u64, u64) {
    (
        event.presale_id,
        event.commitments,
        event.accepted_quote,
        event.refundable_quote,
        event.token_allocation,
    )
}

#[test_only]
public fun cancelled_fields<SaleToken, Quote>(
    event: &PresaleCancelled<SaleToken, Quote>,
): (ID, u64, u64) {
    (event.presale_id, event.commitments, event.refundable_quote)
}

#[test_only]
public fun migrated_fields<SaleToken, Quote>(
    event: &PresaleMigrated<SaleToken, Quote>,
): (ID, TypeName, u64, u64) {
    (
        event.presale_id,
        event.migration_witness,
        event.quote,
        event.liquidity_tokens,
    )
}

#[test_only]
public fun claim_fields<SaleToken, Quote>(
    event: &Claimed<SaleToken, Quote>,
): (ID, address, u64, u64, u64, u64) {
    (
        event.presale_id,
        event.participant,
        event.commitment,
        event.tokens,
        event.quote_refund,
        event.remaining_commitments,
    )
}

#[test_only]
public fun reclaimed_fields<SaleToken, Quote>(
    event: &CancelledAssetsReclaimed<SaleToken, Quote>,
): (ID, ID, u64, u64) {
    (
        event.presale_id,
        event.treasury_cap_id,
        event.sale_tokens,
        event.liquidity_tokens,
    )
}

// === Events ===

/// A presale was created with fully funded token allocations.
public struct PresaleCreated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    presale_cap_id: ID,
    treasury_cap_id: ID,
    token_supply: u64,
    token_allocation_bps: u64,
    liquidity_token_allocation_bps: u64,
    raise_target: u64,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
    migration_witness: TypeName,
    tick_spacing: u32,
    fee_rate: u64,
    creator_fee_bps: u64,
    rewards_fee_bps: u64,
}

/// A presale's fixed commitment and liquidity windows began.
public struct PresaleOpened<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    start_ms: u64,
    end_ms: u64,
    liquidity_deadline_ms: u64,
}

/// Quote joined a presale from the transaction sender.
public struct Committed<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    quote: u64,
    wallet_commitment: u64,
    total_commitments: u64,
    participants: u64,
}

/// A funded presale closed with these fixed claim totals.
public struct PresaleFunded<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    commitments: u64,
    accepted_quote: u64,
    refundable_quote: u64,
    token_allocation: u64,
}

/// A presale became fully refundable without releasing Quote.
public struct PresaleCancelled<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    commitments: u64,
    refundable_quote: u64,
}

/// The exact raise and LP-token allocation entered the configured migrator.
public struct PresaleMigrated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    migration_witness: TypeName,
    quote: u64,
    liquidity_tokens: u64,
}

/// The creator authority recovered the migrated token's mint capability.
public struct TreasuryCapClaimed<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    treasury_cap_id: ID,
}

/// `participant` received its token allocation and Quote refund.
public struct Claimed<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    participant: address,
    commitment: u64,
    tokens: u64,
    quote_refund: u64,
    remaining_commitments: u64,
}

/// The creator recovered the TreasuryCap and all token allocations after cancellation.
public struct CancelledAssetsReclaimed<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    treasury_cap_id: ID,
    sale_tokens: u64,
    liquidity_tokens: u64,
}

// === Constants ===

/// Technical bound on the dynamic commitment records one presale may hold.
const MAX_PARTICIPANTS: u64 = 65_536;

const BASIS_POINTS: u64 = 10_000;

const DIGEST_LENGTH: u64 = 32;

// === Errors ===

#[error(code = 0)]
const EInvalidAssetPair: vector<u8> = b"The sale token and Quote type must differ.";

#[error(code = 1)]
const EInvalidRaiseTarget: vector<u8> = b"The raise target must be positive.";

#[error(code = 2)]
const EInvalidTokenAllocation: vector<u8> = b"Token supply and allocation BPS must produce positive allocations totaling at most 10,000 BPS.";

#[error(code = 3)]
const EInvalidWindow: vector<u8> = b"Commitment and liquidity windows must be positive and fit in u64 milliseconds.";

#[error(code = 4)]
const EInvalidEligibilityPolicy: vector<u8> = b"The eligibility policy has an invalid cap, participant bound, root, or leaf count.";

#[error(code = 5)]
const EInvalidLifecycle: vector<u8> = b"The presale is not in the lifecycle required by this operation.";

#[error(code = 6)]
const EPresaleEnded: vector<u8> = b"The presale commitment window has ended.";

#[error(code = 7)]
const EPresaleNotEnded: vector<u8> = b"The presale commitment window has not ended.";

#[error(code = 8)]
const EZeroCommitment: vector<u8> = b"A presale commitment must be positive.";

#[error(code = 9)]
const EWalletCapExceeded: vector<u8> = b"The wallet commitment exceeds its eligibility cap.";

#[error(code = 10)]
const EParticipantCapacityReached: vector<u8> = b"The presale already contains its maximum number of participants.";

#[error(code = 11)]
const EInvalidEligibilityProof: vector<u8> = b"The submitted wallet, cap, index, or proof does not match the allowlist.";

#[error(code = 12)]
const EWrongEligibilityPolicy: vector<u8> = b"The commit function does not match the presale eligibility policy.";

#[error(code = 13)]
const ETotalCommitmentOverflow: vector<u8> = b"Adding the commitment would overflow the presale total.";

#[error(code = 14)]
const ENoCommitment: vector<u8> = b"The wallet has no undelivered presale commitment.";

#[error(code = 15)]
const EWrongPresaleCap: vector<u8> = b"The creator capability belongs to a different presale.";

#[error(code = 16)]
const ELiquidityDeadlinePassed: vector<u8> = b"The deadline to migrate liquidity has passed.";

#[error(code = 17)]
const ELiquidityDeadlineNotReached: vector<u8> = b"The deadline to cancel an unlaunched funded presale has not arrived.";

#[error(code = 18)]
const ENothingToReclaim: vector<u8> = b"The cancelled presale has no token allocations left to reclaim.";

#[error(code = 19)]
const EInitialSupplyNotZero: vector<u8> = b"The supplied SaleToken TreasuryCap must have zero total supply.";

#[error(code = 20)]
const EInvalidFeeSplit: vector<u8> = b"Creator and holder-reward fee shares must total 10,000 BPS.";

#[error(code = 21)]
const EWrongMigrationWitness: vector<u8> = b"The migrator does not match the venue fixed at presale creation.";

// === Imports ===

use blast_presale::merkle_tree;

use std::{bcs, type_name::{Self, TypeName}};

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    dynamic_field,
    dynamic_object_field,
    event,
    hash,
};

use fun dynamic_field::add as UID.add_dynamic_field;
use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;
use fun dynamic_field::exists as UID.has_dynamic_field;
use fun dynamic_field::remove as UID.remove_dynamic_field;
use fun dynamic_object_field::add as UID.add_dynamic_object_field;
use fun dynamic_object_field::remove as UID.remove_dynamic_object_field;
