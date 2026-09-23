// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Shared Series1-domain authority construction for focused package tests.
///
/// The reusable ACL invariants are proved in `blast_admin`. Series1 tests use
/// this helper only to obtain live typed administration for the product
/// operations they exercise, so every suite commits the same governance
/// configuration the production initializer does.
module blast_boosts_core::domain_fixture;

// === Constants ===

const MAX_ADMINS: u64 = 16;

const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Tests ===

#[test]
/// The fixture commits the same governance configuration as the production
/// initializer, so focused suites cannot drift away from it.
fun the_fixture_uses_this_packages_governance_constants() {
    let mut ctx = tx_context::dummy();
    let (super_admin_cap, authority) = new_authority(&mut ctx);

    assert_eq!(authority.max_admins_for_testing(), MAX_ADMINS);
    assert_eq!(authority.root_transfer_delay_ms_for_testing(), ROOT_TRANSFER_DELAY_MS);

    destroy(super_admin_cap);
    destroy(authority);
    destroy(ctx);
}

// === Test Helpers ===

/// Unshared Series1-domain authority state using this package's real constants.
public fun new_authority(
    ctx: &mut TxContext,
): (SuperAdminCap<BLAST_BOOSTS_CORE>, Authority<BLAST_BOOSTS_CORE>) {
    acl::new_for_testing<BLAST_BOOSTS_CORE>(MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx)
}

// === Imports ===

use blast_admin::acl::{Self, Authority, SuperAdminCap};

use blast_boosts_core::blast_boosts_core::BLAST_BOOSTS_CORE;

use std::unit_test::{assert_eq, destroy};
