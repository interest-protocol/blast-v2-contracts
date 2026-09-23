// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_boosts_products::blast_boosts_products_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

// === Tests ===

#[test]
fun package_init_claims_and_keeps_publisher() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    marker::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let publisher = scenario.take_from_sender<Publisher>();
    assert!(publisher.from_module<BLAST_BOOSTS_PRODUCTS>());
    assert!(publisher.from_package<BLAST_BOOSTS_PRODUCTS>());

    scenario.return_to_sender(publisher);
    scenario.end();
}

#[test]
fun product_tags_are_distinct_non_primitive_types() {
    let bull = type_name::with_original_ids<NVDA_BULL_2X>();
    let bear = type_name::with_original_ids<NVDA_BEAR_2X>();

    assert!(!bull.is_primitive());
    assert!(!bear.is_primitive());
    assert!(bull != bear);
    assert!(bull.module_string() == b"blast_boosts_products".to_ascii_string());
}

// === Imports ===

use blast_boosts_products::blast_boosts_products::{Self as marker, BLAST_BOOSTS_PRODUCTS, NVDA_BEAR_2X, NVDA_BULL_2X};

use std::type_name;

use sui::{package::Publisher, test_scenario};
