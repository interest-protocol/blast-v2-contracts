// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Tests for operation-scoped, venue-neutral observations.
module blast_boosts_core::observation_tests;

// === Tests ===

#[test]
fun price_construction_preserves_normalized_fields() {
    let price = observation::new_price(123, 4, 5);

    assert_eq!(price.price(), 123);
    assert_eq!(price.confidence(), 4);
    assert_eq!(price.publish_time_ms(), 5);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidPrice, location = blast_boosts_core::observation,
)]
fun price_construction_rejects_zero_price() {
    observation::new_price(0, 4, 5);
}

#[test]
fun price_construction_accepts_maximum_values() {
    let max = std::u64::max_value!();
    let price = observation::new_price(max, max, max);

    assert_eq!(price.price(), max);
    assert_eq!(price.confidence(), max);
    assert_eq!(price.publish_time_ms(), max);
}

#[test]
fun long_position_construction_preserves_the_complete_observation() {
    let observation = observation::new_position(
        100, 20, 10, policy::long(), observation::new_price(3, 4, 5), observation::new_price(6, 7, 8), 9,
    );

    assert_eq!(observation.venue_equity(), 100);
    assert_eq!(observation.position_base(), 20);
    assert_eq!(observation.lot_size(), 10);
    assert_eq!(observation.observed_side(), policy::long());
    assert_eq!(observation.base_oracle().price(), 3);
    assert_eq!(observation.base_oracle().confidence(), 4);
    assert_eq!(observation.base_oracle().publish_time_ms(), 5);
    assert_eq!(observation.collateral_oracle().price(), 6);
    assert_eq!(observation.collateral_oracle().confidence(), 7);
    assert_eq!(observation.collateral_oracle().publish_time_ms(), 8);
    assert_eq!(observation.mark_price(), 9);
}

#[test]
fun short_position_construction_preserves_the_observed_side() {
    let observation = observation::new_position(
        100, 30, 10, policy::short(), observation::new_price(3, 4, 5), observation::new_price(6, 7, 8), 9,
    );

    assert_eq!(observation.observed_side(), policy::short());
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidObservationLotSize, location = blast_boosts_core::observation,
)]
fun position_construction_rejects_zero_lot_size() {
    observation::new_position(
        100, 20, 0, policy::long(), observation::new_price(3, 4, 5), observation::new_price(6, 7, 8), 9,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidPositionObservation, location = blast_boosts_core::observation,
)]
fun position_construction_rejects_a_partial_lot() {
    observation::new_position(
        100, 25, 10, policy::long(), observation::new_price(3, 4, 5), observation::new_price(6, 7, 8), 9,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidPrice, location = blast_boosts_core::observation,
)]
fun position_construction_rejects_a_zero_mark() {
    observation::new_position(
        100, 20, 10, policy::long(), observation::new_price(3, 4, 5), observation::new_price(6, 7, 8), 0,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidObservationLotSize, location = blast_boosts_core::observation,
)]
fun lot_size_validation_precedes_mark_validation() {
    observation::new_position(
        100, 20, 0, policy::long(), observation::new_price(3, 4, 5), observation::new_price(6, 7, 8), 0,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidPrice, location = blast_boosts_core::observation,
)]
fun mark_validation_precedes_lot_multiple_validation() {
    observation::new_position(
        100, 25, 10, policy::long(), observation::new_price(3, 4, 5), observation::new_price(6, 7, 8), 0,
    );
}

#[test]
fun funding_construction_preserves_each_settlement_variant() {
    let credit = observation::funding_credit(7);
    assert!(!credit.is_cost());
    assert_eq!(credit.amount(), 7);

    let cost = observation::funding_cost(8);
    assert!(cost.is_cost());
    assert_eq!(cost.amount(), 8);
}

// === Imports ===

use std::unit_test::assert_eq;

use blast_boosts_core::{errors, observation, policy};
