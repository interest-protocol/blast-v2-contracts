/// Blast-owned product tags for Series1 Boost currencies.
///
/// A Boost currency is `blast_boost::BlastBoost<Product>` in the
/// issuing adapter, and its `Product` argument is what a holder reads inside
/// the coin type. Declaring every tag in this module keeps that inner type
/// under the Blast name: `blast_boosts_products::TSLA_3X`.
///
/// Each product is one empty `drop` struct named after its ticker, for example
/// `public struct TSLA_3X() has drop;`. A tag carries no authority and no
/// state: Coin Registry admits one currency per tag type, and the Series1
/// issuer role is the only authority that can issue it. Adding a tag is a
/// compatible upgrade of this package; nothing here is ever removed.
module blast_boosts_products::blast_boosts_products;

// === Public Structs ===

/// One-time witness used only to claim this package's Publisher.
public struct BLAST_BOOSTS_PRODUCTS() has drop;

// === Private Initialization ===

fun init(otw: BLAST_BOOSTS_PRODUCTS, ctx: &mut TxContext) {
    sui::package::claim_and_keep(otw, ctx);
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization with a genuine test one-time witness.
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<BLAST_BOOSTS_PRODUCTS>(), ctx);
}
