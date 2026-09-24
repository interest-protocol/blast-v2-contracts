// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// The migrators package's own operational generation.
///
/// Migrators no longer treats the Launchpad generation as its own. A composed
/// call that mutates both packages supplies both version objects, because each
/// package checks only the transitions it implements.
module blast_fun_migrators::package_version;

// === Constants ===

/// Current migrators generation accepted by every protected mutation.
const PACKAGE_VERSION: u64 = 1;

/// The generation this bytecode hands over to in a governed upgrade.
const NEXT_PACKAGE_VERSION: u64 = 2;

// === Public Types ===

/// Singleton operational generation for the aggregate migrators package.
public struct PackageVersion has key {
    id: UID,
    generation: OperationalVersion<BLAST_FUN_MIGRATORS>,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Package Functions ===

/// Proves the cutover target is exactly next before any upgrade finalizer effect.
public(package) fun assert_next(self: &PackageVersion) {
    self.generation.assert_next(NEXT_PACKAGE_VERSION);
}

/// Advances the generation to the exact bytecode this upgrade installs.
public(package) fun advance(self: &mut PackageVersion) {
    let container_id = self.id.to_inner();

    self.generation.advance(container_id, NEXT_PACKAGE_VERSION);
}

/// Rejects every migrators generation except the active one.
public(package) fun assert_current(self: &PackageVersion) {
    self.generation.assert_current(PACKAGE_VERSION);
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
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): PackageVersion {
    new(ctx)
}

#[test_only]
public fun set_for_testing(self: &mut PackageVersion, version: u64) {
    self.generation.set_generation_for_testing(version);
}

#[test_only]
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

use blast_fun_migrators::blast_fun_migrators::BLAST_FUN_MIGRATORS;
