// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the configuration's abort location.
#[allow(lint(abort_without_constant))]
/// Launch policy each new launch snapshots.
module blast_fun::launch_config;

// === Public Types ===

/// Admitted decimals, Quotes (with the virtual reserve each starts from), and migration
/// adapters; the trade fees; and Blast's one-time migration allocation.
public struct LaunchConfig has key {
    id: UID,
    meme_decimals: VecSet<u8>,
    virtual_quotes: Table<TypeName, u64>,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    migration_witnesses: VecSet<TypeName>,
    protocol_allocation: Option<Recipient>,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Sets, once and for good, Blast's share of every launch's Meme supply and final Quote reserve.
/// The shares leave room for the curve and the pool.
public fun set_protocol_allocation(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    destination: address,
    meme_bps: Bps,
    quote_bps: Bps,
) {
    package_version.assert_current();
    assert!(
        self.protocol_allocation.is_none() && meme_bps.value() <= 9_998 && quote_bps.value() <= 9_999,
        blast_fun::errors::invalid_protocol_allocation!(),
    );

    self.protocol_allocation = option::some(allocation::recipient(destination, meme_bps, quote_bps));

    events::protocol_allocation_set(destination, meme_bps.value(), quote_bps.value());
}

public fun set_meme_decimals_allowed(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    decimals: u8,
    allowed: bool,
) {
    package_version.assert_current();

    if (allowed) self.meme_decimals.insert(decimals) else self.meme_decimals.remove(&decimals);

    events::meme_decimals_set(decimals, allowed);
}

/// Sets the virtual Quote reserve future launches on `Quote` start from; zero disallows `Quote`.
public fun set_quote<Quote>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    virtual_quote: u64,
) {
    package_version.assert_current();
    let quote = type_name::with_original_ids<Quote>();
    let current = if (self.virtual_quotes.contains(quote)) self.virtual_quotes.remove(quote) else 0;
    assert!(current != virtual_quote, blast_fun::errors::unchanged!());

    if (virtual_quote > 0) self.virtual_quotes.add(quote, virtual_quote);

    events::quote_set<Quote>(virtual_quote);
}

/// Sets the trade fees launches created afterward snapshot.
public fun set_trade_fees(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
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

/// Admits or removes a migration adapter's witness type. An admitted adapter can start launches
/// and receives their liquidity at migration; existing launches keep their witness.
///
/// Framework types are rejected because anyone can construct them.
public fun set_migration_witness_allowed<MigrationWitness: drop>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
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

/// Checks the Quote, the adapter, and the decimals, and returns the Quote's virtual reserve and
/// the trade fees.
public(package) fun snapshot_for_launch<Quote>(
    self: &LaunchConfig,
    migration_witness: TypeName,
    decimals: u8,
): (u64, Bps, Bps) {
    let quote = type_name::with_original_ids<Quote>();

    assert!(
        self.migration_witnesses.contains(&migration_witness),
        blast_fun::errors::migration_witness_not_allowed!(),
    );
    assert!(self.meme_decimals.contains(&decimals), blast_fun::errors::decimals_not_allowed!());

    (self.virtual_quotes[quote], self.quote_fee_bps, self.meme_fee_bps)
}

public(package) fun protocol_allocation(self: &LaunchConfig): Recipient {
    *self.protocol_allocation.borrow()
}

// === Private Functions ===

fun new(ctx: &mut TxContext): LaunchConfig {
    LaunchConfig {
        id: object::new(ctx),
        meme_decimals: vec_set::from_keys(vector[6, 9]),
        virtual_quotes: table::new(ctx),
        quote_fee_bps: bps::new(0),
        meme_fee_bps: bps::new(0),
        migration_witnesses: vec_set::empty(),
        protocol_allocation: option::none(),
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
    self.virtual_quotes.length()
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

use blast_admin::acl::AdminWitness;

use blast_fun::{
    allocation::{Self, Recipient},
    blast_fun_domain::BLAST_FUN_DOMAIN,
    bps::{Self, Bps},
    constants,
    events,
    package_version::PackageVersion,
};

use std::type_name::{Self, TypeName};

use sui::{table::{Self, Table}, vec_set::{Self, VecSet}};
