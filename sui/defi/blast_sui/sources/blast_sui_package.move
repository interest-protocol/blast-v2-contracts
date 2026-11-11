// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast SUI's publication and its package witness.
///
/// Publication hands the deployer an owned `Publication<BLAST_SUI_PACKAGE>`, which
/// `blast_admin::package_admin::wrap` turns into the shared `PackageAdmin<BLAST_SUI_PACKAGE>` and
/// the shared `PackageVersion<BLAST_SUI_PACKAGE>`, with every deposit paused. Pausing, upgrades,
/// and immutability go through `blast_admin::package_admin` under the package-scoped roles
/// `PauseAdmin<BLAST_SUI_PACKAGE>`, `UpgradeAdmin<BLAST_SUI_PACKAGE>`, and
/// `CancelAdmin<BLAST_SUI_PACKAGE>`.
///
/// The publication pins `PackageWitness`, the one witness the package passes to the generic
/// administration's pause release. `vault::unpause` releases pause bits once the vault's delays
/// are guarded; it lives beside the state it reads.
module blast_sui::blast_sui_package;

// === Public Types ===

/// The package's one-time witness (OTW), typing its version, publication, and roles.
public struct BLAST_SUI_PACKAGE() has drop;

/// The package witness. Only this package constructs it, through `package_witness`; its one
/// caller passes it straight into the release call, and no function stores it or returns it
/// outside this package.
public struct PackageWitness() has drop;

// === Private Initialization ===

fun init(otw: BLAST_SUI_PACKAGE, ctx: &mut TxContext) {
    package_version::new_publication<_, PackageWitness>(otw, constants::valid_pause_bits!(), ctx)
        .keep(ctx);
}

// === Package Functions ===

/// The package witness, for the package's own pause release.
public(package) fun package_witness(): PackageWitness {
    PackageWitness()
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(BLAST_SUI_PACKAGE(), ctx);
}

#[test_only]
/// An unshared, unpaused version for tests.
public fun version_for_testing(ctx: &mut TxContext): PackageVersion<BLAST_SUI_PACKAGE> {
    package_version::new_for_testing<_, PackageWitness>(constants::valid_pause_bits!(), ctx)
}

#[test_only]
/// Package administration around a test Publisher and upgrade cap, with the 48-hour delay.
public fun package_admin_for_testing(
    ctx: &mut TxContext,
): PackageAdmin<BLAST_SUI_PACKAGE> {
    package_admin::new_for_testing(
        sui::package::test_claim(BLAST_SUI_PACKAGE(), ctx),
        sui::package::test_publish(@blast_sui.to_id(), ctx),
        ctx,
    )
}

// === Imports ===

#[test_only]
use blast_admin::package_admin::{Self, PackageAdmin};

use blast_admin::package_version::{Self, PackageVersion};

use blast_sui::constants;
