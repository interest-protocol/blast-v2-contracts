// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the configuration's abort location.
#[allow(lint(abort_without_constant))]
/// Launch policy each new launch snapshots.
module blast_fun::launch_config;

// === Public Types ===

/// The two trade rates change atomically.
public struct TradeFees has copy, drop, store {
    quote_fee_bps: Bps,
    meme_fee_bps: Bps
}

/// Admitted decimals, Quotes, and venues; the trade fees; Blast's one-time migration allocation;
/// Blast's share of each new vault's LP fees; the SUI every launch pays at creation; and the Blast
/// partners new launches may name. Each creator picks the virtual Quote reserve their curve
/// starts from.
public struct LaunchConfig has key {
    id: UID,
    meme_decimals: VecSet<u8>,
    quotes: VecSet<TypeName>,
    trade_fees: Delayed<TradeFeesKey, TradeFees>,
    venues: DelayedSet<VenueKey, TypeName>,
    protocol_allocation: Delayed<ProtocolAllocationKey, ProtocolAllocation>,
    protocol_lp_fees: Delayed<ProtocolLpFeesKey, ProtocolLpFees>,
    /// In MIST.
    creation_fee: Delayed<CreationFeeKey, u64>,
    partners: PartnerList,
}

/// Keys the trade fees' delayed lifecycle.
public struct TradeFeesKey() has copy, drop, store;

/// Blast's share of each asset in a new vault's LP-fee collections, each at most 3,000 bps; the
/// value applied when a launch migrates goes into its vault.
public struct ProtocolLpFees has copy, drop, store {
    meme_bps: Bps,
    quote_bps: Bps,
}

/// Keys the venue admissions' delayed lifecycle.
public struct VenueKey() has copy, drop, store;

/// Keys Blast's migration allocation's delayed lifecycle.
public struct ProtocolAllocationKey() has copy, drop, store;

/// Keys Blast's LP-fee share's delayed lifecycle.
public struct ProtocolLpFeesKey() has copy, drop, store;

/// Keys the creation fee's delayed lifecycle.
public struct CreationFeeKey() has copy, drop, store;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(
        TradeFees { quote_fee_bps: bps::new(150), meme_fee_bps: bps::new(0) },
        allocation::protocol_allocation(bps::new(250), bps::new(150)),
        new_protocol_lp_fees(bps::new(1_500), bps::new(1_500)),
        0,
        ctx,
    ));
}

// === Public Functions ===

/// Sets Blast's fee share of future launches' Meme supply and final Quote reserve, each at most
/// 1,000 bps; finalized launches keep their snapshotted shares.
/// Schedules protocol allocation after the full administrative delay.
public fun schedule_protocol_allocation(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<TreasuryAdmin>,
    meme_bps: Bps,
    quote_bps: Bps,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    let value = allocation::protocol_allocation(meme_bps, quote_bps);
    self.protocol_allocation.schedule(value, delay_ms, clock);
}

/// Applies the scheduled protocol allocation permissionlessly once ready.
public fun apply_protocol_allocation(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.protocol_allocation.apply(clock);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_protocol_allocation(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.protocol_allocation.cancel();
}

/// Schedules Blast's share of each asset in the LP fees of vaults created afterward, each at most
/// 3,000 bps, after the applied delay. Migrated launches' vaults keep the share they started with.
public fun schedule_protocol_lp_fees(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<FeeAdmin>,
    meme_bps: Bps,
    quote_bps: Bps,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.protocol_lp_fees.schedule(new_protocol_lp_fees(meme_bps, quote_bps), delay_ms, clock);
}

/// Applies Blast's scheduled LP-fee share permissionlessly once ready.
public fun apply_protocol_lp_fees(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.protocol_lp_fees.apply(clock);
}

/// Cancels a pending LP-fee share change, including after its delay has elapsed.
public fun cancel_protocol_lp_fees(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.protocol_lp_fees.cancel();
}

public fun set_meme_decimals_allowed(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<ListingAdmin>,
    decimals: u8,
    allowed: bool,
) {
    package_version.assert_current(constants::version!());

    if (allowed) self.meme_decimals.insert(decimals) else self.meme_decimals.remove(&decimals);

    events::meme_decimals_allowed(decimals, allowed);
}

/// Admits or removes `Quote` for future launches; existing launches keep trading in it.
public fun set_quote_allowed<Quote>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<ListingAdmin>,
    allowed: bool,
) {
    package_version.assert_current(constants::version!());

    let quote = type_name::with_original_ids<Quote>();

    if (allowed) self.quotes.insert(quote) else self.quotes.remove(&quote);

    events::quote_allowed<Quote>(allowed);
}

/// Sets the trade fees launches created afterward snapshot.
/// Schedules trade fees after the full administrative delay.
public fun schedule_trade_fees(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<FeeAdmin>,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    assert!(
        quote_fee_bps.value() <= constants::max_trade_fee_bps!() && meme_fee_bps.value() <= constants::max_trade_fee_bps!(),
        blast_fun::errors::invalid_trade_fee_bps!()
    );

    self.trade_fees.schedule(TradeFees { quote_fee_bps, meme_fee_bps }, delay_ms, clock);
}

/// Applies the scheduled trade fees permissionlessly once ready.
public fun apply_trade_fees(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.trade_fees.apply(clock);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_trade_fees(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.trade_fees.cancel();
}

/// Sets the SUI, in MIST, every launch created afterward pays; at most 10 SUI.
/// Schedules creation fee after the full administrative delay.
public fun schedule_creation_fee(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<FeeAdmin>,
    creation_fee: u64,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    assert!(
        creation_fee <= constants::max_creation_fee_mist!(),
        blast_fun::errors::invalid_creation_fee!(),
    );
    self.creation_fee.schedule(creation_fee, delay_ms, clock);
}

/// Applies the scheduled creation fee permissionlessly once ready.
public fun apply_creation_fee(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.creation_fee.apply(clock);
}

/// Cancels a pending change, including after its delay has elapsed.
public fun cancel_creation_fee(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.creation_fee.cancel();
}

/// Lets new launches name `partner`, at once. Adding a partner whose removal is pending cancels
/// the removal; adding a removed partner accepts it again.
public fun add_partner(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<FeeAdmin>,
    partner: &Partner,
) {
    package_version.assert_current(constants::version!());

    self.partners.add(partner);
}

/// Stops new launches naming `partner` after the delay Blast gives for every change to a
/// partner, `blast_partners::delay_ms()`. Launches that already name it keep paying it.
public fun remove_partner(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<FeeAdmin>,
    partner: &Partner,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.partners.remove(object::id(partner), clock);
}

/// Admits a venue's witness type after the applied admission delay. An admitted venue's tickets
/// start launches, and only that venue redeems their migrations; existing launches keep their
/// venue. Rescheduling a pending admission restarts its delay.
///
/// Primitive and framework types are rejected because anyone can construct them.
public fun schedule_venue<Venue: drop>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<VenueAdmin>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    let venue = type_name::with_original_ids<Venue>();
    assert!(!venue.is_primitive(), blast_fun::errors::invalid_venue!());
    let origin = type_name::original_id<Venue>();
    assert!(origin != @0x1 && origin != @0x2, blast_fun::errors::invalid_venue!());

    self.venues.schedule_add(venue, clock);
}

/// Permissionlessly applies the approved admission once ready.
public fun apply_venue<Venue: drop>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.venues.apply_add(type_name::with_original_ids<Venue>(), clock);
}

/// Cancels a pending venue admission, including after its threshold.
public fun cancel_venue<Venue: drop>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.venues.cancel_add(type_name::with_original_ids<Venue>());
}

/// Immediately removes a venue for new launches and cancels any pending admission.
public fun remove_venue<Venue: drop>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<VenueAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.venues.remove(type_name::with_original_ids<Venue>());
}

/// Proposes only the admission delay. Pending admissions keep their deadlines.
public fun schedule_venue_delay(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<VenueAdmin>,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.venues.schedule_delay(delay_ms, clock);
}

/// Permissionlessly applies a ready admission-delay proposal.
public fun apply_venue_delay(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.venues.apply_delay(clock);
}

/// Cancels only the admission-delay proposal.
public fun cancel_venue_delay(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.venues.cancel_delay();
}

/// Clears the requested pause bits once every launchpad delay and the core treasury's delay are
/// guarded: nonzero, with no pending change that would set one to zero and no pending admission.
/// A delay left at its zero publication value therefore blocks release instead of going live; the
/// generic administration then checks the upgrade delay and the pinned witness. Claims and
/// opening-round delivery never require unpausing; settling an opening round needs the trading
/// bit clear.
public fun unpause(
    self: &LaunchConfig,
    package_version: &mut PackageVersion<BLAST_FUN>,
    unpause_admin: &AdminWitness<UnpauseAdmin<BLAST_FUN>>,
    package_admin: &PackageAdmin<BLAST_FUN>,
    runtime_config: &RuntimeConfig,
    treasury: &Treasury,
    bits: u8,
) {
    package_version.assert_current(constants::version!());

    assert!(
        self.is_guarded() && runtime_config.is_guarded() && treasury.is_guarded(),
        blast_fun::errors::unguarded_delay!(),
    );

    package_admin.clear_pause_bits(unpause_admin, package_witness(), package_version, bits);
}

// === Package Functions ===

/// Checks the Quote, the venue, and the decimals, and returns the trade fees.
public(package) fun snapshot_for_launch<Quote>(
    self: &LaunchConfig,
    venue: TypeName,
    decimals: u8,
): (Bps, Bps) {
    assert!(
        self.quotes.contains(&type_name::with_original_ids<Quote>()),
        blast_fun::errors::quote_not_allowed!(),
    );
    assert!(
        self.venues.contains(&venue),
        blast_fun::errors::venue_not_allowed!(),
    );
    assert!(self.meme_decimals.contains(&decimals), blast_fun::errors::decimals_not_allowed!());

    (self.trade_fees.value().quote_fee_bps, self.trade_fees.value().meme_fee_bps)
}

public(package) fun protocol_allocation(self: &LaunchConfig): ProtocolAllocation {
    self.protocol_allocation.value()
}

/// Blast's applied share of each asset in new vaults' LP fees.
public(package) fun protocol_lp_fees(self: &LaunchConfig): (Bps, Bps) {
    let ProtocolLpFees { meme_bps, quote_bps } = self.protocol_lp_fees.value();

    (meme_bps, quote_bps)
}

/// True when every launch policy's delay is guarded (see `unpause`).
public(package) fun is_guarded(self: &LaunchConfig): bool {
    self.trade_fees.is_guarded()
        && self.venues.is_guarded()
        && self.protocol_allocation.is_guarded()
        && self.protocol_lp_fees.is_guarded()
        && self.creation_fee.is_guarded()
}

public(package) fun creation_fee(self: &LaunchConfig): u64 {
    self.creation_fee.value()
}

/// Aborts unless new launches may name `partner_id` now.
public(package) fun assert_partner(self: &LaunchConfig, partner_id: ID, clock: &Clock) {
    self.partners.assert_accepted(partner_id, clock);
}

// === Private Functions ===

/// Blast's LP-fee share, each asset at most 3,000 bps.
fun new_protocol_lp_fees(meme_bps: Bps, quote_bps: Bps): ProtocolLpFees {
    assert!(
        meme_bps.value() <= blast_core::constants::max_lp_fee_bps!()
            && quote_bps.value() <= blast_core::constants::max_lp_fee_bps!(),
        blast_fun::errors::invalid_lp_fee_bps!(),
    );

    ProtocolLpFees { meme_bps, quote_bps }
}

fun new(
    trade_fees: TradeFees,
    protocol_allocation: ProtocolAllocation,
    protocol_lp_fees: ProtocolLpFees,
    delay_ms: u64,
    ctx: &mut TxContext,
): LaunchConfig {
    let id = object::new(ctx);

    LaunchConfig {
        meme_decimals: vec_set::from_keys(vector[6, 9]),
        quotes: vec_set::empty(),
        trade_fees: delayed::new(TradeFeesKey(), &id, trade_fees, delay_ms),
        venues: delayed_set::new(VenueKey(), &id, delay_ms),
        protocol_allocation: delayed::new(ProtocolAllocationKey(), &id, protocol_allocation, delay_ms),
        protocol_lp_fees: delayed::new(ProtocolLpFeesKey(), &id, protocol_lp_fees, delay_ms),
        creation_fee: delayed::new(CreationFeeKey(), &id, 0, delay_ms),
        partners: partner_list::new(&id, ctx),
        id,
    }
}

// === Test-Only Functions ===

#[test_only]
/// Reads the applied admission delay independently of pending admissions.
public fun venue_delay_ms_for_testing(self: &LaunchConfig): u64 {
    self.venues.delay_ms()
}

#[test_only]
public fun venues_for_testing(self: &LaunchConfig): &DelayedSet<VenueKey, TypeName> {
    &self.venues
}

#[test_only]
public fun set_venue_allowed_for_testing<Venue: drop>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    admin: &AdminWitness<VenueAdmin>,
    allowed: bool,
    ctx: &mut TxContext
) {
    if (!allowed) {
        self.remove_venue<Venue>(package_version, admin);
        return
    };
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_venue<Venue>(package_version, admin, &clock);
    clock.set_for_testing(initial_upgrade_delay_ms_for_testing());
    self.apply_venue<Venue>(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_protocol_allocation_for_testing(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    admin: &AdminWitness<TreasuryAdmin>,
    meme_bps: Bps,
    quote_bps: Bps,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    let delay_ms = self.protocol_allocation.delay_ms();
    self.schedule_protocol_allocation(
        package_version,
        admin,
        meme_bps,
        quote_bps,
        delay_ms,
        &clock
    );
    clock.set_for_testing(initial_upgrade_delay_ms_for_testing());
    self.apply_protocol_allocation(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_creation_fee_for_testing(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    admin: &AdminWitness<FeeAdmin>,
    creation_fee: u64,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    let delay_ms = self.creation_fee.delay_ms();
    self.schedule_creation_fee(package_version, admin, creation_fee, delay_ms, &clock);
    clock.set_for_testing(initial_upgrade_delay_ms_for_testing());
    self.apply_creation_fee(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_trade_fees_for_testing(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    admin: &AdminWitness<FeeAdmin>,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    let delay_ms = self.trade_fees.delay_ms();
    self.schedule_trade_fees(package_version, admin, quote_fee_bps, meme_fee_bps, delay_ms, &clock);
    clock.set_for_testing(initial_upgrade_delay_ms_for_testing());
    self.apply_trade_fees(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Explicit zero-fee fixture with the existing administrative delay.
public fun new_zero_fees_for_testing(ctx: &mut TxContext): LaunchConfig {
    new(
        TradeFees { quote_fee_bps: bps::new(0), meme_fee_bps: bps::new(0) },
        allocation::protocol_allocation(bps::new(0), bps::new(0)),
        new_protocol_lp_fees(bps::new(0), bps::new(0)),
        initial_upgrade_delay_ms_for_testing(),
        ctx,
    )
}

#[test_only]
/// Shares a zero-fee genesis fixture without changing delay semantics.
public fun init_zero_fees_for_testing(ctx: &mut TxContext) {
    transfer::share_object(new(
        TradeFees { quote_fee_bps: bps::new(0), meme_fee_bps: bps::new(0) },
        allocation::protocol_allocation(bps::new(0), bps::new(0)),
        new_protocol_lp_fees(bps::new(0), bps::new(0)),
        0,
        ctx,
    ));
}

#[test_only]
public fun allowed_quote_count_for_testing(self: &LaunchConfig): u64 {
    self.quotes.length()
}

#[test_only]
public fun allowed_meme_decimals_count_for_testing(self: &LaunchConfig): u64 {
    self.meme_decimals.length()
}

#[test_only]
public fun rate_defaults_for_testing(self: &LaunchConfig): (u64, u64) {
    (self.trade_fees.value().quote_fee_bps.value(), self.trade_fees.value().meme_fee_bps.value())
}

#[test_only]
public fun allowed_venue_count_for_testing(self: &LaunchConfig): u64 {
    self.venues.members().length()
}

#[test_only]
/// Fixture convenience: exercises scheduling, advances a synthetic Clock, then applies.
public fun set_protocol_lp_fees_for_testing(
    self: &mut LaunchConfig,
    package_version: &PackageVersion<BLAST_FUN>,
    admin: &AdminWitness<FeeAdmin>,
    meme_bps: Bps,
    quote_bps: Bps,
    ctx: &mut TxContext,
) {
    let mut clock = sui::clock::create_for_testing(ctx);
    let delay_ms = self.protocol_lp_fees.delay_ms();
    self.schedule_protocol_lp_fees(package_version, admin, meme_bps, quote_bps, delay_ms, &clock);
    clock.set_for_testing(initial_upgrade_delay_ms_for_testing());
    self.apply_protocol_lp_fees(package_version, &clock);
    clock.destroy_for_testing();
}

// === Imports ===

#[test_only]
use blast_admin::package_admin::initial_upgrade_delay_ms_for_testing;

use blast_admin::{
    blast_acl::AdminWitness,
    delayed::{Self, Delayed},
    delayed_set::{Self, DelayedSet},
    package_admin::{PackageAdmin, UnpauseAdmin},
    package_version::PackageVersion
};

use blast_core::{
    blast_domain::{VenueAdmin, CancelAdmin, FeeAdmin, ListingAdmin, TreasuryAdmin},
    blast_treasury::Treasury,
    bps::{Self, Bps}
};

use blast_fun::{
    allocation::{Self, ProtocolAllocation},
    blast_fun::{BLAST_FUN, package_witness},
    constants,
    events,
    runtime_config::RuntimeConfig
};

use blast_partners::{blast_partners::Partner, partner_list::{Self, PartnerList}};

use std::type_name::{Self, TypeName};

use sui::{clock::Clock, vec_set::{Self, VecSet}};
