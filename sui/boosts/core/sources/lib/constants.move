// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Package-wide immutable core numeric constants.
module blast_boosts_core::constants;

// === Package Constants ===

/// Returns the denominator for one basis-point rate.
macro public(package) fun basis_points_denominator(): u64 {
    10_000
}

/// Structural ceiling on any leverage threshold: 100x in leverage basis points.
///
/// No leveraged coin in this protocol targets more than a small multiple, and
/// the mint-contribution allowance scales with target leverage, so an unbounded
/// threshold would let a transposed or mistyped policy admit almost any
/// contribution. The ceiling is a sanity fence, not a selected product value.
macro public(package) fun leverage_ceiling_bps(): u64 {
    100 * basis_points_denominator!()
}

/// Structural ceiling on the minimum operation size in live venue lots.
///
/// The minimum exists so a small holder can still exit; a million lots can
/// never be small in collateral terms. The fence also catches a policy that
/// swaps `min_order_lots` with an atomic-collateral value such as the NAV
/// cap, which would otherwise brick every mint of an immutable policy.
macro public(package) fun max_min_order_lots(): u64 {
    1_000_000
}

/// Widest asset precision the notional formulas support without overflow.
macro public(package) fun max_asset_decimals(): u8 {
    18
}

/// One rebalance's bounded execution and capacity projection share this budget.
macro public(package) fun max_rebalance_orders(): u64 {
    16
}

/// How long after shutdown begins the close-only execution bound takes to
/// widen, linearly, from the ordinary bound to the emergency one: 24 hours.
///
/// A permissionless close must stay as cheap for holders as honest depth
/// allows, yet a book that stays thin must not refuse the exit forever, so the
/// admitted execution widens with time instead of opening at the wide bound.
macro public(package) fun unwind_bound_widening_duration_ms(): u64 {
    86_400_000
}
