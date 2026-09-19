// Package error macros keep stable codes in `errors.move`; the lint sees the expanded literal.
#[allow(lint(abort_without_constant))]
/// Whole-lot, fixed-pair sizing with conservative per-session execution headroom.
module blast_boosts_core::rebalance_math;

// === Package Functions ===

/// Prices the position at the oracle price, rounding up, in collateral atoms.
///
/// `base_unit` and `collateral_unit` are `10^decimals` of each asset, so the
/// formula is decimal-agnostic: `base / base_unit * price ratio * collateral_unit`.
public(package) fun oracle_notional_up(
    base: u64, base_price: u64, collateral_price: u64, base_unit: u64, collateral_unit: u64,
): u64 {
    assert!(base_price > 0 && collateral_price > 0, blast_boosts_core::errors::invalid_price!());

    let numerator = (base as u256) * (base_price as u256) * (collateral_unit as u256);
    let denominator = (collateral_price as u256) * (base_unit as u256);
    let value = numerator.div_ceil(denominator);
    assert!(value <= std::u64::max_value!() as u256, blast_boosts_core::errors::arithmetic_overflow!());

    value as u64
}

/// Converts a notional cap to the largest whole-lot base it permits.
public(package) fun base_for_notional_down(
    notional: u64, base_price: u64, collateral_price: u64, lot_size: u64, base_unit: u64, collateral_unit: u64,
): u64 {
    assert!(base_price > 0 && collateral_price > 0, blast_boosts_core::errors::invalid_price!());
    assert!(lot_size > 0, blast_boosts_core::errors::invalid_lot_size!());

    let base = (notional as u256) * (collateral_price as u256) * (base_unit as u256)
        / ((base_price as u256) * (collateral_unit as u256));
    assert!(base <= std::u64::max_value!() as u256, blast_boosts_core::errors::arithmetic_overflow!());

    (base as u64) / lot_size * lot_size
}

/// Reserves adverse execution first, then the authenticated fee on that adverse quote.
/// Each session calls this separately: rounding a multi-order total is not equivalent.
fun execution_cost_up(notional: u64, venue_fee_bps: u64, max_slippage_bps: u64): u128 {
    assert!(
        venue_fee_bps <= constants::basis_points_denominator!() && max_slippage_bps < constants::basis_points_denominator!(),
        blast_boosts_core::errors::venue_fee_unusable!(),
    );

    let denominator = constants::basis_points_denominator!() as u128;
    let adverse = ((notional as u128) * (max_slippage_bps as u128)).div_ceil(denominator);
    let fee = (((notional as u128) + adverse) * (venue_fee_bps as u128)).div_ceil(denominator);

    adverse + fee
}

/// Finds the maximal next whole-lot increase under both the live order cap and post-cost target.
/// The adapter must recompute from each accepted session and enforce its fixed work bound.
public(package) fun increase_base_down(
    nav: u64, notional: u64, target_leverage_bps: u64, base_price: u64, collateral_price: u64,
    lot_size: u64, max_order_notional: u64, venue_fee_bps: u64, max_slippage_bps: u64, base_unit: u64, collateral_unit: u64,
): u64 {
    let target = accounting_math::target_notional_down(nav, target_leverage_bps);
    if (target <= notional) return 0;

    let headroom = (target - notional).min(max_order_notional);
    let maximum = base_for_notional_down(headroom, base_price, collateral_price, lot_size, base_unit, collateral_unit);
    let mut low = 0;
    let mut high = maximum / lot_size;

    while (low < high) {
        let candidate = low + (high - low).div_ceil(2);
        let value = oracle_notional_up(candidate * lot_size, base_price, collateral_price, base_unit, collateral_unit);
        let cost = execution_cost_up(value, venue_fee_bps, max_slippage_bps);
        let within_target = (nav as u128) > cost
            && ((notional as u128) + (value as u128)) * (constants::basis_points_denominator!() as u128)
                <= (target_leverage_bps as u128) * ((nav as u128) - cost);

        if (within_target) {
            low = candidate;
        } else {
            high = candidate - 1;
        };
    };

    low * lot_size
}

/// Returns whether leverage rose from one reading to the next, comparing `notional / nav` exactly.
public(package) fun leverage_rose(notional_before: u64, nav_before: u64, notional_after: u64, nav_after: u64): bool {
    (notional_after as u128) * (nav_before as u128) > (notional_before as u128) * (nav_after as u128)
}

/// Returns whether a rebalance moved leverage enough to be worth executing.
///
/// Leverage distance is `|notional * 10_000 / nav - target_leverage_bps|`. To avoid
/// division, each distance is kept scaled by its own NAV, so comparing the
/// before and after distances cross-multiplies by the other side's NAV.
/// Sufficient means either the remaining gap is within one lot of notional
/// (whole lots cannot get closer) without having moved away from the target,
/// or leverage moved at least `min_leverage_improvement_bps` toward it.
/// Neither clause admits a landing farther from target than the start, so the
/// predicate stays safe even if a caller sized past the target.
public(package) fun reduction_is_sufficient(
    notional_before: u64, nav_before: u64, notional_after: u64, nav_after: u64,
    target_leverage_bps: u64, min_leverage_improvement_bps: u64, one_lot_notional: u64,
): bool {
    assert!(nav_before > 0 && nav_after > 0, blast_boosts_core::errors::invalid_nav!());

    let bps = constants::basis_points_denominator!() as u256;
    let nav_before = nav_before as u256;
    let nav_after = nav_after as u256;
    let target = target_leverage_bps as u256;

    // Each distance is in bps, multiplied through by its own NAV.
    let before_distance = ((notional_before as u256) * bps).diff(target * nav_before);
    let after_distance = ((notional_after as u256) * bps).diff(target * nav_after);
    // Both distances over a common denominator, so they compare directly.
    let scaled_before = before_distance * nav_after;
    let scaled_after = after_distance * nav_before;

    let not_farther_than_before = scaled_after <= scaled_before;
    let within_one_lot_of_target = after_distance <= (one_lot_notional as u256) * bps;
    let improved_by_minimum =
        scaled_before >= scaled_after + (min_leverage_improvement_bps as u256) * nav_before * nav_after;

    (within_one_lot_of_target && not_farther_than_before) || improved_by_minimum
}

// === Test-Only Functions ===

#[test_only]
public fun execution_cost_up_for_testing(notional: u64, venue_fee_bps: u64, max_slippage_bps: u64): u128 {
    execution_cost_up(notional, venue_fee_bps, max_slippage_bps)
}

// === Imports ===

use blast_boosts_core::{accounting_math, constants};
