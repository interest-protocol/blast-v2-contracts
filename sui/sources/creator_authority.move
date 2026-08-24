// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations and the stable code map documented in `docs/error-codes.md`.
#[allow(lint(abort_without_constant))]
module blast_fun::creator_authority;

use blast_fun::{constants, events, x_claim_config::XClaimConfig};
use std::{bcs, type_name::{Self, TypeName}};
use sui::{clock::Clock, coin_registry::MetadataCap};

// === Public Types ===

/// One-time creator claim authorization stored by a launch until consumed.
public struct CreatorAuthority<phantom Meme> has store {
    identity: CreatorIdentity,
}

/// Authority over creator-controlled settings and accrued fees for one coin type.
public struct CreatorCap<phantom Meme> has key, store {
    id: UID,
}

/// The launch-time rule for who may claim the creator capability.
public enum CreatorIdentity has drop, store {
    Address(address),
    X(vector<u8>),
}

/// Canonical BCS message signed by the Blast backend after authenticated X verification.
public struct XClaimMessage has copy, drop {
    meme: TypeName,
    x_identity_hash: vector<u8>,
    claimant: address,
    expiry_ms: u64,
}

// === Package Functions ===

/// Records a concrete wallet or SuiNS-resolved address as the one permitted claimant.
public(package) fun new_address<Meme>(
    creator: address,
): CreatorAuthority<Meme> {
    assert!(creator != @0x0, blast_fun::errors::invalid_creator!());

    CreatorAuthority<Meme> {
        identity: CreatorIdentity::Address(creator),
    }
}

/// Records an immutable stable X user-id commitment as the only permitted claim identity.
public(package) fun new_x<Meme>(
    x_identity_hash: vector<u8>,
): CreatorAuthority<Meme> {
    assert!(
        x_identity_hash.length() == constants::x_identity_hash_length!(),
        blast_fun::errors::invalid_x_identity_hash!(),
    );

    CreatorAuthority<Meme> {
        identity: CreatorIdentity::X(x_identity_hash),
    }
}

/// Consumes the launch's creator authority and returns its two independent capabilities.
public(package) fun claim_creator_cap<Meme>(
    authority: CreatorAuthority<Meme>,
    metadata_cap: MetadataCap<Meme>,
    config: &XClaimConfig,
    x_attestation: Option<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
): (CreatorCap<Meme>, MetadataCap<Meme>) {
    let claimant = ctx.sender();

    let (x_identity_hash, x_claim_expiry_ms) = match (&authority.identity) {
        CreatorIdentity::Address(creator) => {
            assert!(
                x_attestation.is_none(),
                blast_fun::errors::unexpected_x_claim_attestation!(),
            );
            assert!(claimant == *creator, blast_fun::errors::creator_not_sender!());

            x_attestation.destroy_none();
            (option::none(), option::none())
        },
        CreatorIdentity::X(identity_hash) => {
            assert!(
                x_attestation.is_some(),
                blast_fun::errors::missing_x_claim_attestation!(),
            );
            config.assert_active();

            let (expiry_ms, signature) = parse_x_claim_attestation(
                x_attestation.destroy_some(),
            );

            assert!(
                clock.timestamp_ms() <= expiry_ms,
                blast_fun::errors::x_claim_expired!(),
            );

            let message = x_claim_message_bytes<Meme>(
                *identity_hash,
                claimant,
                expiry_ms,
            );
            config.verify_signature(&message, &signature);
            (option::some(*identity_hash), option::some(expiry_ms))
        },
    };

    let CreatorAuthority { .. } = authority;
    let creator_cap = CreatorCap<Meme> { id: object::new(ctx) };

    events::creator_cap_claimed<Meme>(
        claimant,
        x_identity_hash,
        x_claim_expiry_ms,
    );

    (creator_cap, metadata_cap)
}

// === Private Functions ===

/// Produces the exact BCS bytes that the X authentication backend must sign.
fun x_claim_message_bytes<Meme>(
    x_identity_hash: vector<u8>,
    claimant: address,
    expiry_ms: u64,
): vector<u8> {
    XClaimMessage {
        meme: type_name::with_original_ids<Meme>(),
        x_identity_hash,
        claimant,
        expiry_ms,
    }.to_bytes()
}

fun to_bytes(message: &XClaimMessage): vector<u8> {
    bcs::to_bytes(message)
}

/// Parses canonical BCS `(expiry_ms: u64, signature: vector<u8>)` call data.
fun parse_x_claim_attestation(attestation: vector<u8>): (u64, vector<u8>) {
    assert!(
        attestation.length() == constants::x_claim_attestation_length!()
            && attestation[constants::x_claim_expiry_bcs_length!()]
                == constants::ed25519_signature_length!(),
        blast_fun::errors::invalid_x_claim_attestation!(),
    );

    let mut expiry_ms = 0u64;
    let mut index = constants::x_claim_expiry_bcs_length!();
    while (index > 0) {
        index = index - 1;
        expiry_ms = (expiry_ms << 8) | (attestation[index] as u64);
    };

    (expiry_ms, attestation.skip(constants::x_claim_signature_offset!()))
}

// === Test-Only Functions ===

#[test_only]
/// Produces canonical claim bytes for the independent signature fixture test.
public fun x_claim_attestation_bytes_for_testing<Meme>(
    x_identity_hash: vector<u8>,
    claimant: address,
    expiry_ms: u64,
): vector<u8> {
    x_claim_message_bytes<Meme>(x_identity_hash, claimant, expiry_ms)
}

#[test_only]
/// Constructs X-only call data without adding a production constructor to the interface.
public fun new_x_claim_attestation_for_testing(
    expiry_ms: u64,
    signature: vector<u8>,
): vector<u8> {
    let mut attestation = bcs::to_bytes(&expiry_ms);

    attestation.push_back(constants::ed25519_signature_length!());
    attestation.append(signature);

    attestation
}

#[test_only]
/// Destroys standalone creator authority state after a test.
public fun destroy_for_testing<Meme>(authority: CreatorAuthority<Meme>) {
    let CreatorAuthority { .. } = authority;
}

#[test_only]
/// Deletes a creator capability after a test has inspected it.
public fun destroy_cap_for_testing<Meme>(cap: CreatorCap<Meme>) {
    let CreatorCap { id } = cap;

    id.delete();
}
