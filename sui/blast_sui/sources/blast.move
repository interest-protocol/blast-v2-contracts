/// Canonical package provenance witness.
module blast_sui::blast;

// === Public Structs ===

/// One-time witness used only to claim this package's Publisher.
public struct BLAST() has drop;

// === Private Initialization ===

fun init(otw: BLAST, ctx: &mut TxContext) {
    sui::package::claim_and_keep(otw, ctx);
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization with a genuine test one-time witness.
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<BLAST>(), ctx);
}

#[test_only]
public fun publisher_for_testing(ctx: &mut TxContext): sui::package::Publisher {
    sui::package::test_claim(BLAST(), ctx)
}
