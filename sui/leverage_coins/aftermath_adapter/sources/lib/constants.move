/// Package-wide immutable adapter constants.
module blast_leverage_aftermath::constants;

// === Package Constants ===

/// Fixed decimals for every Series1 leverage currency issued by this adapter.
macro public(package) fun share_decimals(): u8 {
    9
}

// The package-digest length moved to `blast_admin::upgrade_custody`, which owns
// the authorization check that reads it.
