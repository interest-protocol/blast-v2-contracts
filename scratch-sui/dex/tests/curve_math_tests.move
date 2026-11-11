#[test_only]
module blast_fun_dex::curve_math_tests;

// === Tests ===

#[test]
fun tick_price_and_floor_agree_at_grid_edges() {
    assert_eq!(sqrt_price_x96(0), constants::min_sqrt_price_x96!());
    assert_eq!(sqrt_price_x96(constants::max_tick!()), 1u256 << 96);
    assert_eq!(sqrt_price_x96(2 * constants::max_tick!()), constants::max_sqrt_price_x96!());
    let midpoint = constants::max_tick!();
    let price = sqrt_price_x96(midpoint + 60);
    assert_eq!(floor_index(price, 0, 2 * midpoint), midpoint + 60);
    assert_eq!(floor_index(price - 1, 0, 2 * midpoint), midpoint + 59);
}

#[test]
fun extreme_deltas_and_price_inverse_keep_their_rounding() {
    let lo = constants::min_sqrt_price_x96!();
    let hi = constants::max_sqrt_price_x96!() - 1;
    let liquidity = u128::max_value!();
    assert_eq!(asset_delta(lo, hi, liquidity, true), 6276865795046577716716727052920969657919881535178523893768);
    assert_eq!(quote_delta(lo, hi, liquidity, true), 6276865796315986613307619852238232712829278890648656544662);
    let end = next_price(hi, liquidity, 1_000_000_000, false);
    assert!(input_delta(hi, end, liquidity, false) <= 1_000_000_000);
    assert!(input_delta(hi, end - 1, liquidity, false) > 1_000_000_000);
}

#[test]
fun wide_division_preserves_exact_and_rounded_results() {
    let price = (1u256 << 96) - 3;
    let liquidity = 1u128 << 79;
    assert_eq!(next_price(price, liquidity - 2, 0, false), price);
    assert_eq!(next_price(price, liquidity - 2, 1, false), price - 131_072);
    assert_eq!(next_price(price, liquidity, 1, false), price - 131_071);
    assert_eq!(
        next_price(constants::max_sqrt_price_x96!() - 1, u128::max_value!(), std::u64::max_value!(), false),
        730737084945921794831612301621056775468038290870,
    );

    let lower = 1u256 << 96;
    let upper = (1u256 << 97) + 1;
    assert_eq!(asset_delta(lower, upper, 1 << 65, false), 1u256 << 64);
    assert_eq!(asset_delta(lower, upper, 1 << 65, true), (1u256 << 64) + 1);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::ELiquidityLimit, location = blast_fun_dex::curve)]
fun aggregate_liquidity_cannot_wrap() {
    let mut ctx = tx_context::dummy();
    let mut curve = curve::new(1 << 96, &mut ctx);
    let mut fees = curve::new_position_fees();
    let center = constants::max_tick!();
    curve.change_liquidity(&mut fees, center - 1, center + 1, 0, u128::max_value!(), true);
    curve.change_liquidity(&mut fees, center - 1, center + 1, u128::max_value!(), 1, true);
    destroy(curve);
}

#[test]
fun reversing_at_an_initialized_boundary_selects_the_correct_active_range() {
    let mut ctx = tx_context::dummy();
    let mut curve = curve::new(1 << 96, &mut ctx);
    let mut lower = curve::new_position_fees();
    let mut upper = curve::new_position_fees();
    let center = constants::max_tick!();
    let far = center + 70_000;
    curve.change_liquidity(&mut lower, center - 70_000, center, 0, 10, true);
    curve.change_liquidity(&mut upper, center, far, 0, 20, true);
    assert_eq!(curve.liquidity(), 20);
    assert_eq!(curve.next_tick(true).destroy_some(), far);
    assert_eq!(curve.next_tick(false).destroy_some(), center);
    curve.cross(center, false);
    assert_eq!(curve.liquidity(), 10);
    assert_eq!(curve.next_tick(false).destroy_some(), center - 70_000);
    assert_eq!(curve.next_tick(true).destroy_some(), center);
    curve.cross(center, true);
    assert_eq!(curve.liquidity(), 20);
    curve.change_liquidity(&mut upper, center, far, 20, 20, false);
    assert_eq!(curve.liquidity(), 0);
    assert!(curve.next_tick(true).is_none());
    destroy(curve);
}

#[test]
fun fractional_claims_survive_partial_burns_without_paying_past_fees_to_new_liquidity() {
    let mut ctx = tx_context::dummy();
    let mut curve = curve::new(1 << 96, &mut ctx);
    let mut early = curve::new_position_fees();
    let mut late = curve::new_position_fees();
    let center = constants::max_tick!();
    let (lower, upper) = (center - 1, center + 1);
    curve.change_liquidity(&mut early, lower, upper, 0, 3, true);
    curve.credit(1, 0);
    curve.change_liquidity(&mut late, lower, upper, 0, 1, true);
    curve.credit(1, 0);

    curve.change_liquidity(&mut early, lower, upper, 3, 1, false);
    let (asset, quote) = early.take_fees(false);
    assert_eq!(asset, 1);
    assert_eq!(quote, 0);
    curve.change_liquidity(&mut early, lower, upper, 2, 1, false);
    let (asset, _) = early.take_fees(false);
    assert_eq!(asset, 0);
    curve.credit(1, 0);

    curve.change_liquidity(&mut early, lower, upper, 1, 1, false);
    let (asset, _) = early.take_fees(true);
    assert_eq!(asset, 1);
    curve.change_liquidity(&mut late, lower, upper, 1, 1, false);
    let (asset, _) = late.take_fees(true);
    assert_eq!(asset, 0);
    destroy(curve);
}

// === Imports ===

use blast_fun_dex::{
    constants,
    curve,
    sqrt_price_math::{asset_delta, input_delta, next_price, quote_delta},
    tick_math::{floor_index, sqrt_price_x96},
};
use std::{u128, unit_test::{assert_eq, destroy}};
