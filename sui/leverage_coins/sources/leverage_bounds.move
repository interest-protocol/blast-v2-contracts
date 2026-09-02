// `blast_leverage_coins::errors` centralizes package abort codes through zero-cost macros. This
// narrow suppression preserves caller-local abort locations and the stable code map documented in
// this package's `README.md`.
#[allow(lint(abort_without_constant))]
/// Immutable ordering for one Series' accounting-leverage policy.
///
/// Values use leverage basis points, where 10,000 means 1x. This module
/// validates only relationships that are independent of simulation. It does
/// not select a production target, band, or hard cap.
module blast_leverage_coins::leverage_bounds;

// === Public Types ===

/// Strictly ordered operating band and terminal risk limit for one Series.
public struct LeverageBounds has copy, drop, store {
    lower_bps: u64,
    target_bps: u64,
    upper_bps: u64,
    hard_cap_bps: u64,
}

// === Package Functions ===

/// Creates bounds with a positive lower edge, an internal target, and a hard
/// cap strictly above the operating band.
public(package) fun new(
    lower_bps: u64,
    target_bps: u64,
    upper_bps: u64,
    hard_cap_bps: u64,
): LeverageBounds {
    assert!(
        lower_bps > 0
            && lower_bps < target_bps
            && target_bps < upper_bps
            && upper_bps < hard_cap_bps,
        blast_leverage_coins::errors::invalid_leverage_bounds!(),
    );

    LeverageBounds {
        lower_bps,
        target_bps,
        upper_bps,
        hard_cap_bps,
    }
}

/// Returns the leverage below which an active Series may increase risk.
public(package) fun lower_bps(self: &LeverageBounds): u64 {
    self.lower_bps
}

/// Returns the leverage toward which a rebalance sizes exposure.
public(package) fun target_bps(self: &LeverageBounds): u64 {
    self.target_bps
}

/// Returns the leverage above which a Series must reduce risk.
public(package) fun upper_bps(self: &LeverageBounds): u64 {
    self.upper_bps
}

/// Returns the leverage that a risk-increasing operation may never reach.
public(package) fun hard_cap_bps(self: &LeverageBounds): u64 {
    self.hard_cap_bps
}
