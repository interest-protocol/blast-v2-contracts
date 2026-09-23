// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Owns the one shared package-generation cutover used by every mutable protocol object.
///
/// The generation value, its arithmetic, and its replay event belong to
/// `blast_admin::operational_version`. This module owns only the canonical
/// shared container and the two compiled constants that identify this bytecode
/// and the bytecode a governed upgrade cuts over to.
module blast_fun::package_version;

// === Constants ===

/// Current Blast package generation accepted by the shared cutover.
const PACKAGE_VERSION: u64 = 1;

/// The generation this bytecode hands over to in a governed upgrade.
const NEXT_PACKAGE_VERSION: u64 = 2;

// === Public Types ===

/// Singleton operational package generation.
public struct PackageVersion has key {
    id: UID,
    generation: OperationalVersion<BLAST_FUN>,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
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
    let container_id = self.id.to_inner();

    self.generation.advance(container_id, NEXT_PACKAGE_VERSION);
}

// === Private Functions ===

fun new(ctx: &mut TxContext): PackageVersion {
    PackageVersion {
        id: object::new(ctx),
        generation: operational_version::new(),
    }
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Creates unshared current package-version state for focused tests.
public fun new_for_testing(ctx: &mut TxContext): PackageVersion {
    new(ctx)
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

// === Imports ===

use blast_admin::operational_version::{Self, OperationalVersion};

use blast_fun::blast_fun::BLAST_FUN;
