// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Standalone overflow presales with capped commitments, proportional fills,
/// migration-gated claims, and full refunds when a sale does not migrate.
module blast_presale::blast_presale;

// === Public Types ===

/// Who may commit and the maximum Quote each wallet may commit.
///
/// `Open` gives every wallet the same cap and minimum. The minimum times the
/// participant bound must reach the raise, so filling every slot funds the sale
/// and dust commitments cannot lock real buyers out. `Allowlisted` commits one
/// cap per wallet in a positional Blake2b-256 Merkle tree, supporting equal,
/// tiered, or fully custom caps.
public enum EligibilityPolicy has copy, drop, store {
    Open { wallet_cap: u64, max_participants: u64, min_commitment: u64 },
    Allowlisted { root: vector<u8>, leaf_count: u64 },
}

/// Who may commit once an uncapped phase lifts wallet caps.
public enum UncappedAccess has copy, drop, store {
    /// Only wallets the sale's eligibility policy admits, without their caps.
    Eligible,
    /// Any wallet, bounded like an open policy: `min_commitment * max_participants`
    /// must reach the raise so dust cannot lock buyers out.
    Anyone { max_participants: u64, min_commitment: u64 },
}

/// An optional closing phase, starting `starts_after_ms` into the commitment window,
/// that lifts wallet caps. With `hard_cap`, commitments in the phase take only what is
/// left of the raise and return the excess at once, and the sale stops accepting
/// Quote when the raise is full; without it, the sale still overflows and every
/// wallet is filled at one common rate.
public struct UncappedPhase has copy, drop, store {
    starts_after_ms: u64,
    access: UncappedAccess,
    hard_cap: bool,
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

/// A creator-configured share of the fixed token supply, in BPS.
public struct RecipientAllocation has copy, drop, store {
    recipient: address,
    bps: u64,
}

/// The exact tokens one recipient receives at migration, apportioned from its
/// `RecipientAllocation` when the presale is created.
public struct RecipientPayout has copy, drop, store {
    recipient: address,
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
/// Presale, LP, Blast, and additional recipient allocations stay escrowed until
/// a funded migration atomically releases them. Blast's rates are snapshotted
/// at creation, and its shares are paid only on migration. If the raise is
/// missed, every commitment is refunded. Anyone may migrate a funded sale until
/// it is cancelled; once LP is still unmigrated at its deadline, anyone may
/// cancel it so every commitment becomes refundable.
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
    uncapped: Option<UncappedPhase>,
    uncapped_from_ms: u64,
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
    recipient_payouts: vector<RecipientPayout>,
    recipient_tokens: Balance<SaleToken>,
    raise_payouts: vector<RecipientPayout>,
    protocol_fees: ProtocolFees,
    protocol_quote: u64,
    protocol_tokens: Balance<SaleToken>,
}

// === Public Functions ===

/// Creates one equal-cap policy with a bounded number of distinct wallets, each
/// of which must commit at least `min_commitment` in total.
public fun open_eligibility(
    wallet_cap: u64,
    max_participants: u64,
    min_commitment: u64,
): EligibilityPolicy {
    assert!(
        min_commitment > 0
            && min_commitment <= wallet_cap
            && max_participants > 0
            && max_participants <= MAX_PARTICIPANTS,
        EInvalidEligibilityPolicy,
    );

    EligibilityPolicy::Open { wallet_cap, max_participants, min_commitment }
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

/// Lifts wallet caps for eligible wallets `starts_after_ms` into the window.
public fun uncapped_for_eligible(starts_after_ms: u64, hard_cap: bool): UncappedPhase {
    UncappedPhase { starts_after_ms, access: UncappedAccess::Eligible, hard_cap }
}

/// Opens the sale to any wallet without caps `starts_after_ms` into the window, admitting
/// at most `max_participants` wallets in total, each committing at least `min_commitment`.
public fun uncapped_for_anyone(
    starts_after_ms: u64,
    max_participants: u64,
    min_commitment: u64,
    hard_cap: bool,
): UncappedPhase {
    assert!(
        min_commitment > 0 && max_participants > 0 && max_participants <= MAX_PARTICIPANTS,
        EInvalidUncappedPhase,
    );

    UncappedPhase {
        starts_after_ms,
        access: UncappedAccess::Anyone { max_participants, min_commitment },
        hard_cap,
    }
}

/// Configures one additional recipient's share of the fixed token supply.
public fun recipient_allocation(recipient: address, bps: u64): RecipientAllocation {
    assert!(recipient != @0x0 && bps > 0 && bps <= BASIS_POINTS, EInvalidTokenAllocation);

    RecipientAllocation { recipient, bps }
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
    let end_ms = start_ms.checked_add(self.duration_ms).destroy_or!(abort EInvalidWindow);
    let liquidity_deadline_ms = end_ms
        .checked_add(self.liquidity_window_ms)
        .destroy_or!(abort EInvalidWindow);
    // `new` bounds the offset below the duration, so this cannot overflow.
    let uncapped_from_ms = self.uncapped.map_ref!(|phase| start_ms + phase.starts_after_ms).destroy_or!(end_ms);

    self.lifecycle = Lifecycle::Open;
    self.end_ms = end_ms;
    self.liquidity_deadline_ms = liquidity_deadline_ms;
    self.uncapped_from_ms = uncapped_from_ms;

    event::emit(PresaleOpened<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        start_ms,
        end_ms,
        liquidity_deadline_ms,
        uncapped_from_ms,
    });

    transfer::share_object(self);
}

/// Locks the supplied `Coin<Quote>` in this presale under an equal-cap, open
/// eligibility policy and returns whatever a hard-capped uncapped phase could not
/// accept (a zero coin otherwise).
public fun commit_open<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    quote_in: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    self.assert_open(clock);
    assert!(quote_in.value() > 0, EZeroCommitment);

    let (wallet_cap, max_participants, min_commitment) = open_limits(self.eligibility);

    self.record_commitment(quote_in, wallet_cap, max_participants, min_commitment, clock, ctx)
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
): Coin<Quote> {
    self.assert_open(clock);
    assert!(quote_in.value() > 0, EZeroCommitment);

    let max_participants = verify_allowlisted(
        self.eligibility,
        index,
        ctx.sender(),
        wallet_cap,
        &proof,
    );

    // Allowlisted wallets are few and named, so any positive commitment counts.
    self.record_commitment(quote_in, wallet_cap, max_participants, 1, clock, ctx)
}

/// Locks Quote from any wallet once an uncapped phase open to anyone has started,
/// returning whatever a hard cap could not accept.
public fun commit_uncapped<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    quote_in: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    self.assert_open(clock);
    assert!(quote_in.value() > 0, EZeroCommitment);
    assert!(clock.timestamp_ms() >= self.uncapped_from_ms, EUncappedPhaseNotOpen);

    let (max_participants, min_commitment) = match (self.uncapped.destroy_some()) {
        UncappedPhase { access: UncappedAccess::Anyone { max_participants, min_commitment }, .. } => {
            (max_participants, min_commitment)
        },
        _ => abort EUncappedPhaseNotOpen,
    };

    self.record_commitment(quote_in, std::u64::max_value!(), max_participants, min_commitment, clock, ctx)
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
    let (tokens, quote_refund) = self.claim_payout(commitment);

    self.remaining_commitments = self.remaining_commitments - commitment;
    self.sale_tokens.pay(tokens, participant, ctx);
    self.quote.pay(quote_refund, participant, ctx);

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
    treasury_cap: TreasuryCap<SaleToken>,
    currency: &mut Currency<SaleToken>,
    token_supply: u64,
    token_allocation_bps: u64,
    liquidity_token_allocation_bps: u64,
    recipient_allocations: vector<RecipientAllocation>,
    burnable: bool,
    raise_target: u64,
    raise_allocations: vector<RecipientAllocation>,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    _: MigrationWitness,
    tick_spacing: u32,
    fee_rate: u64,
    fee_recipients: vector<FeeRecipient>,
    rewards_fee_bps: u64,
    fee_policy: &FeePolicy,
    ctx: &mut TxContext,
): (Presale<SaleToken, Quote>, PresaleCap) {
    let protocol_fees = fee_policy.fees();
    assert!(
        type_name::with_original_ids<SaleToken>() != type_name::with_original_ids<Quote>(),
        EInvalidAssetPair,
    );
    // `Currency<SaleToken>` and `TreasuryCap<SaleToken>` are each unique per type, and making the
    // supply fixed or burn-only consumes the cap, so holding it proves the supply is still unknown.
    assert!(treasury_cap.total_supply() == 0, EInitialSupplyNotZero);
    assert!(raise_target > 0, EInvalidRaiseTarget);
    assert_raise_allocations(&raise_allocations);
    assert_token_allocations(
        token_supply,
        token_allocation_bps,
        liquidity_token_allocation_bps,
        protocol_fees.token_bps(),
        &recipient_allocations,
    );
    assert_fee_split(&fee_recipients, rewards_fee_bps);
    assert!(duration_ms > 0 && liquidity_window_ms > 0, EInvalidWindow);
    assert!(eligibility.can_reach(raise_target), EUnreachableRaise);
    uncapped.do_ref!(|phase| assert_uncapped_phase(phase, duration_ms, eligibility, raise_target));

    let (
        token_allocation,
        liquidity_token_allocation,
        protocol_token_allocation,
        recipient_payouts,
    ) = apportion_supply(
        token_supply,
        token_allocation_bps,
        liquidity_token_allocation_bps,
        protocol_fees.token_bps(),
        &recipient_allocations,
    );
    let (raise_payouts, protocol_quote, liquidity_quote) = apportion_raise(
        &raise_allocations,
        protocol_fees.raise_bps(),
        raise_target,
    );
    assert!(
        migration_math::is_seedable(
            migration_math::sqrt_price_x64(liquidity_token_allocation, liquidity_quote, true),
        ),
        EUnseedablePrice,
    );
    assert!(recipient_payouts.all!(|payout| payout.amount > 0), EInvalidTokenAllocation);

    let treasury_cap_id = object::id(&treasury_cap);
    let (sale_tokens, liquidity_tokens, protocol_tokens, recipient_tokens) = mint_and_seal_supply(
        treasury_cap,
        currency,
        token_supply,
        token_allocation,
        liquidity_token_allocation,
        protocol_token_allocation,
        burnable,
    );

    let id = object::new(ctx);
    let presale_id = id.to_inner();
    let cap = PresaleCap { id: object::new(ctx), presale_id };
    let presale_cap_id = cap.id.to_inner();
    let migration_witness = type_name::with_original_ids<MigrationWitness>();

    event::emit(PresaleCreated<SaleToken, Quote> {
        presale_id,
        presale_cap_id,
        treasury_cap_id,
        token_supply,
        token_allocation_bps,
        liquidity_token_allocation_bps,
        recipients: recipient_allocations.map_ref!(|allocation| allocation.recipient),
        recipient_bps: recipient_allocations.map_ref!(|allocation| allocation.bps),
        burnable,
        raise_target,
        raise_recipients: raise_allocations.map_ref!(|allocation| allocation.recipient),
        raise_recipient_bps: raise_allocations.map_ref!(|allocation| allocation.bps),
        duration_ms,
        liquidity_window_ms,
        eligibility,
        uncapped,
        migration_witness,
        tick_spacing,
        fee_rate,
        fee_recipients: fee_recipient_addresses(&fee_recipients),
        fee_recipient_bps: fee_recipient_bps(&fee_recipients),
        rewards_fee_bps,
        protocol_fees,
        protocol_quote,
        protocol_tokens: protocol_token_allocation,
    });

    (
        Presale {
            id,
            presale_cap_id,
            lifecycle: Lifecycle::Pending,
            duration_ms,
            liquidity_window_ms,
            end_ms: 0,
            liquidity_deadline_ms: 0,
            raise_target,
            eligibility,
            uncapped,
            uncapped_from_ms: 0,
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
            recipient_payouts,
            recipient_tokens,
            raise_payouts,
            protocol_fees,
            protocol_quote,
            protocol_tokens,
        },
        cap,
    )
}

/// Pays Blast and the raise recipients their shares at once, then releases the
/// rest of the raise and the LP-token allocation only to the configured
/// migrator. Anyone may call that migrator at any time until the sale is
/// cancelled; its pool creation remains atomic with this state transition.
public(package) fun migrate<SaleToken, Quote, MigrationWitness: drop>(
    self: &mut Presale<SaleToken, Quote>,
    fee_policy: &FeePolicy,
    _: MigrationWitness,
    ctx: &mut TxContext,
): (Balance<SaleToken>, Balance<Quote>) {
    assert!(self.lifecycle == Lifecycle::Funded, EInvalidLifecycle);
    assert!(
        self.migration_witness == type_name::with_original_ids<MigrationWitness>(),
        EWrongMigrationWitness,
    );

    let mut quote = self.quote.split(self.raise_target);
    let liquidity_tokens = self.liquidity_tokens.withdraw_all();
    let recipient_tokens = self.recipient_tokens.value();

    self.pay_protocol_fees(&mut quote, fee_policy.destination(), ctx);
    self.pay_raise_allocations(&mut quote, ctx);
    self.release_recipient_tokens(ctx);
    self.lifecycle = Lifecycle::Migrated;

    event::emit(PresaleMigrated<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        migration_witness: self.migration_witness,
        quote: quote.value(),
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

/// The tick spacing and fee rate of the pool migration creates.
public(package) fun pool_tier<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): (u32, u64) {
    (self.tick_spacing, self.fee_rate)
}

/// The presale and creator-capability IDs, the LP-fee split, and Blast's rates its vault inherits.
public(package) fun vault_config<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
): (ID, ID, vector<FeeRecipient>, u64, ProtocolFees) {
    (
        self.id.to_inner(),
        self.presale_cap_id,
        self.fee_recipients,
        self.rewards_fee_bps,
        self.protocol_fees,
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

/// Transfers `amount` split from `self` to `recipient`, skipping empty shares.
public(package) fun pay<T>(
    self: &mut Balance<T>,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    if (amount > 0) transfer::public_transfer(self.split(amount).into_coin(ctx), recipient);
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

    // Hand out the leftover units to the largest remainders, earlier shares first on ties.
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

// Presale creation

/// Raise allocations: distinct recipients sharing strictly less than the whole raise.
fun assert_raise_allocations(raise_allocations: &vector<RecipientAllocation>) {
    assert!(raise_allocations.length() <= MAX_RECIPIENTS, EInvalidRaiseAllocation);
    raise_allocations.do_ref!(|allocation| assert!(
        allocation.recipient != @0x0
            && allocation.bps > 0
            && allocation.bps < BASIS_POINTS
            // ponytail: O(n²) duplicate validation is bounded by MAX_RECIPIENTS.
            && raise_allocations.count!(|other| other.recipient == allocation.recipient) == 1,
        EInvalidRaiseAllocation,
    ));
    assert!(allocated_bps(raise_allocations) < BASIS_POINTS, EInvalidRaiseAllocation);
}

/// Token allocations: bounded shares totalling exactly 10,000 BPS with Blast's share.
fun assert_token_allocations(
    token_supply: u64,
    token_allocation_bps: u64,
    liquidity_token_allocation_bps: u64,
    protocol_token_bps: u64,
    recipient_allocations: &vector<RecipientAllocation>,
) {
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
        (*recipient_allocations).fold!(
            token_allocation_bps + liquidity_token_allocation_bps + protocol_token_bps,
            |sum, allocation| sum + allocation.bps,
        ) == BASIS_POINTS,
        EInvalidTokenAllocation,
    );
}

/// LP-fee split: bounded recipients plus the holder share totalling exactly 10,000 BPS.
fun assert_fee_split(fee_recipients: &vector<FeeRecipient>, rewards_fee_bps: u64) {
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
        (*fee_recipients).fold!(rewards_fee_bps, |sum, fee_recipient| sum + fee_recipient.bps)
            == BASIS_POINTS,
        EInvalidFeeSplit,
    );
}

/// The phase starts inside the window, and an open-to-anyone phase admits at least the
/// policy's wallets while its minimum over its participant bound still reaches the raise.
fun assert_uncapped_phase(
    phase: &UncappedPhase,
    duration_ms: u64,
    eligibility: EligibilityPolicy,
    raise_target: u64,
) {
    assert!(phase.starts_after_ms < duration_ms, EInvalidUncappedPhase);
    match (phase.access) {
        UncappedAccess::Anyone { max_participants, min_commitment } => {
            assert!(max_participants >= eligibility.participant_bound(), EInvalidUncappedPhase);
            assert!(
                (min_commitment as u128) * (max_participants as u128) >= (raise_target as u128),
                EUnreachableRaise,
            );
        },
        UncappedAccess::Eligible => (),
    }
}

/// The number of distinct wallets the eligibility policy admits.
fun participant_bound(self: EligibilityPolicy): u64 {
    match (self) {
        EligibilityPolicy::Open { max_participants, .. } => max_participants,
        EligibilityPolicy::Allowlisted { leaf_count, .. } => leaf_count,
    }
}

/// Whether filling every open participant slot at the minimum commitment funds the raise.
/// Allowlist caps are committed off chain, so only the open policy is checked.
fun can_reach(self: EligibilityPolicy, raise_target: u64): bool {
    match (self) {
        EligibilityPolicy::Open { max_participants, min_commitment, .. } => {
            (min_commitment as u128) * (max_participants as u128) >= (raise_target as u128)
        },
        EligibilityPolicy::Allowlisted { .. } => true,
    }
}

/// Apportions the supply so every atomic unit belongs to exactly one allocation, returning the
/// presale and LP allocations, which must be positive, Blast's allocation, and each recipient's
/// payout.
fun apportion_supply(
    token_supply: u64,
    token_allocation_bps: u64,
    liquidity_token_allocation_bps: u64,
    protocol_token_bps: u64,
    recipient_allocations: &vector<RecipientAllocation>,
): (u64, u64, u64, vector<RecipientPayout>) {
    let mut shares = vector[token_allocation_bps, liquidity_token_allocation_bps, protocol_token_bps];
    recipient_allocations.do_ref!(|allocation| shares.push_back(allocation.bps));
    let amounts = apportion(shares, token_supply);
    assert!(amounts[0] > 0 && amounts[1] > 0, EInvalidTokenAllocation);

    (amounts[0], amounts[1], amounts[2], payouts(recipient_allocations, &amounts, 3))
}

/// Apportions the raise the same way among the recipients, Blast, and the LP, which keeps the
/// last share, returning each recipient's payout, Blast's Quote, and the LP's Quote. Every
/// recipient and the LP must receive a positive amount.
fun apportion_raise(
    raise_allocations: &vector<RecipientAllocation>,
    protocol_raise_bps: u64,
    raise_target: u64,
): (vector<RecipientPayout>, u64, u64) {
    let allocated = allocated_bps(raise_allocations) + protocol_raise_bps;
    assert!(allocated < BASIS_POINTS, EInvalidRaiseAllocation);

    let mut shares = raise_allocations.map_ref!(|allocation| allocation.bps);
    shares.push_back(protocol_raise_bps);
    shares.push_back(BASIS_POINTS - allocated);
    let amounts = apportion(shares, raise_target);
    let raise_payouts = payouts(raise_allocations, &amounts, 0);
    let liquidity_quote = amounts[raise_allocations.length() + 1];
    assert!(
        raise_payouts.all!(|payout| payout.amount > 0) && liquidity_quote > 0,
        EInvalidRaiseAllocation,
    );

    (raise_payouts, amounts[raise_allocations.length()], liquidity_quote)
}

/// The BPS these allocations take in total.
fun allocated_bps(allocations: &vector<RecipientAllocation>): u64 {
    (*allocations).fold!(0, |sum, allocation| sum + allocation.bps)
}

/// Pairs each allocation's recipient with its apportioned amount, read from `amounts` starting
/// at `first`.
fun payouts(
    allocations: &vector<RecipientAllocation>,
    amounts: &vector<u64>,
    first: u64,
): vector<RecipientPayout> {
    vector::tabulate!(allocations.length(), |i| RecipientPayout {
        recipient: allocations[i].recipient,
        amount: amounts[first + i],
    })
}

/// Mints the complete supply once, splits off the presale, LP, and Blast allocations, then gives
/// up mint authority forever by making the supply fixed or burn-only.
fun mint_and_seal_supply<SaleToken>(
    mut treasury_cap: TreasuryCap<SaleToken>,
    currency: &mut Currency<SaleToken>,
    token_supply: u64,
    token_allocation: u64,
    liquidity_token_allocation: u64,
    protocol_token_allocation: u64,
    burnable: bool,
): (Balance<SaleToken>, Balance<SaleToken>, Balance<SaleToken>, Balance<SaleToken>) {
    let mut recipient_tokens = treasury_cap.mint_balance(token_supply);
    let sale_tokens = recipient_tokens.split(token_allocation);
    let liquidity_tokens = recipient_tokens.split(liquidity_token_allocation);
    let protocol_tokens = recipient_tokens.split(protocol_token_allocation);
    if (burnable) currency.make_supply_burn_only(treasury_cap)
    else currency.make_supply_fixed(treasury_cap);

    (sale_tokens, liquidity_tokens, protocol_tokens, recipient_tokens)
}

// Commitments

fun record_commitment<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    mut quote_in: Coin<Quote>,
    wallet_cap: u64,
    max_participants: u64,
    min_commitment: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    let uncapped = clock.timestamp_ms() >= self.uncapped_from_ms;
    let (max_participants, hard_cap) = self.participant_limits(uncapped, max_participants);
    let quote = self.accepted_quote(quote_in.value(), hard_cap);
    let fills_raise = hard_cap && self.total_commitments + quote == self.raise_target;

    let key = CommitmentKey(ctx.sender());
    let exists = self.id.has_dynamic_field(key);
    let current = if (exists) *dynamic_field::borrow<_, Commitment>(&self.id, key)
    else Commitment { quote: 0, wallet_cap };
    let wallet_commitment = current.add_within_cap(quote, wallet_cap, uncapped);
    // The commitment that exactly fills a hard cap may be smaller than the minimum.
    assert!(wallet_commitment >= min_commitment || fills_raise, EBelowMinimumCommitment);
    assert!(exists || self.participants < max_participants, EParticipantCapacityReached);
    let total_commitments = self
        .total_commitments
        .checked_add(quote)
        .destroy_or!(abort ETotalCommitmentOverflow);

    self.store_commitment(key, wallet_commitment, wallet_cap);
    self.total_commitments = total_commitments;
    self.remaining_commitments = total_commitments;
    self.quote.join(quote_in.split(quote, ctx).into_balance());

    event::emit(Committed<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        quote,
        wallet_commitment,
        total_commitments,
        participants: self.participants,
    });

    quote_in
}

fun open_limits(policy: EligibilityPolicy): (u64, u64, u64) {
    match (policy) {
        EligibilityPolicy::Open { wallet_cap, max_participants, min_commitment } => {
            (wallet_cap, max_participants, min_commitment)
        },
        EligibilityPolicy::Allowlisted { .. } => abort EWrongEligibilityPolicy,
    }
}

/// The participant bound and hard-cap flag that apply now: the policy's bound without a hard
/// cap until the uncapped phase starts, then the phase's own.
fun participant_limits<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    uncapped: bool,
    policy_max_participants: u64,
): (u64, bool) {
    if (!uncapped) return (policy_max_participants, false);

    let UncappedPhase { access, hard_cap, .. } = self.uncapped.destroy_some();
    let max_participants = match (access) {
        UncappedAccess::Anyone { max_participants, .. } => max_participants,
        UncappedAccess::Eligible => policy_max_participants,
    };

    (max_participants, hard_cap)
}

/// The Quote a commitment of `offered` adds: all of it, except that a hard-capped uncapped
/// phase accepts only what is left of the raise.
fun accepted_quote<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    offered: u64,
    hard_cap: bool,
): u64 {
    if (!hard_cap) return offered;

    assert!(self.total_commitments < self.raise_target, EPresaleFilled);
    offered.min(self.raise_target - self.total_commitments)
}

/// The wallet's total after adding `quote`, held to the caller's cap until the uncapped phase.
fun add_within_cap(self: Commitment, quote: u64, wallet_cap: u64, uncapped: bool): u64 {
    // Caps no longer apply once uncapped, so a record's cap need not match the caller's.
    assert!(uncapped || self.wallet_cap == wallet_cap, EInvalidEligibilityProof);
    let wallet_commitment = self.quote.checked_add(quote).destroy_or!(abort EWalletCapExceeded);
    assert!(uncapped || wallet_commitment <= wallet_cap, EWalletCapExceeded);

    wallet_commitment
}

/// Records the wallet's new total, admitting the wallet as a participant on its first commitment.
fun store_commitment<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    key: CommitmentKey,
    wallet_commitment: u64,
    wallet_cap: u64,
) {
    if (self.id.has_dynamic_field(key)) {
        self.id.dynamic_field_mut<_, Commitment>(key).quote = wallet_commitment;
    } else {
        self.id.add_dynamic_field(key, Commitment { quote: wallet_commitment, wallet_cap });
        self.participants = self.participants + 1;
    };
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

// Claims

/// One commitment's tokens, after migration only, and Quote refund, each its pro-rata share;
/// the last claim instead takes everything left, absorbing the integer-rounding remainder.
fun claim_payout<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    commitment: u64,
): (u64, u64) {
    let last = self.remaining_commitments == commitment;
    let tokens = if (self.lifecycle != Lifecycle::Migrated) 0
    else if (last) self.sale_tokens.value()
    else self.token_allocation.mul_div(commitment, self.total_commitments);
    let refund_total = if (self.lifecycle == Lifecycle::Cancelled) self.total_commitments
    else self.total_commitments - self.raise_target;
    let quote_refund = if (last) self.quote.value()
    else refund_total.mul_div(commitment, self.total_commitments);

    (tokens, quote_refund)
}

// Migration

/// Pays Blast its shares of the raise, out of `quote`, and of the supply at `destination`.
fun pay_protocol_fees<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    quote: &mut Balance<Quote>,
    destination: address,
    ctx: &mut TxContext,
) {
    let tokens = self.protocol_tokens.value();

    quote.pay(self.protocol_quote, destination, ctx);
    self.protocol_tokens.pay(tokens, destination, ctx);

    event::emit(ProtocolFeesPaid<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        destination,
        quote: self.protocol_quote,
        tokens,
    });
}

/// Pays each raise recipient its share out of `quote`, leaving the LP's share.
fun pay_raise_allocations<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    quote: &mut Balance<Quote>,
    ctx: &mut TxContext,
) {
    self.raise_payouts.do_ref!(|payout| {
        let RecipientPayout { recipient, amount } = *payout;
        transfer::public_transfer(quote.split(amount).into_coin(ctx), recipient);
        event::emit(RaiseAllocated<SaleToken, Quote> {
            presale_id: self.id.to_inner(),
            recipient,
            quote: amount,
        });
    });
}

/// Releases every escrowed recipient token to its configured recipient.
fun release_recipient_tokens<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    ctx: &mut TxContext,
) {
    self.recipient_payouts.length().do!(|i| {
        let RecipientPayout { recipient, amount } = self.recipient_payouts[i];
        transfer::public_transfer(self.recipient_tokens.split(amount).into_coin(ctx), recipient);
        event::emit(RecipientAllocated<SaleToken, Quote> {
            presale_id: self.id.to_inner(),
            recipient,
            tokens: amount,
        });
    });
    assert!(self.recipient_tokens.value() == 0, EInvalidTokenAllocation);
}

// Cancellation

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
): (u64, u64, u64, u64, u64, u64, u64, u64) {
    (
        self.total_commitments,
        self.remaining_commitments,
        self.participants,
        self.quote.value(),
        self.sale_tokens.value(),
        self.liquidity_tokens.value(),
        self.recipient_tokens.value(),
        self.protocol_tokens.value(),
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
): (vector<address>, vector<u64>, bool) {
    (event.recipients, event.recipient_bps, event.burnable)
}

#[test_only]
public fun created_protocol_fields<SaleToken, Quote>(
    event: &PresaleCreated<SaleToken, Quote>,
): (ProtocolFees, u64, u64) {
    (event.protocol_fees, event.protocol_quote, event.protocol_tokens)
}

#[test_only]
public fun opened_fields<SaleToken, Quote>(
    event: &PresaleOpened<SaleToken, Quote>,
): (ID, u64, u64, u64, u64) {
    (
        event.presale_id,
        event.start_ms,
        event.end_ms,
        event.liquidity_deadline_ms,
        event.uncapped_from_ms,
    )
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
public fun raise_allocated_fields<SaleToken, Quote>(
    event: &RaiseAllocated<SaleToken, Quote>,
): (ID, address, u64) {
    (event.presale_id, event.recipient, event.quote)
}

#[test_only]
public fun protocol_fees_paid_fields<SaleToken, Quote>(
    event: &ProtocolFeesPaid<SaleToken, Quote>,
): (ID, address, u64, u64) {
    (event.presale_id, event.destination, event.quote, event.tokens)
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
    recipients: vector<address>,
    recipient_bps: vector<u64>,
    burnable: bool,
    raise_target: u64,
    raise_recipients: vector<address>,
    raise_recipient_bps: vector<u64>,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    migration_witness: TypeName,
    tick_spacing: u32,
    fee_rate: u64,
    fee_recipients: vector<address>,
    fee_recipient_bps: vector<u64>,
    rewards_fee_bps: u64,
    /// Blast's rates, snapshotted for this sale.
    protocol_fees: ProtocolFees,
    /// Blast's shares of the raise and of the supply, paid on migration.
    protocol_quote: u64,
    protocol_tokens: u64,
}

/// A presale's fixed commitment and liquidity windows began.
public struct PresaleOpened<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    start_ms: u64,
    end_ms: u64,
    liquidity_deadline_ms: u64,
    uncapped_from_ms: u64,
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

/// The raise left after Blast's and the recipients' shares, and the LP-token allocation,
/// entered the configured migrator.
public struct PresaleMigrated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    migration_witness: TypeName,
    quote: u64,
    liquidity_tokens: u64,
    recipient_tokens: u64,
}

/// Blast received its shares of the raise and of the supply at `destination`.
public struct ProtocolFeesPaid<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    destination: address,
    quote: u64,
    tokens: u64,
}

/// One configured recipient received its share of the raise.
public struct RaiseAllocated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    recipient: address,
    quote: u64,
}

/// One configured recipient received its immutable token allocation.
public struct RecipientAllocated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    recipient: address,
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
const EInvalidTokenAllocation: vector<u8> = b"Token allocations must be unique, positive, bounded, and total exactly 10,000 BPS with Blast's share.";

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


#[error(code = 20)]
const EBelowMinimumCommitment: vector<u8> = b"The wallet's total commitment is below the sale's minimum commitment.";

#[error(code = 21)]
const EUnreachableRaise: vector<u8> = b"An open sale's minimum commitment times its participant bound must reach the raise target.";

#[error(code = 22)]
const EUnseedablePrice: vector<u8> = b"The raise and LP-token allocation give a seed price the venues cannot pool.";

#[error(code = 23)]
const EInvalidUncappedPhase: vector<u8> = b"An uncapped phase must start inside the window, and an open-to-anyone phase needs a positive minimum and a participant bound at least the policy's.";

#[error(code = 24)]
const EUncappedPhaseNotOpen: vector<u8> = b"The presale has no uncapped phase open to any wallet, or it has not started.";

#[error(code = 25)]
const EPresaleFilled: vector<u8> = b"The hard-capped presale has already reached its raise.";

#[error(code = 26)]
const EInvalidRaiseAllocation: vector<u8> = b"Raise allocations must be unique, positive, bounded, leave the LP a positive share after Blast's, and apportion to positive amounts.";

// === Imports ===

use blast_presale::{fee_policy::{FeePolicy, ProtocolFees}, merkle_tree, migration_math};

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

use fun pay as Balance.pay;

use fun dynamic_field::add as UID.add_dynamic_field;
use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;
use fun dynamic_field::exists as UID.has_dynamic_field;
use fun dynamic_field::remove as UID.remove_dynamic_field;
