// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::runtime_config_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const PROTOCOL_ADMIN: address = @0xAD;

const PARTNER: address = @0x9A27;

/// When the fixture clock removes a partner.
const NOW_MS: u64 = 1_000;

// === Test-Only Types ===

/// Live-settings administration under each setter's own role.
public struct ConfigFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    config: RuntimeConfig,
    clock: Clock,
}

// === Tests ===

#[test]
/// Package initialization shares a silent configuration with account claims disabled, no
/// protocol share, and free creation.
fun package_init_shares_a_config_without_signer_or_protocol_share() {
    let (events, signer_public_key, protocol_fee_share_bps, creation_fee) = published_config();

    assert_eq!(events, 0);
    assert!(signer_public_key.is_empty());
    assert_eq!(protocol_fee_share_bps, 0);
    assert_eq!(creation_fee, 0);
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

// --- Creation fee ---

#[test]
fun admin_sets_the_creation_fee_and_it_emits_the_new_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_creation_fee(2_000_000_000);

        assert_eq!(f.config.creation_fee(), 2_000_000_000);
        assert_eq!(
            bcs::to_bytes(&collect_one<events::CreationFeeChanged>()),
            bcs::to_bytes(&2_000_000_000u64),
        );
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EUnchanged, location = blast_fun::runtime_config)]
fun creation_fee_rejects_the_current_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_creation_fee(0);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun creation_fee_checks_the_version_before_the_current_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.package_version.set_for_testing(2);

        f.set_creation_fee(0);
    });

    fixture.end();
}

// --- Partners ---

#[test]
fun an_added_partner_is_accepted_at_once() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();

        f.add_partner(&partner);

        f.config.assert_partner(object::id(&partner), NOW_MS);
        assert_eq!(
            bcs::to_bytes(&collect_one<events::PartnerAdded>()),
            bcs::to_bytes(&object::id(&partner)),
        );
        destroy(partner);
    });

    fixture.end();
}

#[test]
/// A removed partner stays accepted for exactly the partner delay.
fun a_removed_partner_stays_accepted_for_the_partner_delay() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();
        let partner_id = object::id(&partner);
        f.add_partner(&partner);

        f.remove_partner(&partner);

        f.config.assert_partner(partner_id, NOW_MS + partners::delay_ms() - 1);
        let mut expected = bcs::to_bytes(&partner_id);
        expected.append(bcs::to_bytes(&(NOW_MS + partners::delay_ms())));
        assert_eq!(bcs::to_bytes(&collect_one<events::PartnerRemoved>()), expected);
        destroy(partner);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EPartnerNotAccepted, location = blast_fun::runtime_config)]
fun a_removed_partner_is_refused_once_its_notice_ends() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();
        f.add_partner(&partner);
        f.remove_partner(&partner);

        f.config.assert_partner(object::id(&partner), NOW_MS + partners::delay_ms());
        destroy(partner);
    });

    fixture.end();
}

#[test]
/// Adding a partner whose removal is pending cancels the removal.
fun adding_a_removed_partner_accepts_it_again() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();
        f.add_partner(&partner);
        f.remove_partner(&partner);

        f.add_partner(&partner);

        f.config.assert_partner(object::id(&partner), std::u64::max_value!() - 1);
        destroy(partner);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EUnchanged, location = blast_fun::runtime_config)]
fun adding_an_accepted_partner_aborts() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();
        f.add_partner(&partner);

        f.add_partner(&partner);
        destroy(partner);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EUnchanged, location = blast_fun::runtime_config)]
fun removing_a_partner_twice_aborts() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();
        f.add_partner(&partner);
        f.remove_partner(&partner);

        f.remove_partner(&partner);
        destroy(partner);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EPartnerNotAccepted, location = blast_fun::runtime_config)]
fun removing_an_unknown_partner_aborts() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();

        f.remove_partner(&partner);
        destroy(partner);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun adding_a_partner_checks_the_version_first() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();
        f.package_version.set_for_testing(2);

        f.add_partner(&partner);
        destroy(partner);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun removing_a_partner_checks_the_version_before_the_list() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let partner = f.new_partner();
        f.package_version.set_for_testing(2);

        f.remove_partner(&partner);
        destroy(partner);
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

/// Package initialization's events, and its shared configuration's signer key, protocol share, and
/// creation fee.
fun published_config(): (u64, vector<u8>, u64, u64) {
    let mut scenario = test_scenario::begin(PUBLISHER);
    runtime_config::init_for_testing(scenario.ctx());

    let events = scenario.next_tx(PUBLISHER).num_user_events();
    let config = scenario.take_shared<RuntimeConfig>();
    let signer_public_key = *config.creator_claim_signer();
    let protocol_fee_share_bps = config.protocol_fee_share().value();
    let creation_fee = config.creation_fee();
    test_scenario::return_shared(config);
    scenario.end();

    (events, signer_public_key, protocol_fee_share_bps, creation_fee)
}

/// A configuration as package initialization leaves it.
fun start(): ConfigFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let config = runtime_config::new_disabled_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);

    ConfigFixture { scenario, package_version, config, clock }
}

fun config_set_protocol_fee_share(self: &mut ConfigFixture, protocol_fee_share_bps: Bps) {
    let admin_witness = blast_acl::witness_for_testing<FeeAdmin>();

    self.config.set_protocol_fee_share(&self.package_version, &admin_witness, protocol_fee_share_bps);
}

fun config_set_creator_claim_signer(self: &mut ConfigFixture, signer_public_key: vector<u8>) {
    let admin_witness = blast_acl::witness_for_testing<ClaimSignerAdmin>();

    self.config.set_creator_claim_signer(&self.package_version, &admin_witness, signer_public_key);
}

fun config_set_creation_fee(self: &mut ConfigFixture, creation_fee: u64) {
    let admin_witness = blast_acl::witness_for_testing<FeeAdmin>();

    self.config.set_creation_fee(&self.package_version, &admin_witness, creation_fee);
}

fun config_new_partner(self: &mut ConfigFixture): Partner {
    partners::new_for_testing(PARTNER, 4_000, self.scenario.ctx())
}

fun config_add_partner(self: &mut ConfigFixture, partner: &Partner) {
    let admin_witness = blast_acl::witness_for_testing<FeeAdmin>();

    self.config.add_partner(&self.package_version, &admin_witness, partner);
}

fun config_remove_partner(self: &mut ConfigFixture, partner: &Partner) {
    let admin_witness = blast_acl::witness_for_testing<FeeAdmin>();

    self.config.remove_partner(&self.package_version, &admin_witness, partner, &self.clock);
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

use blast_admin::blast_acl;

use blast_fun::{
    blast_events::Event,
    blast_fun_domain::{ClaimSignerAdmin, FeeAdmin},
    bps::{Self, Bps},
    events,
    package_version::{Self, PackageVersion},
    runtime_config::{Self, RuntimeConfig},
};

use blast_partners::blast_partners::{Self as partners, Partner};

use std::{bcs, unit_test::{assert_eq, destroy}};

use sui::{clock::{Self, Clock}, event, test_scenario::{Self, Scenario}};

use fun config_end as ConfigFixture.end;

use fun config_next_tx as ConfigFixture.next_tx;

use fun config_set_creator_claim_signer as ConfigFixture.set_creator_claim_signer;

use fun config_set_protocol_fee_share as ConfigFixture.set_protocol_fee_share;

use fun config_set_creation_fee as ConfigFixture.set_creation_fee;

use fun config_new_partner as ConfigFixture.new_partner;

use fun config_add_partner as ConfigFixture.add_partner;

use fun config_remove_partner as ConfigFixture.remove_partner;
