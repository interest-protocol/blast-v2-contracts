#[test_only]
/// Pins the vendored `ifixed` bodies (transcribed from the deployed bytecode)
/// to two's-complement reference semantics, so every adapter test that decodes
/// a venue carrier runs the arithmetic the venue runs.
module blast_boosts_aftermath::ifixed_port_tests;

// === Tests ===

#[test]
fun one_is_the_adapter_scale() {
    assert_eq!(ifixed::ifixed::one(), constants::ifixed_one!());
}

#[test]
fun sign_and_magnitude_follow_two_s_complement() {
    assert!(!ifixed::ifixed::is_neg(0));
    assert!(!ifixed::ifixed::is_neg(SIGN - 1));
    assert!(ifixed::ifixed::is_neg(SIGN));
    assert!(ifixed::ifixed::is_neg(std::u256::max_value!()));
    assert_eq!(ifixed::ifixed::abs(0), 0);
    assert_eq!(ifixed::ifixed::abs(7), 7);
    assert_eq!(ifixed::ifixed::abs(SIGN - 1), SIGN - 1);
    assert_eq!(ifixed::ifixed::abs(negative(7)), 7);
    assert_eq!(ifixed::ifixed::abs(std::u256::max_value!()), 1);
    assert_eq!(ifixed::ifixed::abs(SIGN + 1), SIGN - 1);
}

#[test]
#[expected_failure(arithmetic_error, location = ifixed::ifixed)]
fun the_most_negative_value_has_no_magnitude() {
    ifixed::ifixed::abs(SIGN);
}

#[test]
fun signed_add_and_sub_match_two_s_complement_across_the_small_domain() {
    // Every signed value in [-9, 9] against every other: the venue's signed
    // add and sub equal wrapping addition and subtraction of the carriers.
    let values = vector[negative(9), negative(5), negative(2), negative(1), 0, 1, 2, 5, 9];
    values.do_ref!(|x| values.do_ref!(|y| {
        assert_eq!(ifixed::ifixed::add(*x, *y), wrapping_add(*x, *y));
        assert_eq!(ifixed::ifixed::sub(*x, *y), wrapping_sub(*x, *y));
    }));
}

#[test]
fun signed_add_and_sub_hold_at_the_encoding_edges() {
    let max_positive = SIGN - 1;
    let most_negative = SIGN;
    assert_eq!(ifixed::ifixed::add(max_positive, negative(1)), max_positive - 1);
    assert_eq!(ifixed::ifixed::add(most_negative, 1), most_negative + 1);
    assert_eq!(ifixed::ifixed::sub(max_positive, max_positive), 0);
    assert_eq!(ifixed::ifixed::sub(most_negative, most_negative), 0);
    assert_eq!(ifixed::ifixed::sub(0, max_positive), most_negative + 1);
    assert_eq!(ifixed::ifixed::add(max_positive, most_negative), std::u256::max_value!());
}

#[test]
#[expected_failure(abort_code = 12001, location = ifixed::ifixed)]
fun a_positive_sum_past_the_encoding_overflows() {
    ifixed::ifixed::add(SIGN - 1, 1);
}

#[test]
#[expected_failure(abort_code = 12001, location = ifixed::ifixed)]
fun a_negative_sum_past_the_encoding_overflows() {
    ifixed::ifixed::add(SIGN, std::u256::max_value!());
}

#[test]
#[expected_failure(abort_code = 12001, location = ifixed::ifixed)]
fun a_positive_difference_past_the_encoding_overflows() {
    ifixed::ifixed::sub(SIGN - 1, std::u256::max_value!());
}

#[test]
#[expected_failure(abort_code = 12001, location = ifixed::ifixed)]
fun a_negative_difference_past_the_encoding_overflows() {
    ifixed::ifixed::sub(SIGN, 1);
}

// === Test Helpers ===

const SIGN: u256 = 1 << 255;

/// `-magnitude` in the venue's two's-complement carrier.
fun negative(magnitude: u256): u256 {
    std::u256::max_value!() - magnitude + 1
}

fun wrapping_add(x: u256, y: u256): u256 {
    let max = std::u256::max_value!();
    if (x > max - y) { x - (max - y) - 1 } else { x + y }
}

fun wrapping_sub(x: u256, y: u256): u256 {
    if (x >= y) { x - y } else { std::u256::max_value!() - (y - x) + 1 }
}

// === Imports ===

use blast_boosts_aftermath::constants;


use std::unit_test::assert_eq;
