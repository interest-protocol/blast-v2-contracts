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
    /// Any wallet, bounded like an open policy: `min_commitment` over the slots held to it must
    /// reach the raise so dust cannot lock buyers out. Every slot counts under an open policy;
    /// under an allowlist only the slots beyond its leaves do, since allowlisted wallets may
    /// commit any positive amount.
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

/// Linear vesting from the schedule's start, migration for a recipient share and the claim for a
/// participant: nothing before `cliff_ms`, then the vested amount steps up every `period_ms` until
/// all `periods` have elapsed.
public struct VestingTerms has copy, drop, store {
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
}

/// One recipient's share, in BPS, of the token supply, of the raise, or of every collected LP
/// fee. The creator takes LP fees as an ordinary fee recipient. A token or raise share may vest;
/// a fee share may not.
public struct RecipientShare has copy, drop, store {
    recipient: address,
    bps: Bps,
    vesting: Option<VestingTerms>,
}

/// The exact token or Quote amount one recipient receives at migration, apportioned from its
/// `RecipientShare` when the presale is created, and the terms it vests under, if any.
public struct RecipientPayout has copy, drop, store {
    recipient: address,
    amount: u64,
    vesting: Option<VestingTerms>,
}

/// How every collected LP fee is split: each recipient's share, then the holder-reward share.
/// Only `fee_split` builds one, so wherever a split is held its shares total exactly 10,000 BPS
/// and every fee it apportions is assigned in full.
public struct FeeSplit has copy, drop, store {
    shares: vector<RecipientShare>,
    holder_rewards_bps: Bps,
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
/// at creation, the AdminCap may change them until the window starts, and its
/// shares are paid only on migration, or, when the sale names a Blast partner,
/// held from migration until `pay_partner` pays the partner its cut of Blast's
/// raise share. If the raise is missed, every commitment
/// is refunded. Anyone may migrate a funded sale until it is cancelled; once LP
/// is still unmigrated at its deadline, anyone may cancel it so every
/// commitment becomes refundable. Under participant vesting, each claim locks the
/// participant's tokens in its own schedule instead of paying them out.
public struct Presale<phantom SaleToken, phantom Quote> has key {
    id: UID,
    presale_cap_id: ID,
    lifecycle: Lifecycle,
    duration_ms: u64,
    liquidity_window_ms: u64,
    /// When commitments open, fixed by `share`; zero until then. The window's end, the LP
    /// deadline, and the uncapped start are derived from it and the lengths above.
    start_ms: u64,
    raise_target: u64,
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    migration_witness: TypeName,
    tick_spacing: u32,
    pool_fee_rate: u64,
    fee_split: FeeSplit,
    total_commitments: u64,
    /// The wallets holding an undelivered commitment: admitted by their first commitment and
    /// released by their claim, so the claim that empties the sale is the last one.
    participants: u64,
    quote: Balance<Quote>,
    token_allocation: u64,
    participant_vesting: Option<VestingTerms>,
    sale_tokens: Balance<SaleToken>,
    liquidity_tokens: Balance<SaleToken>,
    recipient_payouts: vector<RecipientPayout>,
    recipient_tokens: Balance<SaleToken>,
    raise_payouts: vector<RecipientPayout>,
    protocol_fees: ProtocolFees,
    protocol_quote: u64,
    protocol_tokens: Balance<SaleToken>,
    /// The Blast partner named at creation, paid its share of Blast's raise share. It never changes
    /// once the sale is shared.
    partner_id: Option<ID>,
    /// Blast's raise share, held from a partnered sale's migration until `pay_partner` splits it.
    unpaid_protocol_quote: Option<Balance<Quote>>,
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
        root.length() == merkle_tree::digest_length()
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

/// One recipient's share in BPS. Presale creation validates each list of shares under that
/// list's own rules and error.
public fun recipient_share(recipient: address, bps: Bps): RecipientShare {
    RecipientShare { recipient, bps, vesting: option::none() }
}

/// One recipient's token or raise share in BPS, locked at migration in an irrevocable linear
/// schedule under `vesting` instead of paid out.
public fun vested_recipient_share(
    recipient: address,
    bps: Bps,
    vesting: VestingTerms,
): RecipientShare {
    RecipientShare { recipient, bps, vesting: option::some(vesting) }
}

/// Linear vesting terms. The steps and cliff must fit in `MAX_VESTING_DURATION_MS`, so migration and
/// claims can always create the schedule. Product limits on the duration belong to creation tooling.
public fun vesting_terms(cliff_ms: u64, period_ms: u64, periods: u64): VestingTerms {
    assert!(
        period_ms > 0
            && periods > 0
            && period_ms <= MAX_VESTING_DURATION_MS / periods
            && cliff_ms <= period_ms * periods,
        EInvalidVestingTerms,
    );

    VestingTerms { cliff_ms, period_ms, periods }
}

/// The LP-fee split a sale and its vault pay collected fees under: at most `MAX_FEE_RECIPIENTS`
/// distinct unvested recipients whose shares total exactly 10,000 BPS with the holder-reward
/// share. The creator takes its LP fees as one of the recipients.
public fun fee_split(shares: vector<RecipientShare>, holder_rewards_bps: Bps): FeeSplit {
    assert!(
        valid_shares(&shares, MAX_FEE_RECIPIENTS)
            && shares.all!(|share| share.vesting.is_none())
            && total_bps(&shares) + holder_rewards_bps.value() == bps::denominator(),
        EInvalidFeeSplit,
    );

    FeeSplit { shares, holder_rewards_bps }
}

/// Mints and apportions the complete token supply, then irreversibly makes it
/// fixed or burn-only before returning the presale.
///
/// A migrator in this or any other package creates its sales here with its own `MigrationWitness`,
/// which only its defining module can construct. The `CreationPolicy` must allow that witness, so
/// Blast decides which migrators may open sales; the sale then releases its liquidity only to
/// `migrate` called with the same witness.
public fun new<SaleToken, Quote, MigrationWitness: drop>(
    treasury_cap: TreasuryCap<SaleToken>,
    currency: &mut Currency<SaleToken>,
    token_supply: u64,
    token_allocation_bps: Bps,
    participant_vesting: Option<VestingTerms>,
    liquidity_token_allocation_bps: Bps,
    recipient_allocations: vector<RecipientShare>,
    burnable: bool,
    raise_target: u64,
    raise_allocations: vector<RecipientShare>,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    _: MigrationWitness,
    tick_spacing: u32,
    pool_fee_rate: u64,
    fee_split: FeeSplit,
    creation_policy: &CreationPolicy,
    fee_policy: &FeePolicy,
    ctx: &mut TxContext,
): (Presale<SaleToken, Quote>, PresaleCap) {
    creation_policy.assert_allowed<Quote, MigrationWitness>();
    assert!(
        type_name::with_original_ids<SaleToken>() != type_name::with_original_ids<Quote>(),
        EInvalidAssetPair,
    );
    // `Currency<SaleToken>` and `TreasuryCap<SaleToken>` are each unique per type, and making the
    // supply fixed or burn-only consumes the cap, so holding it proves the supply is still unknown.
    assert!(treasury_cap.total_supply() == 0, EInitialSupplyNotZero);

    let protocol_fees = fee_policy.fees();
    assert!(raise_target > 0, EInvalidRaiseTarget);
    assert_raise_allocations(&raise_allocations, protocol_fees.raise_bps());
    assert_token_allocations(
        token_supply,
        token_allocation_bps,
        liquidity_token_allocation_bps,
        protocol_fees.token_bps(),
        &recipient_allocations,
    );

    assert!(duration_ms > 0 && liquidity_window_ms >= MIN_LIQUIDITY_WINDOW_MS, EInvalidWindow);
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

    assert_seedable_price(liquidity_token_allocation, liquidity_quote);

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
        token_allocation_bps: token_allocation_bps.value(),
        participant_vesting,
        liquidity_token_allocation_bps: liquidity_token_allocation_bps.value(),
        recipients: recipient_allocations.recipients(),
        recipient_bps: recipient_allocations.bps(),
        recipient_vesting: recipient_allocations.vesting_terms(),
        burnable,
        raise_target,
        raise_recipients: raise_allocations.recipients(),
        raise_recipient_bps: raise_allocations.bps(),
        raise_recipient_vesting: raise_allocations.vesting_terms(),
        duration_ms,
        liquidity_window_ms,
        eligibility,
        uncapped,
        migration_witness,
        tick_spacing,
        pool_fee_rate,
        fee_recipients: fee_split.shares.recipients(),
        fee_recipient_bps: fee_split.shares.bps(),
        holder_rewards_bps: fee_split.holder_rewards_bps.value(),
        protocol_raise_bps: protocol_fees.raise_bps().value(),
        protocol_token_bps: protocol_fees.token_bps().value(),
        protocol_lp_fee_meme_bps: protocol_fees.lp_fee_meme_bps().value(),
        protocol_lp_fee_quote_bps: protocol_fees.lp_fee_quote_bps().value(),
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
            start_ms: 0,
            raise_target,
            eligibility,
            uncapped,
            migration_witness,
            tick_spacing,
            pool_fee_rate,
            fee_split,
            total_commitments: 0,
            participants: 0,
            quote: balance::zero(),
            token_allocation,
            participant_vesting,
            sale_tokens,
            liquidity_tokens,
            recipient_payouts,
            recipient_tokens,
            raise_payouts,
            protocol_fees,
            protocol_quote,
            protocol_tokens,
            partner_id: option::none(),
            unpaid_protocol_quote: option::none(),
        },
        cap,
    )
}

/// Names the sale's Blast partner, one the `CreationPolicy` lets new presales name, before `share`
/// fixes it for good. The partner earns its share of Blast's raise share, and of nothing else:
/// migration holds Blast's shares, and `pay_partner` pays them.
public fun set_partner<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    creation_policy: &CreationPolicy,
    partner: &Partner,
    clock: &Clock,
) {
    assert!(self.lifecycle == Lifecycle::Pending, EInvalidLifecycle);
    let partner_id = object::id(partner);
    creation_policy.assert_partner(partner_id, clock.timestamp_ms());

    self.partner_id = option::some(partner_id);
}

/// Shares a newly created presale and fixes its windows from `start_ms`, or from now once that
/// has passed, so a sale can be created ahead of its start. Commitments open at the start; until
/// then the AdminCap may change the sale's Blast rates.
public fun share<SaleToken, Quote>(
    mut self: Presale<SaleToken, Quote>,
    start_ms: u64,
    clock: &Clock,
) {
    assert!(self.lifecycle == Lifecycle::Pending, EInvalidLifecycle);

    // Every deadline is derived from the start, so the share proves each one fits in u64.
    let start_ms = start_ms.max(clock.timestamp_ms());
    let end_ms = start_ms.checked_add(self.duration_ms).destroy_or!(abort EInvalidWindow);
    let liquidity_deadline_ms = end_ms
        .checked_add(self.liquidity_window_ms)
        .destroy_or!(abort EInvalidWindow);

    self.lifecycle = Lifecycle::Open;
    self.start_ms = start_ms;

    event::emit(PresaleOpened<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        start_ms,
        end_ms,
        liquidity_deadline_ms,
        uncapped_from_ms: self.uncapped_from_ms(),
        partner_id: self.partner_id,
    });

    transfer::share_object(self);
}

/// Replaces this sale's snapshot of Blast's rates before its window starts, while nobody can have
/// committed. Blast's token share is reapportioned against the buyers' sale allocation and its
/// raise share against the LP's Quote, each rounded down; every recipient keeps its amount.
public fun set_protocol_fees<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    admin_registry: &AdminRegistry,
    admin_cap: &AdminCap,
    raise_bps: Bps,
    token_bps: Bps,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
    clock: &Clock,
) {
    admin_registry.assert_admin_cap(admin_cap);
    assert!(self.lifecycle == Lifecycle::Open, EInvalidLifecycle);
    assert!(clock.timestamp_ms() < self.start_ms, EPresaleStarted);
    let protocol_fees = fee_policy::protocol_fees(
        raise_bps,
        token_bps,
        lp_fee_meme_bps,
        lp_fee_quote_bps,
    );
    assert!(protocol_fees != self.protocol_fees, EProtocolFeesUnchanged);

    // Blast's Quote comes out of the raise left after the recipients', whose rest the LP keeps;
    // its tokens come out of its own and the buyers' allocations, whose rest the buyers keep.
    let unallocated_raise = self.raise_target - total_amount(&self.raise_payouts);
    let unallocated_tokens = self.token_allocation + self.protocol_tokens.value();
    let protocol_quote = self.raise_target.mul_div(raise_bps.value(), bps::denominator());
    let protocol_tokens = self.token_supply().mul_div(token_bps.value(), bps::denominator());
    assert!(protocol_quote < unallocated_raise, EInvalidRaiseAllocation);
    assert!(protocol_tokens < unallocated_tokens, EInvalidTokenAllocation);
    assert_seedable_price(self.liquidity_tokens.value(), unallocated_raise - protocol_quote);

    self.sale_tokens.join(self.protocol_tokens.withdraw_all());
    self.protocol_tokens.join(self.sale_tokens.split(protocol_tokens));
    self.token_allocation = unallocated_tokens - protocol_tokens;
    self.protocol_quote = protocol_quote;
    self.protocol_fees = protocol_fees;

    event::emit(ProtocolFeesChanged<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        protocol_raise_bps: raise_bps.value(),
        protocol_token_bps: token_bps.value(),
        protocol_lp_fee_meme_bps: lp_fee_meme_bps.value(),
        protocol_lp_fee_quote_bps: lp_fee_quote_bps.value(),
        protocol_quote,
        protocol_tokens,
        token_allocation: self.token_allocation,
    });
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

/// Locks Quote from an allowlisted wallet after verifying its Merkle-committed cap,
/// returning whatever a hard cap could not accept.
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
    assert!(clock.timestamp_ms() >= self.uncapped_from_ms(), EUncappedPhaseNotOpen);

    let (max_participants, min_commitment) = anyone_limits(self.uncapped.destroy_some());
    let no_wallet_cap = std::u64::max_value!();

    self.record_commitment(quote_in, no_wallet_cap, max_participants, min_commitment, clock, ctx)
}

/// Fixes the fill after the commitment window. Underfunded sales become fully
/// refundable. Anyone may settle.
public fun settle<SaleToken, Quote>(self: &mut Presale<SaleToken, Quote>, clock: &Clock) {
    assert!(self.lifecycle == Lifecycle::Open, EInvalidLifecycle);
    assert!(clock.timestamp_ms() >= self.end_ms(), EPresaleNotEnded);

    if (self.total_commitments < self.raise_target) {
        self.cancel();
    } else {
        self.lifecycle = Lifecycle::Funded;

        event::emit(PresaleFunded<SaleToken, Quote> {
            presale_id: self.id.to_inner(),
            total_commitments: self.total_commitments,
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
        clock.timestamp_ms() >= self.liquidity_deadline_ms(),
        ELiquidityDeadlineNotReached,
    );

    self.cancel();
}

/// Delivers one participant's pro-rata tokens and overflow Quote after migration,
/// or its full Quote after cancellation. Under participant vesting, the tokens are
/// locked in a shared irrevocable linear schedule starting at this claim instead of
/// paid out; the Quote refund is always paid at once. Anyone may relay; the final
/// claim receives the bounded integer-rounding remainder.
public fun claim<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    participant: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(
        self.lifecycle == Lifecycle::Migrated || self.lifecycle == Lifecycle::Cancelled,
        EInvalidLifecycle,
    );

    let key = CommitmentKey(participant);
    assert!(self.id.has_dynamic_field(key), ENoCommitment);

    let Commitment { quote: commitment, .. } = self.id.remove_dynamic_field<_, Commitment>(key);
    let tokens = self.claimable_tokens(commitment);
    let quote_refund = self.refundable_quote(commitment);
    let payout = RecipientPayout {
        recipient: participant,
        amount: tokens,
        vesting: self.participant_vesting,
    };

    self.participants = self.participants - 1;
    let vesting_id = self.sale_tokens.pay_or_vest(payout, clock, ctx);
    self.quote.pay(quote_refund, participant, ctx);

    event::emit(Claimed<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        participant,
        wallet_commitment: commitment,
        tokens,
        quote_refund,
        remaining_participants: self.participants,
        vesting_id,
    });
}

/// Pays Blast and the raise recipients their shares and releases every token
/// recipient's tokens at once, locking each vesting share in its own shared irrevocable
/// schedule starting now, then releases the rest of the raise and the
/// LP-token allocation only to the configured migrator, the holder of the witness the sale was
/// created with. A sale naming a Blast partner holds Blast's shares instead, for `pay_partner`.
/// Anyone may call that migrator at any time until the sale is cancelled; its pool creation
/// remains atomic with this state transition.
public fun migrate<SaleToken, Quote, MigrationWitness: drop>(
    self: &mut Presale<SaleToken, Quote>,
    fee_policy: &FeePolicy,
    _: MigrationWitness,
    clock: &Clock,
    ctx: &mut TxContext,
): (Balance<SaleToken>, Balance<Quote>) {
    assert!(self.lifecycle == Lifecycle::Funded, EInvalidLifecycle);
    assert!(
        self.migration_witness == type_name::with_original_ids<MigrationWitness>(),
        EWrongMigrationWitness,
    );

    let mut quote = self.quote.split(self.raise_target);
    let protocol_quote = quote.split(self.protocol_quote);
    let liquidity_tokens = self.liquidity_tokens.withdraw_all();
    let recipient_tokens = self.recipient_tokens.value();

    if (self.partner_id.is_none()) {
        self.pay_protocol_fees(protocol_quote, 0, fee_policy.destination(), ctx);
    } else {
        self.unpaid_protocol_quote.fill(protocol_quote);
    };
    self.pay_raise_allocations(&mut quote, clock, ctx);
    self.release_recipient_tokens(clock, ctx);
    self.lifecycle = Lifecycle::Migrated;

    event::emit(PresaleMigrated<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        migration_witness: self.migration_witness,
        liquidity_quote: quote.value(),
        liquidity_tokens: liquidity_tokens.value(),
        recipient_tokens,
    });

    (liquidity_tokens, quote)
}

/// Pays a migrated sale's Blast partner its share of Blast's raise share, rounded down so Blast
/// keeps the remainder, and pays Blast the rest of it and its token share at the `FeePolicy`'s
/// current destination. The partner's share is the one in force now. Anyone may call it once
/// after migration: both recipients are fixed.
public fun pay_partner<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    fee_policy: &FeePolicy,
    partner: &Partner,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(self.partner_id.contains(&object::id(partner)), EWrongPartner);
    assert!(self.unpaid_protocol_quote.is_some(), ENoPartnerPayout);

    let mut quote = self.unpaid_protocol_quote.extract();
    let partner_quote = partner.pay(&mut quote, clock);

    self.pay_protocol_fees(quote, partner_quote, fee_policy.destination(), ctx);
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

public(package) fun assert_cap<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    cap: &PresaleCap,
) {
    assert!(object::id(cap) == self.presale_cap_id, EWrongPresaleCap);
}

/// The tick spacing and fee rate of the pool migration creates.
public(package) fun pool_tier<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): (u32, u64) {
    (self.tick_spacing, self.pool_fee_rate)
}

/// The presale and creator-capability IDs, the LP-fee split, and Blast's rates its vault inherits.
public(package) fun vault_config<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
): (ID, ID, FeeSplit, ProtocolFees) {
    (self.id.to_inner(), self.presale_cap_id, self.fee_split, self.protocol_fees)
}

/// Splits one fee amount into each recipient's share followed by the holder-reward
/// share, assigning every atomic unit exactly once. Remainder units go to the largest
/// fractional remainders; equal remainders favor the earlier share, so fee recipients
/// win ties over the holder-reward share and earlier recipients over later ones.
public(package) fun apportion_fee(self: &FeeSplit, amount: u64): vector<u64> {
    let mut shares = self.shares.map_ref!(|share| share.bps);
    shares.push_back(self.holder_rewards_bps);

    apportion(shares, amount)
}

/// Each fee recipient's share, in payment order.
public(package) fun shares(self: &FeeSplit): &vector<RecipientShare> {
    &self.shares
}

/// The holder-reward share of every collected fee.
public(package) fun holder_rewards_bps(self: &FeeSplit): Bps {
    self.holder_rewards_bps
}

/// Each share's recipient, in order.
public(package) fun recipients_of(shares: &vector<RecipientShare>): vector<address> {
    shares.map_ref!(|share| share.recipient)
}

/// Each share's BPS, in order.
public(package) fun bps_of(shares: &vector<RecipientShare>): vector<u64> {
    shares.map_ref!(|share| share.bps.value())
}

/// Transfers `amount` split from `self` to `recipient`, skipping empty shares.
public(package) fun pay<Asset>(
    self: &mut Balance<Asset>,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    if (amount > 0) transfer::public_transfer(self.split(amount).into_coin(ctx), recipient);
}

// === Private Functions ===

fun assert_open<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, clock: &Clock) {
    assert!(self.lifecycle == Lifecycle::Open, EInvalidLifecycle);
    assert!(clock.timestamp_ms() >= self.start_ms, EPresaleNotStarted);
    assert!(clock.timestamp_ms() < self.end_ms(), EPresaleEnded);
}

// Windows, derived from the start `share` fixed: it proved both sums below fit in u64.

/// The exclusive end of the commitment window.
fun end_ms<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): u64 {
    self.start_ms + self.duration_ms
}

/// From when anyone may cancel a funded sale that has not migrated.
fun liquidity_deadline_ms<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): u64 {
    self.end_ms() + self.liquidity_window_ms
}

/// When wallet caps lift: the uncapped phase's offset into the window, which `new` bounds below
/// the duration, or the end of a sale without one.
fun uncapped_from_ms<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): u64 {
    self.uncapped.map_ref!(|phase| self.start_ms + phase.starts_after_ms).destroy_or!(self.end_ms())
}

/// Largest-remainder apportionment. Shares must sum to 10,000 BPS.
fun apportion(shares: vector<Bps>, total: u64): vector<u64> {
    let denominator = bps::denominator() as u128;
    let scaled_shares = shares.map!(|share| (total as u128) * (share.value() as u128));
    let mut amounts = scaled_shares.map_ref!(|scaled| (*scaled / denominator) as u64);
    let remainders = scaled_shares.map!(|scaled| scaled % denominator);

    // Hand out the leftover units to the largest remainders, earlier shares first on ties.
    let mut by_remainder = vector::tabulate!(remainders.length(), |i| i);
    by_remainder.insertion_sort_by!(|a, b| {
        remainders[*a] > remainders[*b] || (remainders[*a] == remainders[*b] && *a <= *b)
    });
    let leftover = total - amounts.fold!(0, |sum, amount| sum + amount);
    leftover.do!(|rank| {
        let amount = &mut amounts[by_remainder[rank]];
        *amount = *amount + 1;
    });

    amounts
}

// Presale creation

/// Raise allocations: distinct recipients that, with Blast's share, leave the LP part of the raise.
fun assert_raise_allocations(raise_allocations: &vector<RecipientShare>, protocol_raise_bps: Bps) {
    assert!(
        valid_shares(raise_allocations, MAX_RECIPIENTS)
            && total_bps(raise_allocations) + protocol_raise_bps.value() < bps::denominator(),
        EInvalidRaiseAllocation,
    );
}

/// Token allocations: distinct recipients totalling exactly 10,000 BPS with the sale's, the LP's,
/// and Blast's shares.
fun assert_token_allocations(
    token_supply: u64,
    token_allocation_bps: Bps,
    liquidity_token_allocation_bps: Bps,
    protocol_token_bps: Bps,
    recipient_allocations: &vector<RecipientShare>,
) {
    assert!(
        token_supply > 0
            && token_allocation_bps.value() > 0
            && liquidity_token_allocation_bps.value() > 0
            && valid_shares(recipient_allocations, MAX_RECIPIENTS),
        EInvalidTokenAllocation,
    );
    assert!(
        total_bps(recipient_allocations)
            + token_allocation_bps.value()
            + liquidity_token_allocation_bps.value()
            + protocol_token_bps.value() == bps::denominator(),
        EInvalidTokenAllocation,
    );
}

/// Whether there are at most `max` shares, each naming a distinct nonzero recipient and taking
/// positive BPS.
fun valid_shares(shares: &vector<RecipientShare>, max: u64): bool {
    shares.length() <= max
        && shares.all!(|share| {
            share.recipient != @0x0
                && share.bps.value() > 0
                // ponytail: O(n²) duplicate validation is bounded by `max`.
                && shares.count!(|other| other.recipient == share.recipient) == 1
        })
}

/// The BPS these shares take in total.
fun total_bps(shares: &vector<RecipientShare>): u64 {
    (*shares).fold!(0, |sum, share| sum + share.bps.value())
}

/// The amount these payouts take in total.
fun total_amount(payouts: &vector<RecipientPayout>): u64 {
    (*payouts).fold!(0, |sum, payout| sum + payout.amount)
}

/// The phase starts inside the window, and an open-to-anyone phase admits at least the
/// policy's wallets while its minimum over the slots held to it still reaches the raise.
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
                reaches(min_commitment, eligibility.slots_at_minimum(max_participants), raise_target),
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

/// The slots of an open-to-anyone phase whose commitments are held to the phase minimum: every
/// slot under an open policy, whose wallets already meet a minimum that reaches the raise, and
/// the slots beyond the leaf count under an allowlist, whose wallets may commit any positive
/// amount. The phase bound is at least the policy's, so the subtraction cannot underflow.
fun slots_at_minimum(self: EligibilityPolicy, max_participants: u64): u64 {
    match (self) {
        EligibilityPolicy::Open { .. } => max_participants,
        EligibilityPolicy::Allowlisted { leaf_count, .. } => max_participants - leaf_count,
    }
}

/// Whether filling every open participant slot at the minimum commitment funds the raise.
/// Allowlist caps are committed off chain, so only the open policy is checked.
fun can_reach(self: EligibilityPolicy, raise_target: u64): bool {
    match (self) {
        EligibilityPolicy::Open { max_participants, min_commitment, .. } => {
            reaches(min_commitment, max_participants, raise_target)
        },
        EligibilityPolicy::Allowlisted { .. } => true,
    }
}

/// Whether `max_participants` wallets each committing `min_commitment` reach `raise_target`.
fun reaches(min_commitment: u64, max_participants: u64, raise_target: u64): bool {
    (min_commitment as u128) * (max_participants as u128) >= (raise_target as u128)
}

/// The LP's tokens and Quote seed a price both venues can pool.
fun assert_seedable_price(liquidity_tokens: u64, liquidity_quote: u64) {
    assert!(
        migration_math::is_seedable(
            migration_math::sqrt_price_x64(liquidity_tokens, liquidity_quote, true),
        ),
        EUnseedablePrice,
    );
}

/// Apportions the supply so every atomic unit belongs to exactly one allocation, returning the
/// presale and LP allocations, Blast's allocation, and each recipient's payout. The presale, LP,
/// and every recipient must receive a positive amount.
fun apportion_supply(
    token_supply: u64,
    token_allocation_bps: Bps,
    liquidity_token_allocation_bps: Bps,
    protocol_token_bps: Bps,
    recipient_allocations: &vector<RecipientShare>,
): (u64, u64, u64, vector<RecipientPayout>) {
    // Apportioned in this order: the presale, the LP, Blast, then each recipient.
    let mut shares = vector[token_allocation_bps, liquidity_token_allocation_bps, protocol_token_bps];
    recipient_allocations.do_ref!(|allocation| shares.push_back(allocation.bps));
    let amounts = apportion(shares, token_supply);

    let (token_allocation, liquidity_token_allocation) = (amounts[0], amounts[1]);
    let recipient_payouts = payouts(recipient_allocations, &amounts, 3);
    assert!(
        token_allocation > 0
            && liquidity_token_allocation > 0
            && recipient_payouts.all!(|payout| payout.amount > 0),
        EInvalidTokenAllocation,
    );

    (token_allocation, liquidity_token_allocation, amounts[2], recipient_payouts)
}

/// Apportions the raise the same way among the recipients, Blast, and the LP, which keeps the
/// last share, returning each recipient's payout, Blast's Quote, and the LP's Quote. Every
/// recipient and the LP must receive a positive amount.
fun apportion_raise(
    raise_allocations: &vector<RecipientShare>,
    protocol_raise_bps: Bps,
    raise_target: u64,
): (vector<RecipientPayout>, u64, u64) {
    // Apportioned in this order: each recipient, Blast, then the LP, which keeps the rest.
    let allocated_bps = total_bps(raise_allocations) + protocol_raise_bps.value();
    let mut shares = raise_allocations.map_ref!(|allocation| allocation.bps);
    shares.push_back(protocol_raise_bps);
    shares.push_back(bps::new(bps::denominator() - allocated_bps));
    let amounts = apportion(shares, raise_target);

    let raise_payouts = payouts(raise_allocations, &amounts, 0);
    let protocol_quote = amounts[raise_allocations.length()];
    let liquidity_quote = amounts[raise_allocations.length() + 1];
    assert!(
        raise_payouts.all!(|payout| payout.amount > 0) && liquidity_quote > 0,
        EInvalidRaiseAllocation,
    );

    (raise_payouts, protocol_quote, liquidity_quote)
}

/// Pairs each allocation's recipient with its apportioned amount, read from `amounts` starting
/// at `first`.
fun payouts(
    allocations: &vector<RecipientShare>,
    amounts: &vector<u64>,
    first: u64,
): vector<RecipientPayout> {
    vector::tabulate!(allocations.length(), |i| RecipientPayout {
        recipient: allocations[i].recipient,
        amount: amounts[first + i],
        vesting: allocations[i].vesting,
    })
}

/// Each share's vesting terms, in order; `none` where it is paid out.
fun vesting_terms_of(shares: &vector<RecipientShare>): vector<Option<VestingTerms>> {
    shares.map_ref!(|share| share.vesting)
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

// Fee changes

/// The complete supply, all of it still escrowed before the window starts.
fun token_supply<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): u64 {
    self.sale_tokens.value()
        + self.liquidity_tokens.value()
        + self.recipient_tokens.value()
        + self.protocol_tokens.value()
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
    let uncapped = clock.timestamp_ms() >= self.uncapped_from_ms();
    let (max_participants, hard_cap) = self.participant_limits(uncapped, max_participants);
    let accepted_quote = self.acceptable_quote(quote_in.value(), hard_cap);
    let fills_raise = hard_cap && self.total_commitments + accepted_quote == self.raise_target;

    let key = CommitmentKey(ctx.sender());
    let is_new_participant = !self.id.has_dynamic_field(key);
    let wallet_commitment = self
        .commitment_or_empty(key, wallet_cap)
        .add_within_cap(accepted_quote, wallet_cap, uncapped);

    // The commitment that exactly fills a hard cap may be smaller than the minimum.
    assert!(wallet_commitment >= min_commitment || fills_raise, EBelowMinimumCommitment);
    assert!(
        !is_new_participant || self.participants < max_participants,
        EParticipantCapacityReached,
    );
    let total_commitments = self
        .total_commitments
        .checked_add(accepted_quote)
        .destroy_or!(abort ETotalCommitmentOverflow);

    self.store_commitment(key, wallet_commitment, wallet_cap);
    self.total_commitments = total_commitments;
    self.quote.join(quote_in.split(accepted_quote, ctx).into_balance());

    event::emit(Committed<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        quote: accepted_quote,
        wallet_commitment,
        total_commitments,
        participants: self.participants,
    });

    quote_in
}

/// The wallet cap, participant bound, and minimum commitment of an open policy.
fun open_limits(policy: EligibilityPolicy): (u64, u64, u64) {
    match (policy) {
        EligibilityPolicy::Open { wallet_cap, max_participants, min_commitment } => {
            (wallet_cap, max_participants, min_commitment)
        },
        EligibilityPolicy::Allowlisted { .. } => abort EWrongEligibilityPolicy,
    }
}

/// The participant bound and minimum commitment of an uncapped phase open to anyone.
fun anyone_limits(phase: UncappedPhase): (u64, u64) {
    match (phase.access) {
        UncappedAccess::Anyone { max_participants, min_commitment } => {
            (max_participants, min_commitment)
        },
        UncappedAccess::Eligible => abort EUncappedPhaseNotOpen,
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
fun acceptable_quote<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    offered: u64,
    hard_cap: bool,
): u64 {
    if (!hard_cap) return offered;

    assert!(self.total_commitments < self.raise_target, EPresaleFilled);
    offered.min(self.raise_target - self.total_commitments)
}

/// The wallet's commitment so far, or an empty one under `wallet_cap` before its first commit.
fun commitment_or_empty<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    key: CommitmentKey,
    wallet_cap: u64,
): Commitment {
    if (self.id.has_dynamic_field(key)) *dynamic_field::borrow(&self.id, key)
    else Commitment { quote: 0, wallet_cap }
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

/// The allowlist's leaf count, after proving `wallet_cap` is `wallet`'s committed cap at `index`.
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
            assert!(wallet_cap > 0, EInvalidEligibilityProof);

            let digest = allowlist_leaf(index, wallet, wallet_cap);
            assert!(merkle_tree::verify(root, digest, index, leaf_count, proof), EInvalidEligibilityProof);

            leaf_count
        },
    }
}

/// The domain-separated digest of one allowlist leaf.
fun allowlist_leaf(index: u64, wallet: address, wallet_cap: u64): vector<u8> {
    let mut bytes = b"\x00blast-presale-v1";
    bytes.append(bcs::to_bytes(&index));
    bytes.append(bcs::to_bytes(&wallet));
    bytes.append(bcs::to_bytes(&wallet_cap));
    hash::blake2b256(&bytes)
}

// Claims

/// The sale tokens one commitment claims: none unless the sale migrated, otherwise its pro-rata
/// share of the token allocation, or everything left on the last claim.
fun claimable_tokens<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, commitment: u64): u64 {
    if (self.lifecycle != Lifecycle::Migrated) return 0;
    if (self.is_last_claim()) return self.sale_tokens.value();

    self.token_allocation.mul_div(commitment, self.total_commitments)
}

/// The Quote one commitment gets back: its pro-rata share of every commitment after a
/// cancellation, or of the overflow above the raise after a migration; everything left on the
/// last claim.
fun refundable_quote<SaleToken, Quote>(self: &Presale<SaleToken, Quote>, commitment: u64): u64 {
    if (self.is_last_claim()) return self.quote.value();

    let refund_pool = if (self.lifecycle == Lifecycle::Cancelled) self.total_commitments
    else self.total_commitments - self.raise_target;

    refund_pool.mul_div(commitment, self.total_commitments)
}

/// Whether the claim in progress, whose record `claim` has already removed, is the final one: it
/// takes everything left so the integer-rounding remainder is never stranded.
fun is_last_claim<SaleToken, Quote>(self: &Presale<SaleToken, Quote>): bool {
    self.participants == 1
}

// Migration

/// Pays Blast `quote`, what it keeps of its raise share after its partner's `partner_quote`, and
/// its share of the supply at `destination`.
fun pay_protocol_fees<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    mut quote: Balance<Quote>,
    partner_quote: u64,
    destination: address,
    ctx: &mut TxContext,
) {
    let quote_amount = quote.value();
    let tokens = self.protocol_tokens.value();

    quote.pay(quote_amount, destination, ctx);
    quote.destroy_zero();
    self.protocol_tokens.pay(tokens, destination, ctx);

    event::emit(ProtocolFeesPaid<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        destination,
        quote: quote_amount,
        tokens,
        partner_quote,
    });
}

/// Releases each raise recipient its share out of `quote`, leaving the LP's share.
fun pay_raise_allocations<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
    quote: &mut Balance<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.raise_payouts.do_ref!(|payout| {
        event::emit(RaiseAllocated<SaleToken, Quote> {
            presale_id: self.id.to_inner(),
            recipient: payout.recipient,
            quote: payout.amount,
            vesting_id: quote.pay_or_vest(*payout, clock, ctx),
        });
    });
}

/// Releases every escrowed recipient token to its configured recipient.
fun release_recipient_tokens<SaleToken, Quote>(
    self: &mut Presale<SaleToken, Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    self.recipient_payouts.length().do!(|i| {
        let payout = self.recipient_payouts[i];
        event::emit(RecipientAllocated<SaleToken, Quote> {
            presale_id: self.id.to_inner(),
            recipient: payout.recipient,
            tokens: payout.amount,
            vesting_id: self.recipient_tokens.pay_or_vest(payout, clock, ctx),
        });
    });
}

/// Pays one payout out of `self` to its recipient or, when a positive amount vests, locks it in a
/// shared irrevocable linear schedule starting now and returns that schedule's ID. A schedule
/// cannot hold nothing, so an empty payout creates none.
fun pay_or_vest<T>(
    self: &mut Balance<T>,
    payout: RecipientPayout,
    clock: &Clock,
    ctx: &mut TxContext,
): Option<ID> {
    let RecipientPayout { recipient, amount, vesting } = payout;
    if (vesting.is_none() || amount == 0) {
        self.pay(amount, recipient, ctx);
        return option::none()
    };

    let VestingTerms { cliff_ms, period_ms, periods } = vesting.destroy_some();
    let schedule = linear_vesting::new_irrevocable(
        self.split(amount).into_coin(ctx),
        recipient,
        clock.timestamp_ms(),
        cliff_ms,
        period_ms,
        periods,
        clock,
        ctx,
    );
    let schedule_id = object::id(&schedule);

    schedule.share();

    option::some(schedule_id)
}

// Cancellation

fun cancel<SaleToken, Quote>(self: &mut Presale<SaleToken, Quote>) {
    self.lifecycle = Lifecycle::Cancelled;

    event::emit(PresaleCancelled<SaleToken, Quote> {
        presale_id: self.id.to_inner(),
        total_commitments: self.total_commitments,
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
public fun vesting_terms_for_testing(share: &RecipientShare): Option<VestingTerms> {
    share.vesting
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
        event.pool_fee_rate,
        event.fee_recipients,
        event.fee_recipient_bps,
        event.holder_rewards_bps,
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
): (vector<u64>, u64, u64) {
    (
        vector[
            event.protocol_raise_bps,
            event.protocol_token_bps,
            event.protocol_lp_fee_meme_bps,
            event.protocol_lp_fee_quote_bps,
        ],
        event.protocol_quote,
        event.protocol_tokens,
    )
}

#[test_only]
public fun created_vesting_fields<SaleToken, Quote>(
    event: &PresaleCreated<SaleToken, Quote>,
): (Option<VestingTerms>, vector<Option<VestingTerms>>, vector<Option<VestingTerms>>) {
    (event.participant_vesting, event.recipient_vesting, event.raise_recipient_vesting)
}

#[test_only]
public fun protocol_fees_changed_fields<SaleToken, Quote>(
    event: &ProtocolFeesChanged<SaleToken, Quote>,
): (ID, vector<u64>, u64, u64, u64) {
    (
        event.presale_id,
        vector[
            event.protocol_raise_bps,
            event.protocol_token_bps,
            event.protocol_lp_fee_meme_bps,
            event.protocol_lp_fee_quote_bps,
        ],
        event.protocol_quote,
        event.protocol_tokens,
        event.token_allocation,
    )
}

#[test_only]
public fun opened_partner_id<SaleToken, Quote>(
    event: &PresaleOpened<SaleToken, Quote>,
): Option<ID> {
    event.partner_id
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
        event.total_commitments,
        event.accepted_quote,
        event.refundable_quote,
        event.token_allocation,
    )
}

#[test_only]
public fun cancelled_fields<SaleToken, Quote>(
    event: &PresaleCancelled<SaleToken, Quote>,
): (ID, u64, u64) {
    (event.presale_id, event.total_commitments, event.refundable_quote)
}

#[test_only]
public fun migrated_fields<SaleToken, Quote>(
    event: &PresaleMigrated<SaleToken, Quote>,
): (ID, TypeName, u64, u64, u64) {
    (
        event.presale_id,
        event.migration_witness,
        event.liquidity_quote,
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
public fun raise_allocated_vesting_id<SaleToken, Quote>(
    event: &RaiseAllocated<SaleToken, Quote>,
): Option<ID> {
    event.vesting_id
}

#[test_only]
public fun recipient_allocated_fields<SaleToken, Quote>(
    event: &RecipientAllocated<SaleToken, Quote>,
): (ID, address, u64) {
    (event.presale_id, event.recipient, event.tokens)
}

#[test_only]
public fun recipient_allocated_vesting_id<SaleToken, Quote>(
    event: &RecipientAllocated<SaleToken, Quote>,
): Option<ID> {
    event.vesting_id
}

#[test_only]
public fun protocol_fees_paid_fields<SaleToken, Quote>(
    event: &ProtocolFeesPaid<SaleToken, Quote>,
): (ID, address, u64, u64) {
    (event.presale_id, event.destination, event.quote, event.tokens)
}

#[test_only]
public fun protocol_fees_paid_partner_quote<SaleToken, Quote>(
    event: &ProtocolFeesPaid<SaleToken, Quote>,
): u64 {
    event.partner_quote
}

#[test_only]
/// Blast's raise share a partnered migration holds for `pay_partner`, if it still does.
public fun unpaid_protocol_quote_for_testing<SaleToken, Quote>(
    self: &Presale<SaleToken, Quote>,
): Option<u64> {
    self.unpaid_protocol_quote.map_ref!(|quote| quote.value())
}

#[test_only]
public fun claim_fields<SaleToken, Quote>(
    event: &Claimed<SaleToken, Quote>,
): (ID, address, u64, u64, u64, u64) {
    (
        event.presale_id,
        event.participant,
        event.wallet_commitment,
        event.tokens,
        event.quote_refund,
        event.remaining_participants,
    )
}

#[test_only]
public fun claimed_vesting_id<SaleToken, Quote>(event: &Claimed<SaleToken, Quote>): Option<ID> {
    event.vesting_id
}

// === Events ===

/// A presale was created with fully funded token allocations.
public struct PresaleCreated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    presale_cap_id: ID,
    treasury_cap_id: ID,
    token_supply: u64,
    token_allocation_bps: u64,
    participant_vesting: Option<VestingTerms>,
    liquidity_token_allocation_bps: u64,
    recipients: vector<address>,
    recipient_bps: vector<u64>,
    recipient_vesting: vector<Option<VestingTerms>>,
    burnable: bool,
    raise_target: u64,
    raise_recipients: vector<address>,
    raise_recipient_bps: vector<u64>,
    raise_recipient_vesting: vector<Option<VestingTerms>>,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    migration_witness: TypeName,
    tick_spacing: u32,
    pool_fee_rate: u64,
    fee_recipients: vector<address>,
    fee_recipient_bps: vector<u64>,
    holder_rewards_bps: u64,
    /// Blast's rates, snapshotted for this sale.
    protocol_raise_bps: u64,
    protocol_token_bps: u64,
    protocol_lp_fee_meme_bps: u64,
    protocol_lp_fee_quote_bps: u64,
    /// Blast's shares of the raise and of the supply, paid on migration.
    protocol_quote: u64,
    protocol_tokens: u64,
}

/// A presale was shared with these fixed commitment and liquidity windows and its Blast partner,
/// if any. Commitments open at `start_ms`, which may be later than the share.
public struct PresaleOpened<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    start_ms: u64,
    end_ms: u64,
    liquidity_deadline_ms: u64,
    uncapped_from_ms: u64,
    partner_id: Option<ID>,
}

/// Before the window started, the AdminCap replaced this sale's Blast rates, moving Blast's tokens
/// to or from the sale allocation and its Quote to or from the LP's.
public struct ProtocolFeesChanged<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    protocol_raise_bps: u64,
    protocol_token_bps: u64,
    protocol_lp_fee_meme_bps: u64,
    protocol_lp_fee_quote_bps: u64,
    /// Blast's shares of the raise and of the supply, paid on migration.
    protocol_quote: u64,
    protocol_tokens: u64,
    /// The tokens buyers now share pro rata.
    token_allocation: u64,
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
    total_commitments: u64,
    accepted_quote: u64,
    refundable_quote: u64,
    token_allocation: u64,
}

/// A presale became fully refundable without releasing Quote.
public struct PresaleCancelled<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    total_commitments: u64,
    refundable_quote: u64,
}

/// The raise left after Blast's and the recipients' shares, and the LP-token allocation,
/// entered the configured migrator.
public struct PresaleMigrated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    migration_witness: TypeName,
    liquidity_quote: u64,
    liquidity_tokens: u64,
    recipient_tokens: u64,
}

/// Blast received `quote` of its raise share and its `tokens` at `destination`, after the sale's
/// Blast partner took `partner_quote` of the raise share, which `PartnerPaid` also records.
public struct ProtocolFeesPaid<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    destination: address,
    quote: u64,
    tokens: u64,
    partner_quote: u64,
}

/// One configured recipient received its share of the raise, or the vesting schedule
/// `vesting_id` that holds it.
public struct RaiseAllocated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    recipient: address,
    quote: u64,
    vesting_id: Option<ID>,
}

/// One configured recipient received its immutable token allocation, or the vesting schedule
/// `vesting_id` that holds it.
public struct RecipientAllocated<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    recipient: address,
    tokens: u64,
    vesting_id: Option<ID>,
}

/// `participant` received its token allocation, or the vesting schedule `vesting_id` that holds
/// it, and its Quote refund, leaving `remaining_participants` wallets still to claim.
public struct Claimed<phantom SaleToken, phantom Quote> has copy, drop {
    presale_id: ID,
    participant: address,
    wallet_commitment: u64,
    tokens: u64,
    quote_refund: u64,
    remaining_participants: u64,
    vesting_id: Option<ID>,
}

// === Constants ===

/// Technical bound on the dynamic commitment records one presale may hold.
const MAX_PARTICIPANTS: u64 = 65_536;

/// Bounds the token and raise recipient lists, both paid in the one migration transaction.
const MAX_RECIPIENTS: u64 = 64;

/// Bounds the transfers one fee collection makes.
const MAX_FEE_RECIPIENTS: u64 = 16;

/// The shortest LP-migration window. Migration is permissionless, so a funded sale reaches its
/// refund exit only after a week in which nobody migrated it, and a sale that nobody settled by
/// its end cannot be settled and cancelled in one transaction inside that week.
const MIN_LIQUIDITY_WINDOW_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

/// A technical bound on a vesting schedule's duration: from any clock below 2^63 ms, about 292
/// million years, the schedule's end still fits in u64, so migration cannot overflow creating it.
const MAX_VESTING_DURATION_MS: u64 = 1 << 63;


// === Errors ===

#[error(code = 0)]
const EInvalidAssetPair: vector<u8> = b"The sale token and Quote type must differ.";

#[error(code = 1)]
const EInvalidRaiseTarget: vector<u8> = b"The raise target must be positive.";

#[error(code = 2)]
const EInvalidTokenAllocation: vector<u8> = b"The supply must be positive, and token allocations unique, positive, bounded, totalling exactly 10,000 BPS with Blast's share, and apportioning to positive amounts.";

#[error(code = 3)]
const EInvalidWindow: vector<u8> = b"The commitment window must be positive, the liquidity window at least seven days, and both must end within u64 milliseconds.";

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
const EInvalidFeeSplit: vector<u8> = b"Fee recipients must be unique, positive, unvested, bounded, and total 10,000 BPS with the holder-reward share.";

#[error(code = 19)]
const EWrongMigrationWitness: vector<u8> = b"The migrator does not match the venue fixed at presale creation.";


#[error(code = 20)]
const EBelowMinimumCommitment: vector<u8> = b"The wallet's total commitment is below the sale's minimum commitment.";

#[error(code = 21)]
const EUnreachableRaise: vector<u8> = b"The minimum commitment times the slots held to it, the participant bound of an open policy or the open-to-anyone phase slots beyond any allowlist, must reach the raise target.";

#[error(code = 22)]
const EUnseedablePrice: vector<u8> = b"The raise and LP-token allocation give a seed price the venues cannot pool.";

#[error(code = 23)]
const EInvalidUncappedPhase: vector<u8> = b"An uncapped phase must start inside the window, and an open-to-anyone phase needs a positive minimum and a participant bound between the policy's and 65,536.";

#[error(code = 24)]
const EUncappedPhaseNotOpen: vector<u8> = b"The presale has no uncapped phase open to any wallet, or it has not started.";

#[error(code = 25)]
const EPresaleFilled: vector<u8> = b"The hard-capped presale has already reached its raise.";

#[error(code = 26)]
const EInvalidRaiseAllocation: vector<u8> = b"Raise allocations must be unique, positive, bounded, leave the LP a share after Blast's, and apportion to positive amounts.";

#[error(code = 27)]
const EInvalidVestingTerms: vector<u8> = b"Vesting needs a positive period and period count, a cliff within its duration, and a duration of at most 2^63 milliseconds.";

#[error(code = 28)]
const EPresaleNotStarted: vector<u8> = b"The presale commitment window has not started.";

#[error(code = 29)]
const EPresaleStarted: vector<u8> = b"A presale's Blast rates can change only before its commitment window starts.";

#[error(code = 30)]
const EProtocolFeesUnchanged: vector<u8> = b"A presale fee update must change its stored rates.";

#[error(code = 31)]
const EWrongPartner: vector<u8> = b"The partner is not the one this presale named at creation.";

#[error(code = 32)]
const ENoPartnerPayout: vector<u8> = b"The presale holds no partner payout: it has not migrated, or its partner was already paid.";

// === Imports ===

use blast_fun_vesting::blast_fun_linear_vesting as linear_vesting;

use blast_partners::blast_partners::Partner;

use blast_presale::{
    blast_presale_admin::{AdminCap, AdminRegistry},
    bps::{Self, Bps},
    creation_policy::CreationPolicy,
    fee_policy::{Self, FeePolicy, ProtocolFees},
    merkle_tree,
    migration_math,
};

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
use fun pay_or_vest as Balance.pay_or_vest;

use fun bps_of as vector.bps;
use fun recipients_of as vector.recipients;
use fun vesting_terms_of as vector.vesting_terms;

use fun dynamic_field::add as UID.add_dynamic_field;
use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;
use fun dynamic_field::exists as UID.has_dynamic_field;
use fun dynamic_field::remove as UID.remove_dynamic_field;
