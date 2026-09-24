// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Package-wide protocol constants exposed as zero-cost macros.
module blast_fun::constants;

// === Package Constants ===

/// Maximum distinct recipients in an LP-fee split.
macro public(package) fun max_route_destinations(): u64 { 16 }

/// Combined one-time migration identity bound across both asset tables, excluding the curve.
macro public(package) fun max_migration_channels(): u64 {
    16
}

/// Denominator for protocol rates expressed in basis points.
macro public(package) fun basis_points_denominator(): u64 {
    10_000
}

/// Maximum LaunchConfig trade-fee rate for either the meme or quote asset.
macro public(package) fun max_launch_fee_bps(): u64 {
    1_000
}

/// Maximum creator-selected share of post-fee Meme sell input reserved for burn.
macro public(package) fun max_sell_burn_bps(): u64 {
    5_000
}

/// Maximum Meme symbol length in bytes. A venue may copy the symbol into its pool and position
/// objects more than once, so a bounded symbol keeps every migration within Sui's object size
/// limit.
macro public(package) fun max_meme_symbol_length(): u64 {
    32
}

/// Maximum number of external migration implementations admitted for new launches.
macro public(package) fun max_migration_witnesses(): u64 {
    16
}

/// Exact whole-token supply minted for every generated Meme currency.
macro public(package) fun meme_total_supply_whole_tokens(): u64 {
    1_000_000_000
}

/// Canonical Ed25519 public-key length.
macro public(package) fun ed25519_public_key_length(): u64 {
    32
}

/// Canonical Ed25519 signature length.
macro public(package) fun ed25519_signature_length(): u8 {
    64
}

/// Byte length of an opaque Blast account commitment.
macro public(package) fun account_commitment_length(): u64 {
    32
}

/// BCS byte length of the leading `u64` creator-claim expiry.
macro public(package) fun creator_claim_expiry_bcs_length(): u64 {
    8
}

/// Offset at which the raw Ed25519 signature starts after BCS `vector<u8>` length encoding.
macro public(package) fun creator_claim_signature_offset(): u64 {
    creator_claim_expiry_bcs_length!() + 1
}

/// Exact byte length of canonical BCS `(expiry_ms: u64, signature: vector<u8>)` call data.
macro public(package) fun creator_claim_attestation_length(): u64 {
    creator_claim_signature_offset!() + (ed25519_signature_length!() as u64)
}
