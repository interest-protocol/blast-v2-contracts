// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// The presale administration domain and its roles. Every administrator action asserts exactly
/// one role, and no role authorizes another's actions.
module blast_presale::blast_presale_domain;

// === Constants ===

/// Maximum number of simultaneously registered routine administrators.
const MAX_ADMINS: u64 = 16;

/// Fixed delay before a proposed super administrator may accept root custody.
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

/// Role that authorizes package upgrade custody.
const PACKAGE_ADMIN_ROLE: u64 = 1;

/// Role that authorizes setting Blast's fee on new presales.
const FEE_ADMIN_ROLE: u64 = 2;

/// Role that authorizes choosing where Blast's fee is paid.
const TREASURY_ADMIN_ROLE: u64 = 4;

// === Public Types ===

/// One-time witness that names this administration domain at the type level.
public struct BLAST_PRESALE_DOMAIN() has drop;

// === Private Initialization ===

fun init(otw: BLAST_PRESALE_DOMAIN, ctx: &mut TxContext) {
    blast_admin::acl::new(otw, MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx);
}

// === Package Functions ===

/// The role a witness must carry to authorize, cut over, or seal an upgrade.
public(package) fun package_admin_role(): u64 {
    PACKAGE_ADMIN_ROLE
}

/// The role a witness must carry to change Blast's fee on new presales.
public(package) fun fee_admin_role(): u64 {
    FEE_ADMIN_ROLE
}

/// The role a witness must carry to change where Blast's fee is paid.
public(package) fun treasury_admin_role(): u64 {
    TREASURY_ADMIN_ROLE
}

// === Test-Only Functions ===

#[test_only]
/// Runs domain initialization with a genuine test one-time witness.
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<BLAST_PRESALE_DOMAIN>(), ctx);
}
