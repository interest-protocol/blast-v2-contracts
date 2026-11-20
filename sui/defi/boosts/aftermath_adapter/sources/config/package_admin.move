// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// The generic PackageAdmin owns native upgrade custody, the digest timelock and pause roles.
/// The Boosts Protocol owns the serving generation so a repairable bad build cannot block exits.
module blast_boosts_aftermath::package_admin;

// === Public Functions ===

public fun activate_upgrade(protocol: &mut Protocol, _: &AdminWitness<UpgradeAdmin<BLAST_BOOSTS_AFTERMATH>>) {
    protocol.activate();
}

public fun unpause(
    protocol: &Protocol,
    admin: &PackageAdmin<BLAST_BOOSTS_AFTERMATH>,
    version: &mut PackageVersion<BLAST_BOOSTS_AFTERMATH>,
    treasury: &Treasury,
    witness: &AdminWitness<UnpauseAdmin<BLAST_BOOSTS_AFTERMATH>>,
) {
    protocol.assert_current();
    assert!(treasury.is_guarded(), EUnguardedTreasuryDelay);
    admin.clear_pause_bits(witness, marker::package_witness(), version, marker::deposits!());
}

public fun make_immutable(
    admin: &mut PackageAdmin<BLAST_BOOSTS_AFTERMATH>,
    protocol: &Protocol,
    version: &PackageVersion<BLAST_BOOSTS_AFTERMATH>,
    witness: &AdminWitness<UpgradeAdmin<BLAST_BOOSTS_AFTERMATH>>,
    clock: &Clock,
) {
    protocol.assert_current();
    admin.make_immutable(witness, marker::package_witness(), version, clock);
}

// === Errors ===

const EUnguardedTreasuryDelay: u64 = 0;

// === Imports ===

use blast_core::blast_treasury::Treasury;

use blast_admin::{
    blast_acl::AdminWitness,
    package_admin::{PackageAdmin, UnpauseAdmin, UpgradeAdmin},
    package_version::PackageVersion,
};

use blast_boosts_aftermath::blast_boosts_aftermath::{Self as marker, BLAST_BOOSTS_AFTERMATH, Protocol};

use sui::clock::Clock;
