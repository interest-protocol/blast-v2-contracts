// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the launch's abort location.
#[allow(lint(abort_without_constant))]
/// Launch construction, the bonding curve, and the migration handoff.
module blast_fun::launch;

// === Public Types ===

public enum Lifecycle has copy, drop, store {
    Live,
    MigrationReady,
    Migrated,
}

/// Dynamic-field name of one sender's cumulative protected gross Meme purchases.
public struct ProtectedPurchasesKey(address) has copy, drop, store;

/// One launch: its curve, its settings, and custody until migration.
///
/// Until `protection_end_ms`, each public purchase's gross Meme output, and each transaction
/// sender's running total of it, are limited.
public struct Launch<phantom Meme, phantom Quote> has key {
    id: UID,
    lifecycle: Lifecycle,
    protection_end_ms: Option<u64>,
    protection_window_ms: u64,
    cumulative_atomic_limit: u64,
    per_transaction_atomic_limit: u64,
    sell_burn_bps: Bps,
    virtual_quote: u64,
    graduation_target: u64,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    migration_witness: TypeName,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
    lp_fee_split: FeeSplit,
    atomic_supply: u64,
    meme_reserve: Balance<Meme>,
    real_quote_reserve: Balance<Quote>,
    pending_burn: Balance<Meme>,
    allocation_plan: AllocationPlan,
    allocated_meme: Balance<Meme>,
    fee_ledger: FeeLedger<Meme, Quote>,
    metadata_cap: MetadataCap<Meme>,
    creator: Option<CreatorRecipient>,
    curve_fee_cap_id: Option<ID>,
    blast_metadata_cap_id: Option<ID>,
}

/// Hot potato from `new` to `finalize`, collecting the creator's settings.
public struct LaunchInitializer<phantom Meme, phantom Quote> {
    ticket: LaunchTicket<Meme>,
    migration_witness: TypeName,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
    virtual_quote: u64,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    graduation_target: Option<u64>,
    allocation_plan: Option<AllocationPlan>,
    lp_fee_split: Option<FeeSplit>,
    protection_window_ms: u64,
    cumulative_sender_bps: Bps,
    per_transaction_bps: Bps,
}

// === Public Functions ===

/// Starts a launch for the adapter that constructs `Witness`, at the creator's pool tier in that
/// venue's units. The Quote, the adapter, and the decimals must be admitted.
public fun new<Meme, Quote, Witness: drop>(
    ticket: LaunchTicket<Meme>,
    package_version: &PackageVersion,
    config: &LaunchConfig,
    _: Witness,
    pool_tick_spacing: u32,
    pool_fee_rate: u64,
): LaunchInitializer<Meme, Quote> {
    package_version.assert_current();
    assert!(
        type_name::with_original_ids<Meme>() != type_name::with_original_ids<Quote>(),
        blast_fun::errors::invalid_meme_quote_pair!(),
    );
    let migration_witness = type_name::with_original_ids<Witness>();
    let (virtual_quote, quote_fee_bps, meme_fee_bps) = config.snapshot_for_launch<Quote>(
        migration_witness,
        ticket.decimals(),
    );

    LaunchInitializer {
        ticket,
        migration_witness,
        pool_tick_spacing,
        pool_fee_rate,
        virtual_quote,
        quote_fee_bps,
        meme_fee_bps,
        graduation_target: option::none(),
        allocation_plan: option::none(),
        lp_fee_split: option::none(),
        protection_window_ms: 0,
        cumulative_sender_bps: bps::new(0),
        per_transaction_bps: bps::new(0),
    }
}

/// Lends the treasury capability to the starting adapter, e.g. for a pool reservation.
public fun treasury_cap_mut<Meme, Quote, Witness: drop>(
    self: &mut LaunchInitializer<Meme, Quote>,
    _: Witness,
): &mut TreasuryCap<Meme> {
    assert!(
        self.migration_witness == type_name::with_original_ids<Witness>(),
        blast_fun::errors::invalid_migration_witness!(),
    );

    self.ticket.treasury_cap_mut()
}

/// Sets the Quote reserve at which the curve closes.
public fun set_graduation_target<Meme, Quote>(
    self: &mut LaunchInitializer<Meme, Quote>,
    graduation_target: u64,
) {
    self.graduation_target = option::some(graduation_target);
}

public fun set_allocation_plan<Meme, Quote>(
    self: &mut LaunchInitializer<Meme, Quote>,
    allocation_plan: AllocationPlan,
) {
    self.allocation_plan = option::some(allocation_plan);
}

public fun set_lp_fee_split<Meme, Quote>(
    self: &mut LaunchInitializer<Meme, Quote>,
    lp_fee_split: FeeSplit,
) {
    self.lp_fee_split = option::some(lp_fee_split);
}

/// Sets public-purchase protection. A zero window with both rates zero disables it; a nonzero
/// window needs a positive cumulative rate, and a zero per-transaction rate skips that check.
public fun set_protection<Meme, Quote>(
    self: &mut LaunchInitializer<Meme, Quote>,
    window_ms: u64,
    cumulative_sender_bps: Bps,
    per_transaction_bps: Bps,
) {
    self.protection_window_ms = window_ms;
    self.cumulative_sender_bps = cumulative_sender_bps;
    self.per_transaction_bps = per_transaction_bps;
}

/// Checks every setting, adds Blast's allocation to the plan, fixes the canonical supply in the
/// Coin Registry, and splits the Meme into the curve reserve and the migration allocations.
public fun finalize<Meme, Quote>(
    self: LaunchInitializer<Meme, Quote>,
    package_version: &PackageVersion,
    currency: &mut Currency<Meme>,
    config: &LaunchConfig,
    ctx: &mut TxContext,
): Launch<Meme, Quote> {
    package_version.assert_current();
    let LaunchInitializer {
        ticket,
        migration_witness,
        pool_tick_spacing,
        pool_fee_rate,
        virtual_quote,
        quote_fee_bps,
        meme_fee_bps,
        graduation_target,
        allocation_plan,
        lp_fee_split,
        protection_window_ms,
        cumulative_sender_bps,
        per_transaction_bps,
    } = self;
    assert!(
        graduation_target.is_some() && allocation_plan.is_some() && lp_fee_split.is_some(),
        blast_fun::errors::launch_settings_incomplete!(),
    );
    let graduation_target = graduation_target.destroy_some();
    let allocation_plan = allocation_plan.destroy_some().add_protocol(config.protocol_allocation());
    assert!(
        if (protection_window_ms == 0) {
            cumulative_sender_bps.value() == 0 && per_transaction_bps.value() == 0
        } else {
            cumulative_sender_bps.value() > 0
        },
        blast_fun::errors::invalid_protection!(),
    );
    assert!(
        currency.symbol().length() <= constants::max_meme_symbol_length!(),
        blast_fun::errors::meme_symbol_too_long!(),
    );
    // Trading closes with the reserve at the target, so the pool's share of it must be positive.
    let (lp_quote, _) = allocation_plan.apportion_quote(graduation_target);
    assert!(lp_quote > 0, blast_fun::errors::invalid_graduation_target!());
    let ticket_id = ticket.id();
    let atomic_supply = launch_ticket::atomic_supply(ticket.decimals());
    let (curve_meme, _, _) = allocation_plan.apportion_meme(atomic_supply);
    let (mut meme, metadata_cap, creator, sell_burn_bps) = ticket.destroy(currency, atomic_supply);

    let launch = Launch {
        id: object::new(ctx),
        lifecycle: Lifecycle::Live,
        protection_end_ms: option::none(),
        protection_window_ms,
        cumulative_atomic_limit: atomic_supply.mul_div(
            cumulative_sender_bps.value(),
            constants::basis_points_denominator!(),
        ),
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
        pool_tick_spacing,
        pool_fee_rate,
        lp_fee_split: lp_fee_split.destroy_some(),
        atomic_supply,
        meme_reserve: meme.split(curve_meme),
        real_quote_reserve: balance::zero(),
        pending_burn: balance::zero(),
        allocation_plan,
        allocated_meme: meme,
        fee_ledger: fees::new(),
        metadata_cap,
        creator: option::some(creator),
        curve_fee_cap_id: option::none(),
        blast_metadata_cap_id: option::none(),
    };

    events::launch_created<Quote>(
        launch.id.to_inner(),
        ticket_id,
        launch.migration_witness,
        launch.pool_tick_spacing,
        launch.pool_fee_rate,
        launch.lp_fee_split,
        launch.virtual_quote,
        launch.graduation_target,
        launch.quote_fee_bps.value(),
        launch.meme_fee_bps.value(),
        launch.allocation_plan,
        launch.protection_window_ms,
        cumulative_sender_bps.value(),
        per_transaction_bps.value(),
    );

    launch
}

/// Shares the launch. Public trading starts now; protection ends `protection_window_ms` later.
public fun share<Meme, Quote>(mut self: Launch<Meme, Quote>, clock: &Clock) {
    assert!(self.protection_end_ms.is_none(), blast_fun::errors::invalid_launch_lifecycle!());

    let public_start_ms = clock.timestamp_ms();
    self.protection_end_ms = option::some(public_start_ms + self.protection_window_ms);

    events::launch_shared(self.id.to_inner(), public_start_ms);

    transfer::share_object(self);
}

/// Returns the creator's `(tick_spacing, fee_rate)` pool tier, in the adapter's venue units.
public fun pool_tier<Meme, Quote>(self: &Launch<Meme, Quote>): (u32, u64) {
    (self.pool_tick_spacing, self.pool_fee_rate)
}

public fun lp_fee_split<Meme, Quote>(self: &Launch<Meme, Quote>): FeeSplit {
    self.lp_fee_split
}

/// Authenticates the creator recipient and issues both creator capabilities.
public fun claim_creator_caps<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    config: &RuntimeConfig,
    account_attestation: Option<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
): (CurveFeeCap<Meme>, BlastMetadataCap<Meme>) {
    package_version.assert_current();
    assert!(self.protection_end_ms.is_some(), blast_fun::errors::invalid_launch_lifecycle!());
    assert!(self.creator.is_some(), blast_fun::errors::creator_authority_unavailable!());

    let (curve_fee_cap, blast_metadata_cap) = creator_authority::claim_creator_caps<Meme>(
        self.creator.extract(),
        config.creator_claim_signer(),
        account_attestation,
        clock,
        ctx,
    );
    self.curve_fee_cap_id = option::some(object::id(&curve_fee_cap));
    self.blast_metadata_cap_id = option::some(object::id(&blast_metadata_cap));

    events::creator_caps_claimed<Meme>(object::id(&curve_fee_cap), object::id(&blast_metadata_cap));

    (curve_fee_cap, blast_metadata_cap)
}

/// Retires the pending claim or the live curve-fee cap and sends a fresh cap to `recipient`.
/// Unclaimed curve fees follow the new cap.
public fun reassign_curve_fee_cap<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness<BLAST_FUN_DOMAIN>,
    recipient: address,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
    admin_witness.assert_role(blast_fun_domain::creator_admin_role());
    assert!(recipient != @0x0, blast_fun::errors::invalid_creator_recipient!());

    self.creator = option::none();
    let curve_fee_cap = creator_authority::new_curve_fee_cap<Meme>(ctx);
    let curve_fee_cap_id = object::id(&curve_fee_cap);
    self.curve_fee_cap_id = option::some(curve_fee_cap_id);
    transfer::public_transfer(curve_fee_cap, recipient);

    events::curve_fee_cap_reassigned(self.id.to_inner(), curve_fee_cap_id, recipient);
}

/// Retires the pending claim or the live metadata cap and sends a fresh cap to `recipient`.
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

    self.creator = option::none();
    let blast_metadata_cap = creator_authority::new_metadata_cap<Meme>(ctx);
    let metadata_cap_id = object::id(&blast_metadata_cap);
    self.blast_metadata_cap_id = option::some(metadata_cap_id);
    transfer::public_transfer(blast_metadata_cap, recipient);

    events::metadata_cap_reassigned(self.id.to_inner(), metadata_cap_id, recipient);
}

public fun set_name<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    package_version: &PackageVersion,
    blast_metadata_cap: &BlastMetadataCap<Meme>,
    currency: &mut Currency<Meme>,
    name: String,
) {
    self.assert_metadata_update(package_version, blast_metadata_cap);
    assert!(currency.name() != name, blast_fun::errors::unchanged!());

    currency.set_name(&self.metadata_cap, name);

    self.emit_metadata_updated(currency);
}

public fun set_description<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    package_version: &PackageVersion,
    blast_metadata_cap: &BlastMetadataCap<Meme>,
    currency: &mut Currency<Meme>,
    description: String,
) {
    self.assert_metadata_update(package_version, blast_metadata_cap);
    assert!(currency.description() != description, blast_fun::errors::unchanged!());

    currency.set_description(&self.metadata_cap, description);

    self.emit_metadata_updated(currency);
}

public fun set_icon_url<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    package_version: &PackageVersion,
    blast_metadata_cap: &BlastMetadataCap<Meme>,
    currency: &mut Currency<Meme>,
    icon_url: String,
) {
    self.assert_metadata_update(package_version, blast_metadata_cap);
    assert!(currency.icon_url() != icon_url, blast_fun::errors::unchanged!());

    currency.set_icon_url(&self.metadata_cap, icon_url);

    self.emit_metadata_updated(currency);
}

/// Buys Meme with Quote; Quote beyond the graduation target is refunded.
///
/// Before the launch is shared only the creator's own transaction can reach it, so those purchases
/// are unprotected. While protected, the gross Meme output must fit the per-purchase limit and the
/// sender's remaining cumulative limit. Sells and transfers never reduce a sender's record.
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
    assert!(self.lifecycle == Lifecycle::Live, blast_fun::errors::invalid_launch_lifecycle!());

    let protected = self.protection_end_ms.is_some_and!(|end_ms| clock.timestamp_ms() < *end_ms);
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
    if (protected) self.record_protected_purchase(ctx.sender(), meme_out_gross);

    let k_before = self.curve_k();
    let mut quote_in = quote_in.into_balance();
    let quote_refund = quote_in.split(quote_refund);
    let quote_fee = quote_in.split(quote_fee);
    self.real_quote_reserve.join(quote_in);
    let mut meme_out = self.meme_reserve.split(meme_out_gross);
    let meme_fee = meme_out.split(meme_fee);
    assert!(self.curve_k() >= k_before, blast_fun::errors::constant_product_invariant_decreased!());
    if (self.real_quote_reserve.value() >= self.graduation_target) {
        self.lifecycle = Lifecycle::MigrationReady;
    };
    let (protocol_meme, creator_meme, protocol_quote, creator_quote) = self
        .fee_ledger
        .accrue(meme_fee, quote_fee, runtime_config.protocol_fee_share());

    events::bought(
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

    (meme_out.into_coin(ctx), quote_refund.into_coin(ctx))
}

/// Sells Meme for Quote; the sell-burn share of the input waits in `pending_burn`.
public fun sell<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    runtime_config: &RuntimeConfig,
    meme_in: Coin<Meme>,
    min_quote_out: u64,
    ctx: &mut TxContext,
): Coin<Quote> {
    package_version.assert_current();
    assert!(
        self.protection_end_ms.is_some() && self.lifecycle == Lifecycle::Live,
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

    let k_before = self.curve_k();
    let mut meme_in = meme_in.into_balance();
    let meme_fee = meme_in.split(meme_fee);
    self.pending_burn.join(meme_in.split(pending_burn_delta));
    self.meme_reserve.join(meme_in);
    let mut quote_out = self.real_quote_reserve.split(quote_out_gross);
    assert!(self.curve_k() >= k_before, blast_fun::errors::constant_product_invariant_decreased!());
    let quote_fee = quote_out.split(quote_fee);
    let (protocol_meme, creator_meme, protocol_quote, creator_quote) = self
        .fee_ledger
        .accrue(meme_fee, quote_fee, runtime_config.protocol_fee_share());

    events::sold(
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
    package_version: &PackageVersion,
    curve_fee_cap: &CurveFeeCap<Meme>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    package_version.assert_current();
    self.assert_curve_fee_cap(curve_fee_cap);

    let (meme, quote) = self.fee_ledger.claim_creator_fees(ctx);

    events::creator_fees_claimed(self.id.to_inner(), meme.value(), quote.value());

    (meme, quote)
}

public fun claim_protocol_fees<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    package_version.assert_current();

    let (meme, quote) = self.fee_ledger.claim_protocol_fees(ctx);

    events::protocol_fees_claimed(self.id.to_inner(), meme.value(), quote.value());

    (meme, quote)
}

/// Pays every recipient its allocation, burns the curve's unsold Meme and the pending sell-burn (or
/// sends them to `@0x0` when the supply is fixed), and hands the pool's share to the stored adapter.
public fun migrate<Meme, Quote, Witness: drop>(
    self: &mut Launch<Meme, Quote>,
    package_version: &PackageVersion,
    currency: &mut Currency<Meme>,
    _: Witness,
    ctx: &mut TxContext,
): (Balance<Meme>, Balance<Quote>) {
    package_version.assert_current();
    assert!(
        self.lifecycle == Lifecycle::MigrationReady,
        blast_fun::errors::invalid_launch_lifecycle!(),
    );
    self.assert_migration_witness<_, _, Witness>();

    let plan = self.allocation_plan;
    let (_, lp_meme, recipient_meme) = plan.apportion_meme(self.atomic_supply);
    let (lp_quote, recipient_quote) = plan.apportion_quote(self.real_quote_reserve.value());
    let destinations = plan.destinations();
    destinations.length().do!(|i| {
        let (destination, meme, quote) = (destinations[i], recipient_meme[i], recipient_quote[i]);
        if (meme > 0) {
            transfer::public_transfer(self.allocated_meme.split(meme).into_coin(ctx), destination);
        };
        if (quote > 0) {
            transfer::public_transfer(
                self.real_quote_reserve.split(quote).into_coin(ctx),
                destination,
            );
        };
        events::migration_allocation_paid(self.id.to_inner(), destination, meme, quote);
    });
    let meme = self.allocated_meme.withdraw_all();
    let quote = self.real_quote_reserve.withdraw_all();
    assert!(
        meme.value() == lp_meme && quote.value() == lp_quote,
        blast_fun::errors::migration_settlement_mismatch!(),
    );

    let burnable = currency.is_supply_burn_only();
    let mut disposal = self.pending_burn.withdraw_all();
    let disposed_meme = disposal.join(self.meme_reserve.withdraw_all());
    if (burnable) currency.burn_balance(disposal)
    else transfer::public_transfer(disposal.into_coin(ctx), @0x0);
    self.lifecycle = Lifecycle::Migrated;

    events::migrated(
        self.id.to_inner(),
        lp_meme,
        lp_quote,
        disposed_meme,
        burnable,
        currency.total_supply().destroy_some(),
    );

    (meme, quote)
}

/// Aborts unless `curve_fee_cap` is the curve-fee cap this launch currently honors.
public fun assert_curve_fee_cap<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    curve_fee_cap: &CurveFeeCap<Meme>,
) {
    assert!(
        self.curve_fee_cap_id.contains(&object::id(curve_fee_cap)),
        blast_fun::errors::creator_cap_not_live!(),
    );
}

// === Private Functions ===

fun assert_migration_witness<Meme, Quote, Witness>(self: &Launch<Meme, Quote>) {
    assert!(
        self.migration_witness == type_name::with_original_ids<Witness>(),
        blast_fun::errors::invalid_migration_witness!(),
    );
}

fun assert_metadata_update<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    package_version: &PackageVersion,
    blast_metadata_cap: &BlastMetadataCap<Meme>,
) {
    package_version.assert_current();
    assert!(
        self.blast_metadata_cap_id.contains(&object::id(blast_metadata_cap)),
        blast_fun::errors::creator_cap_not_live!(),
    );
}

fun emit_metadata_updated<Meme, Quote>(self: &Launch<Meme, Quote>, currency: &Currency<Meme>) {
    events::meme_metadata_updated(
        self.id.to_inner(),
        currency.name(),
        currency.description(),
        currency.icon_url(),
    );
}

fun curve_k<Meme, Quote>(self: &Launch<Meme, Quote>): u256 {
    (self.meme_reserve.value() as u256)
        * ((self.virtual_quote as u256) + (self.real_quote_reserve.value() as u256))
}

/// Checks one protected purchase against the per-purchase limit and the sender's remaining
/// cumulative limit, then adds it to the sender's record.
fun record_protected_purchase<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    sender: address,
    meme_out_gross: u64,
) {
    assert!(
        self.per_transaction_atomic_limit == 0 || meme_out_gross <= self.per_transaction_atomic_limit,
        blast_fun::errors::per_transaction_limit_exceeded!(),
    );
    let key = ProtectedPurchasesKey(sender);
    if (!self.id.has_dynamic_field(key)) self.id.add_dynamic_field(key, 0u64);
    let purchases = self.id.dynamic_field_mut<_, u64>(key);
    assert!(
        meme_out_gross <= self.cumulative_atomic_limit - *purchases,
        blast_fun::errors::cumulative_limit_exceeded!(),
    );
    *purchases = *purchases + meme_out_gross;
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
public fun policy_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): (u64, u64) {
    (self.quote_fee_bps.value(), self.meme_fee_bps.value())
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
public fun blast_metadata_cap_id_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): Option<ID> {
    self.blast_metadata_cap_id
}

#[test_only]
/// Runs the protected-purchase check and record on an exact gross output.
public fun record_protected_purchase_for_testing<Meme, Quote>(
    self: &mut Launch<Meme, Quote>,
    sender: address,
    meme_out_gross: u64,
) {
    self.record_protected_purchase(sender, meme_out_gross);
}

#[test_only]
public fun protected_purchases_for_testing<Meme, Quote>(
    self: &Launch<Meme, Quote>,
    sender: address,
): u64 {
    let key = ProtectedPurchasesKey(sender);

    if (self.id.has_dynamic_field(key)) *dynamic_field::borrow(&self.id, key) else 0
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

#[test_only]
public fun protection_end_ms_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): Option<u64> {
    self.protection_end_ms
}

#[test_only]
public fun protection_window_ms_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.protection_window_ms
}

#[test_only]
public fun cumulative_atomic_limit_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.cumulative_atomic_limit
}

#[test_only]
public fun per_transaction_atomic_limit_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): u64 {
    self.per_transaction_atomic_limit
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
public fun migration_witness_for_testing<Meme, Quote>(self: &Launch<Meme, Quote>): TypeName {
    self.migration_witness
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::{
    allocation::{AllocationPlan, FeeSplit},
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    bps::{Self, Bps},
    constants,
    creator_authority::{Self, BlastMetadataCap, CreatorRecipient, CurveFeeCap},
    curve,
    events,
    fees::{Self, FeeLedger},
    launch_config::LaunchConfig,
    launch_ticket::{Self, LaunchTicket},
    package_version::PackageVersion,
    runtime_config::RuntimeConfig,
};

use std::{string::String, type_name::{Self, TypeName}};

use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Coin, TreasuryCap},
    coin_registry::{Currency, MetadataCap},
    dynamic_field,
};

use fun dynamic_field::add as UID.add_dynamic_field;

use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;

use fun dynamic_field::exists as UID.has_dynamic_field;
