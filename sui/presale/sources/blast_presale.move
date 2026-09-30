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

/// One immutable share of the fixed token supply, paid only after migration.
public struct RecipientAllocation has copy, drop, store {
    recipient: address,
    bps: u64,
    amount: u64,
}

/// One immutable share of every collected LP fee, paid to `recipient` as fees
/// are collected. The creator is configured as an ordinary recipient.
public struct FeeRecipient has copy, drop, store {
    recipient: address,
    bps: u64,
}

/// Dynamic-field name for one wallet's undelivered commitment.
public struct CommitmentKey(address) has copy, drop, store;

/// One wallet's Quote commitment and immutable cap.
public struct Commitment has copy, drop, store {
    quote: u64,
    wallet_cap: u64,
}

/// One standalone presale and its complete custody until migration or refund.
///
/// The complete fixed or burn-only token supply is apportioned at creation.
/// Presale, LP, and additional recipient allocations stay escrowed until a
/// funded migration atomically releases them. If the raise is missed, every
/// commitment is refunded. Anyone may migrate a funded sale until it is
/// cancelled; once LP is still unmigrated at its deadline, anyone may cancel it
/// so every commitment becomes refundable.
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
    fee_recipients: vector<FeeRecipient>,
    rewards_fee_bps: u64,
    total_commitments: u64,
    remaining_commitments: u64,
    participants: u64,
    quote: Balance<Quote>,
    token_allocation: u64,
    sale_tokens: Balance<SaleToken>,
    liquidity_tokens: Balance<SaleToken>,
    recipient_allocations: vector<RecipientAllocation>,
    recipient_tokens: Balance<SaleToken>,
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

/// Configures one additional recipient's share of the fixed token supply.
public fun recipient_allocation(recipient: address, bps: u64): RecipientAllocation {
    assert!(recipient != @0x0 && bps > 0 && bps <= BASIS_POINTS, EInvalidTokenAllocation);

    RecipientAllocation { recipient, bps, amount: 0 }
}

/// Configures one address's share of every collected LP fee.
public fun fee_recipient(recipient: address, bps: u64): FeeRecipient {
    assert!(recipient != @0x0 && bps > 0 && bps <= BASIS_POINTS, EInvalidFeeSplit);

    FeeRecipient { recipient, bps }
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

/// Fixes the fill after the commitment window. Underfunded sales become fully
/// refundable. Anyone may settle.
public fun settle<SaleToken, Quote>(self: &mut Presale<SaleToken, Quote>, clock: &Clock) {
    assert!(self.lifecycle == Lifecycle::Open, EInvalidLifecycle);
    assert!(clock.timestamp_ms() >= self.end_ms, EPresaleNotEnded);

    if (self.total_commitments < self.raise_target) {
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

/// Cancels a funded presale still unmigrated at its LP deadline, preserving all
/// Quote for refunds. Anyone may cancel.
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

/// Destroys the creator capability after cancellation. All minted SaleToken
/// allocations remain permanently locked in the cancelled presale.
public fun destroy_cap<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, cap: PresaleCap) {
    self.assert_cap(&cap);
    assert!(self.lifecycle == Lifecycle::Cancelled, EInvalidLifecycle);

    let PresaleCap { id, presale_id: _ } = cap;
    id.delete();
}

// === Package Functions ===

/// Mints and apportions the complete token supply, then irreversibly makes it
/// fixed or burn-only before returning the presale.
public(package) fun new<SaleToken, Quote, MigrationWitness: drop>(
    mut treasury_cap: TreasuryCap<SaleToken>,
    currency: &mut Currency<SaleToken>,
    token_supply: u64,
    token_allocation_bps: u64,
    liquidity_token_allocation_bps: u64,
    mut recipient_allocations: vector<RecipientAllocation>,
    burnable: bool,
    raise_target: u64,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
    _: MigrationWitness,
    tick_spacing: u32,
    fee_rate: u64,
    fee_recipients: vector<FeeRecipient>,
    rewards_fee_bps: u64,
    ctx: &mut TxContext,
): (Presale<SaleToken, Quote>, PresaleCap) {
    assert!(
        type_name::with_original_ids<SaleToken>() != type_name::with_original_ids<Quote>(),
        EInvalidAssetPair,
    );
    // `Currency<SaleToken>` and `TreasuryCap<SaleToken>` are each unique per type, and making the
    // supply fixed or burn-only consumes the cap, so holding it proves the supply is still unknown.
    assert!(treasury_cap.total_supply() == 0, EInitialSupplyNotZero);
    assert!(raise_target > 0, EInvalidRaiseTarget);
    assert!(
        token_supply > 0
            && token_allocation_bps > 0
            && token_allocation_bps <= BASIS_POINTS
            && liquidity_token_allocation_bps > 0
            && liquidity_token_allocation_bps <= BASIS_POINTS
            && recipient_allocations.length() <= MAX_RECIPIENTS,
        EInvalidTokenAllocation,
    );
    recipient_allocations.do_ref!(|allocation| assert!(
        allocation.recipient != @0x0
            && allocation.bps > 0
            && allocation.bps <= BASIS_POINTS
            // ponytail: O(n²) duplicate validation is bounded by MAX_RECIPIENTS.
            && recipient_allocations.count!(|other| other.recipient == allocation.recipient) == 1,
        EInvalidTokenAllocation,
    ));
    assert!(
        recipient_allocations.fold!(
            token_allocation_bps + liquidity_token_allocation_bps,
            |sum, allocation| sum + allocation.bps,
        ) == BASIS_POINTS,
        EInvalidTokenAllocation,
    );
    assert!(
        fee_recipients.length() <= MAX_FEE_RECIPIENTS && rewards_fee_bps <= BASIS_POINTS,
        EInvalidFeeSplit,
    );
    fee_recipients.do_ref!(|fee_recipient| assert!(
        fee_recipient.recipient != @0x0
            && fee_recipient.bps > 0
            && fee_recipient.bps <= BASIS_POINTS
            // ponytail: O(n²) duplicate validation is bounded by MAX_FEE_RECIPIENTS.
            && fee_recipients.count!(|other| other.recipient == fee_recipient.recipient) == 1,
        EInvalidFeeSplit,
    ));
    assert!(
        fee_recipients.fold!(rewards_fee_bps, |sum, fee_recipient| sum + fee_recipient.bps)
            == BASIS_POINTS,
        EInvalidFeeSplit,
    );
    assert!(duration_ms > 0 && liquidity_window_ms > 0, EInvalidWindow);

    let mut shares = vector[token_allocation_bps, liquidity_token_allocation_bps];
    recipient_allocations.do_ref!(|allocation| shares.push_back(allocation.bps));
    let amounts = apportion(shares, token_supply);
    let token_allocation = amounts[0];
    let liquidity_token_allocation = amounts[1];
    assert!(token_allocation > 0 && liquidity_token_allocation > 0, EInvalidTokenAllocation);
    let mut tokens = treasury_cap.mint_balance(token_supply);
    let sale_tokens = tokens.split(token_allocation);
    let liquidity_tokens = tokens.split(liquidity_token_allocation);
    let mut i = 0;
    recipient_allocations.do_mut!(|allocation| {
        allocation.amount = amounts[i + 2];
        assert!(allocation.amount > 0, EInvalidTokenAllocation);
        i = i + 1;
    });
    let recipient_tokens = tokens;
    let treasury_cap_id = object::id(&treasury_cap);
    if (burnable) currency.make_supply_burn_only(treasury_cap)
    else currency.make_supply_fixed(treasury_cap);
    let id = object::new(ctx);
    let presale_id = id.to_inner();
    let cap = PresaleCap { id: object::new(ctx), presale_id };
    let presale_cap_id = cap.id.to_inner();
    let migration_witness = type_name::with_original_ids<MigrationWitness>();
    let recipient_count = recipient_allocations.length();
    let fee_recipient_addresses = fee_recipient_addresses(&fee_recipients);
    let fee_recipient_bps = fee_recipient_bps(&fee_recipients);
    let presale = Presale {
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
        fee_recipients,
        rewards_fee_bps,
        total_commitments: 0,
        remaining_commitments: 0,
        participants: 0,
        quote: balance::zero(),
        token_allocation,
        sale_tokens,
        liquidity_tokens,
        recipient_allocations,
        recipient_tokens,
    };

    event::emit(PresaleCreated<SaleToken, Quote> {
        presale_id,
        presale_cap_id,
        treasury_cap_id,
        token_supply,
        token_allocation_bps,
        liquidity_token_allocation_bps,
        recipient_count,
        burnable,
        raise_target,
        duration_ms,
        liquidity_window_ms,
        eligibility,
        migration_witness,
        tick_spacing,
        fee_rate,
        fee_recipients: fee_recipient_addresses,
        fee_recipient_bps,
        rewards_fee_bps,
    });

    (presale, cap)
}

/// Releases the exact raise and LP-token allocation only to the configured
/// migrator. Anyone may call that migrator at any time until the sale is
/// cancelled; its pool creation remains atomic with this state transition.
public(package) fun migrate<SaleToken, Quote, MigrationWitness: drop>(
    self: &mut Presale<SaleToken, Quote>,
    _: MigrationWitness,
    ctx: &mut TxContext,
): (Balance<SaleToken>, Balance<Quote>) {
    assert!(self.lifecycle == Lifecycle::Funded, EInvalidLifecycle);
    assert!(
        self.migration_witness == type_name::with_original_ids<MigrationWitness>(),
        EWrongMigrationWitness,
    );

    let quote = self.quote.split(self.raise_target);
    let liquidity_tokens = self.liquidity_tokens.withdraw_all();
    let recipient_tokens = self.recipient_tokens.value();
    let mut i = 0;
    while (i < self.recipient_allocations.length()) {
        let RecipientAllocation { recipient, bps, amount } = self.recipient_allocations[i];
        transfer::public_transfer(self.recipient_tokens.split(amount).into_coin(ctx), recipient);
        event::emit(RecipientAllocated<SaleToken, Quote> {
            presale_id: self.id.to_inner(),
            recipient,
            bps,
            tokens: amount,
        });
        i = i + 1;
    };
    assert!(self.recipient_tokens.value() == 0, EInvalidTokenAllocation);
    self.lifecycle = Lifecycle::Migrated;

    event::emit(PresaleMigrated<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        migration_witness: self.migration_witness,
        quote: self.raise_target,
        liquidity_tokens: liquidity_tokens.value(),
        recipient_tokens,
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
): (ID, ID, u32, u64, vector<FeeRecipient>, u64) {
    (
        self.id.to_inner(),
        self.presale_cap_id,
        self.tick_spacing,
        self.fee_rate,
        self.fee_recipients,
        self.rewards_fee_bps,
    )
}

/// Splits one fee amount into each recipient's share followed by the holder-reward
/// share, assigning every atomic unit exactly once. Remainder units go to the largest
/// fractional remainders; equal remainders favor the earlier share, so fee recipients
/// win ties over the holder-reward share and earlier recipients over later ones.
public(package) fun apportion_fee(
    fee_recipients: &vector<FeeRecipient>,
    rewards_fee_bps: u64,
    amount: u64,
): vector<u64> {
    let mut shares = fee_recipients.map_ref!(|fee_recipient| fee_recipient.bps);
    shares.push_back(rewards_fee_bps);

    apportion(shares, amount)
}

public(package) fun fee_recipient_addresses(
    fee_recipients: &vector<FeeRecipient>,
): vector<address> {
    fee_recipients.map_ref!(|fee_recipient| fee_recipient.recipient)
}

public(package) fun fee_recipient_bps(fee_recipients: &vector<FeeRecipient>): vector<u64> {
    fee_recipients.map_ref!(|fee_recipient| fee_recipient.bps)
}

// === Private Functions ===

fun assert_open<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, clock: &Clock) {
    assert!(self.lifecycle == Lifecycle::Open, EInvalidLifecycle);
    assert!(clock.timestamp_ms() < self.end_ms, EPresaleEnded);
}

/// Largest-remainder apportionment. Shares must sum to 10,000 BPS.
fun apportion(shares: vector<u64>, total: u64): vector<u64> {
    let denominator = BASIS_POINTS as u128;
    let products = shares.map!(|share| (total as u128) * (share as u128));
    let mut amounts = products.map_ref!(|product| (*product / denominator) as u64);
    let mut order = vector::tabulate!(products.length(), |i| i);
    order.insertion_sort_by!(|a, b| {
        let (remainder_a, remainder_b) = (
            products[*a] % denominator,
            products[*b] % denominator,
        );
        remainder_a > remainder_b || (remainder_a == remainder_b && *a <= *b)
    });
    let leftover = total - amounts.fold!(0, |sum, amount| sum + amount);
    leftover.do!(|i| *&mut amounts[order[i]] = amounts[order[i]] + 1);

    amounts
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
): (u64, u64, u64, u64, u64, u64, u64) {
    (
        self.total_commitments,
        self.remaining_commitments,
        self.participants,
        self.quote.value(),
        self.sale_tokens.value(),
        self.liquidity_tokens.value(),
        self.recipient_tokens.value(),
    )
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
): (TypeName, u32, u64, vector<address>, vector<u64>, u64) {
    (
        event.migration_witness,
        event.tick_spacing,
        event.fee_rate,
        event.fee_recipients,
        event.fee_recipient_bps,
        event.rewards_fee_bps,
    )
}

#[test_only]
public fun created_supply_fields<SaleToken, Quote>(
    event: &PresaleCreated<SaleToken, Quote>,
): (u64, bool) {
    (event.recipient_count, event.burnable)
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
): (ID, TypeName, u64, u64, u64) {
    (
        event.presale_id,
        event.migration_witness,
        event.quote,
        event.liquidity_tokens,
        event.recipient_tokens,
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

// === Events ===

/// A presale was created with fully funded token allocations.
public struct PresaleCreated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    presale_cap_id: ID,
    treasury_cap_id: ID,
    token_supply: u64,
    token_allocation_bps: u64,
    liquidity_token_allocation_bps: u64,
    recipient_count: u64,
    burnable: bool,
    raise_target: u64,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
    migration_witness: TypeName,
    tick_spacing: u32,
    fee_rate: u64,
    fee_recipients: vector<address>,
    fee_recipient_bps: vector<u64>,
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
    recipient_tokens: u64,
}

/// One configured recipient received its immutable token allocation.
public struct RecipientAllocated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    recipient: address,
    bps: u64,
    tokens: u64,
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

// === Constants ===

/// Technical bound on the dynamic commitment records one presale may hold.
const MAX_PARTICIPANTS: u64 = 65_536;

const MAX_RECIPIENTS: u64 = 64;

/// Bounds the transfers one fee collection makes.
const MAX_FEE_RECIPIENTS: u64 = 16;

const BASIS_POINTS: u64 = 10_000;

const DIGEST_LENGTH: u64 = 32;

// === Errors ===

#[error(code = 0)]
const EInvalidAssetPair: vector<u8> = b"The sale token and Quote type must differ.";

#[error(code = 1)]
const EInvalidRaiseTarget: vector<u8> = b"The raise target must be positive.";

#[error(code = 2)]
const EInvalidTokenAllocation: vector<u8> = b"Token allocations must be unique, positive, bounded, and total exactly 10,000 BPS.";

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
const ELiquidityDeadlineNotReached: vector<u8> = b"The deadline to cancel an unlaunched funded presale has not arrived.";

#[error(code = 17)]
const EInitialSupplyNotZero: vector<u8> = b"The supplied SaleToken TreasuryCap must have zero total supply.";

#[error(code = 18)]
const EInvalidFeeSplit: vector<u8> = b"Fee recipients must be unique, positive, bounded, and total 10,000 BPS with the holder-reward share.";

#[error(code = 19)]
const EWrongMigrationWitness: vector<u8> = b"The migrator does not match the venue fixed at presale creation.";


// === Imports ===

use blast_presale::merkle_tree;

use std::{bcs, type_name::{Self, TypeName}};

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::Currency,
    dynamic_field,
    event,
    hash,
};

use fun dynamic_field::add as UID.add_dynamic_field;
use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;
use fun dynamic_field::exists as UID.has_dynamic_field;
use fun dynamic_field::remove as UID.remove_dynamic_field;
