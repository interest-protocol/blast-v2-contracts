// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the creator authority's abort location.
#[allow(lint(abort_without_constant))]
/// Creator recipients, the one-time claim they authorize, and the revocable caps it issues.
module blast_fun::creator_authority;

// === Public Types ===

/// Who may claim a launch's creator caps: an address, or a Blast account the backend attests.
public enum CreatorRecipient has copy, drop, store {
    Address(address),
    Account(vector<u8>),
}

/// Authority over one launch's curve creator fees; the launch honors only the cap ID it records.
public struct CurveFeeCap<phantom Meme> has key, store {
    id: UID,
}

/// Authority over one coin's metadata; the launch honors only the cap ID it records.
public struct BlastMetadataCap<phantom Meme> has key, store {
    id: UID,
}

/// The BCS message the Blast backend signs for an account claim.
public struct CreatorClaimMessage has copy, drop {
    meme: TypeName,
    account_commitment: vector<u8>,
    claimant: address,
    expiry_ms: u64,
}

// === Public Functions ===

public fun new_address(recipient: address): CreatorRecipient {
    assert!(recipient != @0x0, blast_fun::errors::invalid_creator_recipient!());

    CreatorRecipient::Address(recipient)
}

public fun new_account(account_commitment: vector<u8>): CreatorRecipient {
    assert!(
        account_commitment.length() == constants::account_commitment_length!(),
        blast_fun::errors::invalid_account_commitment!(),
    );

    CreatorRecipient::Account(account_commitment)
}

/// Deletes a curve-fee cap. Deleting the live cap leaves curve fees unclaimable until an
/// administrator reassigns the cap.
public fun destroy_curve_fee_cap<Meme>(self: CurveFeeCap<Meme>) {
    let CurveFeeCap { id } = self;

    id.delete();
}

/// Deletes a metadata cap. Deleting the live cap freezes the metadata until an administrator
/// reassigns the cap.
public fun destroy_metadata_cap<Meme>(self: BlastMetadataCap<Meme>) {
    let BlastMetadataCap { id } = self;

    id.delete();
}

// === Package Functions ===

/// Authenticates the sender as `recipient` and issues both creator caps.
///
/// An account claim carries `attestation`, the BCS `(expiry_ms, signature)` the backend signed
/// over `CreatorClaimMessage` with `signer_public_key`; an address claim carries none.
public(package) fun claim_creator_caps<Meme>(
    recipient: CreatorRecipient,
    signer_public_key: &vector<u8>,
    attestation: Option<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
): (CurveFeeCap<Meme>, BlastMetadataCap<Meme>) {
    let claimant = ctx.sender();
    match (recipient) {
        CreatorRecipient::Address(recipient) => {
            assert!(attestation.is_none(), blast_fun::errors::invalid_creator_claim_attestation!());
            assert!(claimant == recipient, blast_fun::errors::creator_not_sender!());
        },
        CreatorRecipient::Account(account_commitment) => {
            assert!(attestation.is_some(), blast_fun::errors::invalid_creator_claim_attestation!());
            let mut attestation = bcs::new(attestation.destroy_some());
            let expiry_ms = attestation.peel_u64();
            let signature = attestation.peel_vec_u8();
            assert!(
                signature.length() == constants::ed25519_signature_length!()
                    && attestation.into_remainder_bytes().is_empty(),
                blast_fun::errors::invalid_creator_claim_attestation!(),
            );
            assert!(clock.timestamp_ms() <= expiry_ms, blast_fun::errors::creator_claim_expired!());
            assert!(
                ed25519::ed25519_verify(
                    &signature,
                    signer_public_key,
                    &creator_claim_message_bytes<Meme>(account_commitment, claimant, expiry_ms),
                ),
                blast_fun::errors::invalid_creator_claim_signature!(),
            );
        },
    };

    (new_curve_fee_cap<Meme>(ctx), new_metadata_cap<Meme>(ctx))
}

public(package) fun new_curve_fee_cap<Meme>(ctx: &mut TxContext): CurveFeeCap<Meme> {
    CurveFeeCap { id: object::new(ctx) }
}

public(package) fun new_metadata_cap<Meme>(ctx: &mut TxContext): BlastMetadataCap<Meme> {
    BlastMetadataCap { id: object::new(ctx) }
}

// === Private Functions ===

fun creator_claim_message_bytes<Meme>(
    account_commitment: vector<u8>,
    claimant: address,
    expiry_ms: u64,
): vector<u8> {
    std::bcs::to_bytes(&CreatorClaimMessage {
        meme: type_name::with_original_ids<Meme>(),
        account_commitment,
        claimant,
        expiry_ms,
    })
}

// === Test-Only Functions ===

#[test_only]
public fun creator_claim_message_bytes_for_testing<Meme>(
    account_commitment: vector<u8>,
    claimant: address,
    expiry_ms: u64,
): vector<u8> {
    creator_claim_message_bytes<Meme>(account_commitment, claimant, expiry_ms)
}

#[test_only]
public fun new_creator_claim_attestation_for_testing(
    expiry_ms: u64,
    signature: vector<u8>,
): vector<u8> {
    let mut attestation = std::bcs::to_bytes(&expiry_ms);
    attestation.append(std::bcs::to_bytes(&signature));

    attestation
}

// === Imports ===

use blast_fun::constants;

use std::type_name::{Self, TypeName};

use sui::{bcs, clock::Clock, ed25519};
