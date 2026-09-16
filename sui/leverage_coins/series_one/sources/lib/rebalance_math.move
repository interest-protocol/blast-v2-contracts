/// Whole-lot, fixed-pair sizing with conservative per-session execution headroom.
module blast_leverage_series_one::rebalance_math;

// === Errors ===

#[error(code = 2)]
const EInvalidNav: vector<u8> = b"A priced operation requires positive Series NAV.";

#[error(code = 9)]
const EInvalidTargetLeverageBps: vector<u8> = b"A target leverage rate must be positive.";

#[error(code = 10)]
const EInvalidLotSize: vector<u8> = b"A venue lot size must be positive.";

#[error(code = 15)]
const EArithmeticOverflow: vector<u8> = b"An arithmetic result exceeds the supported u64 range.";

#[error(code = 29)]
const EInvalidValuationPrice: vector<u8> = b"A gated valuation price is zero.";

#[error(code = 98)]
const EVenueFeeUnusable: vector<u8> = b"A venue fee or execution bound cannot be represented conservatively.";

// === Constants ===

/// Nine-decimal base atoms per six-decimal collateral atom at equal prices.
const BASE_TO_COLLATERAL_SCALE: u256 = 1_000;

// === Package Functions ===

/// Compares exact leverage-distance improvement, or admits a one-lot target remainder.
///
/// With `d = |notional * 10_000 - target_bps * nav|`, `d / nav` is the exact
/// leverage distance from target in basis points. The reduction is sufficient
/// when that distance fell by at least `minimum_improvement_bps`, or when the
/// after-position sits within one lot's notional of the target and is no
/// farther from it, in leverage terms, than the start. Neither clause admits a
/// landing farther from target than the start, so the predicate stays safe
/// even if a caller sized past the target. Every comparison cross-multiplies
/// exact integers; nothing rounds.
public(package) fun reduction_is_sufficient(
    before_notional: u64, before_nav: u64, after_notional: u64, after_nav: u64,
    target_bps: u64, minimum_improvement_bps: u64, one_lot_notional: u64,
): bool {
    assert!(before_nav > 0 && after_nav > 0, EInvalidNav);
    let before_distance = ((before_notional as u256) * 10_000).diff((target_bps as u256) * (before_nav as u256));
    let after_distance = ((after_notional as u256) * 10_000).diff((target_bps as u256) * (after_nav as u256));
    let scaled_before = before_distance * (after_nav as u256);
    let scaled_after = after_distance * (before_nav as u256);
    (after_distance <= (one_lot_notional as u256) * 10_000 && scaled_after <= scaled_before)
        || scaled_before
            >= scaled_after + (minimum_improvement_bps as u256) * (before_nav as u256) * (after_nav as u256)
}

/// Prices index exposure conservatively in six-decimal collateral atoms.
public(package) fun index_notional_up(base: u64, base_price: u64, collateral_price: u64): u64 {
    assert!(base_price > 0 && collateral_price > 0, EInvalidValuationPrice);
    let numerator = (base as u256) * (base_price as u256);
    let denominator = (collateral_price as u256) * BASE_TO_COLLATERAL_SCALE;
    let value = numerator.div_ceil(denominator);
    assert!(value <= std::u64::max_value!() as u256, EArithmeticOverflow);
    value as u64
}

/// Converts a notional cap to the largest whole-lot base it permits.
public(package) fun base_for_notional_down(notional: u64, base_price: u64, collateral_price: u64, lot: u64): u64 {
    assert!(base_price > 0 && collateral_price > 0, EInvalidValuationPrice);
    assert!(lot > 0, EInvalidLotSize);
    let base = (notional as u256) * (collateral_price as u256) * BASE_TO_COLLATERAL_SCALE / (base_price as u256);
    assert!(base <= std::u64::max_value!() as u256, EArithmeticOverflow);
    (base as u64) / lot * lot
}

/// Reserves adverse execution first, then the authenticated fee on that adverse quote.
/// Each session calls this separately: rounding a multi-order total is not equivalent.
public(package) fun execution_cost_up(notional: u64, fee_bps: u64, tolerance_bps: u64): u128 {
    assert!(fee_bps <= 10_000 && tolerance_bps < 10_000,
        EVenueFeeUnusable);
    let adverse = ((notional as u128) * (tolerance_bps as u128)).div_ceil(10_000);
    let fee = (((notional as u128) + adverse) * (fee_bps as u128)).div_ceil(10_000);
    adverse + fee
}

/// Finds the maximal next whole-lot increase under both the live order cap and post-cost target.
/// The adapter must recompute from each accepted session and enforce its fixed work bound.
public(package) fun increase_base_down(
    nav: u64, notional: u64, target_bps: u64, base_price: u64, collateral_price: u64,
    lot: u64, order_cap: u64, fee_bps: u64, tolerance_bps: u64,
): u64 {
    assert!(nav > 0, EInvalidNav);
    assert!(target_bps > 0, EInvalidTargetLeverageBps);
    let target = (nav as u128) * (target_bps as u128) / 10_000;
    assert!(target <= std::u64::max_value!() as u128, EArithmeticOverflow);
    if (target <= notional as u128) { return 0 };
    let headroom = ((target as u64) - notional).min(order_cap);
    let maximum = base_for_notional_down(headroom, base_price, collateral_price, lot);
    let mut low = 0;
    let mut high = maximum / lot;
    while (low < high) {
        let candidate = low + (high - low).div_ceil(2);
        let value = index_notional_up(candidate * lot, base_price, collateral_price);
        let cost = execution_cost_up(value, fee_bps, tolerance_bps);
        if ((nav as u128) > cost
            && ((notional as u128) + (value as u128)) * 10_000 <= (target_bps as u128) * ((nav as u128) - cost)) {
            low = candidate;
        } else {
            high = candidate - 1;
        };
    };
    low * lot
}
