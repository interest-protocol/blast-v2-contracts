// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations and the stable code map documented in `docs/error-codes.md`.
#[allow(lint(abort_without_constant))]
/// Cold launch-time policy snapshotted before bonding begins.
module blast_fun::launch_config;

use blast_fun::{acl::AdminWitness, constants, events};
use std::type_name::{Self, TypeName};
use sui::{
    vec_map::{Self, VecMap},
    vec_set::{Self, VecSet},
};

// === Public Structs ===

/// Shared singleton containing cold policy snapshotted by each new launch.
public struct LaunchConfig has key {
    id: UID,
    quotes: VecMap<TypeName, QuoteParameters>,
    quote_migration_fee_bps: u64,
    protocol_meme_graduation_fee_bps: u64,
    meme_liquidity_provision_bps: u64,
    migration_witnesses: VecSet<TypeName>,
}

/// Immutable curve-shape and terminal parameters admitted for one Quote type.
public struct QuoteParameters has copy, drop, store {
    virtual_quote: u64,
    migration_quote_target: u64,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    let config = new(ctx);
    let config_id = config.id.to_inner();
    let quote_migration_fee_bps = config.quote_migration_fee_bps;
    let protocol_meme_graduation_fee_bps = config.protocol_meme_graduation_fee_bps;
    let meme_liquidity_provision_bps = config.meme_liquidity_provision_bps;

    transfer::share_object(config);

    events::launch_config_created(
        config_id,
        constants::max_quote_assets!(),
        constants::max_migration_witnesses!(),
        quote_migration_fee_bps,
        protocol_meme_graduation_fee_bps,
        meme_liquidity_provision_bps,
    );
}

// === Public Functions ===

/// Admits one quote type or updates its curve parameters for launches created afterward.
public fun allow_quote<Quote>(
    self: &mut LaunchConfig,
    _: &AdminWitness,
    virtual_quote: u64,
    migration_quote_target: u64,
) {
    assert!(
        virtual_quote > 0,
        blast_fun::errors::invalid_virtual_quote!(),
    );
    assert!(
        migration_quote_target > 0,
        blast_fun::errors::invalid_migration_quote_target!(),
    );

    let quote = type_name::with_original_ids<Quote>();
    let quote_index = self.quotes.get_idx_opt(&quote);

    if (quote_index.is_some()) {
        let (_, current_parameters) = self.quotes.get_entry_by_idx_mut(
            quote_index.destroy_some(),
        );
        let old_virtual_quote = current_parameters.virtual_quote;
        let old_migration_quote_target = current_parameters.migration_quote_target;

        assert!(
            virtual_quote != old_virtual_quote
                || migration_quote_target != old_migration_quote_target,
            blast_fun::errors::quote_parameters_unchanged!(),
        );

        *current_parameters = QuoteParameters {
            virtual_quote,
            migration_quote_target,
        };

        events::quote_parameters_changed<Quote>(
            old_virtual_quote,
            old_migration_quote_target,
            virtual_quote,
            migration_quote_target,
        );
    } else {
        assert!(
            self.quotes.length() < constants::max_quote_assets!(),
            blast_fun::errors::quote_capacity_reached!(),
        );

        self.quotes.insert(quote, QuoteParameters {
            virtual_quote,
            migration_quote_target,
        });

        events::quote_allowed<Quote>(virtual_quote, migration_quote_target);
    };
}

/// Disallows one quote from launches created afterward.
public fun disallow_quote<Quote>(self: &mut LaunchConfig, _: &AdminWitness) {
    let quote = type_name::with_original_ids<Quote>();
    let quote_index = self.quotes.get_idx_opt(&quote);

    assert!(
        quote_index.is_some(),
        blast_fun::errors::quote_not_allowed!(),
    );

    let (_, previous_parameters) = self.quotes.remove_entry_by_idx(
        quote_index.destroy_some(),
    );

    events::quote_disallowed<Quote>(
        previous_parameters.virtual_quote,
        previous_parameters.migration_quote_target,
    );
}

/// Changes the graduation economics snapshotted by launches created afterward.
public fun set_graduation_defaults(
    self: &mut LaunchConfig,
    _: &AdminWitness,
    quote_migration_fee_bps: u64,
    protocol_meme_graduation_fee_bps: u64,
    meme_liquidity_provision_bps: u64,
) {
    assert!(
        quote_migration_fee_bps <= constants::max_quote_migration_fee_bps!(),
        blast_fun::errors::invalid_quote_migration_fee_bps!(),
    );
    assert!(
        protocol_meme_graduation_fee_bps
            <= constants::max_protocol_meme_graduation_fee_bps!(),
        blast_fun::errors::invalid_protocol_meme_graduation_fee_bps!(),
    );
    assert!(
        meme_liquidity_provision_bps > 0
            && meme_liquidity_provision_bps
                <= constants::max_meme_liquidity_provision_bps!(),
        blast_fun::errors::invalid_meme_liquidity_provision_bps!(),
    );
    assert!(
        protocol_meme_graduation_fee_bps + meme_liquidity_provision_bps
            < constants::basis_points_denominator!(),
        blast_fun::errors::invalid_meme_supply_partition_bps!(),
    );
    assert!(
        quote_migration_fee_bps != self.quote_migration_fee_bps
            || protocol_meme_graduation_fee_bps
                != self.protocol_meme_graduation_fee_bps
            || meme_liquidity_provision_bps
                != self.meme_liquidity_provision_bps,
        blast_fun::errors::graduation_defaults_unchanged!(),
    );

    let old_quote_migration_fee_bps = self.quote_migration_fee_bps;
    let old_protocol_meme_graduation_fee_bps =
        self.protocol_meme_graduation_fee_bps;
    let old_meme_liquidity_provision_bps =
        self.meme_liquidity_provision_bps;

    self.quote_migration_fee_bps = quote_migration_fee_bps;
    self.protocol_meme_graduation_fee_bps = protocol_meme_graduation_fee_bps;
    self.meme_liquidity_provision_bps = meme_liquidity_provision_bps;

    events::graduation_defaults_changed(
        old_quote_migration_fee_bps,
        old_protocol_meme_graduation_fee_bps,
        old_meme_liquidity_provision_bps,
        quote_migration_fee_bps,
        protocol_meme_graduation_fee_bps,
        meme_liquidity_provision_bps,
    );
}

/// Allows future launches to select one external migrator's sealed witness type.
public fun allow_migration_witness<MigrationWitness: drop>(
    self: &mut LaunchConfig,
    _: &AdminWitness,
) {
    let migration_witness = type_name::with_original_ids<MigrationWitness>();

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
    _: &AdminWitness,
) {
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
): (u64, u64, u64, u64, u64, TypeName) {
    let quote = type_name::with_original_ids<Quote>();
    let quote_index = self.quotes.get_idx_opt(&quote);

    assert!(
        quote_index.is_some(),
        blast_fun::errors::quote_not_allowed!(),
    );

    let (_, parameters) = self.quotes.get_entry_by_idx(
        quote_index.destroy_some(),
    );
    let migration_witness = type_name::with_original_ids<MigrationWitness>();

    assert!(
        self.migration_witnesses.contains(&migration_witness),
        blast_fun::errors::migration_witness_not_allowed!(),
    );
    assert!(
        self.meme_liquidity_provision_bps > 0,
        blast_fun::errors::invalid_meme_liquidity_provision_bps!(),
    );

    (
        parameters.virtual_quote,
        parameters.migration_quote_target,
        self.quote_migration_fee_bps,
        self.protocol_meme_graduation_fee_bps,
        self.meme_liquidity_provision_bps,
        migration_witness,
    )
}

// === Private Functions ===

fun new(ctx: &mut TxContext): LaunchConfig {
    LaunchConfig {
        id: object::new(ctx),
        quotes: vec_map::empty(),
        quote_migration_fee_bps: 0,
        protocol_meme_graduation_fee_bps: 0,
        meme_liquidity_provision_bps: 0,
        migration_witnesses: vec_set::empty(),
    }
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
/// Returns the number of migration witnesses admitted by focused tests.
public fun allowed_migration_witness_count_for_testing(self: &LaunchConfig): u64 {
    self.migration_witnesses.length()
}
