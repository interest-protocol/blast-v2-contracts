/// Package-wide immutable Series1 numeric constants.
module blast_leverage_series_one::constants;

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
macro public(package) fun max_leverage_bps(): u64 {
    1_000_000
}

/// Structural ceiling on the minimum operation size in live venue lots.
///
/// The minimum exists so a small holder can still exit; a million lots can
/// never be small in collateral terms. The fence also catches a policy that
/// swaps `min_exposure_lots` with an atomic-collateral value such as the NAV
/// cap, which would otherwise brick every mint of an immutable policy.
macro public(package) fun max_min_exposure_lots(): u64 {
    1_000_000
}

// Administration configuration and role bits moved to
// `blast_leverage_series_one::series_one_domain`, which owns the typed
// `blast_admin` domain shared with every Series1 adapter.
