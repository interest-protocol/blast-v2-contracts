// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Package-wide immutable adapter constants.
module blast_boosts_aftermath::constants;

// === Package Constants ===

/// Fixed decimals for every Boost currency issued by this adapter.
macro public(package) fun share_decimals(): u8 {
    9
}

/// Decimals this adapter normalizes every venue base amount to.
macro public(package) fun base_decimals(): u8 {
    9
}

/// Decimals of the only collateral this adapter admits.
macro public(package) fun collateral_decimals(): u8 {
    6
}

/// One in IFixed: `10^18`.
macro public(package) fun ifixed_one(): u256 {
    1_000_000_000_000_000_000
}

/// One basis point in IFixed: `10^18 / 10_000`.
macro public(package) fun ifixed_per_basis_point(): u256 {
    100_000_000_000_000
}

/// Raw IFixed units in one base atom: `10^(18 - 9)`.
macro public(package) fun base_atom_to_ifixed_scale(): u256 {
    1_000_000_000
}

/// Raw IFixed units in one collateral atom: `10^(18 - 6)`.
macro public(package) fun collateral_atom_to_ifixed_scale(): u256 {
    1_000_000_000_000
}

/// Base atoms per collateral atom at a unit price: `10^(9 - 6)`.
macro public(package) fun collateral_to_base_scale(): u256 {
    1_000
}

/// Maximum market-order calls permitted in one atomic initialization session.
macro public(package) fun max_initialization_orders(): u64 {
    16
}

/// Hard ceiling on venue market calls in one active atomic operation.
macro public(package) fun max_active_orders(): u64 {
    16
}

/// Aftermath's immediate-or-cancel order type for `clearing_house::place_limit_order`.
///
/// The deployed `execute_limit_order` (`0x3ec740df…`, interface revision
/// `f62e74a`) admits types 0 to 3: 0 posts the unfilled remainder, 1 aborts
/// unless the whole size fills, 2 aborts on any fill, and 3 fills what rests
/// at or inside the limit and drops the rest without posting. Every order the
/// adapter places is the last kind, so a session never leaves a resting order
/// and a thin book fills less rather than worse.
macro public(package) fun immediate_or_cancel_order_type(): u64 {
    3
}
