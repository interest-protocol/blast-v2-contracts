/// The Launchpad-owned administration domain shared with Migrators and Distributor.
///
/// This module owns the domain one-time witness, the governance configuration,
/// and the single exported role bit. Reusing packages import
/// `AdminWitness<LAUNCHPAD_DOMAIN>` and `package_admin_role`; they never create
/// another authority and never restate the numeric role.
module blast_fun::launchpad_domain;

// === Constants ===

/// Maximum number of simultaneously registered routine administrators.
const MAX_ADMINS: u64 = 16;

/// Fixed delay before a proposed super administrator may accept root custody.
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

/// Role that authorizes package upgrade custody in every package of this domain.
const PACKAGE_ADMIN_ROLE: u64 = 1;

// === Public Structs ===

/// One-time witness that names this administration domain at the type level.
public struct LAUNCHPAD_DOMAIN has drop {}

// === Private Initialization ===

fun init(otw: LAUNCHPAD_DOMAIN, ctx: &mut TxContext) {
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
    init(sui::test_utils::create_one_time_witness<LAUNCHPAD_DOMAIN>(), ctx);
}
