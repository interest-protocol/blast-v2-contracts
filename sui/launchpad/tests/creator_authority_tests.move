// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Creator recipients and the claim they authorize. Address claims through a launch are covered in
/// `launch_tests`; this suite proves the Blast account attestation.
module blast_fun::creator_authority_tests;

// === Constants ===

const ADMIN: address = @0xAD;

const CREATOR: address = @0xC0FFEE;

const NOW_MS: u64 = 1_000_000;

const EXPIRY_MS: u64 = 2_000_000;

// === Test-Only Types ===

public struct TEST_MEME() has drop;

public struct OTHER_MEME() has drop;

/// A runtime configuration whose signer is live, the ACL that rotates it, and a clock at `NOW_MS`.
public struct ClaimFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    config: RuntimeConfig,
    clock: Clock,
}

// === Tests ===

// --- Recipients ---

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorRecipient, location = blast_fun::creator_authority)]
fun address_recipient_rejects_the_zero_address() {
    creator_authority::new_address(@0x0);
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidAccountCommitment, location = blast_fun::creator_authority)]
fun account_recipient_rejects_a_commitment_that_is_not_32_bytes() {
    creator_authority::new_account(x"1122");
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimAttestation, location = blast_fun::creator_authority)]
fun address_claim_rejects_an_attestation() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(creator_authority::new_address(CREATOR), option::some(attestation()));
    });

    fixture.end();
}

// --- Account claims ---

#[test]
/// The backend signs the BCS claim message binding the Meme type, the account, the claimant, and
/// the expiry; the claimant presents it and receives both caps.
fun account_claim_with_the_backend_signature_issues_both_caps() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        assert_eq!(
            creator_authority::creator_claim_message_bytes_for_testing<TEST_MEME>(
                account_commitment(),
                CREATOR,
                EXPIRY_MS,
            ),
            x"64303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303a3a63726561746f725f617574686f726974795f74657374733a3a544553545f4d454d452011223344556677889900aabbccddeeffffeeddccbbaa009988776655443322110000000000000000000000000000000000000000000000000000000000c0ffee80841e0000000000",
        );

        let (curve_fee_cap, metadata_cap) = creator_authority::claim_creator_caps<TEST_MEME>(
            account_recipient(),
            f.config.creator_claim_signer(),
            option::some(attestation()),
            &f.clock,
            f.ctx!(),
        );

        assert!(object::id(&curve_fee_cap) != object::id(&metadata_cap));
        curve_fee_cap.destroy_curve_fee_cap();
        metadata_cap.destroy_metadata_cap();
    });

    fixture.end();
}

#[test]
fun account_claim_is_accepted_at_the_expiry() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.clock.set_for_testing(EXPIRY_MS);

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun account_claim_requires_an_attestation() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::none());
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
fun account_claim_rejects_a_signature_that_is_not_64_bytes() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let mut signature = signature();
        signature.pop_back();
        let attestation = creator_authority::new_creator_claim_attestation_for_testing(
            EXPIRY_MS,
            signature,
        );

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimAttestation, location = blast_fun::creator_authority)]
fun account_claim_rejects_trailing_attestation_bytes() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let mut attestation = attestation();
        attestation.push_back(0);

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECreatorClaimExpired, location = blast_fun::creator_authority)]
fun account_claim_rejects_an_expired_attestation() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.clock.set_for_testing(EXPIRY_MS + 1);

        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
fun account_claim_rejects_a_signature_for_another_claimant() {
    let mut fixture = start();

    fixture.next_tx!(@0xBAD, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
fun account_claim_rejects_a_signature_for_another_meme() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        f.claim<OTHER_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
fun account_claim_rejects_a_signature_for_another_account() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let other_account = creator_authority::new_account(
            x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        );

        f.claim<TEST_MEME>(other_account, option::some(attestation()));
    });

    fixture.end();
}

// --- Signer rotation ---

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
fun account_claim_rejects_an_attestation_from_a_rotated_signer() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        f.set_creator_claim_signer(
            x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        );
    });

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorClaimSignature, location = blast_fun::creator_authority)]
/// An empty signer key revokes account claims: even a correctly signed attestation fails.
fun account_claim_rejects_every_attestation_once_the_signer_is_revoked() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        f.set_creator_claim_signer(vector[]);
    });

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

#[test]
fun restoring_the_signer_reenables_account_claims() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        f.set_creator_claim_signer(vector[]);
        f.set_creator_claim_signer(signer_public_key());
    });

    fixture.next_tx!(CREATOR, |f| {
        f.claim<TEST_MEME>(account_recipient(), option::some(attestation()));
    });

    fixture.end();
}

// === Test Helpers ===

macro fun claim_next_tx(
    $fixture: &mut ClaimFixture,
    $sender: address,
    $fn: |&mut ClaimFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun claim_ctx($fixture: &mut ClaimFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun start(): ClaimFixture {
    let mut scenario = test_scenario::begin(ADMIN);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        blast_fun_domain::claim_signer_admin_role(),
        ADMIN,
        scenario.ctx(),
    );
    destroy(super_admin_cap);
    let config = runtime_config::new_for_testing(signer_public_key(), scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(NOW_MS);

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();

    ClaimFixture { scenario, package_version, authority, admin_cap, config, clock }
}

/// Claims as the current sender with the live signer key and discards both caps.
fun claim_claim<Meme>(
    self: &mut ClaimFixture,
    recipient: CreatorRecipient,
    attestation: Option<vector<u8>>,
) {
    let (curve_fee_cap, metadata_cap) = creator_authority::claim_creator_caps<Meme>(
        recipient,
        self.config.creator_claim_signer(),
        attestation,
        &self.clock,
        self.scenario.ctx(),
    );

    curve_fee_cap.destroy_curve_fee_cap();
    metadata_cap.destroy_metadata_cap();
}

fun claim_set_creator_claim_signer(self: &mut ClaimFixture, signer_public_key: vector<u8>) {
    let admin_witness = self.authority.sign_in(&self.admin_cap);

    self.config.set_creator_claim_signer(&self.package_version, &admin_witness, signer_public_key);
}

fun claim_end(self: ClaimFixture) {
    destroy(self);
}

fun account_recipient(): CreatorRecipient {
    creator_authority::new_account(account_commitment())
}

/// The backend's attestation for `CREATOR` claiming `TEST_MEME` for `account_commitment()`.
fun attestation(): vector<u8> {
    creator_authority::new_creator_claim_attestation_for_testing(EXPIRY_MS, signature())
}

fun account_commitment(): vector<u8> {
    x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211"
}

fun signer_public_key(): vector<u8> {
    x"0ca5b32f943a1d9f119adc9b45615a06bbf0ab9f46ccbcc62d167d7d5e55ce47"
}

fun signature(): vector<u8> {
    x"9ad5e8a47856b8080b3105c805c3555bcfbdf28889ffe3fc54bc54700ff308e495e6dd1b014c9e2316bc98f0ec55c08293065ccee444aa96b1f5e107004a9a02"
}

// === Imports ===

use blast_admin::acl::{Authority, AdminCap};

use blast_fun::{
    blast_fun_domain::{Self, BLAST_FUN_DOMAIN},
    creator_authority::{Self, CreatorRecipient},
    domain_fixture,
    package_version::{Self, PackageVersion},
    runtime_config::{Self, RuntimeConfig},
};

use std::unit_test::{assert_eq, destroy};

use sui::{clock::{Self, Clock}, test_scenario::{Self, Scenario}};

use fun claim_claim as ClaimFixture.claim;

use fun claim_ctx as ClaimFixture.ctx;

use fun claim_end as ClaimFixture.end;

use fun claim_next_tx as ClaimFixture.next_tx;

use fun claim_set_creator_claim_signer as ClaimFixture.set_creator_claim_signer;
