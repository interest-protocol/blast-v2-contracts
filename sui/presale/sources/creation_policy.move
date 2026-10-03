// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast's allowlists for new presales: the Quote coins a sale may raise and the migrators that
/// may create one.
///
/// A presale is checked once, when it is created. Later changes apply only to later sales, so a
/// delisting never strands a live sale's commitments or blocks its migration.
module blast_presale::creation_policy;

// === Public Types ===

/// Shared singleton holding the Quote types and migration witnesses new presales may use.
public struct CreationPolicy has key {
    id: UID,
    allowed_quotes: VecSet<TypeName>,
    allowed_migration_witnesses: VecSet<TypeName>,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Allows or disallows `Quote` for presales created afterward; existing sales keep it.
public fun set_quote_allowed<Quote>(
    self: &mut CreationPolicy,
    admin_registry: &AdminRegistry,
    admin_cap: &AdminCap,
    allowed: bool,
) {
    admin_registry.assert_admin_cap(admin_cap);
    let quote = type_name::with_original_ids<Quote>();
    assert!(self.allowed_quotes.contains(&quote) != allowed, EAllowanceUnchanged);

    if (allowed) self.allowed_quotes.insert(quote) else self.allowed_quotes.remove(&quote);

    event::emit(QuoteSet { quote, allowed });
}

/// Allows or disallows the migrator identified by `MigrationWitness` to create presales
/// afterward; existing sales still migrate through it.
public fun set_migration_witness_allowed<MigrationWitness: drop>(
    self: &mut CreationPolicy,
    admin_registry: &AdminRegistry,
    admin_cap: &AdminCap,
    allowed: bool,
) {
    admin_registry.assert_admin_cap(admin_cap);
    let migration_witness = type_name::with_original_ids<MigrationWitness>();
    assert!(
        self.allowed_migration_witnesses.contains(&migration_witness) != allowed,
        EAllowanceUnchanged,
    );

    if (allowed) self.allowed_migration_witnesses.insert(migration_witness)
    else self.allowed_migration_witnesses.remove(&migration_witness);

    event::emit(MigrationWitnessSet { migration_witness, allowed });
}

// === Package Functions ===

/// Aborts unless a new presale may raise `Quote` and be created by `MigrationWitness`'s migrator.
public(package) fun assert_allowed<Quote, MigrationWitness>(self: &CreationPolicy) {
    assert!(
        self.allowed_quotes.contains(&type_name::with_original_ids<Quote>()),
        EQuoteNotAllowed,
    );
    assert!(
        self
            .allowed_migration_witnesses
            .contains(&type_name::with_original_ids<MigrationWitness>()),
        EMigrationWitnessNotAllowed,
    );
}

// === Private Functions ===

fun new(ctx: &mut TxContext): CreationPolicy {
    CreationPolicy {
        id: object::new(ctx),
        allowed_quotes: vec_set::empty(),
        allowed_migration_witnesses: vec_set::empty(),
    }
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): CreationPolicy {
    new(ctx)
}

/// A policy that allows exactly `Quote` and `MigrationWitness`.
#[test_only]
public fun allowing_for_testing<Quote, MigrationWitness>(ctx: &mut TxContext): CreationPolicy {
    let mut policy = new(ctx);
    policy.allowed_quotes.insert(type_name::with_original_ids<Quote>());
    policy.allowed_migration_witnesses.insert(type_name::with_original_ids<MigrationWitness>());

    policy
}

#[test_only]
public fun destroy_for_testing(self: CreationPolicy) {
    let CreationPolicy { id, allowed_quotes: _, allowed_migration_witnesses: _ } = self;
    id.delete();
}

#[test_only]
public fun quote_set_fields(event: &QuoteSet): (TypeName, bool) {
    (event.quote, event.allowed)
}

#[test_only]
public fun migration_witness_set_fields(event: &MigrationWitnessSet): (TypeName, bool) {
    (event.migration_witness, event.allowed)
}

// === Events ===

/// Presales created afterward may (`allowed`) or may not raise `quote`.
public struct QuoteSet has copy, drop {
    quote: TypeName,
    allowed: bool,
}

/// The migrator identified by `migration_witness` may (`allowed`) or may not create presales
/// afterward.
public struct MigrationWitnessSet has copy, drop {
    migration_witness: TypeName,
    allowed: bool,
}

// === Errors ===

#[error(code = 0)]
const EAllowanceUnchanged: vector<u8> = b"An allowlist update must change whether the type is allowed.";

#[error(code = 1)]
const EQuoteNotAllowed: vector<u8> = b"This Quote type is not allowed for new presales.";

#[error(code = 2)]
const EMigrationWitnessNotAllowed: vector<u8> = b"This migration witness is not allowed for new presales.";

// === Imports ===

use blast_presale::blast_presale_admin::{AdminCap, AdminRegistry};

use std::type_name::{Self, TypeName};

use sui::{event, vec_set::{Self, VecSet}};
