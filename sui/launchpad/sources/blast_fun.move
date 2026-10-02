// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Canonical package provenance witness named after the package, and the shared package version
/// every entry point checks so old bytecode stops after an upgrade.
///
/// Both come from the one-time witness: `init` seeds the generation from it and then claims the
/// Publisher with it, so no other package can ever create this package's generation.
module blast_fun::blast_fun;

// === Constants ===

/// Current package generation accepted by every protected mutation.
const PACKAGE_VERSION: u64 = 1;

/// The generation this bytecode hands over to in a governed upgrade.
const NEXT_PACKAGE_VERSION: u64 = 2;

// === Public Types ===

/// One-time witness: it seeds the package generation and claims this package's Publisher.
public struct BLAST_FUN() has drop;

/// Singleton operational package generation.
public struct PackageVersion has key {
    id: UID,
    generation: OperationalVersion<BLAST_FUN>,
}

// === Private Initialization ===

fun init(otw: BLAST_FUN, ctx: &mut TxContext) {
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

fun new(otw: &BLAST_FUN, ctx: &mut TxContext): PackageVersion {
    PackageVersion {
        id: object::new(ctx),
        generation: operational_version::new(otw),
    }
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(BLAST_FUN(), ctx);
}

#[test_only]
/// Creates unshared current package-version state for focused tests.
public fun new_for_testing(ctx: &mut TxContext): PackageVersion {
    let otw = BLAST_FUN();

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
/// Claims an additional canonical-module Publisher for package-administration fixture inputs.
public fun publisher_for_testing(ctx: &mut TxContext): sui::package::Publisher {
    sui::package::test_claim(BLAST_FUN(), ctx)
}

// === Imports ===

use blast_admin::operational_version::{Self, OperationalVersion};
