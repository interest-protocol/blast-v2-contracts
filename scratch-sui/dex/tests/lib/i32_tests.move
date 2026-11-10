#[test_only]
module blast_fun_dex::i32_tests;

// === Tests ===

#[test]
fun from_u32_keeps_nonnegative_values() {
    assert_eq!(i32::from_u32(0).magnitude(), 0);
    assert_eq!(i32::from_u32(0).is_negative(), false);
    assert_eq!(i32::from_u32(0x7fff_ffff).magnitude(), 0x7fff_ffff);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EMagnitudeTooLarge, location = blast_fun_dex::i32)]
fun from_u32_rejects_two_pow_31() {
    i32::from_u32(0x8000_0000);
}

#[test]
fun neg_from_u32_round_trips_magnitude_up_to_the_minimum() {
    assert_eq!(i32::neg_from_u32(0).is_negative(), false);
    assert_eq!(i32::neg_from_u32(0).magnitude(), 0);
    assert_eq!(i32::neg_from_u32(1).is_negative(), true);
    assert_eq!(i32::neg_from_u32(1).magnitude(), 1);
    assert_eq!(i32::neg_from_u32(887_272).magnitude(), 887_272);
    assert_eq!(i32::neg_from_u32(0x8000_0000).magnitude(), 0x8000_0000);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EMagnitudeTooLarge, location = blast_fun_dex::i32)]
fun neg_from_u32_rejects_one_past_the_minimum() {
    i32::neg_from_u32(0x8000_0001);
}

#[test]
fun lt_orders_signed_values() {
    let min = i32::neg_from_u32(0x8000_0000);
    let minus_one = i32::neg_from_u32(1);
    let zero = i32::from_u32(0);
    let one = i32::from_u32(1);
    let max = i32::from_u32(0x7fff_ffff);

    assert!(min.lt(&minus_one));
    assert!(minus_one.lt(&zero));
    assert!(zero.lt(&one));
    assert!(one.lt(&max));
    assert!(!zero.lt(&zero));
    assert!(!max.lt(&min));
    assert!(!one.lt(&minus_one));
}

// === Imports ===

use blast_fun_dex::i32;
use std::unit_test::assert_eq;
