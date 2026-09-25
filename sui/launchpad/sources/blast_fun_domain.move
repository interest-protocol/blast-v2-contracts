// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// The blast.fun administration domain and its roles, shared with the migrators. Every
/// administrator action asserts exactly one role, and no role authorizes another's actions.
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

/// Role that authorizes claiming Blast's fees and choosing where Blast is paid.
const TREASURY_ADMIN_ROLE: u64 = 8;

/// Role that authorizes setting Blast's trade fees and fee shares.
const FEE_ADMIN_ROLE: u64 = 16;

/// Role that authorizes the Quotes and Meme decimals new launches may use.
const LISTING_ADMIN_ROLE: u64 = 32;

/// Role that authorizes admitting and removing migration adapters.
const ADAPTER_ADMIN_ROLE: u64 = 64;

/// Role that authorizes replacing the key that signs account claims.
const CLAIM_SIGNER_ADMIN_ROLE: u64 = 128;

/// Role that authorizes publishing holder-reward rounds.
const REWARDS_ADMIN_ROLE: u64 = 256;

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

/// The role a witness must carry to claim Blast's fees or change where Blast is paid.
public fun treasury_admin_role(): u64 {
    TREASURY_ADMIN_ROLE
}

/// The role a witness must carry to change Blast's trade fees or fee shares.
public fun fee_admin_role(): u64 {
    FEE_ADMIN_ROLE
}

/// The role a witness must carry to publish a holder-reward round.
public fun rewards_admin_role(): u64 {
    REWARDS_ADMIN_ROLE
}

// === Package Functions ===

/// The role a witness must carry to revoke and reissue creator capabilities.
public(package) fun creator_admin_role(): u64 {
    CREATOR_ADMIN_ROLE
}

/// The role a witness must carry to admit or remove a Quote or Meme decimals.
public(package) fun listing_admin_role(): u64 {
    LISTING_ADMIN_ROLE
}

/// The role a witness must carry to admit or remove a migration adapter.
public(package) fun adapter_admin_role(): u64 {
    ADAPTER_ADMIN_ROLE
}

/// The role a witness must carry to replace the account-claim signer.
public(package) fun claim_signer_admin_role(): u64 {
    CLAIM_SIGNER_ADMIN_ROLE
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

#[test_only]
public fun listing_admin_role_for_testing(): u64 {
    LISTING_ADMIN_ROLE
}

#[test_only]
public fun adapter_admin_role_for_testing(): u64 {
    ADAPTER_ADMIN_ROLE
}
