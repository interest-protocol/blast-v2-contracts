/// Canonical package marker for this adapter.
module blast_boosts_aftermath::aftermath;

// === Public Structs ===

/// One-time witness used only to claim this package's Publisher.
public struct AFTERMATH() has drop;

// === Private Initialization ===

fun init(otw: AFTERMATH, ctx: &mut TxContext) {
    sui::package::claim_and_keep(otw, ctx);
}

// === Test-Only Functions ===

#[test_only]
/// Runs package-marker initialization with a genuine test one-time witness.
///
/// The shared operational generation is created by `protocol::init`, which owns
/// the container that names this marker. Keeping the two initializers apart is
/// what lets the container type this marker without a module cycle.
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<AFTERMATH>(), ctx);
}

#[test_only]
/// Creates the canonical Publisher without transferring it.
public fun publisher_for_testing(ctx: &mut TxContext): Publisher {
    sui::package::test_claim(AFTERMATH(), ctx)
}

// === Imports ===

use sui::package::Publisher;
