// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// The blast.fun administration domain and its roles, shared with the migrators.
module blast_fun::blast_fun_domain;

// === Constants ===

/// Maximum number of simultaneously registered routine administrators.
const MAX_ADMINS: u64 = 16;

/// Fixed delay before a proposed super administrator may accept root custody.
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

/// Role that authorizes package upgrade custody in every package of this domain.
const PACKAGE_ADMIN_ROLE: u64 = 1;

/// Role that authorizes revoking and reissuing creator fee authority in every package.
const CREATOR_ADMIN_ROLE: u64 = 2;

/// Role that authorizes swapping a vault's burn Quote for Meme to burn.
const BUYBACK_ADMIN_ROLE: u64 = 4;

// === Public Types ===

/// One-time witness that names this administration domain at the type level.
public struct BLAST_FUN_DOMAIN() has drop;

// === Private Initialization ===

fun init(otw: BLAST_FUN_DOMAIN, ctx: &mut TxContext) {
    blast_admin::acl::new(otw, MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx);
}

// === Public Functions ===

/// The role a witness must carry to authorize, cut over, restrict, or seal an upgrade.
public fun package_admin_role(): u64 {
    PACKAGE_ADMIN_ROLE
}

/// The role a witness must carry to buy back and burn Meme with a vault's burn Quote.
public fun buyback_admin_role(): u64 {
    BUYBACK_ADMIN_ROLE
}

// === Package Functions ===

/// The role a witness must carry to revoke and reissue creator capabilities.
public(package) fun creator_admin_role(): u64 {
    CREATOR_ADMIN_ROLE
}

// === Test-Only Functions ===

#[test_only]
/// Runs domain initialization with a genuine test one-time witness.
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<BLAST_FUN_DOMAIN>(), ctx);
}

#[test_only]
public fun creator_admin_role_for_testing(): u64 {
    CREATOR_ADMIN_ROLE
}
