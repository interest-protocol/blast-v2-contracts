// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_migrators::vault_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const PROTOCOL_ADMIN: address = @0xAD;

const MAX_ADMINS: u64 = 16;

const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

public struct MEME has drop {}

public struct QUOTE has drop {}

public struct TestVenue() has drop;

public struct OtherVenue() has drop;

public struct TestPosition has key, store { id: UID }

/// Shared position custody and protocol residuals through the vault seam.
public struct VaultFixture {
    scenario: Scenario,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    migrators_version: MigratorsVersion,
    vault: LpVault<MEME, QUOTE>,
    position_id: ID,
}

// === Tests ===

#[test]
fun prepared_vault_keeps_its_id_when_attached_and_shared() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let position = TestPosition { id: object::new(scenario.ctx()) };
    let pool_uid = object::new(scenario.ctx());
    let pool_id = pool_uid.to_inner();
    pool_uid.delete();
    let mut pending_vault = vault::prepare<MEME, QUOTE>(
        balance::zero(),
        balance::zero(),
        scenario.ctx(),
    );
    let pending_id = object::id(&pending_vault);
    pending_vault.attach(&TestVenue(), pool_id, position);
    pending_vault.share<_, _, TestVenue>(&TestVenue());

    scenario.next_tx(PUBLISHER);
    let shared = scenario.take_shared<LpVault<MEME, QUOTE>>();
    assert_eq!(object::id(&shared), pending_id);
    assert_eq!(shared.pool_id(), pool_id);
    test_scenario::return_shared(shared);
    scenario.end();
}

#[test]
fun protocol_claim_pays_both_residuals_once_and_emits_the_exact_claim() {
    let mut fixture = start_with_residuals(3, 4);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let (meme, quote) =
            f.vault.claim_protocol_fees(
                &f.migrators_version,
                &admin_witness,
                f.ctx!(),
            );

        assert_eq!(meme.value(), 3);
        assert_eq!(quote.value(), 4);
        assert_eq!(f.vault.protocol_meme_residual(), 0);
        assert_eq!(f.vault.protocol_quote_residual(), 0);

        let events = sui::event::events_by_type<blast_events::ProtocolFeesClaimed>();
        let mut expected = bcs::to_bytes(&object::id(&f.vault));
        expected.append(bcs::to_bytes(&type_name::with_original_ids<MEME>()));
        expected.append(bcs::to_bytes(&type_name::with_original_ids<QUOTE>()));
        let claimant = PROTOCOL_ADMIN;
        expected.append(bcs::to_bytes(&claimant));
        expected.append(bcs::to_bytes(&3u64));
        expected.append(bcs::to_bytes(&4u64));
        assert_eq!(events.length(), 1);
        assert_eq!(bcs::to_bytes(&events[0]), expected);

        destroy(meme);
        destroy(quote);
    });

    fixture.end();
}

#[test]
fun protocol_claim_pays_a_one_sided_residual() {
    let mut fixture = start_with_residuals(5, 0);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let (meme, quote) =
            f.vault.claim_protocol_fees(
                &f.migrators_version,
                &admin_witness,
                f.ctx!(),
            );

        assert_eq!(meme.value(), 5);
        assert_eq!(quote.value(), 0);

        destroy(meme);
        destroy(quote);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = vault::ENothingClaimable,
    location = blast_fun_migrators::vault,
)]
fun protocol_claim_rejects_a_vault_without_residuals() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let (meme, quote) =
            f.vault.claim_protocol_fees(
                &f.migrators_version,
                &admin_witness,
                f.ctx!(),
            );

        destroy(meme);
        destroy(quote);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = vault::ENothingClaimable,
    location = blast_fun_migrators::vault,
)]
fun drained_residuals_cannot_be_claimed_again() {
    let mut fixture = start_with_residuals(3, 4);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let (meme, quote) =
            f.vault.claim_protocol_fees(
                &f.migrators_version,
                &admin_witness,
                f.ctx!(),
            );
        destroy(meme);
        destroy(quote);

        let (meme, quote) =
            f.vault.claim_protocol_fees(
                &f.migrators_version,
                &admin_witness,
                f.ctx!(),
            );

        destroy(meme);
        destroy(quote);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun a_stale_generation_rejects_the_protocol_claim_before_the_residual_check() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.migrators_version.set_for_testing(2);
        let (meme, quote) =
            f.vault.claim_protocol_fees(
                &f.migrators_version,
                &admin_witness,
                f.ctx!(),
            );

        destroy(meme);
        destroy(quote);
    });

    fixture.end();
}

#[test]
fun borrow_returns_the_attached_position() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let venue = TestVenue();
        let position = f.vault.position_mut<
            MEME,
            QUOTE,
            TestVenue,
            TestPosition,
        >(&venue);

        assert_eq!(object::id(position), f.position_id);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = vault::EWrongVenue,
    location = blast_fun_migrators::vault,
)]
fun wrong_venue_borrow_fails_closed() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let venue = OtherVenue();

        f.vault.position_mut<MEME, QUOTE, OtherVenue, TestPosition>(
            &venue,
        );
    });

    fixture.end();
}

// === Test Helpers ===

macro fun next_tx(
    $fixture: &mut VaultFixture,
    $sender: address,
    $fn: |&mut VaultFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun ctx($fixture: &mut VaultFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun start(): VaultFixture {
    start_with_residuals(0, 0)
}

fun start_with_residuals(
    protocol_meme_residual: u64,
    protocol_quote_residual: u64,
): VaultFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let migrators_version = migrators_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = acl::new_for_testing<BLAST_FUN_DOMAIN>(
        MAX_ADMINS,
        ROOT_TRANSFER_DELAY_MS,
        scenario.ctx(),
    );
    authority.grant_admin(&super_admin_cap, 0, PROTOCOL_ADMIN, scenario.ctx());
    destroy(super_admin_cap);
    let position = TestPosition { id: object::new(scenario.ctx()) };
    let position_id = object::id(&position);
    let pool_uid = object::new(scenario.ctx());
    let pool_id = pool_uid.to_inner();
    pool_uid.delete();
    let mut vault = vault::prepare<MEME, QUOTE>(
        balance::create_for_testing<MEME>(protocol_meme_residual),
        balance::create_for_testing<QUOTE>(protocol_quote_residual),
        scenario.ctx(),
    );
    vault.attach(&TestVenue(), pool_id, position);
    vault.share<_, _, TestVenue>(&TestVenue());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    let vault = scenario.take_shared<LpVault<MEME, QUOTE>>();

    VaultFixture {
        scenario,
        authority,
        admin_cap,
        migrators_version,
        vault,
        position_id,
    }
}

fun sign_in(self: &VaultFixture): AdminWitness<BLAST_FUN_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun end(self: VaultFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap, AdminWitness};

use blast_fun::blast_fun_domain::BLAST_FUN_DOMAIN;

use blast_fun_migrators::{
    blast_events,
    package_version::{Self as migrators_version, PackageVersion as MigratorsVersion},
    vault::{Self, LpVault},
};

use std::{bcs, type_name, unit_test::{assert_eq, destroy}};

use sui::{balance, test_scenario::{Self, Scenario}};
