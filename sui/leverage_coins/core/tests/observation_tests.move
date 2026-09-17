#[test_only]
/// Tests for operation-scoped, venue-neutral observations.
module blast_leverage_core::observation_tests;

use std::unit_test::assert_eq;

use blast_leverage_core::{observation, policy};

// === Tests ===

#[test]
fun price_construction_preserves_normalized_fields() {
    let price = observation::new_price(123, 4, 5);

    assert_eq!(price.price(), 123);
    assert_eq!(price.confidence(), 4);
    assert_eq!(price.publish_time_ms(), 5);
    price.destroy();
}

#[test]
#[expected_failure(
    abort_code = observation::EInvalidObservationPrice, location = blast_leverage_core::observation,
)]
fun price_construction_rejects_zero_price() {
    observation::new_price(0, 4, 5).destroy();
}

#[test]
fun long_position_construction_preserves_the_complete_observation() {
    let observation = observation::new_position(
        100,
        20,
        40,
        10,
        policy::long(),
        2,
        true,
        true,
        true,
        observation::new_price(3, 4, 5),
        observation::new_price(6, 7, 8),
        9,
    );

    assert_eq!(observation.venue_equity(), 100);
    assert_eq!(observation.position_base(), 20);
    assert_eq!(observation.position_collateral(), 40);
    assert_eq!(observation.lot_size(), 10);
    assert_eq!(observation.observed_side(), policy::long());
    assert_eq!(observation.pending_order_count(), 2);
    assert!(observation.is_margin_safe());
    assert!(observation.is_venue_operational());
    assert!(observation.is_checkpoint_clean());
    assert_eq!(observation.base_index().price(), 3);
    assert_eq!(observation.base_index().confidence(), 4);
    assert_eq!(observation.base_index().publish_time_ms(), 5);
    assert_eq!(observation.collateral_oracle().price(), 6);
    assert_eq!(observation.collateral_oracle().confidence(), 7);
    assert_eq!(observation.collateral_oracle().publish_time_ms(), 8);
    assert_eq!(observation.mark_price(), 9);
    observation.destroy();
}

#[test]
fun short_position_construction_preserves_the_observed_side() {
    let observation = observation::new_position(
        100,
        30,
        60,
        10,
        policy::short(),
        0,
        true,
        true,
        true,
        observation::new_price(3, 4, 5),
        observation::new_price(6, 7, 8),
        9,
    );

    assert_eq!(observation.observed_side(), policy::short());
    observation.destroy();
}

#[test]
#[expected_failure(
    abort_code = observation::EInvalidObservationLotSize, location = blast_leverage_core::observation,
)]
fun position_construction_rejects_zero_lot_size() {
    observation::new_position(
        100,
        20,
        40,
        0,
        policy::long(),
        0,
        true,
        true,
        true,
        observation::new_price(3, 4, 5),
        observation::new_price(6, 7, 8),
        9,
    )
    .destroy();
}

#[test]
#[expected_failure(
    abort_code = observation::EInvalidPositionObservation, location = blast_leverage_core::observation,
)]
fun position_construction_rejects_a_flat_base_with_nonzero_notional() {
    observation::new_position(
        100,
        0,
        40,
        10,
        policy::long(),
        0,
        true,
        true,
        true,
        observation::new_price(3, 4, 5),
        observation::new_price(6, 7, 8),
        9,
    )
    .destroy();
}

#[test]
fun funding_construction_preserves_each_settlement_variant() {
    let none = observation::no_funding();
    assert!(!none.is_cost());
    assert_eq!(none.amount(), 0);
    none.destroy();

    let credit = observation::funding_credit(7);
    assert!(!credit.is_cost());
    assert_eq!(credit.amount(), 7);
    credit.destroy();

    let cost = observation::funding_cost(8);
    assert!(cost.is_cost());
    assert_eq!(cost.amount(), 8);
    cost.destroy();
}
