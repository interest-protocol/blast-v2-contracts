#[test_only]
/// Tests for generic adapter-owned product witnesses.
module blast_leverage_aftermath::product_tests;

use blast_leverage_aftermath::{aftermath::AFTERMATH, product::{Self, Product}};
use std::{type_name, unit_test::assert_eq};

// === Test Tags ===

public struct TwoX() has drop;

public struct FiveX() has drop;

// === Tests ===

#[test]
fun tags_create_distinct_products_from_the_adapter_package() {
    let two_x = product::new<TwoX>();
    let five_x = product::new<FiveX>();

    assert_eq!(
        type_name::original_id<Product<TwoX>>(),
        type_name::original_id<AFTERMATH>(),
    );
    assert_eq!(
        type_name::original_id<Product<FiveX>>(),
        type_name::original_id<AFTERMATH>(),
    );
    assert!(
        type_name::with_original_ids<Product<TwoX>>()
            != type_name::with_original_ids<Product<FiveX>>(),
    );

    std::unit_test::destroy(two_x);
    std::unit_test::destroy(five_x);
}

#[test]
fun one_tag_can_create_multiple_stateless_product_values() {
    let first = product::new<TwoX>();
    let second = product::new<TwoX>();

    std::unit_test::destroy(first);
    std::unit_test::destroy(second);
}
