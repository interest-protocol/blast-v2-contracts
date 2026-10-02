// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the configuration's abort location.
#[allow(lint(abort_without_constant))]
/// Launch policy each new launch snapshots.
module blast_fun::launch_config;

// === Public Types ===

/// Admitted decimals, Quotes, and migration adapters; the trade fees; Blast's one-time migration
/// allocation; the SUI every launch pays at creation; and the Blast partners new launches may
/// name. Each creator picks the virtual Quote reserve their curve starts from.
public struct LaunchConfig has key {
    id: UID,
    meme_decimals: VecSet<u8>,
    quotes: Table<TypeName, bool>,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    migration_witnesses: VecSet<TypeName>,
    protocol_allocation: ProtocolAllocation,
    /// In MIST.
    creation_fee: u64,
}

/// Dynamic-field key of a Blast partner new launches may name. Its value is the time the partner
/// stops being accepted: `u64::MAX` until Blast removes it.
public struct PartnerKey(ID) has copy, drop, store;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Sets Blast's fee share of future launches' Meme supply and final Quote reserve. The shares
/// leave room for the curve and the pool; finalized launches keep their snapshotted shares.
public fun set_protocol_allocation(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<TreasuryAdmin>,
    meme_bps: Bps,
    quote_bps: Bps,
) {
    package_version.assert_current();
    assert!(
        meme_bps.value() <= 9_998 && quote_bps.value() <= 9_999,
        blast_fun::errors::invalid_protocol_allocation!(),
    );

    let protocol_allocation = allocation::protocol_allocation(meme_bps, quote_bps);
    assert!(self.protocol_allocation != protocol_allocation, blast_fun::errors::unchanged!());

    self.protocol_allocation = protocol_allocation;

    events::protocol_allocation_set(meme_bps.value(), quote_bps.value());
}

public fun set_meme_decimals_allowed(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<ListingAdmin>,
    decimals: u8,
    allowed: bool,
) {
    package_version.assert_current();

    if (allowed) self.meme_decimals.insert(decimals) else self.meme_decimals.remove(&decimals);

    events::meme_decimals_set(decimals, allowed);
}

/// Admits or removes `Quote` for future launches; existing launches keep trading in it.
public fun set_quote_allowed<Quote>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<ListingAdmin>,
    allowed: bool,
) {
    package_version.assert_current();
    let quote = type_name::with_original_ids<Quote>();

    if (allowed) self.quotes.add(quote, true) else { self.quotes.remove(quote); };

    events::quote_set<Quote>(allowed);
}

/// Sets the trade fees launches created afterward snapshot.
public fun set_trade_fees(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
) {
    package_version.assert_current();
    assert!(
        quote_fee_bps.value() <= constants::max_launch_fee_bps!()
            && meme_fee_bps.value() <= constants::max_launch_fee_bps!(),
        blast_fun::errors::invalid_trade_fee_bps!(),
    );
    assert!(quote_fee_bps != self.quote_fee_bps || meme_fee_bps != self.meme_fee_bps, blast_fun::errors::unchanged!());

    self.quote_fee_bps = quote_fee_bps;
    self.meme_fee_bps = meme_fee_bps;

    events::launch_trade_fees_changed(quote_fee_bps.value(), meme_fee_bps.value());
}

/// Sets the SUI, in MIST, every launch created afterward pays.
public fun set_creation_fee(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    creation_fee: u64,
) {
    package_version.assert_current();
    assert!(creation_fee != self.creation_fee, blast_fun::errors::unchanged!());

    self.creation_fee = creation_fee;

    events::creation_fee_changed(creation_fee);
}

/// Lets new launches name `partner`, at once. Adding a partner whose removal is pending cancels
/// the removal; adding a removed partner accepts it again.
public fun add_partner(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    partner: &Partner,
) {
    package_version.assert_current();

    let partner_id = object::id(partner);
    let key = PartnerKey(partner_id);

    if (self.id.has_dynamic_field(key)) {
        let accepted_until_ms: &mut u64 = self.id.dynamic_field_mut(key);
        assert!(*accepted_until_ms != std::u64::max_value!(), blast_fun::errors::unchanged!());
        *accepted_until_ms = std::u64::max_value!();
    } else {
        self.id.add_dynamic_field(key, std::u64::max_value!());
    };

    events::partner_added(partner_id);
}

/// Stops new launches naming `partner` after the notice Blast gives for every change to a
/// partner, `blast_partners::delay_ms()`. Launches that already name it keep paying it.
public fun remove_partner(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    partner: &Partner,
    clock: &Clock,
) {
    package_version.assert_current();

    let partner_id = object::id(partner);
    let now_ms = clock.timestamp_ms();
    self.assert_partner(partner_id, now_ms);
    let accepted_until_ms = now_ms + partners::delay_ms();

    let current: &mut u64 = self.id.dynamic_field_mut(PartnerKey(partner_id));
    assert!(*current == std::u64::max_value!(), blast_fun::errors::unchanged!());
    *current = accepted_until_ms;

    events::partner_removed(partner_id, accepted_until_ms);
}

/// Admits or removes a migration adapter's witness type. An admitted adapter can start launches
/// and receives their liquidity at migration; existing launches keep their witness.
///
/// Framework types are rejected because anyone can construct them.
public fun set_migration_witness_allowed<MigrationWitness: drop>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<AdapterAdmin>,
    allowed: bool,
) {
    package_version.assert_current();
    let origin = type_name::original_id<MigrationWitness>();
    assert!(origin != @0x1 && origin != @0x2, blast_fun::errors::invalid_migration_witness_type!());

    let witness = type_name::with_original_ids<MigrationWitness>();

    if (allowed) self.migration_witnesses.insert(witness)
    else self.migration_witnesses.remove(&witness);

    events::migration_witness_set<MigrationWitness>(allowed);
}

// === Package Functions ===

/// Checks the Quote, the adapter, and the decimals, and returns the trade fees.
public(package) fun snapshot_for_launch<Quote>(
    self: &LaunchConfig,
    migration_witness: TypeName,
    decimals: u8,
): (Bps, Bps) {
    assert!(
        self.quotes.contains(type_name::with_original_ids<Quote>()),
        blast_fun::errors::quote_not_allowed!(),
    );
    assert!(
        self.migration_witnesses.contains(&migration_witness),
        blast_fun::errors::migration_witness_not_allowed!(),
    );
    assert!(self.meme_decimals.contains(&decimals), blast_fun::errors::decimals_not_allowed!());

    (self.quote_fee_bps, self.meme_fee_bps)
}

public(package) fun protocol_allocation(self: &LaunchConfig): ProtocolAllocation {
    self.protocol_allocation
}

public(package) fun creation_fee(self: &LaunchConfig): u64 {
    self.creation_fee
}

/// Aborts unless new launches may name `partner_id` at `now_ms`.
public(package) fun assert_partner(self: &LaunchConfig, partner_id: ID, now_ms: u64) {
    let key = PartnerKey(partner_id);

    assert!(self.id.has_dynamic_field(key), blast_fun::errors::partner_not_accepted!());
    let accepted_until_ms: u64 = *dynamic_field::borrow(&self.id, key);
    assert!(now_ms < accepted_until_ms, blast_fun::errors::partner_not_accepted!());
}

// === Private Functions ===

fun new(ctx: &mut TxContext): LaunchConfig {
    LaunchConfig {
        id: object::new(ctx),
        meme_decimals: vec_set::from_keys(vector[6, 9]),
        quotes: table::new(ctx),
        quote_fee_bps: bps::new(0),
        meme_fee_bps: bps::new(0),
        migration_witnesses: vec_set::empty(),
        protocol_allocation: allocation::protocol_allocation(bps::new(0), bps::new(0)),
        creation_fee: 0,
    }
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): LaunchConfig {
    new(ctx)
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
    (self.quote_fee_bps.value(), self.meme_fee_bps.value())
}

#[test_only]
public fun allowed_migration_witness_count_for_testing(self: &LaunchConfig): u64 {
    self.migration_witnesses.length()
}

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_fun::{
    allocation::{Self, ProtocolAllocation},
    blast_fun_domain::{AdapterAdmin, FeeAdmin, ListingAdmin, TreasuryAdmin},
    bps::{Self, Bps},
    constants,
    events,
    blast_fun::PackageVersion,
};

use blast_partners::blast_partners::{Self as partners, Partner};

use std::type_name::{Self, TypeName};

use sui::{clock::Clock, dynamic_field, table::{Self, Table}, vec_set::{Self, VecSet}};

use fun dynamic_field::add as UID.add_dynamic_field;

use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;

use fun dynamic_field::exists as UID.has_dynamic_field;
