// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the module's abort location.
#[allow(lint(abort_without_constant))]
/// Blast's allowlists for new presales: the Quote coins a sale may raise, the venues whose tickets
/// may start a sale, and the Blast partners a sale may name; and the presale's `unpause`, which
/// reads these and the fee policy's delays.
///
/// A presale is checked once, when it is created. Later changes apply only to later sales, so a
/// delisting never strands a live sale's commitments, blocks its migration, or stops paying its
/// partner.
module blast_presale::creation_policy;

// === Public Types ===

/// Shared singleton holding the Quote types, venues, and partners new presales may use.
public struct CreationPolicy has key {
    id: UID,
    allowed_quotes: VecSet<TypeName>,
    venues: DelayedSet<VenueKey, TypeName>,
    partners: PartnerList,
}

/// Keys the delayed lifecycle of venue admissions and their delay.
public struct VenueKey() has copy, drop, store;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(0, ctx));
}

// === Public Functions ===

/// Allows or disallows `Quote` for presales created afterward; existing ones keep it.
public fun set_quote_allowed<Quote>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    _: &AdminWitness<ListingAdmin>,
    allowed: bool,
) {
    package_version.assert_current(constants::version!());

    let quote = type_name::with_original_ids<Quote>();
    assert!(
        self.allowed_quotes.contains(&quote) != allowed,
        blast_presale::errors::allowance_unchanged!(),
    );

    if (allowed) self.allowed_quotes.insert(quote) else self.allowed_quotes.remove(&quote);

    events::quote_allowed<Quote>(allowed);
}

/// Admits a venue's witness type after the applied admission delay. An admitted venue's tickets
/// start presales afterward, and only that venue redeems their migrations; existing sales keep
/// their venue. Rescheduling a pending admission restarts its delay.
///
/// `presale::new` and `presale::migrate` are public, so whoever can construct an admitted witness
/// can open sales and redeem their liquidity. Admit only a struct whose defining module is the
/// reviewed venue and keeps its constructor private. A primitive, a vector, or a framework type,
/// any of which a caller can construct, is rejected.
public fun schedule_venue<Venue: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    _: &AdminWitness<VenueAdmin>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    let venue = type_name::with_original_ids<Venue>();
    assert!(!venue.is_primitive(), blast_presale::errors::invalid_venue!());
    let origin = type_name::original_id<Venue>();
    assert!(origin != @0x1 && origin != @0x2, blast_presale::errors::invalid_venue!());

    self.venues.schedule_add(venue, clock);
}

/// Permissionlessly applies the approved admission once ready.
public fun apply_venue<Venue: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.venues.apply_add(type_name::with_original_ids<Venue>(), clock);
}

/// Cancels a pending venue admission, including after its threshold.
public fun cancel_venue<Venue: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.venues.cancel_add(type_name::with_original_ids<Venue>());
}

/// Immediately removes a venue for new presales and cancels any pending admission.
public fun remove_venue<Venue: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    _: &AdminWitness<VenueAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.venues.remove(type_name::with_original_ids<Venue>());
}

/// Lets new presales name `partner`, at once. Adding a partner whose removal is pending cancels
/// the removal; adding a removed partner accepts it again.
public fun add_partner(
    self: &mut CreationPolicy,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    _: &AdminWitness<FeeAdmin>,
    partner: &Partner,
) {
    package_version.assert_current(constants::version!());

    self.partners.add(partner);
}

/// Stops new presales naming `partner` after the delay Blast gives for every change to a
/// partner, `blast_partners::delay_ms()`. Sales that already name it keep paying it.
public fun remove_partner(
    self: &mut CreationPolicy,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    _: &AdminWitness<FeeAdmin>,
    partner: &Partner,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.partners.remove(object::id(partner), clock);
}

/// Proposes only the admission delay. Existing admission deadlines remain fixed.
public fun schedule_venue_delay(
    self: &mut CreationPolicy,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    _: &AdminWitness<VenueAdmin>,
    delay_ms: u64,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.venues.schedule_delay(delay_ms, clock);
}

/// Permissionlessly applies a ready admission-delay proposal.
public fun apply_venue_delay(
    self: &mut CreationPolicy,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.venues.apply_delay(clock);
}

/// Cancels only the admission-delay proposal.
public fun cancel_venue_delay(
    self: &mut CreationPolicy,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    _: &AdminWitness<CancelAdmin>,
) {
    package_version.assert_current(constants::version!());

    self.venues.cancel_delay();
}

/// Clears the requested pause bits once every presale delay and the core treasury's delay are
/// guarded: nonzero, with no pending change that would set one to zero and no pending admission.
/// A delay left at its zero publication value therefore blocks release instead of going live; the
/// generic administration then checks the upgrade delay and the pinned witness. Settlement,
/// cancellation, refunds and claims never require unpausing.
public fun unpause(
    self: &CreationPolicy,
    package_version: &mut PackageVersion<BLAST_PRESALE_PACKAGE>,
    unpause_admin: &AdminWitness<UnpauseAdmin<BLAST_PRESALE_PACKAGE>>,
    package_admin: &PackageAdmin<BLAST_PRESALE_PACKAGE>,
    fee_policy: &FeePolicy,
    treasury: &Treasury,
    bits: u8,
) {
    package_version.assert_current(constants::version!());

    assert!(
        self.is_guarded() && fee_policy.is_guarded() && treasury.is_guarded(),
        blast_presale::errors::unguarded_delay!(),
    );

    package_admin.clear_pause_bits(unpause_admin, package_witness(), package_version, bits);
}

// === Package Functions ===

/// True when the venue allowlist's delay is guarded (see `unpause`).
public(package) fun is_guarded(self: &CreationPolicy): bool {
    self.venues.is_guarded()
}

/// Aborts unless a new presale may raise `Quote` and migrate to `venue`.
public(package) fun assert_allowed<Quote>(self: &CreationPolicy, venue: TypeName) {
    assert!(
        self.allowed_quotes.contains(&type_name::with_original_ids<Quote>()),
        blast_presale::errors::quote_not_allowed!(),
    );
    assert!(self.venues.contains(&venue), blast_presale::errors::venue_not_allowed!());
}

/// Aborts unless a new presale may name the partner `partner_id` now.
public(package) fun assert_partner(self: &CreationPolicy, partner_id: ID, clock: &Clock) {
    self.partners.assert_accepted(partner_id, clock);
}

// === Private Functions ===

fun new(delay_ms: u64, ctx: &mut TxContext): CreationPolicy {
    let id = object::new(ctx);
    let venues = delayed_set::new(VenueKey(), &id, delay_ms);
    let partners = partner_list::new(&id, ctx);

    CreationPolicy { id, allowed_quotes: vec_set::empty(), venues, partners }
}

// === Test-Only Functions ===

#[test_only]
/// Reads the shared admission policy independently of pending admissions.
public fun venue_delay_ms_for_testing(self: &CreationPolicy): u64 {
    self.venues.delay_ms()
}

#[test_only]
public fun venues_for_testing(self: &CreationPolicy): &DelayedSet<VenueKey, TypeName> {
    &self.venues
}

#[test_only]
public fun set_venue_allowed_for_testing<Venue: drop>(
    self: &mut CreationPolicy,
    package_version: &PackageVersion<BLAST_PRESALE_PACKAGE>,
    admin: &AdminWitness<VenueAdmin>,
    allowed: bool,
    ctx: &mut TxContext,
) {
    if (!allowed) {
        self.remove_venue<Venue>(package_version, admin);
        return
    };
    let mut clock = sui::clock::create_for_testing(ctx);
    self.schedule_venue<Venue>(package_version, admin, &clock);
    clock.set_for_testing(self.venues.delay_ms());
    self.apply_venue<Venue>(package_version, &clock);
    clock.destroy_for_testing();
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): CreationPolicy {
    new(blast_admin::package_admin::initial_upgrade_delay_ms_for_testing(), ctx)
}

#[test_only]
/// The allowlist exactly as publication creates it, at zero delay.
public fun new_publication_for_testing(ctx: &mut TxContext): CreationPolicy {
    new(0, ctx)
}

/// A policy that allows exactly `Quote` and `Venue`, admitted at zero delay before the 48-hour
/// delay applies.
#[test_only]
public fun allowing_for_testing<Quote, Venue>(ctx: &mut TxContext): CreationPolicy {
    let clock = sui::clock::create_for_testing(ctx);
    let mut policy = new(0, ctx);
    let venue = type_name::with_original_ids<Venue>();
    policy.allowed_quotes.insert(type_name::with_original_ids<Quote>());
    policy.venues.schedule_add(venue, &clock);
    policy.venues.apply_add(venue, &clock);
    policy
        .venues
        .schedule_delay(blast_admin::package_admin::initial_upgrade_delay_ms_for_testing(), &clock);
    policy.venues.apply_delay(&clock);
    clock.destroy_for_testing();

    policy
}

#[test_only]
public fun destroy_for_testing(self: CreationPolicy) {
    let CreationPolicy { id, allowed_quotes: _, venues, partners } = self;
    std::unit_test::destroy(venues);
    partners.destroy();
    id.delete();
}

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    delayed_set::{Self, DelayedSet},
    package_admin::{PackageAdmin, UnpauseAdmin},
    package_version::PackageVersion
};

use blast_core::{
    blast_domain::{VenueAdmin, CancelAdmin, FeeAdmin, ListingAdmin},
    blast_treasury::Treasury
};

use blast_partners::{blast_partners::Partner, partner_list::{Self, PartnerList}};

use blast_presale::{
    blast_presale_package::{BLAST_PRESALE_PACKAGE, package_witness},
    constants,
    events,
    fee_policy::FeePolicy
};

use std::type_name::{Self, TypeName};

use sui::{clock::Clock, vec_set::{Self, VecSet}};
