// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one package registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
/// Cold launch-time policy snapshotted before bonding begins.
module blast_fun::launch_config;

// === Public Types ===

/// Shared singleton containing cold policy snapshotted by each new launch.
/// Each admitted Quote maps to the virtual reserve that shapes its curve.
public struct LaunchConfig has key {
    id: UID,
    meme_decimals: VecSet<u8>,
    quotes: Table<TypeName, u64>,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    migration_witnesses: VecSet<TypeName>,
    protocol_allocation: Option<ProtocolAllocation>,
}

/// One-time Blast allocation policy for all subsequently created immutable tables.
public struct ProtocolAllocation has drop, store {
    channel_id: u64,
    destination: address,
    meme_bps: Bps,
    quote_bps: Bps,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Permanently sets the named Blast migration identity and its per-asset allocations.
/// A zero/zero policy omits the protocol channel from launch tables.
public fun set_protocol_allocation(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    channel_id: u64,
    destination: address,
    meme_bps: Bps,
    quote_bps: Bps,
) {
    package_version.assert_current();
    assert!(self.protocol_allocation.is_none(), blast_fun::errors::protocol_channel_mismatch!());
    assert!(
        channel_id != 0 && destination != @0x0,
        blast_fun::errors::protocol_channel_mismatch!(),
    );
    // Meme must leave positive weights for both curve and LP; Quote needs only LP.
    assert!(
        meme_bps.value() <= 9_998 && quote_bps.value() <= 9_999,
        blast_fun::errors::protocol_channel_mismatch!(),
    );

    self.protocol_allocation =
        option::some(ProtocolAllocation { channel_id, destination, meme_bps, quote_bps });

    events::protocol_allocation_configured(
        channel_id,
        destination,
        meme_bps.value(),
        quote_bps.value(),
    );
}

/// Admits one decimal precision for launch intake.
public fun allow_meme_decimals(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    decimals: u8,
) {
    package_version.assert_current();

    if (!self.meme_decimals.contains(&decimals)) {
        self.meme_decimals.insert(decimals);

        events::meme_decimals_allowed(decimals);
    };
}

/// Disallows one decimal precision at launch intake, including for tickets that already exist.
public fun disallow_meme_decimals(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    decimals: u8,
) {
    package_version.assert_current();
    assert!(self.meme_decimals.contains(&decimals), blast_fun::errors::decimals_not_allowed!());

    self.meme_decimals.remove(&decimals);

    events::meme_decimals_disallowed(decimals);
}

/// Admits one quote, or replaces the virtual reserve future launches on it start from.
public fun allow_quote<Quote>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    virtual_quote: u64,
) {
    package_version.assert_current();
    assert!(virtual_quote > 0, blast_fun::errors::invalid_virtual_quote!());
    let quote = type_name::with_original_ids<Quote>();

    if (self.quotes.contains(quote)) {
        let stored = &mut self.quotes[quote];
        assert!(*stored != virtual_quote, blast_fun::errors::quote_parameters_unchanged!());
        *stored = virtual_quote;
    } else {
        self.quotes.add(quote, virtual_quote);
    };

    events::quote_allowed<Quote>(virtual_quote);
}

/// Disallows one quote from launches created afterward.
public fun disallow_quote<Quote>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
) {
    package_version.assert_current();

    let quote = type_name::with_original_ids<Quote>();

    assert!(self.quotes.contains(quote), blast_fun::errors::quote_not_allowed!());

    self.quotes.remove(quote);
    events::quote_disallowed<Quote>();
}

/// Changes the trade-fee pair snapshotted by launches created afterward.
public fun set_trade_fees(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
) {
    package_version.assert_current();
    self.assert_valid_trade_fees(quote_fee_bps, meme_fee_bps);

    self.quote_fee_bps = quote_fee_bps;
    self.meme_fee_bps = meme_fee_bps;

    events::launch_trade_fees_changed(quote_fee_bps.value(), meme_fee_bps.value());
}

/// Admits one external migrator's sealed witness type: its adapter may then start launches, borrow
/// the initializer's treasury capability while it prepares its venue, and migrate them.
///
/// Primitive, vector, and `0x1`/`0x2` framework types are rejected because any caller can
/// construct them, and a migration witness receives the launch's liquidity principal.
public fun allow_migration_witness<MigrationWitness: drop>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
) {
    package_version.assert_current();

    let migration_witness = type_name::with_original_ids<MigrationWitness>();

    assert!(
        !migration_witness.is_primitive(),
        blast_fun::errors::invalid_migration_witness_type!(),
    );
    let origin = type_name::original_id<MigrationWitness>();
    assert!(origin != @0x1 && origin != @0x2, blast_fun::errors::invalid_migration_witness_type!());
    assert!(
        !self.migration_witnesses.contains(&migration_witness),
        blast_fun::errors::migration_witness_already_allowed!(),
    );
    assert!(
        self.migration_witnesses.length()
            < constants::max_migration_witnesses!(),
        blast_fun::errors::migration_witness_capacity_reached!(),
    );

    self.migration_witnesses.insert(migration_witness);

    events::migration_witness_allowed<MigrationWitness>();
}

/// Removes one external migrator witness type: its adapter can no longer start launches; existing
/// launches keep their stored witness.
public fun disallow_migration_witness<MigrationWitness: drop>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
) {
    package_version.assert_current();

    let migration_witness = type_name::with_original_ids<MigrationWitness>();

    assert!(
        self.migration_witnesses.contains(&migration_witness),
        blast_fun::errors::migration_witness_not_allowed!(),
    );

    self.migration_witnesses.remove(&migration_witness);

    events::migration_witness_disallowed<MigrationWitness>();
}

// === Package Functions ===

/// Requires explicit initialization and validates the sealed launch plan against the immutable policy.
public(package) fun assert_allocation_policy(
    self: &LaunchConfig,
    plan: &blast_fun::allocation::AllocationPlan,
) {
    assert!(self.protocol_allocation.is_some(), blast_fun::errors::protocol_channel_mismatch!());
    let policy = self.protocol_allocation.borrow();
    plan.assert_protocol_policy(
        policy.channel_id,
        policy.meme_bps,
        policy.quote_bps,
        policy.destination,
    );
}

/// Validates the launch Quote and the starting adapter's witness against the allowlists and
/// returns all cold policy to snapshot into launch state.
public(package) fun snapshot_for_launch<Quote>(
    self: &LaunchConfig,
    migration_witness: TypeName,
): (u64, Bps, Bps) {
    let quote = type_name::with_original_ids<Quote>();

    assert!(self.quotes.contains(quote), blast_fun::errors::quote_not_allowed!());
    assert!(
        self.migration_witnesses.contains(&migration_witness),
        blast_fun::errors::migration_witness_not_allowed!(),
    );

    (self.quotes[quote], self.quote_fee_bps, self.meme_fee_bps)
}

/// Aborts unless `decimals` is admitted for launches created now.
public(package) fun assert_decimals_allowed(self: &LaunchConfig, decimals: u8) {
    assert!(self.meme_decimals.contains(&decimals), blast_fun::errors::decimals_not_allowed!());
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
        protocol_allocation: option::none(),
    }
}

fun assert_valid_trade_fees(self: &LaunchConfig, quote_fee_bps: Bps, meme_fee_bps: Bps) {
    assert!(
        quote_fee_bps.value() <= constants::max_launch_fee_bps!(),
        blast_fun::errors::invalid_quote_fee_bps!(),
    );
    assert!(
        meme_fee_bps.value() <= constants::max_launch_fee_bps!(),
        blast_fun::errors::invalid_meme_fee_bps!(),
    );
    assert!(
        quote_fee_bps != self.quote_fee_bps
            || meme_fee_bps != self.meme_fee_bps,
        blast_fun::errors::trade_fee_defaults_unchanged!(),
    );
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Creates unshared cold launch policy for focused construction tests.
public fun new_for_testing(ctx: &mut TxContext): LaunchConfig {
    new(ctx)
}

#[test_only]
/// Returns the number of quotes currently admitted by focused tests.
public fun allowed_quote_count_for_testing(self: &LaunchConfig): u64 {
    self.quotes.length()
}

#[test_only]
/// Returns the number of decimal precisions admitted by focused tests.
public fun allowed_meme_decimals_count_for_testing(self: &LaunchConfig): u64 {
    self.meme_decimals.length()
}

#[test_only]
/// Returns the trade rate defaults inspected by focused tests.
public fun rate_defaults_for_testing(self: &LaunchConfig): (u64, u64) {
    (self.quote_fee_bps.value(), self.meme_fee_bps.value())
}

#[test_only]
/// Returns the number of migration witnesses admitted by focused tests.
public fun allowed_migration_witness_count_for_testing(self: &LaunchConfig): u64 {
    self.migration_witnesses.length()
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::{
    bps::{Self, Bps},
    constants,
    events,
    blast_fun_domain::BLAST_FUN_DOMAIN,
    package_version::PackageVersion,
};

use std::type_name::{Self, TypeName};

use sui::{table::{Self, Table}, vec_set::{Self, VecSet}};
