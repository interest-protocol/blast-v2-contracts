// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Canonical package provenance witness for the aggregate migrators package, and its own
/// operational generation.
///
/// `init` seeds the generation from the one-time witness and then claims the Publisher with it,
/// so no other package can create this package's generation. The marker never declares an
/// administration role: Migrators reuses the Launchpad's roles in the shared Blast ACL and owns
/// only its package-local state. Migrators does not treat the Launchpad generation as its own;
/// a composed call that mutates both packages supplies both version objects, because each
/// package checks only the transitions it implements.
module blast_fun_migrators::blast_fun_migrators;

// === Public Types ===

/// One-time witness: it seeds the package generation and claims this package's Publisher.
public struct BLAST_FUN_MIGRATORS has drop {}

/// Singleton operational package generation.
public struct PackageVersion has key {
    id: UID,
    generation: OperationalVersion<BLAST_FUN_MIGRATORS>,
}

// === Private Initialization ===

/// Shares the generation seeded from the one-time witness, then claims the Publisher with it.
fun init(otw: BLAST_FUN_MIGRATORS, ctx: &mut TxContext) {
    transfer::share_object(new(&otw, ctx));
    sui::package::claim_and_keep(otw, ctx);
}

// === Package Functions ===

/// Rejects callable bytecode from every package generation except the active one.
public(package) fun assert_current(self: &PackageVersion) {
    self.generation.assert_current(PACKAGE_VERSION);
}

/// Proves the cutover target is exactly next before any upgrade finalizer effect.
public(package) fun assert_next(self: &PackageVersion) {
    self.generation.assert_next(NEXT_PACKAGE_VERSION);
}

/// Advances the shared generation to the exact bytecode this upgrade installs.
public(package) fun advance(self: &mut PackageVersion) {
    self.generation.advance(&self.id, NEXT_PACKAGE_VERSION);
}

// === Private Functions ===

/// Builds the unshared generation singleton at the one-time witness's seed generation.
fun new(otw: &BLAST_FUN_MIGRATORS, ctx: &mut TxContext): PackageVersion {
    PackageVersion {
        id: object::new(ctx),
        generation: operational_version::new(otw),
    }
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(BLAST_FUN_MIGRATORS {}, ctx);
}

#[test_only]
/// Creates unshared current package-version state for focused tests.
public fun new_for_testing(ctx: &mut TxContext): PackageVersion {
    let otw = BLAST_FUN_MIGRATORS {};

    new(&otw, ctx)
}

#[test_only]
/// Forces a package generation for guard and cutover tests.
public fun set_for_testing(self: &mut PackageVersion, version: u64) {
    self.generation.set_generation_for_testing(version);
}

#[test_only]
/// Returns the stored package generation for transition assertions.
public fun version_for_testing(self: &PackageVersion): u64 {
    self.generation.generation_for_testing()
}

#[test_only]
/// Exercises the compiled cutover target without a native upgrade fixture.
public fun advance_for_testing(self: &mut PackageVersion) {
    self.advance();
}

#[test_only]
/// Claims the canonical Publisher without transferring it.
public fun publisher_for_testing(ctx: &mut TxContext): sui::package::Publisher {
    sui::package::test_claim(BLAST_FUN_MIGRATORS {}, ctx)
}

// === Constants ===

/// Current package generation accepted by every protected mutation.
const PACKAGE_VERSION: u64 = 1;

/// The generation this bytecode hands over to in a governed upgrade.
const NEXT_PACKAGE_VERSION: u64 = 2;

// === Imports ===

use blast_admin::operational_version::{Self, OperationalVersion};
