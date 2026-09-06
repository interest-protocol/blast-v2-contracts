#[test_only]
/// Shared Series1-domain authority construction for focused adapter tests.
///
/// The reusable ACL invariants are proved in `blast_admin`, and the domain's own
/// wiring in `blast_leverage_series_one`. Adapter tests use this helper only to
/// obtain live typed administration for the operations they exercise, so every
/// suite commits the same governance configuration Series1 initialization does.
module blast_leverage_aftermath::domain_fixture;

use blast_admin::acl::{Self, Authority, SuperAdminCap};
use blast_leverage_series_one::series_one_domain::SERIES_ONE_DOMAIN;
use std::unit_test::{assert_eq, destroy};

// === Constants ===

const MAX_ADMINS: u64 = 16;
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Public Functions ===

/// Unshared Series1-domain authority state using the domain's real constants.
public fun new_authority(
    ctx: &mut TxContext,
): (SuperAdminCap<SERIES_ONE_DOMAIN>, Authority<SERIES_ONE_DOMAIN>) {
    acl::new_for_testing<SERIES_ONE_DOMAIN>(MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx)
}

// === Tests ===

#[test]
/// The fixture commits the same governance configuration the Series1
/// initializer does, so adapter suites cannot drift away from it.
fun the_fixture_uses_the_series_one_governance_constants() {
    let mut ctx = tx_context::dummy();
    let (super_admin_cap, authority) = new_authority(&mut ctx);

    assert_eq!(authority.max_admins_for_testing(), MAX_ADMINS);
    assert_eq!(authority.root_transfer_delay_ms_for_testing(), ROOT_TRANSFER_DELAY_MS);

    destroy(super_admin_cap);
    destroy(authority);
    destroy(ctx);
}
