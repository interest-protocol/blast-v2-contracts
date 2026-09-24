// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Package-wide protocol constants exposed as zero-cost macros.
module blast_fun::constants;

// === Package Constants ===

/// Denominator for protocol rates expressed in basis points.
macro public(package) fun basis_points_denominator(): u64 {
    10_000
}

/// Maximum recipients in an allocation plan or an LP-fee split.
macro public(package) fun max_recipients(): u64 {
    16
}

/// Maximum LaunchConfig trade-fee rate for either the meme or quote asset.
macro public(package) fun max_launch_fee_bps(): u64 {
    1_000
}

/// Maximum creator-selected share of post-fee Meme sell input reserved for burn.
macro public(package) fun max_sell_burn_bps(): u64 {
    5_000
}

/// Maximum Meme symbol length in bytes. Venues copy the symbol into pool and position objects,
/// which Sui caps in size.
macro public(package) fun max_meme_symbol_length(): u64 {
    32
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
macro public(package) fun ed25519_signature_length(): u64 {
    64
}

/// Byte length of an opaque Blast account commitment.
macro public(package) fun account_commitment_length(): u64 {
    32
}
