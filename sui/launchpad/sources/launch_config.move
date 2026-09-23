// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one append-only registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
/// Cold launch-time policy snapshotted before bonding begins.
module blast_fun::launch_config;

// === Public Structs ===

/// Shared singleton containing cold policy snapshotted by each new launch.
public struct LaunchConfig has key {
    id: UID,
    quotes: Table<TypeName, QuoteParameters>,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
    protocol_quote_migration_fee_bps: Bps,
    protocol_meme_graduation_fee_bps: Bps,
    meme_liquidity_provision_bps: Bps,
    migration_witnesses: VecSet<TypeName>,
}

/// Immutable curve-shape and terminal parameters admitted for one Quote type.
public struct QuoteParameters has copy, drop, store {
    virtual_quote: u64,
    migration_quote_target: u64,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Admits one quote with a migration target of at least two atomic units.
public fun allow_quote<Quote>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    virtual_quote: u64,
    migration_quote_target: u64,
) {
    package_version.assert_current();

    assert!(
        virtual_quote > 0,
        blast_fun::errors::invalid_virtual_quote!(),
    );
    assert!(
        migration_quote_target > 1,
        blast_fun::errors::invalid_migration_quote_target!(),
    );

    let quote = type_name::with_original_ids<Quote>();

    if (self.quotes.contains(quote)) {
        self.update_quote<Quote>(
            quote,
            virtual_quote,
            migration_quote_target,
        );
    } else {
        self.insert_quote<Quote>(quote, virtual_quote, migration_quote_target);
    };
}

/// Disallows one quote from launches created afterward.
public fun disallow_quote<Quote>(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
) {
    package_version.assert_current();

    let quote = type_name::with_original_ids<Quote>();

    assert!(
        self.quotes.contains(quote),
        blast_fun::errors::quote_not_allowed!(),
    );

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

/// Changes the graduation economics snapshotted by launches created afterward.
public fun set_graduation_defaults(
    self: &mut LaunchConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    protocol_quote_migration_fee_bps: Bps,
    protocol_meme_graduation_fee_bps: Bps,
    meme_liquidity_provision_bps: Bps,
) {
    package_version.assert_current();
    self.assert_valid_graduation_defaults(
        protocol_quote_migration_fee_bps,
        protocol_meme_graduation_fee_bps,
        meme_liquidity_provision_bps,
    );

    self.protocol_quote_migration_fee_bps = protocol_quote_migration_fee_bps;
    self.protocol_meme_graduation_fee_bps = protocol_meme_graduation_fee_bps;
    self.meme_liquidity_provision_bps = meme_liquidity_provision_bps;

    events::graduation_defaults_changed(
        protocol_quote_migration_fee_bps.value(),
        protocol_meme_graduation_fee_bps.value(),
        meme_liquidity_provision_bps.value(),
    );
}

/// Allows future launches to select one external migrator's sealed witness type.
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

/// Disallows future launches from selecting one external migrator witness type.
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

/// Validates a launch quote and returns all cold policy to snapshot into launch state.
public(package) fun snapshot_for_launch<Quote, MigrationWitness: drop>(
    self: &LaunchConfig,
): (u64, u64, Bps, Bps, Bps, Bps, Bps, TypeName) {
    let quote = type_name::with_original_ids<Quote>();

    assert!(
        self.quotes.contains(quote),
        blast_fun::errors::quote_not_allowed!(),
    );

    let parameters = &self.quotes[quote];
    let migration_witness = type_name::with_original_ids<MigrationWitness>();

    assert!(
        self.migration_witnesses.contains(&migration_witness),
        blast_fun::errors::migration_witness_not_allowed!(),
    );
    assert!(
        self.meme_liquidity_provision_bps.value() > 0,
        blast_fun::errors::invalid_meme_liquidity_provision_bps!(),
    );

    (
        parameters.virtual_quote,
        parameters.migration_quote_target,
        self.quote_fee_bps,
        self.meme_fee_bps,
        self.protocol_quote_migration_fee_bps,
        self.protocol_meme_graduation_fee_bps,
        self.meme_liquidity_provision_bps,
        migration_witness,
    )
}

// === Private Functions ===

fun new(ctx: &mut TxContext): LaunchConfig {
    LaunchConfig {
        id: object::new(ctx),
        quotes: table::new(ctx),
        quote_fee_bps: bps::new(0),
        meme_fee_bps: bps::new(0),
        protocol_quote_migration_fee_bps: bps::new(0),
        protocol_meme_graduation_fee_bps: bps::new(0),
        meme_liquidity_provision_bps: bps::new(0),
        migration_witnesses: vec_set::empty(),
    }
}

fun update_quote<Quote>(
    self: &mut LaunchConfig,
    quote: TypeName,
    virtual_quote: u64,
    migration_quote_target: u64,
) {
    let quote_parameters_mut = &mut self.quotes[quote];
    let old_virtual_quote = quote_parameters_mut.virtual_quote;
    let old_migration_quote_target = quote_parameters_mut.migration_quote_target;

    assert!(
        virtual_quote != old_virtual_quote
            || migration_quote_target != old_migration_quote_target,
        blast_fun::errors::quote_parameters_unchanged!(),
    );

    *quote_parameters_mut = QuoteParameters {
        virtual_quote,
        migration_quote_target,
    };

    events::quote_parameters_changed<Quote>(
        virtual_quote,
        migration_quote_target,
    );
}

fun insert_quote<Quote>(
    self: &mut LaunchConfig,
    quote: TypeName,
    virtual_quote: u64,
    migration_quote_target: u64,
) {
    self.quotes.add(quote, QuoteParameters {
        virtual_quote,
        migration_quote_target,
    });

    events::quote_allowed<Quote>(virtual_quote, migration_quote_target);
}

fun assert_valid_trade_fees(
    self: &LaunchConfig,
    quote_fee_bps: Bps,
    meme_fee_bps: Bps,
) {
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

fun assert_valid_graduation_defaults(
    self: &LaunchConfig,
    protocol_quote_migration_fee_bps: Bps,
    protocol_meme_graduation_fee_bps: Bps,
    meme_liquidity_provision_bps: Bps,
) {
    assert!(
        protocol_quote_migration_fee_bps.value() <= constants::max_protocol_quote_migration_fee_bps!(),
        blast_fun::errors::invalid_protocol_quote_migration_fee_bps!(),
    );
    assert!(
        protocol_meme_graduation_fee_bps.value()
            <= constants::max_protocol_meme_graduation_fee_bps!(),
        blast_fun::errors::invalid_protocol_meme_graduation_fee_bps!(),
    );
    assert!(
        meme_liquidity_provision_bps.value() > 0
            && meme_liquidity_provision_bps.value()
                < constants::basis_points_denominator!(),
        blast_fun::errors::invalid_meme_liquidity_provision_bps!(),
    );
    assert!(
        protocol_meme_graduation_fee_bps.value() + meme_liquidity_provision_bps.value()
            < constants::basis_points_denominator!(),
        blast_fun::errors::invalid_meme_supply_partition_bps!(),
    );
    assert!(
        protocol_quote_migration_fee_bps != self.protocol_quote_migration_fee_bps
            || protocol_meme_graduation_fee_bps != self.protocol_meme_graduation_fee_bps
            || meme_liquidity_provision_bps != self.meme_liquidity_provision_bps,
        blast_fun::errors::graduation_defaults_unchanged!(),
    );
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Returns the number of quotes currently admitted by focused tests.
public fun allowed_quote_count_for_testing(self: &LaunchConfig): u64 {
    self.quotes.length()
}

#[test_only]
/// Returns the five stored rate defaults inspected by focused tests.
public fun rate_defaults_for_testing(self: &LaunchConfig): (u64, u64, u64, u64, u64) {
    (
        self.quote_fee_bps.value(),
        self.meme_fee_bps.value(),
        self.protocol_quote_migration_fee_bps.value(),
        self.protocol_meme_graduation_fee_bps.value(),
        self.meme_liquidity_provision_bps.value(),
    )
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

use sui::{
    table::{Self, Table},
    vec_set::{Self, VecSet},
};
