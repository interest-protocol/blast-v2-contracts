/// Canonical package provenance witness named after the package.
module blast_fun::blast_fun;

// === Public Structs ===

/// Canonical one-time witness used only to claim this package's Publisher.
public struct BLAST_FUN() has drop;

// === Private Initialization ===

fun init(otw: BLAST_FUN, ctx: &mut TxContext) {
    sui::package::claim_and_keep(otw, ctx);
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(BLAST_FUN(), ctx);
}

#[test_only]
/// Claims an additional canonical-module Publisher for package-administration fixture inputs.
public fun publisher_for_testing(ctx: &mut TxContext): sui::package::Publisher {
    sui::package::test_claim(BLAST_FUN(), ctx)
}
