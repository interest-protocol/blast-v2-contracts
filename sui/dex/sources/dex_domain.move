/// The independent DEX administration domain.
///
/// This package governs its own factory, pool policy, and package custody. It
/// shares no authority with Launchpad, Blast SUI, or Series One: a capability or
/// witness from any other domain is a different type and cannot reach these
/// operations.
///
/// The single deliberate exception is `migration::claim_protocol_fees`, which
/// drains a Launchpad-owned `FeeLedger` and therefore stays under Launchpad
/// product-fee custody rather than DEX administration.
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
