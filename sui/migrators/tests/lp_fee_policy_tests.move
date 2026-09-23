// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_migrators::lp_fee_policy_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;
const MAX_ADMINS: u64 = 16;
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

public struct PARTNER_MEME() has drop;
public struct OTHER_MEME() has drop;

/// Package-initialization facts only; carries no ACL or admin state.
public struct InitFixture {
    scenario: Scenario,
    policy: LpFeePolicy,
}

/// LP-fee policy administration through the ACL sign-in seam.
public struct PolicyFixture {
    scenario: Scenario,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    package_version: package_version::PackageVersion,
    policy: LpFeePolicy,
}

// === Tests ===

#[test]
fun package_init_creates_zero_share_policy_without_events_or_projects() {
    let mut fixture = start_init();

    fixture.next_tx!(PUBLISHER, |f| {
        assert_eq!(f.policy.protocol_fee_share<PARTNER_MEME>().value(), 0);
        assert_eq!(f.policy.project_count_for_testing(), 0);
    });

    fixture.end();
}

#[test]
fun active_admin_updates_default_share_and_emits_new_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.policy.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(3_000));

        let changed = event::events_by_type<blast_events::LpProtocolFeeShareChanged>();
        assert_eq!(changed.length(), 1);
        assert_eq!(changed[0].lp_protocol_fee_share_changed_fields(), 3_000);
        assert_eq!(f.policy.protocol_fee_share<PARTNER_MEME>().value(), 3_000);
    });

    fixture.end();
}

#[test]
fun default_share_accepts_both_percentage_boundaries() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.policy.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(10_000));
        assert_eq!(f.policy.protocol_fee_share<PARTNER_MEME>().value(), 10_000);

        f.policy.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(0));
        assert_eq!(f.policy.protocol_fee_share<PARTNER_MEME>().value(), 0);
        assert_eq!(event::events_by_type<blast_events::LpProtocolFeeShareChanged>().length(), 2);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_policy::EProtocolFeeShareUnchanged,
    location = blast_fun_migrators::lp_fee_policy,
)]
fun default_share_rejects_unchanged_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.policy.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(0));
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidBps,
    location = blast_fun::bps,
)]
fun share_inputs_cannot_exceed_one_hundred_percent() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.policy.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(10_001));
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_package_version_rejects_default_share_before_unchanged_check() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(2);

        f.policy.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(0));
    });

    fixture.end();
}

#[test]
fun project_share_takes_precedence_over_default_and_emits_its_meme() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.policy.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(5_000));
        f.policy.set_project_protocol_fee_share<PARTNER_MEME>(
            &f.package_version,
            &admin_witness,
            bps::new(1_000),
        );

        let set = event::events_by_type<blast_events::ProjectLpProtocolFeeShareSet>();
        assert_eq!(set.length(), 1);
        let (meme, share_bps) = set[0].project_lp_protocol_fee_share_set_fields();
        assert_eq!(meme, type_name::with_original_ids<PARTNER_MEME>());
        assert_eq!(share_bps, 1_000);
        assert_eq!(f.policy.protocol_fee_share<PARTNER_MEME>().value(), 1_000);
        assert_eq!(f.policy.protocol_fee_share<OTHER_MEME>().value(), 5_000);
        assert_eq!(f.policy.project_count_for_testing(), 1);
    });

    fixture.end();
}

#[test]
fun project_share_equal_to_default_is_a_pin_that_survives_default_changes() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.policy.set_project_protocol_fee_share<PARTNER_MEME>(
            &f.package_version,
            &admin_witness,
            bps::new(0),
        );
        f.policy.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(4_000));

        assert_eq!(f.policy.protocol_fee_share<PARTNER_MEME>().value(), 0);
        assert_eq!(f.policy.protocol_fee_share<OTHER_MEME>().value(), 4_000);
    });

    fixture.end();
}

#[test]
fun project_share_repins_to_a_different_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.policy.set_project_protocol_fee_share<PARTNER_MEME>(
            &f.package_version,
            &admin_witness,
            bps::new(1_000),
        );
        f.policy.set_project_protocol_fee_share<PARTNER_MEME>(
            &f.package_version,
            &admin_witness,
            bps::new(10_000),
        );

        assert_eq!(f.policy.protocol_fee_share<PARTNER_MEME>().value(), 10_000);
        assert_eq!(f.policy.project_count_for_testing(), 1);
        assert_eq!(event::events_by_type<blast_events::ProjectLpProtocolFeeShareSet>().length(), 2);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_policy::EProjectProtocolFeeShareUnchanged,
    location = blast_fun_migrators::lp_fee_policy,
)]
fun project_share_rejects_repinning_its_current_value() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.policy.set_project_protocol_fee_share<PARTNER_MEME>(
            &f.package_version,
            &admin_witness,
            bps::new(1_000),
        );
        f.policy.set_project_protocol_fee_share<PARTNER_MEME>(
            &f.package_version,
            &admin_witness,
            bps::new(1_000),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_package_version_rejects_project_share() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(2);

        f.policy.set_project_protocol_fee_share<PARTNER_MEME>(
            &f.package_version,
            &admin_witness,
            bps::new(1_000),
        );
    });

    fixture.end();
}

#[test]
fun cleared_project_follows_the_default_again_and_emits_its_meme() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.policy.set_protocol_fee_share(&f.package_version, &admin_witness, bps::new(2_500));
        f.policy.set_project_protocol_fee_share<PARTNER_MEME>(
            &f.package_version,
            &admin_witness,
            bps::new(500),
        );
        f.policy.clear_project_protocol_fee_share<PARTNER_MEME>(
            &f.package_version,
            &admin_witness,
        );

        let cleared = event::events_by_type<blast_events::ProjectLpProtocolFeeShareCleared>();
        assert_eq!(cleared.length(), 1);
        assert_eq!(
            cleared[0].project_lp_protocol_fee_share_cleared_fields(),
            type_name::with_original_ids<PARTNER_MEME>(),
        );
        assert_eq!(f.policy.protocol_fee_share<PARTNER_MEME>().value(), 2_500);
        assert_eq!(f.policy.project_count_for_testing(), 0);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_policy::EProjectProtocolFeeShareMissing,
    location = blast_fun_migrators::lp_fee_policy,
)]
fun clear_rejects_a_project_without_a_pinned_share() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.policy.set_project_protocol_fee_share<OTHER_MEME>(
            &f.package_version,
            &admin_witness,
            bps::new(500),
        );
        f.policy.clear_project_protocol_fee_share<PARTNER_MEME>(
            &f.package_version,
            &admin_witness,
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_package_version_rejects_clear_before_missing_check() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.package_version.set_for_testing(2);

        f.policy.clear_project_protocol_fee_share<PARTNER_MEME>(
            &f.package_version,
            &admin_witness,
        );
    });

    fixture.end();
}

// === Private Test Helpers ===

macro fun init_next_tx(
    $fixture: &mut InitFixture,
    $sender: address,
    $fn: |&mut InitFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun policy_next_tx(
    $fixture: &mut PolicyFixture,
    $sender: address,
    $fn: |&mut PolicyFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start_init(): InitFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    lp_fee_policy::init_for_testing(scenario.ctx());

    assert_eq!(event::num_events(), 0);

    scenario.next_tx(PUBLISHER);
    let policy = scenario.take_shared<LpFeePolicy>();

    InitFixture { scenario, policy }
}

fun start(): PolicyFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = acl::new_for_testing<BLAST_FUN_DOMAIN>(
        MAX_ADMINS,
        ROOT_TRANSFER_DELAY_MS,
        scenario.ctx(),
    );
    authority.grant_admin(&super_admin_cap, 0, PROTOCOL_ADMIN, scenario.ctx());
    destroy(super_admin_cap);
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();

    PolicyFixture { scenario, authority, admin_cap, package_version, policy }
}

fun sign_in(self: &PolicyFixture): AdminWitness<BLAST_FUN_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun init_end(self: InitFixture) {
    destroy(self);
}

fun policy_end(self: PolicyFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap, AdminWitness};

use blast_fun::{bps, blast_fun_domain::BLAST_FUN_DOMAIN};

use blast_fun_migrators::{blast_events, lp_fee_policy::{Self, LpFeePolicy}, package_version};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{event, test_scenario::{Self, Scenario}};

use fun init_end as InitFixture.end;

use fun init_next_tx as InitFixture.next_tx;

use fun policy_end as PolicyFixture.end;

use fun policy_next_tx as PolicyFixture.next_tx;
