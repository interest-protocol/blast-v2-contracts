#[test_only]
/// Tests for operation-scoped, venue-neutral observations.
module blast_leverage_series_one::observation_tests;

use std::unit_test::assert_eq;

use blast_leverage_series_one::{observation, policy};

// === Tests ===

#[test]
fun price_construction_preserves_normalized_fields() {
    let price = observation::new_price(123, 4, 5);
    let (value, confidence, publish_time_ms) = observation::unpack_price(price);

    assert_eq!(value, 123);
    assert_eq!(confidence, 4);
    assert_eq!(publish_time_ms, 5);
}

#[test]
#[expected_failure(
    abort_code = observation::EInvalidObservationPrice,
    location = blast_leverage_series_one::observation,
)]
fun price_construction_rejects_zero_price() {
    observation::new_price(0, 4, 5).destroy_price_for_testing();
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
    let (
        venue_equity,
        absolute_base,
        absolute_notional,
        lot_size,
        observed_side,
        pending_order_count,
        margin_safe,
        venue_operational,
        checkpoint_clean,
        base_index,
        collateral_oracle,
        mark_price,
    ) = observation::unpack_position(observation);
    let (base_index_price, base_index_confidence, base_index_publish_time_ms) =
        observation::unpack_price(base_index);
    let (
        collateral_oracle_price,
        collateral_oracle_confidence,
        collateral_oracle_publish_time_ms,
    ) = observation::unpack_price(collateral_oracle);

    assert_eq!(venue_equity, 100);
    assert_eq!(absolute_base, 20);
    assert_eq!(absolute_notional, 40);
    assert_eq!(lot_size, 10);
    assert_eq!(observed_side, policy::long());
    assert_eq!(pending_order_count, 2);
    assert!(margin_safe);
    assert!(venue_operational);
    assert!(checkpoint_clean);
    assert_eq!(base_index_price, 3);
    assert_eq!(base_index_confidence, 4);
    assert_eq!(base_index_publish_time_ms, 5);
    assert_eq!(collateral_oracle_price, 6);
    assert_eq!(collateral_oracle_confidence, 7);
    assert_eq!(collateral_oracle_publish_time_ms, 8);
    assert_eq!(mark_price, 9);
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
    let (
        _,
        _,
        _,
        _,
        observed_side,
        _,
        _,
        _,
        _,
        base_index,
        collateral_oracle,
        _,
    ) = observation::unpack_position(observation);

    base_index.destroy_price_for_testing();
    collateral_oracle.destroy_price_for_testing();
    assert_eq!(observed_side, policy::short());
}

#[test]
#[expected_failure(
    abort_code = observation::EInvalidObservationLotSize,
    location = blast_leverage_series_one::observation,
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
    .destroy_position_for_testing();
}

#[test]
#[expected_failure(
    abort_code = observation::EInvalidPositionObservation,
    location = blast_leverage_series_one::observation,
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
    .destroy_position_for_testing();
}

#[test]
fun funding_construction_preserves_each_settlement_variant() {
    let (is_credit, is_cost, amount) = observation::unpack_funding(observation::no_funding());
    assert!(!is_credit);
    assert!(!is_cost);
    assert_eq!(amount, 0);

    let (is_credit, is_cost, amount) = observation::unpack_funding(
        observation::funding_credit(7),
    );
    assert!(is_credit);
    assert!(!is_cost);
    assert_eq!(amount, 7);

    let (is_credit, is_cost, amount) = observation::unpack_funding(
        observation::funding_cost(8),
    );
    assert!(!is_credit);
    assert!(is_cost);
    assert_eq!(amount, 8);
}
