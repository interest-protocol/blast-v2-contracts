// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Shared authority construction for focused DEX tests.
///
/// The reusable ACL invariants are proved in `blast_admin`. DEX tests use this
/// helper to obtain live typed administration in the two domains this package
/// touches: its own for factory, pool policy, and package custody, and the
/// Launchpad domain for the single product-fee exception.
module blast_fun_dex::domain_fixture;

// === Constants ===

const MAX_ADMINS: u64 = 16;

const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Tests ===

#[test]
/// Both fixtures commit the same governance configuration their production
/// initializers do, so focused suites cannot drift away from either.
fun the_fixtures_use_their_packages_governance_constants() {
    let mut ctx = tx_context::dummy();
    let (dex_root, dex_authority) = new_dex_authority(&mut ctx);
    let (launchpad_root, launchpad_authority) = new_launchpad_authority(&mut ctx);

    assert_eq!(dex_authority.max_admins_for_testing(), MAX_ADMINS);
    assert_eq!(dex_authority.root_transfer_delay_ms_for_testing(), ROOT_TRANSFER_DELAY_MS);
    assert_eq!(launchpad_authority.max_admins_for_testing(), MAX_ADMINS);
    assert_eq!(
        launchpad_authority.root_transfer_delay_ms_for_testing(),
        ROOT_TRANSFER_DELAY_MS,
    );

    destroy(dex_root);
    destroy(dex_authority);
    destroy(launchpad_root);
    destroy(launchpad_authority);
    destroy(ctx);
}

// === Test Helpers ===

/// Unshared DEX-domain authority state using this package's real constants.
public fun new_dex_authority(
    ctx: &mut TxContext,
): (SuperAdminCap<DEX_DOMAIN>, Authority<DEX_DOMAIN>) {
    acl::new_for_testing<DEX_DOMAIN>(MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx)
}

/// Unshared Launchpad-domain authority state for the product-fee exception.
public fun new_launchpad_authority(
    ctx: &mut TxContext,
): (SuperAdminCap<BLAST_FUN_DOMAIN>, Authority<BLAST_FUN_DOMAIN>) {
    acl::new_for_testing<BLAST_FUN_DOMAIN>(MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx)
}

// === Imports ===

use blast_admin::acl::{Self, Authority, SuperAdminCap};

use blast_fun::blast_fun_domain::BLAST_FUN_DOMAIN;

use blast_fun_dex::dex_domain::DEX_DOMAIN;

use std::unit_test::{assert_eq, destroy};
