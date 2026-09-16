#[test_only]
/// Boundary and invariant tests for reusable bounded values.
module blast_leverage_series_one::bounded_value_tests;

use std::unit_test::assert_eq;

use blast_leverage_series_one::{bounded_value};

// === Tests ===

#[test]
fun equal_minimum_current_and_maximum_are_accepted() {
    let value = bounded_value::new(7, 7, 7);

    assert_eq!(value.minimum(), 7);
    assert_eq!(value.current(), 7);
    assert_eq!(value.maximum(), 7);
}

#[test]
fun current_at_the_inclusive_minimum_is_accepted() {
    let value = bounded_value::new(1, 1, 3);

    assert_eq!(value.current(), value.minimum());
}

#[test]
fun current_at_the_inclusive_maximum_is_accepted() {
    let value = bounded_value::new(1, 3, 3);

    assert_eq!(value.current(), value.maximum());
}

#[test]
#[expected_failure(
    abort_code = bounded_value::EInvalidBoundedValue,
    location = blast_leverage_series_one::bounded_value,
)]
fun construction_rejects_current_below_the_minimum() {
    bounded_value::new(2, 1, 3);
}

#[test]
#[expected_failure(
    abort_code = bounded_value::EInvalidBoundedValue,
    location = blast_leverage_series_one::bounded_value,
)]
fun construction_rejects_current_above_the_maximum() {
    bounded_value::new(1, 4, 3);
}

#[test]
fun update_accepts_the_minimum_interior_and_maximum() {
    let mut value = bounded_value::new(1, 2, 4);

    value.set_current(1);
    assert_eq!(value.current(), 1);
    value.set_current(3);
    assert_eq!(value.current(), 3);
    value.set_current(4);
    assert_eq!(value.current(), 4);
}

#[test]
#[expected_failure(
    abort_code = bounded_value::EInvalidBoundedValue,
    location = blast_leverage_series_one::bounded_value,
)]
fun update_rejects_one_below_the_minimum() {
    let mut value = bounded_value::new(1, 2, 3);

    value.set_current(0);
}

#[test]
#[expected_failure(
    abort_code = bounded_value::EInvalidBoundedValue,
    location = blast_leverage_series_one::bounded_value,
)]
fun update_rejects_one_above_the_maximum() {
    let mut value = bounded_value::new(1, 2, 3);

    value.set_current(4);
}

#[test]
fun maximum_width_values_are_supported() {
    let max = std::u64::max_value!();
    let mut value = bounded_value::new(0, max, max);

    value.set_current(0);
    value.set_current(max);
    assert_eq!(value.minimum(), 0);
    assert_eq!(value.current(), max);
    assert_eq!(value.maximum(), max);
}

#[test]
fun copies_preserve_independent_snapshots() {
    let mut value = bounded_value::new(1, 2, 3);
    let snapshot = value;

    value.set_current(3);
    assert_eq!(snapshot.minimum(), 1);
    assert_eq!(snapshot.current(), 2);
    assert_eq!(snapshot.maximum(), 3);
    assert_eq!(value.current(), 3);
}

#[test]
fun every_small_valid_tuple_and_update_preserves_the_invariant() {
    0u64.range_do!(6, |minimum| {
        minimum.range_do!(6, |maximum| {
            minimum.range_do!(maximum + 1, |current| {
                let mut value = bounded_value::new(minimum, current, maximum);

                minimum.range_do!(maximum + 1, |next| {
                    value.set_current(next);
                    assert_eq!(value.minimum(), minimum);
                    assert_eq!(value.current(), next);
                    assert_eq!(value.maximum(), maximum);
                });
            });
        });
    });
}
