/// Package-wide immutable adapter constants.
module blast_leverage_aftermath::constants;

// === Package Constants ===

/// Fixed decimals for every Series1 leverage currency issued by this adapter.
macro public(package) fun share_decimals(): u8 {
    9
}

/// Exact byte length of a Sui package digest.
macro public(package) fun package_digest_length(): u64 {
    32
}
