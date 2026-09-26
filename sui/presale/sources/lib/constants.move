// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Package-wide presale constants exposed as zero-cost macros.
module blast_presale::constants;

// === Package Constants ===

/// Denominator for rates expressed in basis points.
macro public(package) fun basis_points_denominator(): u64 {
    10_000
}

/// Highest fee Blast may set on the Quote a presale raises.
macro public(package) fun max_fee_bps(): u64 {
    1_000
}

/// Most tranches one presale may have.
macro public(package) fun max_tranches(): u64 {
    8
}

/// Byte length of a Blake2b-256 digest, the whitelist roots and proof nodes.
macro public(package) fun digest_length(): u64 {
    32
}
