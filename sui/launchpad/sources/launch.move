// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one package registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
/// Normalized launch construction, custody, and revocable creator authority.
module blast_fun::launch;

// === Public Types ===

/// Consensus lifecycle for one launch market and its terminal handoff.
public enum Lifecycle has copy, drop, store {
    Live,
    MigrationReady,
    Migrating,
    Migrated,
}

/// Who may claim bonding-curve creator fees.
///
/// `Unassigned` until a claim or administrator issues a cap, `Cap` for the live revocable
/// curve-fee cap, and terminal `Custodian` once a cap was destroyed to bind the fees
/// permanently to one custodian module, named by the witness type only it can construct.
public enum CurveFeeAuthority has copy, drop, store {
    Unassigned,
    Cap(ID),
    Custodian(TypeName),
}

/// Linear proof that the launch handed its liquidity principal to its stored adapter.
///
/// It has no abilities, so the adapter must complete the migration in the same transaction.
/// One-time-witness Meme types allow one launch per pair type, so the type names the launch.
public struct Migration<phantom Meme, phantom Quote> {
    source_meme: u64,
    source_quote: u64,
}

/// Dynamic-field name of one transaction sender's cumulative protected gross Meme purchases.
public struct ProtectedPurchasesKey(address) has copy, drop, store;

/// Pair-typed custody and immutable policy for one configured launch.
///
/// The native metadata capability never leaves the launch. While `creator_authority` holds
/// the unclaimed claim, neither creator capability is assigned; claiming issues both, and a
/// creator administrator may reassign either one independently.
///
/// Until `protection_end_ms`, public curve purchases are limited by transaction sender, not by
/// wallet balance: each purchase's gross Meme output, and each sender's running total of it.
/// Every protected sender keeps one `ProtectedPurchasesKey` child that is never removed.
public struct Launch<phantom Meme, phantom Quote> has key {
    id: UID,
    lifecycle: Lifecycle,
    fee_router_id: Option<ID>,
    router_config_cap: Option<fee_router::RouterConfigCap<Meme, Quote>>,
    public_start_ms: Option<u64>,
    protection_end_ms: Option<u64>,
    pre_share_buy_completed: bool,
    protection_window_ms: u64,
    cumulative_sender_bps: Bps,
    cumulative_atomic_limit: u64,
    per_transaction_bps: Bps,
    per_transaction_atomic_limit: u64,
    sell_burn_bps: Bps,
    virtual_quote: u64,
    graduation_target: u64,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    migration_witness: TypeName,
    atomic_supply: u64,
    meme_reserve: Balance<Meme>,
    real_quote_reserve: Balance<Quote>,
    pending_burn: Balance<Meme>,
    allocation_plan: AllocationPlan,
    allocated_meme: Balance<Meme>,
    fee_ledger: FeeLedger<Meme, Quote>,
    metadata_cap: MetadataCap<Meme>,
    creator_authority: Option<CreatorAuthority<Meme>>,
    curve_fee_authority: CurveFeeAuthority,
    blast_metadata_cap_id: Option<ID>,
}

// === Public Functions ===

/// Consumes one generated-coin ticket and returns normalized launch custody.
///
/// A ticket is built by the generated package's initializer, which cannot read launch policy,
/// and may come from an older package generation, so intake validates decimals, the sell-burn
/// rate, the admitted witness the ticket was bound to for this Quote, and the canonical supply
/// here, then irreversibly fixes the supply mode on the registered `Currency`. Meme leaves the
/// ticket in two parts: the curve reserve and the pooled migration allocations, paid out to their
/// destinations when migration completes.
///
/// Protection is fixed here for good. A zero window with both rates zero disables it; a nonzero
/// window needs a positive cumulative rate, and a zero per-transaction rate skips that check.
/// Each rate becomes an exact atomic Meme limit of the supply, rounded down.
public fun new<Meme, Quote>(
    ticket: LaunchTicket<Meme>,
    currency: &mut Currency<Meme>,
    package_version: &PackageVersion,
    config: &LaunchConfig,
    graduation_target: u64,
    allocation_plan: AllocationPlan,
    protection_window_ms: u64,
    cumulative_sender_bps: Bps,
    per_transaction_bps: Bps,
    ctx: &mut TxContext,
): Launch<Meme, Quote> {
    package_version.assert_current();
    assert!(
        type_name::with_original_ids<Meme>() != type_name::with_original_ids<Quote>(),
        blast_fun::errors::invalid_meme_quote_pair!(),
    );
    assert!(
        ticket.sell_burn_bps().value() <= constants::max_sell_burn_bps!(),
        blast_fun::errors::invalid_sell_burn_bps!(),
    );
    assert!(
        if (protection_window_ms == 0) {
            cumulative_sender_bps.value() == 0 && per_transaction_bps.value() == 0
        } else {
            cumulative_sender_bps.value() > 0
        },
        blast_fun::errors::invalid_protection!(),
    );
    config.assert_allocation_policy(&allocation_plan);
    let decimals = ticket.decimals();
    config.assert_decimals_allowed(decimals);
    let atomic_supply = launch_ticket::atomic_supply(decimals);

    let (virtual_quote, quote_fee_bps, meme_fee_bps, migration_witness) = config
        .snapshot_for_launch<Quote>(ticket.migration_witness<_, Quote>());
    // The reserve equals the target when trading closes, so the liquidity channel's Quote
    // share at the target is exactly what migration will hand off; it must not round to zero.
    let lp_quote = allocation::amount_for(
        allocation_plan.quote_weights(),
        &allocation_plan.apportion_quote(graduation_target),
        allocation_plan.liquidity_channel_id(),
    );
    assert!(lp_quote > 0, blast_fun::errors::invalid_graduation_target!());
    let ticket_id = ticket.id();
    let meme_amounts = allocation_plan.apportion_meme(atomic_supply);
    let (mut meme, metadata_cap, creator_authority, sell_burn_bps) = ticket.destroy(
        currency,
        atomic_supply,
    );
    let meme_reserve = meme.split(
        allocation::amount_for(allocation_plan.meme_weights(), &meme_amounts, 0),
    );

    let launch = Launch {
        id: object::new(ctx),
        lifecycle: Lifecycle::Live,
        fee_router_id: option::none(),
        router_config_cap: option::none(),
        public_start_ms: option::none(),
        protection_end_ms: option::none(),
        pre_share_buy_completed: false,
        protection_window_ms,
        cumulative_sender_bps,
        cumulative_atomic_limit: atomic_supply.mul_div(
            cumulative_sender_bps.value(),
            constants::basis_points_denominator!(),
        ),
        per_transaction_bps,
        per_transaction_atomic_limit: atomic_supply.mul_div(
            per_transaction_bps.value(),
            constants::basis_points_denominator!(),
        ),
        sell_burn_bps,
        virtual_quote,
        graduation_target,
        quote_fee_bps,
        meme_fee_bps,
        migration_witness,
        atomic_supply,
        meme_reserve,
        real_quote_reserve: balance::zero(),
        pending_burn: balance::zero(),
        allocation_plan,
        allocated_meme: meme,
        fee_ledger: fees::new(),
        metadata_cap,
        creator_authority: option::some(creator_authority),
        curve_fee_authority: CurveFeeAuthority::Unassigned,
        blast_metadata_cap_id: option::none(),
    };

    events::launch_created<Quote>(
        launch.id.to_inner(),
        ticket_id,
        decimals,
        atomic_supply,
        launch.migration_witness,
        launch.virtual_quote,
        launch.graduation_target,
        launch.quote_fee_bps.value(),
        launch.meme_fee_bps.value(),
        launch.allocation_plan,
        meme_amounts,
    );
    events::protection_configured(
        launch.id.to_inner(),
        launch.protection_window_ms,
        launch.cumulative_sender_bps.value(),
        launch.cumulative_atomic_limit,
        launch.per_transaction_bps.value(),
        launch.per_transaction_atomic_limit,
    );

    launch
}

/// Creates the launch's one pending router and its configuration capability before terminal share.
public fun new_fee_router<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    routes: Routes,
    ctx: &mut TxContext,
): (FeeRouter<Meme, Quote>, fee_router::RouterConfigCap<Meme, Quote>) {
    package_version.assert_current();
    assert!(self.fee_router_id.is_none(), blast_fun::errors::router_mismatch!());

    let (router, config_cap) = fee_router::new(self.id.to_inner(), routes, ctx);
    self.fee_router_id = option::some(object::id(&router));

    events::fee_router_created(
        object::id(&router),
        self.id.to_inner(),
        object::id(&config_cap),
        routes,
    );

    (router, config_cap)
}

/// Shares the key-only launch and its router through one terminal sink.
///
/// Public time starts now, and protection ends `protection_window_ms` later; an end past the
/// largest `u64` aborts.
public fun share<Meme, Quote>(
    mut self: Launch<Meme, Quote>,
    package_version: &PackageVersion,
    config_cap: fee_router::RouterConfigCap<Meme, Quote>,
    router: FeeRouter<Meme, Quote>,
    clock: &Clock,
) {
    package_version.assert_current();
    assert!(self.public_start_ms.is_none(), blast_fun::errors::launch_already_shared!());
    assert!(self.creator_authority.is_some(), blast_fun::errors::creator_authority_unavailable!());

    let public_start_ms = clock.timestamp_ms();
    let protection_end_ms = public_start_ms + self.protection_window_ms;
    let launch_id = self.id.to_inner();
    let router_id = object::id(&router);
    let pre_share_buy_completed = self.pre_share_buy_completed;
    self.public_start_ms = option::some(public_start_ms);
    self.protection_end_ms = option::some(protection_end_ms);
    self.router_config_cap.fill(config_cap);

    router.share();
    transfer::share_object(self);

    events::launch_shared(launch_id, router_id, public_start_ms, pre_share_buy_completed);
}

/// Returns the canonical public opening time; owned composition has no public clock.
public fun public_start_ms<Meme, Quote>(self: &Launch<Meme, Quote>): Option<u64> {
    self.public_start_ms
}

/// Returns the first millisecond at which public purchases are no longer protected.
public fun protection_end_ms<Meme, Quote>(self: &Launch<Meme, Quote>): Option<u64> {
    self.protection_end_ms
}

/// Returns how long public purchases stay protected after share; zero disables protection.
public fun protection_window_ms<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.protection_window_ms
}

/// Returns the share of supply one sender may buy from the curve while protected.
public fun cumulative_sender_bps<Meme, Quote>(self: &Launch<Meme, Quote>): Bps {
    self.cumulative_sender_bps
}

/// Returns the atomic Meme one sender may buy from the curve while protected.
public fun cumulative_atomic_limit<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.cumulative_atomic_limit
}

/// Returns the share of supply one protected purchase may take; zero disables that check.
///
/// Despite its name, this limit applies to each purchase call on its own: one transaction can
/// repeat purchases, and only the cumulative sender limit bounds their total.
public fun per_transaction_bps<Meme, Quote>(self: &Launch<Meme, Quote>): Bps {
    self.per_transaction_bps
}

/// Returns the atomic Meme one protected purchase may take when its rate is nonzero.
///
/// Each purchase call is checked on its own; a transaction that repeats purchases is bounded in
/// total only by the cumulative sender limit.
public fun per_transaction_atomic_limit<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.per_transaction_atomic_limit
}

/// Returns the gross Meme `sender` has bought from the curve while protected.
public fun protected_purchases<Meme, Quote>(self: &Launch<Meme, Quote>, sender: address): u64 {
    let key = ProtectedPurchasesKey(sender);

    if (self.id.has_dynamic_field(key)) *self.id.dynamic_field(key) else 0
}

/// Reports whether the one optional owned purchase completed before public opening.
public fun pre_share_buy_completed<Meme, Quote>(self: &Launch<Meme, Quote>): bool {
    self.pre_share_buy_completed
}

/// Returns the exact pending/active router bound during owned construction.
public fun fee_router_id<Meme, Quote>(self: &Launch<Meme, Quote>): Option<ID> {
    self.fee_router_id
}

/// Returns the creator-selected Quote reserve at which the curve closes and migration begins.
public fun graduation_target<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.graduation_target
}

/// Returns the complete immutable allocation contract, including the stable LP identity.
public fun allocation_plan<Meme, Quote>(self: &Launch<Meme, Quote>): &AllocationPlan {
    &self.allocation_plan
}

/// Returns the exact atomic supply the allocation plan partitions.
public fun atomic_supply<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.atomic_supply
}

/// Reports whether the curve is still open: no purchase has reached the graduation target.
public fun is_live<Meme, Quote>(self: &Launch<Meme, Quote>): bool {
    self.lifecycle == Lifecycle::Live
}

/// Reports whether trading closed at the graduation target and only migration remains.
public fun is_migration_ready<Meme, Quote>(self: &Launch<Meme, Quote>): bool {
    self.lifecycle == Lifecycle::MigrationReady
}

/// Reports whether migration completed. All three lifecycle reads are false only inside the
/// migration transaction, between `begin_migration` and `complete_migration`.
public fun is_migrated<Meme, Quote>(self: &Launch<Meme, Quote>): bool {
    self.lifecycle == Lifecycle::Migrated
}

/// Returns the curve's atomic Meme reserve.
public fun meme_reserve<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.meme_reserve.value()
}

/// Returns the atomic Quote the curve holds; prices use it plus `virtual_quote`.
public fun real_quote_reserve<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.real_quote_reserve.value()
}

/// Returns the immutable virtual Quote reserve snapshotted at intake.
public fun virtual_quote<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.virtual_quote
}

/// Returns the adapter witness the ticket was bound to before intake. Only that adapter can
/// begin and complete this launch's migration.
public fun migration_witness<Meme, Quote>(self: &Launch<Meme, Quote>): TypeName {
    self.migration_witness
}

/// Authenticates the original creator recipient and extracts the exact wrapped router config cap.
/// Terminal share must have committed this same cap; no replacement or administrative recovery exists.
public fun claim_setup_caps<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    config: &RuntimeConfig,
    account_attestation: Option<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
): (CurveFeeCap<Meme>, BlastMetadataCap<Meme>, fee_router::RouterConfigCap<Meme, Quote>) {
    package_version.assert_current();
    assert!(self.public_start_ms.is_some(), blast_fun::errors::invalid_launch_lifecycle!());

    let (curve_fee_cap, blast_metadata_cap) = self.claim_creator_caps(
        config,
        account_attestation,
        clock,
        ctx,
    );
    let config_cap = self.router_config_cap.extract();

    events::router_config_cap_released(self.id.to_inner(), object::id(&config_cap));

    (curve_fee_cap, blast_metadata_cap, config_cap)
}

/// Retires the pending claim or live curve-fee cap and delivers a fresh one to `recipient`.
///
/// Community takeovers use this path; unclaimed curve fees follow the new cap. Revoking a
/// pending claim leaves metadata unassigned until `reassign_metadata_cap`. Curve fees
/// permanently bound to a custodian can never be reassigned.
public fun reassign_curve_fee_cap<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness<BLAST_FUN_DOMAIN>,
    recipient: address,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
    assert!(!self.curve_fee_authority.is_custodian(), blast_fun::errors::creator_fees_locked!());
    admin_witness.assert_role(blast_fun_domain::creator_admin_role());
    assert!(recipient != @0x0, blast_fun::errors::invalid_creator_recipient!());

    let revoked_curve_fee_cap_id = match (self.curve_fee_authority) {
        CurveFeeAuthority::Cap(curve_fee_cap_id) => option::some(curve_fee_cap_id),
        _ => option::none(),
    };
    self.deliver_pending_setup_caps(recipient);
    self.revoke_creator_authority();
    let curve_fee_cap = creator_authority::new_curve_fee_cap<Meme>(ctx);
    let curve_fee_cap_id = curve_fee_cap.id();
    self.curve_fee_authority = CurveFeeAuthority::Cap(curve_fee_cap_id);
    transfer::public_transfer(curve_fee_cap, recipient);

    events::curve_fee_cap_reassigned(
        self.id.to_inner(),
        revoked_curve_fee_cap_id,
        curve_fee_cap_id,
        recipient,
    );
}

/// Retires the pending claim or live metadata cap and delivers a fresh one to `recipient`.
///
/// Metadata authority stays reassignable even after curve fees are locked to a custodian.
/// Revoking a pending claim leaves curve fees unassigned until `reassign_curve_fee_cap`.
public fun reassign_metadata_cap<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness<BLAST_FUN_DOMAIN>,
    recipient: address,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
    admin_witness.assert_role(blast_fun_domain::creator_admin_role());
    assert!(recipient != @0x0, blast_fun::errors::invalid_creator_recipient!());

    let revoked_metadata_cap_id = self.blast_metadata_cap_id;
    self.deliver_pending_setup_caps(recipient);
    self.revoke_creator_authority();
    let blast_metadata_cap = creator_authority::new_metadata_cap<Meme>(ctx);
    let metadata_cap_id = blast_metadata_cap.id();
    self.blast_metadata_cap_id = option::some(metadata_cap_id);
    transfer::public_transfer(blast_metadata_cap, recipient);

    events::metadata_cap_reassigned(
        self.id.to_inner(),
        revoked_metadata_cap_id,
        metadata_cap_id,
        recipient,
    );
}

/// Destroys the live curve-fee cap and binds curve fees to the `Custodian` witness permanently.
///
/// Irreversible: no curve-fee cap exists afterward, so `reassign_curve_fee_cap` aborts.
/// Metadata authority is unaffected. Afterward only a caller that can construct `Custodian`
/// claims these fees, so lock only to a witness whose package keeps its constructor private;
/// primitive, vector, and framework witnesses are rejected.
public fun lock_creator_fees<Meme, Quote, Custodian: drop>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    curve_fee_cap: CurveFeeCap<Meme>,
    _: Custodian,
) {
    package_version.assert_current();
    self.assert_curve_fee_cap(&curve_fee_cap);

    let curve_fee_cap_id = curve_fee_cap.id();
    let custodian = custodian_type<Custodian>();
    curve_fee_cap.destroy_curve_fee_cap();
    self.curve_fee_authority = CurveFeeAuthority::Custodian(custodian);

    events::creator_fees_locked(self.id.to_inner(), curve_fee_cap_id, custodian);
}

/// Claims creator trade fees for the custodian module they are permanently bound to.
public fun claim_custodied_creator_fees<Meme, Quote, Custodian: drop>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    custodian: Custodian,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    package_version.assert_current();
    self.assert_fee_custodian(custodian);

    self.claim_ledger_creator_fees(ctx)
}

/// Replaces the coin name through the launch-held native metadata capability.
public fun set_name<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    package_version: &PackageVersion,
    blast_metadata_cap: &BlastMetadataCap<Meme>,
    currency: &mut Currency<Meme>,
    name: String,
) {
    package_version.assert_current();
    self.assert_blast_metadata_cap(blast_metadata_cap);
    assert!(currency.name() != name, blast_fun::errors::metadata_unchanged!());

    currency.set_name(&self.metadata_cap, name);

    self.emit_metadata_updated(currency);
}

/// Replaces the coin description through the launch-held native metadata capability.
public fun set_description<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    package_version: &PackageVersion,
    blast_metadata_cap: &BlastMetadataCap<Meme>,
    currency: &mut Currency<Meme>,
    description: String,
) {
    package_version.assert_current();
    self.assert_blast_metadata_cap(blast_metadata_cap);
    assert!(currency.description() != description, blast_fun::errors::metadata_unchanged!());

    currency.set_description(&self.metadata_cap, description);

    self.emit_metadata_updated(currency);
}

/// Replaces the coin icon URL through the launch-held native metadata capability.
public fun set_icon_url<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    package_version: &PackageVersion,
    blast_metadata_cap: &BlastMetadataCap<Meme>,
    currency: &mut Currency<Meme>,
    icon_url: String,
) {
    package_version.assert_current();
    self.assert_blast_metadata_cap(blast_metadata_cap);
    assert!(currency.icon_url() != icon_url, blast_fun::errors::metadata_unchanged!());

    currency.set_icon_url(&self.metadata_cap, icon_url);

    self.emit_metadata_updated(currency);
}

/// Exchanges Quote for Meme and returns any terminal-target excess as a Quote coin.
///
/// Before `protection_end_ms`, the gross Meme output must also fit the per-transaction limit
/// and the transaction sender's remaining cumulative limit, and it is added to that sender's
/// record. The per-transaction limit bounds this purchase alone, so a transaction that repeats
/// purchases is bounded in total only by the cumulative limit. Sells and transfers never reduce
/// a record.
public fun buy<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    quote_in: Coin<Quote>,
    min_meme_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    package_version.assert_current();
    assert!(self.public_start_ms.is_some(), blast_fun::errors::invalid_launch_lifecycle!());
    self.assert_live();

    let protected = clock.timestamp_ms() < *self.protection_end_ms.borrow();

    self.execute_buy(runtime_config, quote_in, min_meme_out, false, protected, ctx)
}

/// Executes at most one owned purchase under ordinary curve economics, without public timing
/// or protection eligibility. Reaching the terminal target aborts before any balance split.
public fun pre_share_buy<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    quote_in: Coin<Quote>,
    min_meme_out: u64,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    package_version.assert_current();
    assert!(self.public_start_ms.is_none(), blast_fun::errors::launch_already_shared!());
    assert!(!self.pre_share_buy_completed, blast_fun::errors::pre_share_buy_already_completed!());

    self.execute_buy(runtime_config, quote_in, min_meme_out, true, false, ctx)
}

/// Exchanges one Meme coin for Quote and escrows its sell-burn allocation.
public fun sell<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    meme_in: Coin<Meme>,
    min_quote_out: u64,
    ctx: &mut TxContext,
): Coin<Quote> {
    package_version.assert_current();
    assert!(self.public_start_ms.is_some(), blast_fun::errors::invalid_launch_lifecycle!());
    self.assert_live();

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

    let k_before = self.curve_k();
    let mut meme_in = meme_in.into_balance();
    let meme_fee_balance = meme_in.split(meme_fee);
    let pending_burn_total = self.pending_burn.join(meme_in.split(pending_burn_delta));
    self.meme_reserve.join(meme_in);

    let mut quote_out = self.real_quote_reserve.split(quote_out_gross);
    assert!(self.curve_k() >= k_before, blast_fun::errors::constant_product_invariant_decreased!());
    let quote_fee_balance = quote_out.split(quote_fee);

    self.accrue_and_emit_sold(
        meme_fee_balance,
        quote_fee_balance,
        runtime_config.protocol_fee_share(),
        meme_in_gross,
        pending_burn_delta,
        pending_burn_total,
        quote_out_gross,
    );

    quote_out.into_coin(ctx)
}

/// Claims creator trade fees under the launch's live curve-fee capability.
public fun claim_creator_fees<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    curve_fee_cap: &CurveFeeCap<Meme>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    package_version.assert_current();
    self.assert_curve_fee_cap(curve_fee_cap);

    self.claim_ledger_creator_fees(ctx)
}

/// Claims protocol trade fees under live admin authority.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness<BLAST_FUN_DOMAIN>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    package_version.assert_current();

    let (meme, quote) = self.fee_ledger.claim_protocol_fees(admin_witness, ctx);

    events::protocol_fees_claimed(
        self.id.to_inner(),
        meme.value(),
        quote.value(),
    );

    (meme, quote)
}

/// Hands the exact liquidity principal to the stored adapter and marks the launch migrating.
///
/// The returned value has no abilities, so `complete_migration` must run in the same
/// transaction; any abort rolls the lifecycle and every balance back.
public fun begin_migration<Meme, Quote, Witness: drop>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    _: Witness,
): (Balance<Meme>, Balance<Quote>, Migration<Meme, Quote>) {
    package_version.assert_current();
    assert!(
        self.lifecycle == Lifecycle::MigrationReady,
        blast_fun::errors::invalid_launch_lifecycle!(),
    );
    self.assert_migration_witness<_, _, Witness>();

    let lp = self.allocation_plan.liquidity_channel_id();
    let lp_meme = allocation::amount_for(
        self.allocation_plan.meme_weights(),
        &self.allocation_plan.apportion_meme(self.atomic_supply),
        lp,
    );
    let lp_quote = allocation::amount_for(
        self.allocation_plan.quote_weights(),
        &self.allocation_plan.apportion_quote(self.real_quote_reserve.value()),
        lp,
    );

    let meme = self.allocated_meme.split(lp_meme);
    let quote = self.real_quote_reserve.split(lp_quote);
    self.lifecycle = Lifecycle::Migrating;

    let migration = Migration { source_meme: meme.value(), source_quote: quote.value() };

    (meme, quote, migration)
}

/// Completes the migration against the adapter's actual custody objects.
///
/// Consuming `migration` proves the launch is `Migrating`. The vault and position IDs come from
/// the objects themselves; the pool ID comes from the adapter, which reads it from the venue
/// position because some venues share a new pool without returning it. Every handed-off unit
/// must be accounted for as supplied principal or a residual the adapter still holds. The
/// router activates, every other allocation is paid to its destination, terminal disposal
/// runs, and `Migrated` is committed last.
public fun complete_migration<
    Meme,
    Quote,
    Witness: drop,
    Vault: key,
    Position: key,
>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    router: &mut FeeRouter<Meme, Quote>,
    policy: &LpFeePolicy,
    currency: &mut Currency<Meme>,
    migration: Migration<Meme, Quote>,
    _: Witness,
    vault: &Vault,
    pool_id: ID,
    position: &Position,
    supplied_meme: u64,
    supplied_quote: u64,
    residual_meme: &Balance<Meme>,
    residual_quote: &Balance<Quote>,
    liquidity: u128,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
    self.assert_migration_witness<_, _, Witness>();
    let Migration { source_meme, source_quote } = migration;
    assert!(
        supplied_meme.checked_add(residual_meme.value()) == option::some(source_meme)
            && supplied_quote.checked_add(residual_quote.value()) == option::some(source_quote)
            && liquidity > 0,
        blast_fun::errors::migration_settlement_mismatch!(),
    );

    let burnable = currency.is_supply_burn_only();

    router.activate<_, _, Witness>(
        policy,
        object::id(vault),
        pool_id,
        object::id(position),
    );
    self.pay_allocations(source_quote, ctx);
    let mut disposal = self.pending_burn.withdraw_all();
    let disposed_meme = disposal.join(self.meme_reserve.withdraw_all());
    disposal.dispose_meme(currency, burnable, ctx);
    self.lifecycle = Lifecycle::Migrated;

    events::migrated(
        self.id.to_inner(),
        supplied_meme,
        supplied_quote,
        residual_meme.value(),
        residual_quote.value(),
        liquidity,
        disposed_meme,
        burnable,
        currency.total_supply().destroy_some(),
    );
}

/// Aborts unless `Custodian` is the witness this launch's creator fees are permanently bound to.
public fun assert_fee_custodian<Meme, Quote, Custodian: drop>(
    self: &Launch<Meme, Quote>,
    _: Custodian,
) {
    assert!(
        self.curve_fee_authority
            == CurveFeeAuthority::Custodian(type_name::with_original_ids<Custodian>()),
        blast_fun::errors::creator_custodian_mismatch!(),
    );
}

/// Aborts unless `curve_fee_cap` is the curve-fee capability this launch currently honors.
public fun assert_curve_fee_cap<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
) {
    assert!(
        self.curve_fee_authority == CurveFeeAuthority::Cap(curve_fee_cap.id()),
        blast_fun::errors::curve_fee_cap_not_live!(),
    );
}

// === Private Functions ===

fun assert_migration_witness<Meme, Quote, Witness>(self: &Launch<Meme, Quote>) {
    assert!(
        self.migration_witness == type_name::with_original_ids<Witness>(),
        blast_fun::errors::invalid_migration_witness!(),
    );
}

/// Pays every non-liquidity allocation to its immutable destination.
///
/// Both tables are re-apportioned from the totals migration began with, adding back the
/// liquidity Quote already handed off; the pools must end empty.
fun pay_allocations<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    source_quote: u64,
    ctx: &mut TxContext,
) {
    let plan = self.allocation_plan;
    let meme_amounts = plan.apportion_meme(self.atomic_supply);
    let quote_amounts = plan.apportion_quote(self.real_quote_reserve.value() + source_quote);
    let lp = plan.liquidity_channel_id();

    plan.channels().do_ref!(|channel| {
        let channel_id = channel.channel_id();
        if (channel_id != lp) {
            let meme = allocation::amount_for(plan.meme_weights(), &meme_amounts, channel_id);
            let quote = allocation::amount_for(plan.quote_weights(), &quote_amounts, channel_id);
            if (meme > 0) {
                transfer::public_transfer(
                    self.allocated_meme.split(meme).into_coin(ctx),
                    channel.channel_destination(),
                );
            };
            if (quote > 0) {
                transfer::public_transfer(
                    self.real_quote_reserve.split(quote).into_coin(ctx),
                    channel.channel_destination(),
                );
            };
            if (meme > 0 || quote > 0) {
                events::migration_allocation_paid(
                    self.id.to_inner(),
                    channel_id,
                    channel.channel_destination(),
                    meme,
                    quote,
                );
            };
        };
    });
    assert!(
        self.allocated_meme.value() == 0 && self.real_quote_reserve.value() == 0,
        blast_fun::errors::allocation_sum_invalid!(),
    );
}

/// Names the custodian module, rejecting witnesses anyone could construct.
///
/// Primitives and vectors are constructible by every caller, and so are framework types such as
/// `Option`, `String`, and `VecMap`, so a witness must come from a package outside `0x1` and
/// `0x2`. Move cannot prove that package keeps its constructor private; the locking cap holder
/// chooses the type and bears that choice.
fun custodian_type<Custodian>(): TypeName {
    let custodian = type_name::with_original_ids<Custodian>();

    assert!(!custodian.is_primitive(), blast_fun::errors::invalid_fee_custodian!());

    let origin = type_name::original_id<Custodian>();

    assert!(origin != @0x1 && origin != @0x2, blast_fun::errors::invalid_fee_custodian!());

    custodian
}

fun is_custodian(self: &CurveFeeAuthority): bool {
    match (self) {
        CurveFeeAuthority::Custodian(_) => true,
        _ => false,
    }
}

fun assert_blast_metadata_cap<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    blast_metadata_cap: &BlastMetadataCap<Meme>,
) {
    assert!(
        self.blast_metadata_cap_id.contains(&blast_metadata_cap.id()),
        blast_fun::errors::metadata_cap_not_live!(),
    );
}

fun revoke_creator_authority<Meme, Quote>(self: &mut Launch<Meme, Quote>) {
    if (self.creator_authority.is_some()) {
        self.creator_authority.extract().revoke();
    };
}

/// Existing creator takeover delivers each still-pending setup authority once, never recovers it.
fun deliver_pending_setup_caps<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    recipient: address,
) {
    if (self.router_config_cap.is_some()) {
        let config_cap = self.router_config_cap.extract();
        let cap_id = object::id(&config_cap);
        transfer::public_transfer(config_cap, recipient);

        events::router_config_cap_delivered(self.id.to_inner(), cap_id, recipient);
    };
}

fun claim_ledger_creator_fees<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    let (meme, quote) = self.fee_ledger.claim_creator_fees(ctx);

    events::creator_fees_claimed(
        self.id.to_inner(),
        meme.value(),
        quote.value(),
    );

    (meme, quote)
}

fun emit_metadata_updated<Meme, Quote>(self: &Launch<Meme, Quote>, currency: &Currency<Meme>) {
    events::meme_metadata_updated(
        self.id.to_inner(),
        currency.name(),
        currency.description(),
        currency.icon_url(),
    );
}

fun assert_live<Meme, Quote>(self: &Launch<Meme, Quote>) {
    assert!(self.lifecycle == Lifecycle::Live, blast_fun::errors::invalid_launch_lifecycle!());
}

fun curve_k<Meme, Quote>(self: &Launch<Meme, Quote>): u256 {
    curve::k(
        self.meme_reserve.value() as u256,
        (self.virtual_quote as u256) + (self.real_quote_reserve.value() as u256),
    )
}

fun dispose_meme<Meme>(
    disposal: Balance<Meme>,
    currency: &mut Currency<Meme>,
    burn_supply: bool,
    ctx: &mut TxContext,
) {
    if (burn_supply) {
        currency.burn_balance(disposal);
    } else {
        transfer::public_transfer(disposal.into_coin(ctx), @0x0);
    };
}

fun accrue_trade_fees<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    meme_fee: Balance<Meme>,
    quote_fee: Balance<Quote>,
    protocol_fee_share_bps: Bps,
): (u64, u64, u64, u64) {
    if (meme_fee.value() == 0 && quote_fee.value() == 0) {
        meme_fee.destroy_zero();
        quote_fee.destroy_zero();
        (0, 0, 0, 0)
    } else {
        self.fee_ledger.accrue(meme_fee, quote_fee, protocol_fee_share_bps)
    }
}

fun execute_buy<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    runtime_config: &RuntimeConfig,
    quote_in: Coin<Quote>,
    min_meme_out: u64,
    pre_share: bool,
    protected: bool,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
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

    assert!(meme_out_net >= min_meme_out, blast_fun::errors::slippage_exceeded!());
    if (pre_share) {
        assert!(
            self.real_quote_reserve.value() + (quote_in_gross - quote_fee) < self.graduation_target,
            blast_fun::errors::pre_share_buy_would_graduate!(),
        );
    };
    if (protected) {
        self.assert_protected_purchase(ctx.sender(), meme_out_gross);
    };

    let k_before = self.curve_k();
    let mut quote_in = quote_in.into_balance();
    let quote_refund_balance = quote_in.split(quote_refund);
    let quote_fee_balance = quote_in.split(quote_fee);
    self.real_quote_reserve.join(quote_in);

    let mut meme_out = self.meme_reserve.split(meme_out_gross);
    let meme_fee_balance = meme_out.split(meme_fee);
    assert!(self.curve_k() >= k_before, blast_fun::errors::constant_product_invariant_decreased!());
    if (self.real_quote_reserve.value() >= self.graduation_target) {
        self.lifecycle = Lifecycle::MigrationReady;
    };
    if (protected) {
        self.record_protected_purchase(ctx.sender(), meme_out_gross);
    };

    let (protocol_meme, creator_meme, protocol_quote, creator_quote) = self.accrue_trade_fees(
        meme_fee_balance,
        quote_fee_balance,
        runtime_config.protocol_fee_share(),
    );
    if (pre_share) {
        self.pre_share_buy_completed = true;
        events::pre_share_bought(
            self.id.to_inner(),
            quote_in_gross,
            meme_out_gross,
            protocol_meme,
            creator_meme,
            protocol_quote,
            creator_quote,
            self.meme_reserve.value(),
            self.real_quote_reserve.value(),
            meme_out_net,
            quote_refund,
        );
    } else {
        events::bought(
            self.id.to_inner(),
            quote_in_gross,
            meme_out_gross,
            protocol_meme,
            creator_meme,
            protocol_quote,
            creator_quote,
            self.meme_reserve.value(),
            self.real_quote_reserve.value(),
        );
    };

    (meme_out.into_coin(ctx), quote_refund_balance.into_coin(ctx))
}

/// Aborts unless the purchase fits the per-transaction limit, then the sender's remaining limit.
fun assert_protected_purchase<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    sender: address,
    meme_out_gross: u64,
) {
    assert!(
        self.per_transaction_bps.value() == 0
            || meme_out_gross <= self.per_transaction_atomic_limit,
        blast_fun::errors::per_transaction_limit_exceeded!(),
    );
    assert!(
        meme_out_gross <= self.cumulative_atomic_limit - self.protected_purchases(sender),
        blast_fun::errors::cumulative_limit_exceeded!(),
    );
}

/// Adds one protected purchase to its sender's record, creating the record on first purchase.
fun record_protected_purchase<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    sender: address,
    meme_out_gross: u64,
) {
    let key = ProtectedPurchasesKey(sender);

    if (self.id.has_dynamic_field(key)) {
        let purchases = self.id.dynamic_field_mut<_, u64>(key);
        *purchases = *purchases + meme_out_gross;
    } else {
        self.id.add_dynamic_field(key, meme_out_gross);
    };
}

fun claim_creator_caps<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    config: &RuntimeConfig,
    account_attestation: Option<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
): (CurveFeeCap<Meme>, BlastMetadataCap<Meme>) {
    assert!(self.creator_authority.is_some(), blast_fun::errors::creator_authority_unavailable!());

    let (curve_fee_cap, blast_metadata_cap) = self
        .creator_authority
        .extract()
        .claim_creator_caps(
            config,
            account_attestation,
            clock,
            ctx,
        );
    self.curve_fee_authority = CurveFeeAuthority::Cap(curve_fee_cap.id());
    self.blast_metadata_cap_id = option::some(blast_metadata_cap.id());

    (curve_fee_cap, blast_metadata_cap)
}

fun accrue_and_emit_sold<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    meme_fee_balance: Balance<Meme>,
    quote_fee_balance: Balance<Quote>,
    protocol_fee_share_bps: Bps,
    meme_in_gross: u64,
    pending_burn_delta: u64,
    pending_burn_total: u64,
    quote_out_gross: u64,
) {
    let (
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
    ) = self.accrue_trade_fees(
        meme_fee_balance,
        quote_fee_balance,
        protocol_fee_share_bps,
    );

    events::sold(
        self.id.to_inner(),
        meme_in_gross,
        pending_burn_delta,
        pending_burn_total,
        quote_out_gross,
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
        self.meme_reserve.value(),
        self.real_quote_reserve.value(),
    );
}

// === Test-Only Functions ===

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
/// Returns the Quote and Meme trade-fee rates, which have no public getter.
public fun policy_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): (u64, u64) {
    (self.quote_fee_bps.value(), self.meme_fee_bps.value())
}

#[test_only]
public fun metadata_cap_id_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): ID {
    object::id(&self.metadata_cap)
}

#[test_only]
public fun has_creator_authority_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): bool {
    self.creator_authority.is_some()
}

#[test_only]
public fun curve_fee_cap_id_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): Option<ID> {
    match (self.curve_fee_authority) {
        CurveFeeAuthority::Cap(curve_fee_cap_id) => option::some(curve_fee_cap_id),
        _ => option::none(),
    }
}

#[test_only]
public fun blast_metadata_cap_id_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): Option<ID> {
    self.blast_metadata_cap_id
}

#[test_only]
public fun fee_custodian_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): Option<TypeName> {
    match (self.curve_fee_authority) {
        CurveFeeAuthority::Custodian(custodian) => option::some(custodian),
        _ => option::none(),
    }
}

#[test_only]
/// Exposes the transaction-local handoff state for atomic migration rollback tests.
public fun is_migrating_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): bool {
    self.lifecycle == Lifecycle::Migrating
}

#[test_only]
/// Runs the protected-purchase guard on an exact gross output, which a curve buy rarely hits.
public fun assert_protected_purchase_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    sender: address,
    meme_out_gross: u64,
) {
    self.assert_protected_purchase(sender, meme_out_gross);
}

#[test_only]
public fun has_protected_purchases_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    sender: address,
): bool {
    self.id.has_dynamic_field(ProtectedPurchasesKey(sender))
}

#[test_only]
public fun sell_burn_bps_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.sell_burn_bps.value()
}

#[test_only]
public fun fee_totals_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): (u64, u64, u64, u64) {
    self.fee_ledger.totals_for_testing()
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::{
    allocation::{Self, AllocationPlan, Routes},
    bps::Bps,
    constants,
    creator_authority::{Self, BlastMetadataCap, CreatorAuthority, CurveFeeCap},
    curve,
    events,
    fees::{Self, FeeLedger},
    fee_router::{Self, FeeRouter},
    launch_config::LaunchConfig,
    launch_ticket::{Self, LaunchTicket},
    lp_fee_policy::LpFeePolicy,
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    package_version::PackageVersion,
    runtime_config::RuntimeConfig,
};

use std::{string::String, type_name::{Self, TypeName}};

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::Coin,
    coin_registry::{Currency, MetadataCap},
    dynamic_field,
};

use fun dispose_meme as Balance.dispose_meme;

use fun dynamic_field::add as UID.add_dynamic_field;

use fun dynamic_field::borrow as UID.dynamic_field;

use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;

use fun dynamic_field::exists as UID.has_dynamic_field;
