// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// The independent DEX administration domain.
///
/// This package governs its own factory, pool policy, and package custody. It
/// shares no authority with Launchpad, Blast SUI, or Series One: a capability or
/// witness from any other domain is a different type and cannot reach these
/// operations.
///
/// The two deliberate exceptions are `migration::claim_protocol_fees` and
/// `migration::issue_lp_fee_cap`. Both govern a Launchpad-owned `FeeLedger`, so they
/// stay under Launchpad product-fee custody rather than DEX administration.
module blast_fun_dex::dex_domain;

// === Constants ===

/// Maximum number of simultaneously registered routine administrators.
const MAX_ADMINS: u64 = 16;

/// Fixed delay before a proposed super administrator may accept root custody.
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

/// Role that authorizes package upgrade custody in this domain.
const PACKAGE_ADMIN_ROLE: u64 = 1;

// === Public Structs ===

/// One-time witness that names this administration domain at the type level.
public struct DEX_DOMAIN has drop {}

// === Private Initialization ===

fun init(otw: DEX_DOMAIN, ctx: &mut TxContext) {
    blast_admin::acl::new(otw, MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx);
}

// === Public Functions ===

/// The role a witness must carry to authorize, cut over, restrict, or seal an upgrade.
public fun package_admin_role(): u64 {
    PACKAGE_ADMIN_ROLE
}

// === Test-Only Functions ===

#[test_only]
/// Runs domain initialization with a genuine test one-time witness.
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<DEX_DOMAIN>(), ctx);
}
