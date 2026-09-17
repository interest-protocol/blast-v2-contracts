/// Aftermath adapter operational generation.
///
/// The generation value, its checked arithmetic, and its replay event belong to
/// `blast_admin::operational_version`. This module owns only the shared
/// container and the two compiled constants that identify this bytecode and the
/// bytecode a governed upgrade cuts over to.
module blast_leverage_aftermath::protocol;

// === Constants ===

/// Current adapter generation accepted by every protected mutation.
const PACKAGE_VERSION: u64 = 1;

/// The generation this bytecode hands over to in a governed upgrade.
const NEXT_PACKAGE_VERSION: u64 = 2;

// === Public Structs ===

/// Shared operational generation for the Aftermath adapter package.
public struct Protocol has key {
    id: UID,
    generation: OperationalVersion<AFTERMATH>,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Package Functions ===

/// Rejects bytecode that is not the active adapter generation.
public(package) fun assert_current(self: &Protocol) {
    self.generation.assert_current(PACKAGE_VERSION);
}

/// Proves the cutover target is exactly next before any upgrade finalizer effect.
public(package) fun assert_next(self: &Protocol) {
    self.generation.assert_next(NEXT_PACKAGE_VERSION);
}

/// Advances the generation to the exact bytecode this upgrade installs.
public(package) fun advance(self: &mut Protocol) {
    let container_id = self.id.to_inner();

    self.generation.advance(container_id, NEXT_PACKAGE_VERSION);
}

// === Private Functions ===

fun new(ctx: &mut TxContext): Protocol {
    Protocol { id: object::new(ctx), generation: operational_version::new() }
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): Protocol {
    new(ctx)
}

#[test_only]
public fun id_for_testing(self: &Protocol): ID {
    self.id.to_inner()
}

#[test_only]
public fun version_for_testing(self: &Protocol): u64 {
    self.generation.generation_for_testing()
}

#[test_only]
public fun set_version_for_testing(self: &mut Protocol, version: u64) {
    self.generation.set_generation_for_testing(version);
}

#[test_only]
/// Exercises the compiled cutover target without a native upgrade fixture.
public fun advance_for_testing(self: &mut Protocol) {
    self.advance();
}

#[test_only]
/// Exercises the finalizer's pre-commit proof without a native upgrade fixture.
public fun assert_next_for_testing(self: &Protocol) {
    self.assert_next();
}

#[test_only]
/// Exercises the generation guard every protected mutation runs first.
public fun assert_current_for_testing(self: &Protocol) {
    self.assert_current();
}

// === Imports ===

use blast_admin::operational_version::{Self, OperationalVersion};

use blast_leverage_aftermath::aftermath::AFTERMATH;
