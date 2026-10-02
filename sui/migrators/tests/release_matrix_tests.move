// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// The release adapter matrix: Launchpad admits the Cetus and Bluefin witnesses as two distinct
/// migration witnesses. That no other module declares a witness or reaches a launchpad seam is
/// proven by the migrator source gate, not by this test.
module blast_fun_migrators::release_matrix_tests;

// === Constants ===

const ADMIN: address = @0xAD;

// === Test-Only Types ===

public struct MatrixFixture {
    scenario: Scenario,
    version: PackageVersion,
    config: LaunchConfig,
}

// === Tests ===

#[test]
fun the_cetus_and_bluefin_witnesses_are_admissible() {
    let mut f = start();

    f.admit<cetus::Witness>();
    f.admit<bluefin::Witness>();

    assert_eq!(f.config.allowed_migration_witness_count_for_testing(), 2);

    f.end();
}

// === Test Helpers ===

fun start(): MatrixFixture {
    let mut scenario = test_scenario::begin(ADMIN);
    let version = package_version::new_for_testing(scenario.ctx());
    let config = launch_config::new_for_testing(scenario.ctx());

    MatrixFixture { scenario, version, config }
}

fun admit<MigrationWitness: drop>(self: &mut MatrixFixture) {
    let admin = blast_acl::witness_for_testing<AdapterAdmin>();
    self.config.set_migration_witness_allowed<MigrationWitness>(&self.version, &admin, true);
}

fun end(self: MatrixFixture) {
    let MatrixFixture { scenario, version, config } = self;
    destroy(config);
    destroy(version);
    scenario.end();
}

// === Imports ===

use blast_admin::blast_acl;

use blast_fun::{
    blast_fun_domain::AdapterAdmin,
    launch_config::{Self, LaunchConfig},
    blast_fun::{Self as package_version, PackageVersion},
};

use blast_fun_migrators::{bluefin, cetus};

use std::unit_test::{assert_eq, destroy};

use sui::test_scenario::{Self, Scenario};
