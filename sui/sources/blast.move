/// Package provenance and Publisher custody bootstrap.
module blast_fun::blast;

// === Public Structs ===

/// Canonical one-time witness used only to claim this package's Publisher.
public struct BLAST() has drop;

// === Private Initialization ===

fun init(otw: BLAST, ctx: &mut TxContext) {
    sui::package::claim_and_keep(otw, ctx);
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(BLAST(), ctx);
}

#[test_only]
/// Claims an additional canonical-module Publisher for package-administration fixture inputs.
public fun publisher_for_testing(ctx: &mut TxContext): sui::package::Publisher {
    sui::package::test_claim(BLAST(), ctx)
}
