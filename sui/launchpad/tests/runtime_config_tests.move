// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::runtime_config_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const PROTOCOL_ADMIN: address = @0xAD;

// === Test-Only Types ===

/// Live-settings administration through the ACL sign-in seam.
public struct ConfigFixture {
    scenario: Scenario,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    package_version: PackageVersion,
    config: RuntimeConfig,
}

// === Tests ===

#[test]
/// Package initialization shares a silent configuration with account claims disabled and no
/// protocol share.
fun package_init_shares_a_config_without_signer_or_protocol_share() {
    let (events, signer_public_key, protocol_fee_share_bps) = published_config();

    assert_eq!(events, 0);
    assert!(signer_public_key.is_empty());
    assert_eq!(protocol_fee_share_bps, 0);
}

// --- Protocol fee share ---

#[test]
fun admin_sets_the_protocol_fee_share_and_it_emits_the_new_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_fee_share(bps::new(7_000));

        assert_eq!(f.config.protocol_fee_share().value(), 7_000);
        assert_eq!(
            bcs::to_bytes(&collect_one<events::ProtocolFeeShareChanged>()),
            bcs::to_bytes(&7_000u64),
        );
    });

    fixture.end();
}

#[test]
fun protocol_fee_share_accepts_both_percentage_boundaries() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_fee_share(bps::new(10_000));
        assert_eq!(f.config.protocol_fee_share().value(), 10_000);

        f.set_protocol_fee_share(bps::new(0));
        assert_eq!(f.config.protocol_fee_share().value(), 0);

        let changes = collect<events::ProtocolFeeShareChanged>();
        assert_eq!(changes.length(), 2);
        assert_eq!(bcs::to_bytes(&changes[0]), bcs::to_bytes(&10_000u64));
        assert_eq!(bcs::to_bytes(&changes[1]), bcs::to_bytes(&0u64));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EUnchanged, location = blast_fun::runtime_config)]
fun protocol_fee_share_rejects_the_current_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_protocol_fee_share(bps::new(0));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun protocol_fee_share_checks_the_version_before_the_current_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.package_version.set_for_testing(2);

        f.set_protocol_fee_share(bps::new(0));
    });

    fixture.end();
}

// --- Creator-claim signer ---

#[test]
fun admin_sets_the_claim_signer_and_it_emits_the_key() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_creator_claim_signer(signer_public_key());

        assert_eq!(*f.config.creator_claim_signer(), signer_public_key());
        assert_eq!(
            bcs::to_bytes(&collect_one<events::CreatorClaimSignerSet>()),
            bcs::to_bytes(&signer_public_key()),
        );
    });

    fixture.end();
}

#[test]
/// An empty key revokes account claims and emits the empty key.
fun an_empty_key_revokes_the_claim_signer() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_creator_claim_signer(signer_public_key());
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_creator_claim_signer(vector[]);

        assert!(f.config.creator_claim_signer().is_empty());
        assert_eq!(
            bcs::to_bytes(&collect_one<events::CreatorClaimSignerSet>()),
            bcs::to_bytes(&vector<u8>[]),
        );
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimPublicKey, location = blast_fun::runtime_config)]
fun claim_signer_rejects_a_key_that_is_not_32_bytes() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_creator_claim_signer(x"00");
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EUnchanged, location = blast_fun::runtime_config)]
fun claim_signer_rejects_the_current_key() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_creator_claim_signer(signer_public_key());
        f.set_creator_claim_signer(signer_public_key());
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EUnchanged, location = blast_fun::runtime_config)]
fun claim_signer_rejects_revoking_an_absent_signer() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_creator_claim_signer(vector[]);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun claim_signer_checks_the_version_before_the_key_length() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.package_version.set_for_testing(2);

        f.set_creator_claim_signer(x"00");
    });

    fixture.end();
}

// === Test Helpers ===

macro fun config_next_tx(
    $fixture: &mut ConfigFixture,
    $sender: address,
    $fn: |&mut ConfigFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

/// Package initialization's events, and its shared configuration's signer key and protocol share.
fun published_config(): (u64, vector<u8>, u64) {
    let mut scenario = test_scenario::begin(PUBLISHER);
    runtime_config::init_for_testing(scenario.ctx());

    let events = scenario.next_tx(PUBLISHER).num_user_events();
    let config = scenario.take_shared<RuntimeConfig>();
    let signer_public_key = *config.creator_claim_signer();
    let protocol_fee_share_bps = config.protocol_fee_share().value();
    test_scenario::return_shared(config);
    scenario.end();

    (events, signer_public_key, protocol_fee_share_bps)
}

/// A zero-role administrator over a configuration as package initialization leaves it.
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

fun config_set_protocol_fee_share(self: &mut ConfigFixture, protocol_fee_share_bps: Bps) {
    let admin_witness = self.authority.sign_in(&self.admin_cap);

    self.config.set_protocol_fee_share(&self.package_version, &admin_witness, protocol_fee_share_bps);
}

fun config_set_creator_claim_signer(self: &mut ConfigFixture, signer_public_key: vector<u8>) {
    let admin_witness = self.authority.sign_in(&self.admin_cap);

    self.config.set_creator_claim_signer(&self.package_version, &admin_witness, signer_public_key);
}

fun config_end(self: ConfigFixture) {
    destroy(self);
}

fun signer_public_key(): vector<u8> {
    x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211"
}

fun collect<T: copy + drop>(): vector<T> {
    event::events_by_type<Event<T>>().map!(|event| event.unwrap())
}

fun collect_one<T: copy + drop>(): T {
    let mut payloads = collect<T>();
    assert_eq!(payloads.length(), 1);
    payloads.pop_back()
}

// === Imports ===

use blast_admin::acl::{Authority, AdminCap};

use blast_fun::{
    blast_events::Event,
    blast_fun_domain::BLAST_FUN_DOMAIN,
    bps::{Self, Bps},
    domain_fixture,
    events,
    package_version::{Self, PackageVersion},
    runtime_config::{Self, RuntimeConfig},
};

use std::{bcs, unit_test::{assert_eq, destroy}};

use sui::{event, test_scenario::{Self, Scenario}};

use fun config_end as ConfigFixture.end;

use fun config_next_tx as ConfigFixture.next_tx;

use fun config_set_creator_claim_signer as ConfigFixture.set_creator_claim_signer;

use fun config_set_protocol_fee_share as ConfigFixture.set_protocol_fee_share;
