/// Canonical package marker for this adapter.
module blast_leverage_aftermath::aftermath;

use sui::package::Publisher;

// === Public Structs ===

/// One-time witness used only to claim this package's Publisher.
public struct AFTERMATH() has drop;

// === Private Initialization ===

fun init(otw: AFTERMATH, ctx: &mut TxContext) {
    sui::package::claim_and_keep(otw, ctx);

    let protocol = blast_leverage_aftermath::protocol::new(ctx);
    protocol.share();
}

// === Test-Only Functions ===

#[test_only]
/// Runs complete adapter initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<AFTERMATH>(), ctx);
}

#[test_only]
/// Creates the canonical Publisher without transferring it.
public fun publisher_for_testing(ctx: &mut TxContext): Publisher {
    sui::package::test_claim(AFTERMATH(), ctx)
}
