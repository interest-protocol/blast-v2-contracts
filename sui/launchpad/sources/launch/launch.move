// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the launch's abort location.
#[allow(lint(abort_without_constant))]
/// Launch construction, the bonding curve, the migration hand-off, and the owner proof.
module blast_fun::launch;

// === Constants ===

/// Initial delay for each creator-cap reassignment: 48 hours in milliseconds.
const DEFAULT_CAP_REASSIGNMENT_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;

// === Public Types ===

/// Shared singleton every launch's object ID derives from, so a client finds a coin's one launch
/// from the coin type alone.
public struct LaunchRegistry has key {
    id: UID,
}

/// Derives the one launch of `Meme` from the registry.
public struct LaunchKey<phantom Meme>() has copy, drop, store;

public enum Lifecycle has copy, drop, store {
    OpeningRound,
    Live,
    MigrationReady,
    Migrated,
}

/// Dynamic-field name of one bidder's undelivered opening-round Quote.
public struct OpeningRoundBidKey(address) has copy, drop, store;

/// One launch: its curve, its settings, and custody until migration.
///
/// A launch with an opening round starts in `OpeningRound`. Until `opening_round_ms` after share,
/// Quote joins one pot and nothing trades; settling buys from the curve once with the whole pot, and
/// each bidder is delivered its pro-rata share of the Meme bought and of any Quote refunded.
public struct Launch<phantom Meme, phantom Quote> has key {
    id: UID,
    lifecycle: Lifecycle,
    public_start_ms: Option<u64>,
    opening_round_ms: u64,
    /// Total Quote of the opening-round bids not yet delivered.
    opening_round_bids: u64,
    /// The pot until settlement, then the Quote it left to refund.
    opening_round_quote: Balance<Quote>,
    opening_round_meme: Balance<Meme>,
    sell_burn_bps: Bps,
    virtual_quote: u64,
    graduation_target: u64,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    /// The venue witness type the launch's liquidity migrates to.
    venue: TypeName,
    lp_fee_split: FeeSplit,
    atomic_supply: u64,
    meme_reserve: Balance<Meme>,
    real_quote_reserve: Balance<Quote>,
    pending_burn: Balance<Meme>,
    allocation_plan: AllocationPlan,
    allocated_meme: Balance<Meme>,
    /// Blast's fees: its trade-fee share, the creation fee, and the one-time migration fee.
    protocol_fees: Ledger<Meme, Quote>,
    /// The creator's trade-fee share, claimed with the curve-fee cap.
    creator_meme_fees: Balance<Meme>,
    creator_quote_fees: Balance<Quote>,
    metadata_cap: MetadataCap<Meme>,
    curve_fee_cap_reassignment: DelayedAction<CurveFeeCapReassignment, address>,
    creator_metadata_cap_reassignment: DelayedAction<CreatorMetadataCapReassignment, address>,
    creator: Option<CreatorRecipient>,
    curve_fee_cap_id: Option<ID>,
    creator_metadata_cap_id: Option<ID>,
    /// The Blast partner named at creation, paid its share of every fee Blast takes on this
    /// launch. It never changes.
    partner_id: Option<ID>,
}

/// Keys the curve-fee cap reassignment's delayed lifecycle; its action is the recipient.
public struct CurveFeeCapReassignment() has copy, drop, store;

/// Keys the metadata cap reassignment's delayed lifecycle; its action is the recipient.
public struct CreatorMetadataCapReassignment() has copy, drop, store;

/// Hot potato from `new` to `finalize`, collecting the creator's settings.
public struct LaunchInitializer<phantom Meme, phantom Quote> {
    ticket: LaunchTicket<Meme>,
    treasury_cap: TreasuryCap<Meme>,
    venue: TypeName,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    virtual_quote: Option<u64>,
    graduation_target: Option<u64>,
    allocation_plan: Option<AllocationPlan>,
    lp_fee_split: Option<FeeSplit>,
    opening_round_ms: u64,
    partner_id: Option<ID>,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(LaunchRegistry { id: object::new(ctx) });
}

// === Public Functions ===

/// Starts a launch whose liquidity migrates to the venue that issued `venue_ticket` after
/// preparing the coin with `treasury_cap`. The Quote, the venue, and the decimals must be admitted.
public fun new<Meme, Quote>(
    ticket: LaunchTicket<Meme>,
    treasury_cap: TreasuryCap<Meme>,
    package_version: &PackageVersion<BLAST_FUN>,
    config: &LaunchConfig,
    venue_ticket: VenueTicket<Meme, Quote>,
): LaunchInitializer<Meme, Quote> {
    package_version.assert_current(constants::version!());

    package_version.assert_not_paused(constants::create_pause_bit!());
    assert!(
        type_name::with_original_ids<Meme>() != type_name::with_original_ids<Quote>(),
        blast_fun::errors::invalid_meme_quote_pair!(),
    );
    let venue = venue_ticket.redeem_ticket();
    let (quote_fee_bps, meme_fee_bps) = config.snapshot_for_launch<Quote>(venue, ticket.decimals());

    LaunchInitializer {
        ticket,
        treasury_cap,
        venue,
        quote_fee_bps,
        meme_fee_bps,
        virtual_quote: option::none(),
        graduation_target: option::none(),
        allocation_plan: option::none(),
        lp_fee_split: option::none(),
        opening_round_ms: 0,
        partner_id: option::none(),
    }
}

/// Sets the virtual Quote reserve the curve starts from, which prices the first purchase.
public fun set_virtual_quote<Meme, Quote>(
    self: &mut LaunchInitializer<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    virtual_quote: u64,
) {
    package_version.assert_current(constants::version!());

    self.virtual_quote = option::some(virtual_quote);
}

/// Sets the Quote reserve at which the curve closes.
public fun set_graduation_target<Meme, Quote>(
    self: &mut LaunchInitializer<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    graduation_target: u64,
) {
    package_version.assert_current(constants::version!());

    self.graduation_target = option::some(graduation_target);
}

public fun set_allocation_plan<Meme, Quote>(
    self: &mut LaunchInitializer<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    allocation_plan: AllocationPlan,
) {
    package_version.assert_current(constants::version!());

    self.allocation_plan = option::some(allocation_plan);
}

public fun set_lp_fee_split<Meme, Quote>(
    self: &mut LaunchInitializer<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    lp_fee_split: FeeSplit,
) {
    package_version.assert_current(constants::version!());

    self.lp_fee_split = option::some(lp_fee_split);
}

/// Sets how long the opening round runs after share, within the protocol's bounds. Zero, the
/// default, has no opening round: trading starts at share.
public fun set_opening_round<Meme, Quote>(
    self: &mut LaunchInitializer<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    opening_round_duration_ms: u64,
) {
    package_version.assert_current(constants::version!());

    self.opening_round_ms = opening_round_duration_ms;
}

/// Names the launch's Blast partner, one new launches may name. From `finalize` on it is the
/// launch's partner for good, paid its share of every fee Blast takes on the launch when Blast
/// claims them.
public fun set_partner<Meme, Quote>(
    self: &mut LaunchInitializer<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    config: &LaunchConfig,
    partner: &Partner,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    let partner_id = object::id(partner);
    config.assert_partner(partner_id, clock);

    self.partner_id = option::some(partner_id);
}

/// Checks every setting, adds Blast's allocation to the plan, fixes the canonical supply in the
/// Coin Registry, and splits the Meme into the curve reserve and the migration allocations.
/// `creation_fee` must be exactly the configured fee; it joins Blast's fees on the launch. The
/// version check also rejects stale finalization in a transaction that used current intake. The
/// launch's ID derives from `registry` and the coin type.
public fun finalize<Meme, Quote>(
    self: LaunchInitializer<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    registry: &mut LaunchRegistry,
    currency: &mut Currency<Meme>,
    config: &LaunchConfig,
    creation_fee: Coin<SUI>,
): Launch<Meme, Quote> {
    package_version.assert_current(constants::version!());

    package_version.assert_not_paused(constants::create_pause_bit!());
    let LaunchInitializer {
        ticket,
        treasury_cap,
        venue,
        quote_fee_bps,
        meme_fee_bps,
        virtual_quote,
        graduation_target,
        allocation_plan,
        lp_fee_split,
        opening_round_ms: opening_round_duration_ms,
        partner_id,
    } = self;

    let creation_fee = creation_fee.into_balance();
    assert!(
        creation_fee.value() == config.creation_fee(),
        blast_fun::errors::invalid_creation_fee!()
    );

    let virtual_quote = virtual_quote.destroy_some();
    let graduation_target = graduation_target.destroy_some();
    let allocation_plan = allocation_plan.destroy_some().add_protocol(config.protocol_allocation());
    assert!(virtual_quote > 0, blast_fun::errors::invalid_virtual_quote!());
    assert!(
        opening_round_duration_ms == 0 || (
            opening_round_duration_ms >= constants::min_opening_round_ms!()
                && opening_round_duration_ms <= constants::max_opening_round_ms!()
        ),
        blast_fun::errors::invalid_opening_round!(),
    );

    // Trading closes with the reserve at the target, so the pool's share of it must be positive.
    let (lp_quote, _, _) = allocation_plan.apportion_quote(graduation_target);
    assert!(lp_quote > 0, blast_fun::errors::invalid_graduation_target!());

    let ticket_id = ticket.id();
    let atomic_supply = launch_ticket::atomic_supply(ticket.decimals());
    let (curve_meme, _, _, _) = allocation_plan.apportion_meme(atomic_supply);
    let creation_fee_amount = creation_fee.value();
    let (mut meme, metadata_cap, creator, sell_burn_bps) = ticket.destroy(treasury_cap, currency, atomic_supply);
    let id = derived_object::claim(&mut registry.id, LaunchKey<Meme>());
    let mut protocol_fees = protocol_fees::new(package_witness(), id.to_inner(), partner_id);
    protocol_fees.accrue_sui(creation_fee);
    let curve_fee_cap_reassignment = delayed_action::new(
        CurveFeeCapReassignment(),
        &id,
        DEFAULT_CAP_REASSIGNMENT_DELAY_MS,
    );
    let creator_metadata_cap_reassignment = delayed_action::new(
        CreatorMetadataCapReassignment(),
        &id,
        DEFAULT_CAP_REASSIGNMENT_DELAY_MS,
    );

    let launch = Launch {
        id,
        lifecycle: if (opening_round_duration_ms == 0) Lifecycle::Live else Lifecycle::OpeningRound,
        public_start_ms: option::none(),
        opening_round_ms: opening_round_duration_ms,
        opening_round_bids: 0,
        opening_round_quote: balance::zero(),
        opening_round_meme: balance::zero(),
        sell_burn_bps,
        virtual_quote,
        graduation_target,
        quote_fee_bps,
        meme_fee_bps,
        venue,
        lp_fee_split: lp_fee_split.destroy_some(),
        atomic_supply,
        meme_reserve: meme.split(curve_meme),
        real_quote_reserve: balance::zero(),
        pending_burn: balance::zero(),
        allocation_plan,
        allocated_meme: meme,
        protocol_fees,
        creator_meme_fees: balance::zero(),
        creator_quote_fees: balance::zero(),
        metadata_cap,
        creator: option::some(creator),
        curve_fee_cap_reassignment,
        creator_metadata_cap_reassignment,
        curve_fee_cap_id: option::none(),
        creator_metadata_cap_id: option::none(),
        partner_id,
    };

    events::launch_created<Meme, Quote>(
        launch.id.to_inner(),
        ticket_id,
        launch.venue,
        launch.lp_fee_split,
        launch.virtual_quote,
        launch.graduation_target,
        launch.quote_fee_bps.value(),
        launch.meme_fee_bps.value(),
        launch.allocation_plan,
        launch.opening_round_ms,
        creation_fee_amount,
        partner_id,
    );

    launch
}

/// Shares the launch. Public time starts now: trading, or the opening round, which ends
/// `opening_round_ms` later.
public fun share<Meme, Quote>(
    mut self: Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    package_version.assert_not_paused(constants::create_pause_bit!());
    assert!(self.public_start_ms.is_none(), blast_fun::errors::invalid_launch_lifecycle!());

    let public_starts_at_ms = clock.timestamp_ms();

    self.public_start_ms = option::some(public_starts_at_ms);

    events::launch_shared<Meme, Quote>(self.id.to_inner(), public_starts_at_ms);

    transfer::share_object(self);
}

/// Authenticates the creator recipient and issues both creator capabilities.
public fun claim_creator_caps<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    config: &RuntimeConfig,
    account_attestation: Option<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
): (CurveFeeCap<Meme>, CreatorMetadataCap<Meme>) {
    package_version.assert_current(constants::version!());

    assert!(self.public_start_ms.is_some(), blast_fun::errors::invalid_launch_lifecycle!());

    let (curve_fee_cap, creator_metadata_cap) = creator_authority::claim_creator_caps<Meme>(
        self.creator.extract(),
        &config.creator_claim_signers(),
        account_attestation,
        clock,
        ctx,
    );

    self.curve_fee_cap_id = option::some(object::id(&curve_fee_cap));
    self.creator_metadata_cap_id = option::some(object::id(&creator_metadata_cap));

    events::creator_caps_claimed<Meme, Quote>(
        object::id(&curve_fee_cap),
        object::id(&creator_metadata_cap),
    );

    (curve_fee_cap, creator_metadata_cap)
}

/// Changes only this launch's curve-fee cap delay, after its applied delay.
/// Apply through `apply_curve_fee_cap_delay`; replaces any pending reassignment.
public fun schedule_curve_fee_cap_delay<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CreatorAdmin>,
    delay_ms: u64,
    clock: &Clock
) {
    package_version.assert_current(constants::version!());

    self.curve_fee_cap_reassignment.schedule_delay(delay_ms, clock);
}

/// Announces a replacement recipient without invalidating the current curve-fee cap, after
/// the applied delay. Unclaimed curve fees follow the fresh cap when applied.
public fun schedule_curve_fee_cap_reassignment<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CreatorAdmin>,
    recipient: address,
    clock: &Clock
) {
    package_version.assert_current(constants::version!());

    assert!(recipient != @0x0, blast_fun::errors::invalid_creator_recipient!());

    self.curve_fee_cap_reassignment.schedule(recipient, clock);
}

/// Cancels the pending reassignment or delay change without affecting either live creator cap.
public fun cancel_curve_fee_cap_reassignment<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CancelAdmin>
) {
    package_version.assert_current(constants::version!());

    self.curve_fee_cap_reassignment.cancel();
}

/// Permissionlessly applies a ready curve-fee cap delay change.
public fun apply_curve_fee_cap_delay<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.curve_fee_cap_reassignment.apply_delay(clock);
}

/// Permissionlessly applies a ready reassignment: issues a fresh curve-fee cap to the
/// recipient and retires the old authority.
public fun apply_curve_fee_cap_reassignment<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());

    let recipient = self.curve_fee_cap_reassignment.take_action(clock);

    self.creator = option::none();
    let curve_fee_cap = creator_authority::new_curve_fee_cap<Meme>(ctx);
    let curve_fee_cap_id = object::id(&curve_fee_cap);

    self.curve_fee_cap_id = option::some(curve_fee_cap_id);
    transfer::public_transfer(curve_fee_cap, recipient);

    events::curve_fee_cap_reassigned<Meme, Quote>(self.id.to_inner(), curve_fee_cap_id, recipient);
}

/// Changes only this launch's metadata cap delay, after its applied delay.
/// Apply through `apply_creator_metadata_cap_delay`; replaces any pending reassignment.
public fun schedule_creator_metadata_cap_delay<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CreatorAdmin>,
    delay_ms: u64,
    clock: &Clock
) {
    package_version.assert_current(constants::version!());

    self.creator_metadata_cap_reassignment.schedule_delay(delay_ms, clock);
}

/// Announces a replacement recipient without invalidating the current metadata cap, after
/// the applied delay.
public fun schedule_creator_metadata_cap_reassignment<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CreatorAdmin>,
    recipient: address,
    clock: &Clock
) {
    package_version.assert_current(constants::version!());

    assert!(recipient != @0x0, blast_fun::errors::invalid_creator_recipient!());

    self.creator_metadata_cap_reassignment.schedule(recipient, clock);
}

/// Cancels the pending reassignment or delay change without affecting either live creator cap.
public fun cancel_creator_metadata_cap_reassignment<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CancelAdmin>
) {
    package_version.assert_current(constants::version!());

    self.creator_metadata_cap_reassignment.cancel();
}

/// Permissionlessly applies a ready metadata cap delay change.
public fun apply_creator_metadata_cap_delay<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.creator_metadata_cap_reassignment.apply_delay(clock);
}

/// Permissionlessly applies a ready reassignment: issues a fresh metadata cap to the
/// recipient and retires the old authority.
public fun apply_creator_metadata_cap_reassignment<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());

    let recipient = self.creator_metadata_cap_reassignment.take_action(clock);

    self.creator = option::none();
    let creator_metadata_cap = creator_authority::new_creator_metadata_cap<Meme>(ctx);
    let creator_metadata_cap_id = object::id(&creator_metadata_cap);

    self.creator_metadata_cap_id = option::some(creator_metadata_cap_id);
    transfer::public_transfer(creator_metadata_cap, recipient);

    events::creator_metadata_cap_reassigned<Meme, Quote>(
        self.id.to_inner(),
        creator_metadata_cap_id,
        recipient,
    );
}

public fun set_name<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    creator_metadata_cap: &CreatorMetadataCap<Meme>,
    currency: &mut Currency<Meme>,
    name: String,
) {
    self.assert_metadata_update(package_version, creator_metadata_cap);
    assert!(currency.name() != name, blast_fun::errors::unchanged!());

    currency.set_name(&self.metadata_cap, name);

    self.emit_metadata_updated(currency);
}

public fun set_description<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    creator_metadata_cap: &CreatorMetadataCap<Meme>,
    currency: &mut Currency<Meme>,
    description: String,
) {
    self.assert_metadata_update(package_version, creator_metadata_cap);
    assert!(currency.description() != description, blast_fun::errors::unchanged!());

    currency.set_description(&self.metadata_cap, description);

    self.emit_metadata_updated(currency);
}

public fun set_icon_url<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    creator_metadata_cap: &CreatorMetadataCap<Meme>,
    currency: &mut Currency<Meme>,
    icon_url: String,
) {
    self.assert_metadata_update(package_version, creator_metadata_cap);
    assert!(currency.icon_url() != icon_url, blast_fun::errors::unchanged!());

    currency.set_icon_url(&self.metadata_cap, icon_url);

    self.emit_metadata_updated(currency);
}

/// Adds `quote_in` to the sender's opening-round bid. Before share only the creator's own
/// transaction can reach the launch, so the creator's bid joins the same pot at the same price.
public fun join_opening_round<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    quote_in: Coin<Quote>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());

    package_version.assert_not_paused(constants::trading_pause_bit!());
    assert!(
        self.lifecycle == Lifecycle::OpeningRound,
        blast_fun::errors::invalid_launch_lifecycle!(),
    );
    assert!(!self.has_opening_round_ended(clock), blast_fun::errors::opening_round_ended!());

    let quote = quote_in.value();
    assert!(quote > 0, blast_fun::errors::zero_opening_round_bid!());

    let key = OpeningRoundBidKey(ctx.sender());
    if (!self.id.has_dynamic_field(key)) self.id.add_dynamic_field(key, 0u64);
    let bid = self.id.dynamic_field_mut<_, u64>(key);

    *bid = *bid + quote;

    self.opening_round_bids = self.opening_round_bids + quote;
    self.opening_round_quote.join(quote_in.into_balance());

    events::opening_round_joined<Meme, Quote>(self.id.to_inner(), quote, self.opening_round_bids);
}

/// Closes the ended opening round: buys from the curve once with the whole pot, at the usual fees
/// and graduation cap, and holds the Meme bought and any Quote refunded for delivery. A pot too
/// small to buy one Meme atom is held whole for refund unless it reaches graduation. Anyone may settle.
public fun settle_opening_round<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    runtime_config: &RuntimeConfig,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    package_version.assert_not_paused(constants::trading_pause_bit!());
    assert!(
        self.lifecycle == Lifecycle::OpeningRound,
        blast_fun::errors::invalid_launch_lifecycle!(),
    );
    assert!(self.has_opening_round_ended(clock), blast_fun::errors::opening_round_not_ended!());

    self.lifecycle = Lifecycle::Live;
    let pot = self.opening_round_quote.withdraw_all();
    let (meme, quote_refund) = self.buy_from_curve(runtime_config, pot, 0);
    self.opening_round_meme.join(meme);
    self.opening_round_quote.join(quote_refund);

    events::opening_round_settled<Meme, Quote>(
        self.id.to_inner(),
        self.opening_round_bids,
        self.opening_round_meme.value(),
        self.opening_round_quote.value(),
    );
}

/// Sends `bidder` its share of the settled opening round: the Meme bought and the Quote refunded,
/// pro rata to its bid among the undelivered bids and rounded down, so the last delivery takes the
/// remainder. Anyone may deliver, in any later lifecycle.
public fun deliver_opening_round<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    bidder: address,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());

    assert!(
        self.lifecycle != Lifecycle::OpeningRound,
        blast_fun::errors::invalid_launch_lifecycle!(),
    );

    let bid = self.id.remove_dynamic_field<_, u64>(OpeningRoundBidKey(bidder));
    let meme = self.opening_round_meme.value().mul_div(bid, self.opening_round_bids);
    let quote = self.opening_round_quote.value().mul_div(bid, self.opening_round_bids);

    self.opening_round_bids = self.opening_round_bids - bid;
    self.opening_round_meme.pay(meme, bidder, ctx);
    self.opening_round_quote.pay(quote, bidder, ctx);

    events::opening_round_delivered<Meme, Quote>(self.id.to_inner(), bidder, bid, meme, quote);
}

/// Buys Meme with Quote; Quote beyond the graduation target is refunded. Trading opens at share,
/// or at settlement after an opening round; before share only the creator's transaction can buy.
/// A target-reaching buy may return zero Meme when `min_meme_out` is zero.
public fun buy<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    runtime_config: &RuntimeConfig,
    quote_in: Coin<Quote>,
    min_meme_out: u64,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    package_version.assert_current(constants::version!());

    package_version.assert_not_paused(constants::trading_pause_bit!());
    assert!(self.lifecycle == Lifecycle::Live, blast_fun::errors::invalid_launch_lifecycle!());

    let (meme_out, quote_refund) = self.buy_from_curve(
        runtime_config,
        quote_in.into_balance(),
        min_meme_out,
    );
    assert!(
        meme_out.value() > 0 || self.lifecycle == Lifecycle::MigrationReady,
        blast_fun::errors::zero_trade_output!(),
    );

    (meme_out.into_coin(ctx), quote_refund.into_coin(ctx))
}

/// Sells Meme for Quote; the sell-burn share of the input waits in `pending_burn`.
public fun sell<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    runtime_config: &RuntimeConfig,
    meme_in: Coin<Meme>,
    min_quote_out: u64,
    ctx: &mut TxContext,
): Coin<Quote> {
    package_version.assert_current(constants::version!());

    package_version.assert_not_paused(constants::trading_pause_bit!());
    assert!(
        self.public_start_ms.is_some() && self.lifecycle == Lifecycle::Live,
        blast_fun::errors::invalid_launch_lifecycle!(),
    );

    let meme_in_gross = meme_in.value();
    let (
        meme_fee,
        pending_burn_delta,
        quote_out_gross,
        quote_fee,
        quote_out_net,
    ) = curve::quote_sell(
        self.meme_reserve.value(),
        self.real_quote_reserve.value(),
        self.virtual_quote,
        meme_in_gross,
        self.quote_fee_bps,
        self.meme_fee_bps,
        self.sell_burn_bps,
    );
    assert!(quote_out_net >= min_quote_out, blast_fun::errors::slippage_exceeded!());

    let mut meme_in = meme_in.into_balance();
    let meme_fee = meme_in.split(meme_fee);
    self.pending_burn.join(meme_in.split(pending_burn_delta));
    self.meme_reserve.join(meme_in);

    let mut quote_out = self.real_quote_reserve.split(quote_out_gross);
    let quote_fee = quote_out.split(quote_fee);
    let (protocol_meme, creator_meme, protocol_quote, creator_quote) = self.accrue_trade_fees(
        meme_fee,
        quote_fee,
        runtime_config.protocol_fee_share(),
    );

    events::sold<Meme, Quote>(
        self.id.to_inner(),
        meme_in_gross,
        pending_burn_delta,
        quote_out_gross,
        protocol_meme,
        creator_meme,
        protocol_quote,
        creator_quote,
        self.meme_reserve.value(),
        self.real_quote_reserve.value(),
    );

    quote_out.into_coin(ctx)
}

public fun claim_creator_fees<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    curve_fee_cap: &CurveFeeCap<Meme>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    package_version.assert_current(constants::version!());

    self.assert_curve_fee_cap(curve_fee_cap);
    assert!(
        self.creator_meme_fees.value() > 0 || self.creator_quote_fees.value() > 0,
        blast_fun::errors::nothing_accrued!(),
    );

    let meme = self.creator_meme_fees.withdraw_all().into_coin(ctx);
    let quote = self.creator_quote_fees.withdraw_all().into_coin(ctx);

    events::creator_fees_claimed<Meme, Quote>(self.id.to_inner(), meme.value(), quote.value());

    (meme, quote)
}

/// Pays `treasury` Blast's fees on a launch that names no partner: its trade fees, the creation
/// fee, and the one-time migration fee. Anyone may claim; an empty ledger pays nothing.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    treasury: &Treasury,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());

    self.protocol_fees.pay(treasury, ctx);
}

/// Pays Blast's fees on a launch that names `partner`: the partner its share of each, then
/// `treasury` the rest, in the same call. Anyone may claim; an empty ledger pays nothing.
public fun claim_protocol_fees_with_partner<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    treasury: &Treasury,
    partner: &Partner,
    ctx: &mut TxContext,
) {
    package_version.assert_current(constants::version!());

    self.protocol_fees.pay_with_partner(treasury, partner, ctx);
}

/// Pays every project recipient, outright or into its vesting schedule starting now, accrues
/// Blast's one-time Meme and Quote fee in the launch ledger, burns the curve's unsold Meme and
/// pending sell-burn (or sends them to `@0x0` when the supply is fixed), and returns the hand-off
/// only the stored venue can redeem: the pool's share and the vault's terms, with Blast's applied
/// LP-fee share and the migration residuals paid to Blast.
/// Anyone may call it; an unredeemed hand-off aborts the transaction.
public fun migrate<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    config: &LaunchConfig,
    currency: &mut Currency<Meme>,
    clock: &Clock,
    ctx: &mut TxContext,
): Migration<Meme, Quote> {
    package_version.assert_current(constants::version!());

    package_version.assert_not_paused(constants::migration_pause_bit!());
    assert!(
        self.lifecycle == Lifecycle::MigrationReady,
        blast_fun::errors::invalid_launch_lifecycle!(),
    );

    let (protocol_meme_bps, protocol_quote_bps) = config.protocol_lp_fees();
    let plan = self.allocation_plan;
    let (
        _,
        lp_meme,
        protocol_meme_amount,
        recipient_meme
    ) = plan
        .apportion_meme(self.atomic_supply);
    let (lp_quote, protocol_quote_amount, recipient_quote) = plan
        .apportion_quote(self
        .real_quote_reserve
        .value());
    let payees = plan.payees();

    payees.length().do!(|i| {
        let (payee, meme, quote) = (&payees[i], recipient_meme[i], recipient_quote[i]);
        let meme_vesting_id = payout::pay_or_vest(&mut self.allocated_meme, meme, payee, clock, ctx);
        let quote_vesting_id =
            payout::pay_or_vest(&mut self.real_quote_reserve, quote, payee, clock, ctx);
        events::migration_allocation_paid<Meme, Quote>(
            self.id.to_inner(),
            payee.destination(),
            meme,
            quote,
            meme_vesting_id,
            quote_vesting_id,
        );
    });

    self
        .protocol_fees
        .accrue(
            self.allocated_meme.split(protocol_meme_amount),
            self.real_quote_reserve.split(protocol_quote_amount),
        );
    if (protocol_meme_amount > 0 || protocol_quote_amount > 0) {
        events::protocol_fees_accrued<Meme, Quote>(
            self.id.to_inner(),
            protocol_meme_amount,
            protocol_quote_amount,
        );
    };

    let meme = self.allocated_meme.withdraw_all();
    let quote = self.real_quote_reserve.withdraw_all();

    // Dispose of the unsold Meme and the pending sell-burn.
    let burnable = currency.is_supply_burn_only();
    let mut disposal = self.pending_burn.withdraw_all();
    let disposed_meme = disposal.join(self.meme_reserve.withdraw_all());
    if (burnable) currency.burn_balance(disposal)
    else transfer::public_transfer(disposal.into_coin(ctx), @0x0);
    self.lifecycle = Lifecycle::Migrated;

    events::migrated<Meme, Quote>(
        self.id.to_inner(),
        lp_meme,
        lp_quote,
        disposed_meme,
        currency.total_supply().destroy_some(),
    );

    let terms = migration::vault_terms(
        package_witness(),
        self.id.to_inner(),
        self.lp_fee_split,
        protocol_meme_bps,
        protocol_quote_bps,
        self.partner_id,
        migration::residuals_to_protocol(),
    );

    migration::new(package_witness(), meme, quote, self.venue, terms)
}

/// Proves to the launch's vault that the caller holds the curve-fee cap this launch honors.
public fun prove_owner<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    curve_fee_cap: &CurveFeeCap<Meme>,
): OwnerProof {
    package_version.assert_current(constants::version!());
    self.assert_curve_fee_cap(curve_fee_cap);

    owner_proof::new(package_witness(), self.id.to_inner())
}

// === Private Functions ===

/// Aborts unless `curve_fee_cap` is the curve-fee cap this launch currently honors.
fun assert_curve_fee_cap<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
) {
    assert!(
        self.curve_fee_cap_id.contains(&object::id(curve_fee_cap)),
        blast_fun::errors::creator_cap_not_live!(),
    );
}

fun assert_metadata_update<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    creator_metadata_cap: &CreatorMetadataCap<Meme>,
) {
    package_version.assert_current(constants::version!());
    assert!(
        self.creator_metadata_cap_id.contains(&object::id(creator_metadata_cap)),
        blast_fun::errors::creator_cap_not_live!(),
    );
}

fun emit_metadata_updated<Meme, Quote>(self: &Launch<Meme, Quote>, currency: &Currency<Meme>) {
    events::meme_metadata_updated<Meme, Quote>(
        self.id.to_inner(),
        currency.name(),
        currency.description(),
        currency.icon_url(),
    );
}

/// Buys from the curve with `quote_in` and returns the net Meme and the Quote refunded past the
/// graduation target. Zero-output input is returned whole unless its net Quote reaches the target.
fun buy_from_curve<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    runtime_config: &RuntimeConfig,
    mut quote_in: Balance<Quote>,
    min_meme_out: u64,
): (Balance<Meme>, Balance<Quote>) {
    let (quote_in_gross, quote_refund) = curve::cap_buy_quote_input(
        self.real_quote_reserve.value(),
        self.graduation_target,
        quote_in.value(),
        self.quote_fee_bps,
    );
    let (quote_fee, meme_out_gross, meme_fee, meme_out_net) = curve::quote_buy(
        self.meme_reserve.value(),
        self.real_quote_reserve.value(),
        self.virtual_quote,
        quote_in_gross,
        self.quote_fee_bps,
        self.meme_fee_bps,
    );

    let reaches_target =
        quote_in_gross - quote_fee
        == self.graduation_target - self.real_quote_reserve.value();
    if (meme_out_net == 0 && !reaches_target) return (balance::zero(), quote_in);
    assert!(meme_out_net >= min_meme_out, blast_fun::errors::slippage_exceeded!());

    let quote_refund = quote_in.split(quote_refund);
    let quote_fee = quote_in.split(quote_fee);
    self.real_quote_reserve.join(quote_in);
    let mut meme_out = self.meme_reserve.split(meme_out_gross);
    let meme_fee = meme_out.split(meme_fee);

    if (self.real_quote_reserve.value() >= self.graduation_target) {
        self.lifecycle = Lifecycle::MigrationReady;
    };
    let (protocol_meme, creator_meme, protocol_quote, creator_quote) = self.accrue_trade_fees(
        meme_fee,
        quote_fee,
        runtime_config.protocol_fee_share(),
    );

    events::bought<Meme, Quote>(
        self.id.to_inner(),
        quote_in_gross,
        meme_out_gross,
        meme_out_net,
        quote_refund.value(),
        protocol_meme,
        creator_meme,
        protocol_quote,
        creator_quote,
        self.meme_reserve.value(),
        self.real_quote_reserve.value(),
    );

    (meme_out, quote_refund)
}

/// Splits one trade's fees: Blast's share rounds up into the protocol ledger and the creator keeps
/// the rest. Returns `(protocol_meme, creator_meme, protocol_quote, creator_quote)`.
fun accrue_trade_fees<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    mut meme_fee: Balance<Meme>,
    mut quote_fee: Balance<Quote>,
    protocol_fee_share_bps: Bps,
): (u64, u64, u64, u64) {
    let (protocol_meme, protocol_quote) = self
        .protocol_fees
        .take_cut(&mut meme_fee, &mut quote_fee, protocol_fee_share_bps, protocol_fee_share_bps);
    let (creator_meme, creator_quote) = (meme_fee.value(), quote_fee.value());

    self.creator_meme_fees.join(meme_fee);
    self.creator_quote_fees.join(quote_fee);

    (protocol_meme, creator_meme, protocol_quote, creator_quote)
}

/// Whether the opening round has ended; never before share.
fun has_opening_round_ended<Meme, Quote>(self: &Launch<Meme, Quote>, clock: &Clock): bool {
    let opening_round_duration_ms = self.opening_round_ms;

    self
        .public_start_ms
        .is_some_and!(
            |
                opening_round_starts_at_ms
            | clock.timestamp_ms() >= *opening_round_starts_at_ms + opening_round_duration_ms
        )
}

// === Test-Only Functions ===

#[test_only]
/// An unshared launch registry, as publication shares it.
public fun registry_for_testing(ctx: &mut TxContext): LaunchRegistry {
    LaunchRegistry { id: object::new(ctx) }
}

#[test_only]
/// The key the launch of `Meme` derives its ID from.
public fun launch_key_for_testing<Meme>(): LaunchKey<Meme> {
    LaunchKey()
}

#[test_only]
public fun reassign_creator_metadata_cap_for_testing<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    admin: &AdminWitness<CreatorAdmin>,
    recipient: address,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_creator_metadata_cap_reassignment(package_version, admin, recipient, &clock);
    clock.set_for_testing(DEFAULT_CAP_REASSIGNMENT_DELAY_MS);
    self.apply_creator_metadata_cap_reassignment(package_version, &clock, ctx);
    clock.destroy_for_testing();
}

#[test_only]
public fun reassign_curve_fee_cap_for_testing<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion<BLAST_FUN>,
    admin: &AdminWitness<CreatorAdmin>,
    recipient: address,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_curve_fee_cap_reassignment(package_version, admin, recipient, &clock);
    clock.set_for_testing(DEFAULT_CAP_REASSIGNMENT_DELAY_MS);
    self.apply_curve_fee_cap_reassignment(package_version, &clock, ctx);
    clock.destroy_for_testing();
}

#[test_only]
/// Returns the curve reserve, real Quote reserve, pending burn, and pooled Meme allocations.
public fun balances_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): (u64, u64, u64, u64) {
    (
        self.meme_reserve.value(),
        self.real_quote_reserve.value(),
        self.pending_burn.value(),
        self.allocated_meme.value(),
    )
}

#[test_only]
public fun policy_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): (u64, u64) {
    (self.quote_fee_bps.value(), self.meme_fee_bps.value())
}

#[test_only]
public fun curve_fee_cap_reassignment_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
): &DelayedAction<CurveFeeCapReassignment, address> {
    &self.curve_fee_cap_reassignment
}

#[test_only]
public fun creator_metadata_cap_reassignment_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
): &DelayedAction<CreatorMetadataCapReassignment, address> {
    &self.creator_metadata_cap_reassignment
}

#[test_only]
public fun metadata_cap_id_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): ID {
    object::id(&self.metadata_cap)
}

#[test_only]
public fun has_creator_authority_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): bool {
    self.creator.is_some()
}

#[test_only]
public fun curve_fee_cap_id_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): Option<ID> {
    self.curve_fee_cap_id
}

#[test_only]
public fun creator_metadata_cap_id_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): Option<ID> {
    self.creator_metadata_cap_id
}

#[test_only]
/// Returns the bidder's undelivered opening-round Quote; zero without a bid.
public fun opening_round_bid_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    bidder: address,
): u64 {
    let key = OpeningRoundBidKey(bidder);

    if (self.id.has_dynamic_field(key)) *dynamic_field::borrow(&self.id, key) else 0
}

#[test_only]
public fun has_opening_round_bid_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    bidder: address,
): bool {
    self.id.has_dynamic_field(OpeningRoundBidKey(bidder))
}

#[test_only]
/// Returns the undelivered bids' total, and the Quote and Meme held for them.
public fun opening_round_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): (u64, u64, u64) {
    (
        self.opening_round_bids,
        self.opening_round_quote.value(),
        self.opening_round_meme.value(),
    )
}

#[test_only]
public fun sell_burn_bps_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.sell_burn_bps.value()
}

#[test_only]
/// Returns Blast's and the creator's Meme fees, then Blast's and the creator's Quote fees.
public fun fee_totals_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): (u64, u64, u64, u64) {
    let (protocol_meme, protocol_quote, _) = self.protocol_fees.balances();

    (protocol_meme, self.creator_meme_fees.value(), protocol_quote, self.creator_quote_fees.value())
}

#[test_only]
public fun protocol_sui_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    let (_, _, sui) = self.protocol_fees.balances();

    sui
}

#[test_only]
public fun public_start_ms_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): Option<u64> {
    self.public_start_ms
}

#[test_only]
public fun opening_round_ms_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.opening_round_ms
}

#[test_only]
public fun graduation_target_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.graduation_target
}

#[test_only]
public fun allocation_plan_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): &AllocationPlan {
    &self.allocation_plan
}

#[test_only]
public fun atomic_supply_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.atomic_supply
}

#[test_only]
public fun is_opening_round_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): bool {
    self.lifecycle == Lifecycle::OpeningRound
}

#[test_only]
public fun is_live_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): bool {
    self.lifecycle == Lifecycle::Live
}

#[test_only]
public fun is_migration_ready_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): bool {
    self.lifecycle == Lifecycle::MigrationReady
}

#[test_only]
public fun is_migrated_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): bool {
    self.lifecycle == Lifecycle::Migrated
}

#[test_only]
public fun virtual_quote_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.virtual_quote
}

#[test_only]
public fun venue_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): TypeName {
    self.venue
}

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    delayed_action::{Self, DelayedAction},
    package_version::PackageVersion
};

use blast_core::{
    blast_domain::{CancelAdmin, CreatorAdmin},
    blast_treasury::Treasury,
    bps::Bps,
    fee_split::FeeSplit,
    migration::{Self, Migration, VenueTicket},
    owner_proof::{Self, OwnerProof},
    payout,
    protocol_fees::{Self, Ledger}
};

use blast_fun::{
    allocation::AllocationPlan,
    blast_fun::{BLAST_FUN, package_witness},
    constants,
    creator_authority::{Self, CreatorMetadataCap, CreatorRecipient, CurveFeeCap},
    curve,
    events,
    launch_config::LaunchConfig,
    launch_ticket::{Self, LaunchTicket},
    runtime_config::RuntimeConfig
};

use blast_partners::blast_partners::Partner;

use std::{string::String, type_name::{Self, TypeName}};

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::{Currency, MetadataCap},
    derived_object,
    dynamic_field,
    sui::SUI
};

use fun dynamic_field::add as UID.add_dynamic_field;

use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;

use fun dynamic_field::exists as UID.has_dynamic_field;

use fun dynamic_field::remove as UID.remove_dynamic_field;

use fun payout::pay as Balance.pay;
