/// Canonical package marker for this adapter.
module blast_boosts_aftermath::blast_boosts_aftermath;

// === Public Types ===

/// One-time witness used only to claim this package's Publisher.
public struct BLAST_BOOSTS_AFTERMATH() has drop;

// === Private Initialization ===

fun init(otw: BLAST_BOOSTS_AFTERMATH, ctx: &mut TxContext) {
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
    init(sui::test_utils::create_one_time_witness<BLAST_BOOSTS_AFTERMATH>(), ctx);
}

#[test_only]
/// Creates the canonical Publisher without transferring it.
public fun publisher_for_testing(ctx: &mut TxContext): Publisher {
    sui::package::test_claim(BLAST_BOOSTS_AFTERMATH(), ctx)
}

// === Imports ===

use sui::package::Publisher;
