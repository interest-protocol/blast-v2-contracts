/// Canonical package provenance witness for the holder-rewards distributor.
///
/// This marker types the package's own operational generation and upgrade
/// custody. Distributor reuses the Launchpad administration domain for
/// membership; it never creates a second authority.
module blast_fun_distributor::package_marker;

// === Public Structs ===

/// One-time witness used only to claim this package's Publisher.
public struct PACKAGE_MARKER has drop {}

// === Private Initialization ===

fun init(otw: PACKAGE_MARKER, ctx: &mut TxContext) {
    sui::package::claim_and_keep(otw, ctx);
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<PACKAGE_MARKER>(), ctx);
}

#[test_only]
public fun publisher_for_testing(ctx: &mut TxContext): sui::package::Publisher {
    sui::package::test_claim(PACKAGE_MARKER {}, ctx)
}
