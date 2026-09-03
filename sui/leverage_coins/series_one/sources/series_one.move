/// Canonical provenance marker for the Series1 package Publisher.
module blast_leverage_series_one::series_one;

use sui::package::Publisher;

// === Public Structs ===

/// One-time package witness used only to claim the canonical Publisher.
public struct SERIES_ONE() has drop;

// === Private Initialization ===

fun init(otw: SERIES_ONE, ctx: &mut TxContext) {
    sui::package::claim_and_keep(otw, ctx);
}

// === Test-Only Functions ===

#[test_only]
/// Runs Publisher initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<SERIES_ONE>(), ctx);
}

#[test_only]
/// Creates the canonical Publisher without transferring it to a sender.
public fun publisher_for_testing(ctx: &mut TxContext): Publisher {
    sui::package::test_claim(SERIES_ONE(), ctx)
}
