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

/// Maximum number of simultaneously registered routine administrators.
macro public(package) fun max_admins(): u64 {
    16
}

/// Fixed delay before a proposed super administrator may accept root custody.
macro public(package) fun super_admin_transfer_delay_ms(): u64 {
    7 * 24 * 60 * 60 * 1_000
}

/// Role that authorizes future Vault and share-currency issuance.
macro public(package) fun vault_issuer_role(): u8 {
    1
}

/// Fixed decimals for every Series1 leveraged share currency.
macro public(package) fun share_decimals(): u8 {
    9
}

/// Role that authorizes future risk-module witness rotation.
macro public(package) fun risk_admin_role(): u8 {
    2
}

/// Role that authorizes future adapter-witness rotation.
macro public(package) fun adapter_admin_role(): u8 {
    4
}

/// Role that authorizes future shutdown initiation.
macro public(package) fun shutdown_admin_role(): u8 {
    8
}

/// Role that authorizes package upgrades and operational-version activation.
macro public(package) fun package_admin_role(): u8 {
    16
}

/// Complete bit set of roles recognized by this package generation.
macro public(package) fun all_admin_roles(): u8 {
    31
}

/// Exact byte length of a Sui package digest.
macro public(package) fun package_digest_length(): u64 {
    32
}
