// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::runtime_config_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const PROTOCOL_ADMIN: address = @0xAD;

// === Test-Only Types ===

/// Package-initialization facts only; carries no ACL or admin state.
public struct InitFixture {
    scenario: Scenario,
    config: runtime_config::RuntimeConfig,
}

/// Live-settings administration through the ACL sign-in seam.
public struct ConfigFixture {
    scenario: Scenario,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    package_version: package_version::PackageVersion,
    config: runtime_config::RuntimeConfig,
}

// === Tests ===

#[test]
fun package_init_creates_disabled_zero_share_runtime_config() {
    let mut fixture = start_init();

    fixture.next_tx!(PUBLISHER, |f| {
        assert_eq!(f.config.protocol_fee_share().value(), 0);
    });

    fixture.end();
}

#[test]
fun active_admin_updates_live_share_and_emits_new_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(7_000));

        let changed = events::collect_one<events::ProtocolFeeShareChanged>(0);
        assert_eq!(f.config.protocol_fee_share().value(), 7_000);
        assert_eq!(bcs::to_bytes(&changed), bcs::to_bytes(&7_000u64));
        assert!(event::events_by_type<events::ProtocolFeeShareChanged>().is_empty());
    });

    fixture.end();
}

#[test]
fun one_runtime_config_and_admin_witness_update_both_live_settings() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let signer_public_key =
            x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211";

        f.config.set_creator_claim_signer(
            &f.package_version,
            &admin_witness,
            signer_public_key,
        );
        f.config.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(2_500));

        let signer_set = events::collect_one<events::CreatorClaimSignerSet>(0);
        let fee_share_changed =
            events::collect_one<events::ProtocolFeeShareChanged>(0);

        assert_eq!(bcs::to_bytes(&signer_set), bcs::to_bytes(&signer_public_key));
        assert_eq!(bcs::to_bytes(&fee_share_changed), bcs::to_bytes(&2_500u64));
        assert_eq!(f.config.protocol_fee_share().value(), 2_500);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidBps,
    location = blast_fun::bps,
)]
fun protocol_fee_share_input_cannot_exceed_one_hundred_percent() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(10_001));
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_package_version_rejects_runtime_config_before_unchanged_check() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(2);

        f.config.set_protocol_fee_share(
            &f.package_version,
            &admin_witness,
            bps::new(0),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EProtocolFeeShareUnchanged,
    location = blast_fun::runtime_config,
)]
fun protocol_fee_share_rejects_unchanged_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(0));
    });

    fixture.end();
}

#[test]
fun protocol_fee_share_accepts_both_percentage_boundaries() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(10_000));
        assert_eq!(f.config.protocol_fee_share().value(), 10_000);

        f.config.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(0));
        assert_eq!(f.config.protocol_fee_share().value(), 0);

        let mut changes = events::collect<events::ProtocolFeeShareChanged>();
        assert_eq!(changes.length(), 2);
        let second = changes.pop_back();
        let first = changes.pop_back();

        assert_eq!(bcs::to_bytes(&first), bcs::to_bytes(&10_000u64));
        assert_eq!(bcs::to_bytes(&second), bcs::to_bytes(&0u64));
    });

    fixture.end();
}

// === Test Helpers ===

macro fun init_next_tx(
    $fixture: &mut InitFixture,
    $sender: address,
    $fn: |&mut InitFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun config_next_tx(
    $fixture: &mut ConfigFixture,
    $sender: address,
    $fn: |&mut ConfigFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start_init(): InitFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    runtime_config::init_for_testing(scenario.ctx());

    assert_eq!(event::num_events(), 0);

    scenario.next_tx(PUBLISHER);
    let config = scenario.take_shared<runtime_config::RuntimeConfig>();

    InitFixture { scenario, config }
}

fun start(): ConfigFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(&super_admin_cap, 0, PROTOCOL_ADMIN, scenario.ctx());
    destroy(super_admin_cap);
    let config = runtime_config::new_disabled_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();

    ConfigFixture { scenario, authority, admin_cap, package_version, config }
}

fun sign_in(self: &ConfigFixture): AdminWitness<BLAST_FUN_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun init_end(self: InitFixture) {
    destroy(self);
}

fun config_end(self: ConfigFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::{Authority, AdminCap, AdminWitness};

use blast_fun::{
    bps,
    domain_fixture,
    events,
    blast_fun_domain::BLAST_FUN_DOMAIN,
    package_version,
    runtime_config,
};

use std::{bcs, unit_test::{assert_eq, destroy}};

use sui::{event, test_scenario::{Self, Scenario}};

use fun config_end as ConfigFixture.end;

use fun config_next_tx as ConfigFixture.next_tx;

use fun init_end as InitFixture.end;

use fun init_next_tx as InitFixture.next_tx;
