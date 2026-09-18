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

// The package-digest length moved to `blast_admin::upgrade_custody`, which owns
// the authorization check that reads it.
