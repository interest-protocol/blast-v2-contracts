// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// DEX publication and pause release. The deployer wraps the publication and native
/// upgrade cap through `blast_admin::package_admin::wrap` to start the DEX fully paused.
module blast_fun_dex::blast_fun_dex;

// === Public Types ===

/// The DEX one-time witness, typing its publication, version and package roles.
public struct BLAST_FUN_DEX() has drop;

/// The witness pinned at publication and constructed only by this module.
public struct PackageWitness() has drop;

// === Private Initialization ===

fun init(otw: BLAST_FUN_DEX, ctx: &mut TxContext) {
    package_version::new_publication<_, PackageWitness>(otw, constants::valid_pause_bits!(), ctx)
        .keep(ctx);
}

// === Public Functions ===

/// Releases selected pause bits after checking the active DEX version and the upgrade delay.
public fun unpause(
    package_version: &mut PackageVersion<BLAST_FUN_DEX>,
    unpause_admin: &AdminWitness<UnpauseAdmin<BLAST_FUN_DEX>>,
    package_admin: &PackageAdmin<BLAST_FUN_DEX>,
    bits: u8,
) {
    package_version.assert_current(constants::version!());
    package_admin.clear_pause_bits(unpause_admin, PackageWitness(), package_version, bits);
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(BLAST_FUN_DEX(), ctx);
}

#[test_only]
/// An unshared, current and unpaused DEX version for focused tests.
public fun version_for_testing(ctx: &mut TxContext): PackageVersion<BLAST_FUN_DEX> {
    package_version::new_for_testing<_, PackageWitness>(constants::valid_pause_bits!(), ctx)
}

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    package_admin::{PackageAdmin, UnpauseAdmin},
    package_version::{Self, PackageVersion},
};
use blast_fun_dex::constants;
