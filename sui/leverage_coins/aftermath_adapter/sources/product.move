/// Stateless adapter-owned product witnesses for leverage currencies.
module blast_leverage_aftermath::product;

// === Public Structs ===

/// A product identity scoped by an arbitrary phantom tag.
///
/// The value carries no authority. Series1 administration still authorizes
/// Vault issuance, and Coin Registry makes each `Vault<Product<Tag>>`
/// currency unique.
public struct Product<phantom Tag>() has drop;

// === Public Functions ===

/// Creates a stateless product witness for one tag-defined currency type.
public fun new<Tag>(): Product<Tag> {
    Product()
}
