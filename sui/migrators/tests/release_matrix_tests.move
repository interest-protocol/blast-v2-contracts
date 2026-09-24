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
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
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
    let (root, mut authority) = acl::new_for_testing<BLAST_FUN_DOMAIN>(16, 1, scenario.ctx());
    authority.grant_admin(&root, blast_fun_domain::creator_admin_role_for_testing(), ADMIN, scenario.ctx());
    destroy(root);
    let config = launch_config::new_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();

    MatrixFixture { scenario, version, authority, admin_cap, config }
}

fun admit<MigrationWitness: drop>(self: &mut MatrixFixture) {
    let admin = self.authority.sign_in(&self.admin_cap);
    self.config.set_migration_witness_allowed<MigrationWitness>(&self.version, &admin, true);
}

fun end(self: MatrixFixture) {
    let MatrixFixture { scenario, version, authority, admin_cap, config } = self;
    destroy(config);
    destroy(admin_cap);
    destroy(authority);
    destroy(version);
    scenario.end();
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap};

use blast_fun::{
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    launch_config::{Self, LaunchConfig},
    package_version::{Self, PackageVersion},
};

use blast_fun_migrators::{bluefin, cetus};

use std::unit_test::{assert_eq, destroy};

use sui::test_scenario::{Self, Scenario};
