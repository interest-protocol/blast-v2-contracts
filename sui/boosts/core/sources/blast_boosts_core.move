/// The core-owned administration domain shared with every leverage adapter.
///
/// This module owns the domain one-time witness, the governance configuration,
/// and the four role bits the core recognizes. Adapters import
/// `AdminWitness<BLAST_BOOSTS_CORE>` and these role accessors; they never create
/// another authority and never restate a numeric role.
///
/// The core package is published immutably, so the package-admin role governs
/// adapter package custody rather than any transition in this package.
module blast_boosts_core::blast_boosts_core;

// === Constants ===

/// Maximum number of simultaneously registered routine administrators.
const MAX_ADMINS: u64 = 16;

/// Fixed delay before a proposed super administrator may accept root custody.
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

/// Role that authorizes adapter-owned Vault and share-currency issuance.
const VAULT_ISSUER_ROLE: u64 = 1;

/// Role that authorizes risk-module witness rotation.
const RISK_ADMIN_ROLE: u64 = 2;

/// Role that authorizes shutdown initiation.
const SHUTDOWN_ADMIN_ROLE: u64 = 8;

/// Role that authorizes adapter package upgrade custody in this domain.
const PACKAGE_ADMIN_ROLE: u64 = 16;

// === Public Types ===

/// One-time witness that names this administration domain at the type level.
public struct BLAST_BOOSTS_CORE() has drop;

// === Private Initialization ===

fun init(otw: BLAST_BOOSTS_CORE, ctx: &mut TxContext) {
    blast_admin::acl::new(otw, MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx);
}

// === Public Functions ===

/// The role a witness must carry to issue an adapter Vault and its share currency.
public fun vault_issuer_role(): u64 {
    VAULT_ISSUER_ROLE
}

/// The role a witness must carry to rotate an adapter's risk-module witness.
public fun risk_admin_role(): u64 {
    RISK_ADMIN_ROLE
}

/// The role a witness must carry to initiate an adapter shutdown.
public fun shutdown_admin_role(): u64 {
    SHUTDOWN_ADMIN_ROLE
}

/// The role a witness must carry to authorize, cut over, restrict, or seal an upgrade.
public fun package_admin_role(): u64 {
    PACKAGE_ADMIN_ROLE
}

// === Test-Only Functions ===

#[test_only]
/// Runs domain initialization with a genuine test one-time witness.
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<BLAST_BOOSTS_CORE>(), ctx);
}
