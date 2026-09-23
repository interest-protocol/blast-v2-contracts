// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// The release adapter matrix. Cetus and Bluefin are the package's only migration witnesses, and
/// the migrator source gate proves no other module declares one or reaches a launchpad seam.
module blast_fun_migrators::release_matrix_tests;

// === Constants ===

const ADMIN: address = @0xAD;

// === Tests ===

#[test]
fun the_release_allowlist_admits_exactly_the_cetus_and_bluefin_witnesses() {
    let mut scenario = test_scenario::begin(ADMIN);
    let version = package_version::new_for_testing(scenario.ctx());
    let (root, mut authority) = acl::new_for_testing<BLAST_FUN_DOMAIN>(16, 1, scenario.ctx());
    authority.grant_admin(&root, blast_fun_domain::creator_admin_role(), ADMIN, scenario.ctx());
    let mut config = launch_config::new_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    let admin = authority.sign_in(&admin_cap);
    config.allow_migration_witness<cetus::Witness>(&version, &admin);
    config.allow_migration_witness<bluefin::Witness>(&version, &admin);

    assert_eq!(config.allowed_migration_witness_count_for_testing(), 2);

    destroy(config);
    destroy(admin_cap);
    destroy(authority);
    destroy(root);
    destroy(version);
    scenario.end();
}

// === Imports ===

use blast_admin::acl::{Self, AdminCap};

use blast_fun::{
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    launch_config,
    package_version,
};

use blast_fun_migrators::{bluefin, cetus};

use std::unit_test::{assert_eq, destroy};

use sui::test_scenario;
