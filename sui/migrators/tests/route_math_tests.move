// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_migrators::route_math_tests;

// === Test-Only Types ===

public struct TypeA() has drop;
public struct TypeB() has drop;

// === Tests ===

#[test]
fun tick_bits_encodes_negative_magnitudes_as_twos_complement() {
    // The Turbos full-range lower bound at tick spacing 60.
    assert_eq!(turbos::tick_bits_for_testing(443_580, true), 4_294_523_716);
    assert_eq!(turbos::tick_bits_for_testing(443_580, false), 443_580);
    assert_eq!(turbos::tick_bits_for_testing(1, true), 4_294_967_295);
    assert_eq!(turbos::tick_bits_for_testing(0, false), 0);
    assert_eq!(turbos::tick_bits_for_testing(0, true), 0);
}

#[test]
fun aftermath_order_is_a_strict_total_order_on_distinct_types() {
    let a_less = aftermath::is_type_name_less_for_testing<TypeA, TypeB>();
    let b_less = aftermath::is_type_name_less_for_testing<TypeB, TypeA>();

    assert_eq!(a_less != b_less, true);
    assert_eq!(
        aftermath::is_type_name_less_for_testing<TypeA, TypeA>(),
        false,
    );
}

#[test]
fun aftermath_order_compares_defining_addresses_first() {
    assert_eq!(
        aftermath::is_type_name_less_for_testing<TypeA, SUI>(),
        true,
    );
    assert_eq!(
        aftermath::is_type_name_less_for_testing<SUI, TypeA>(),
        false,
    );
}

// === Imports ===

use blast_fun_migrators::{aftermath, turbos};

use std::unit_test::assert_eq;

use sui::sui::SUI;
