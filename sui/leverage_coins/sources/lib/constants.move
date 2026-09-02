module blast_leverage_coins::constants;

// === Package Constants ===

/// Denominator for protocol rates expressed in basis points.
///
/// Fee rates use it as an exclusive upper bound: a valid fee rate is below
/// 10,000. Leverage rates use the same scale without that bound, so one
/// leverage-bps unit is `1 / 10_000` of 1x and `20_000` means 2x (ADR 0064).
macro public(package) fun basis_points_denominator(): u64 {
    10_000
}
