module blast_fun::constants;

// === Package Constants ===

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

/// Maximum number of external migration implementations admitted for new launches.
macro public(package) fun max_migration_witnesses(): u64 {
    16
}

/// Maximum protocol share of gross terminal Quote collected at graduation.
macro public(package) fun max_protocol_quote_migration_fee_bps(): u64 {
    500
}

/// Maximum initial Meme supply reserved for the protocol at graduation.
macro public(package) fun max_protocol_meme_graduation_fee_bps(): u64 {
    1_000
}

/// Canonical decimal precision for every generated Meme currency.
macro public(package) fun meme_decimals(): u8 {
    9
}

/// One billion nine-decimal Meme coins expressed in atomic units.
macro public(package) fun meme_total_supply_atomic_units(): u64 {
    1_000_000_000__000_000_000
}

/// Maximum number of simultaneously active routine protocol administrators.
macro public(package) fun max_admins(): u64 {
    16
}

/// Fixed delay before a proposed super-admin recipient may accept, in milliseconds.
macro public(package) fun super_admin_transfer_delay_ms(): u64 {
    7 * 24 * 60 * 60 * 1_000
}

/// Canonical Ed25519 public-key length.
macro public(package) fun ed25519_public_key_length(): u64 {
    32
}

/// Exact byte length of a Sui package upgrade digest.
macro public(package) fun package_digest_length(): u64 {
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
