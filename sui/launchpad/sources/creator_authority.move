// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one append-only registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
/// Creator recipients, the one-time claim they authorize, and the revocable caps it issues.
module blast_fun::creator_authority;

use blast_fun::{constants, events, runtime_config::RuntimeConfig};
use std::{bcs, type_name::{Self, TypeName}};
use sui::clock::Clock;

// === Public Types ===

/// Validated recipient selecting who may claim the creator capability.
public enum CreatorRecipient has drop, store {
    Address(address),
    Account(vector<u8>),
}

/// Protected one-time, coin-typed creator claim authorization stored until consumed.
public struct CreatorAuthority<phantom Meme> has store {
    recipient: CreatorRecipient,
}

/// Revocable authority over one launch's bonding-curve creator fees.
///
/// A cap authorizes nothing by itself: `Launch` honors only the cap ID it records, a creator
/// administrator's reassignment retires it, and locking destroys it for a permanent custodian.
public struct CurveFeeCap<phantom Meme> has key, store {
    id: UID,
}

/// Revocable authority to update one coin's metadata through its launch.
///
/// Independent of fee authority: `Launch` honors only the metadata cap ID it records.
public struct BlastMetadataCap<phantom Meme> has key, store {
    id: UID,
}

/// Canonical BCS message signed after a login resolves to the designated Blast account.
public struct CreatorClaimMessage has copy, drop {
    meme: TypeName,
    account_commitment: vector<u8>,
    claimant: address,
    expiry_ms: u64,
}

// === Public Functions ===

/// Designates a concrete wallet or SuiNS-resolved address as creator recipient.
public fun new_address(recipient: address): CreatorRecipient {
    assert!(recipient != @0x0, blast_fun::errors::invalid_creator_recipient!());

    CreatorRecipient::Address(recipient)
}

/// Designates an immutable Blast account commitment as creator recipient.
public fun new_account(account_commitment: vector<u8>): CreatorRecipient {
    assert!(
        account_commitment.length() == constants::account_commitment_length!(),
        blast_fun::errors::invalid_account_commitment!(),
    );

    CreatorRecipient::Account(account_commitment)
}

/// Deletes a curve-fee capability; destroying the live cap forfeits it until reassignment.
public fun destroy_curve_fee_cap<Meme>(self: CurveFeeCap<Meme>) {
    let CurveFeeCap { id } = self;

    id.delete();
}

/// Deletes a metadata capability; destroying the live cap forfeits it until reassignment.
public fun destroy_metadata_cap<Meme>(self: BlastMetadataCap<Meme>) {
    let BlastMetadataCap { id } = self;

    id.delete();
}

// === Package Functions ===

/// Converts validated caller input into one linear, coin-typed claim authorization.
public(package) fun into_authority<Meme>(
    self: CreatorRecipient,
): CreatorAuthority<Meme> {
    CreatorAuthority {
        recipient: self,
    }
}

/// Returns the designated address, if this is the address variant.
public(package) fun recipient_address(self: &CreatorRecipient): Option<address> {
    match (self) {
        CreatorRecipient::Address(recipient) => option::some(*recipient),
        CreatorRecipient::Account(_) => option::none(),
    }
}

/// Returns the designated account commitment, if this is the account variant.
public(package) fun account_commitment(
    self: &CreatorRecipient,
): Option<vector<u8>> {
    match (self) {
        CreatorRecipient::Address(_) => option::none(),
        CreatorRecipient::Account(account_commitment) => option::some(*account_commitment),
    }
}

/// Consumes the launch's creator authority and returns its fee and metadata capabilities.
public(package) fun claim_creator_caps<Meme>(
    self: CreatorAuthority<Meme>,
    config: &RuntimeConfig,
    account_attestation: Option<vector<u8>>,
    clock: &Clock,
    ctx: &mut TxContext,
): (CurveFeeCap<Meme>, BlastMetadataCap<Meme>) {
    let claimant = ctx.sender();
    self.recipient.authorize_claim<Meme>(
        config,
        account_attestation,
        claimant,
        clock,
    );

    let CreatorAuthority { .. } = self;
    let curve_fee_cap = new_curve_fee_cap<Meme>(ctx);
    let metadata_cap = new_metadata_cap<Meme>(ctx);

    events::creator_caps_claimed<Meme>(object::id(&curve_fee_cap), object::id(&metadata_cap));

    (curve_fee_cap, metadata_cap)
}

/// Creates a curve-fee capability that the calling launch must record as live.
public(package) fun new_curve_fee_cap<Meme>(ctx: &mut TxContext): CurveFeeCap<Meme> {
    CurveFeeCap { id: object::new(ctx) }
}

/// Creates a metadata capability that the calling launch must record as live.
public(package) fun new_metadata_cap<Meme>(ctx: &mut TxContext): BlastMetadataCap<Meme> {
    BlastMetadataCap { id: object::new(ctx) }
}

/// Discards pending creator authority during an administrative reassignment.
public(package) fun revoke<Meme>(self: CreatorAuthority<Meme>) {
    let CreatorAuthority { .. } = self;
}

// === Private Functions ===

fun authorize_claim<Meme>(
    self: &CreatorRecipient,
    config: &RuntimeConfig,
    account_attestation: Option<vector<u8>>,
    claimant: address,
    clock: &Clock,
) {
    match (self) {
        CreatorRecipient::Address(recipient) => {
            assert!(
                account_attestation.is_none(),
                blast_fun::errors::unexpected_creator_claim_attestation!(),
            );
            assert!(claimant == *recipient, blast_fun::errors::creator_not_sender!());

            account_attestation.destroy_none();
        },
        CreatorRecipient::Account(account_commitment) => {
            assert!(
                account_attestation.is_some(),
                blast_fun::errors::missing_creator_claim_attestation!(),
            );
            config.assert_creator_claim_active();

            let (expiry_ms, signature) = parse_creator_claim_attestation(
                account_attestation.destroy_some(),
            );

            assert!(
                clock.timestamp_ms() <= expiry_ms,
                blast_fun::errors::creator_claim_expired!(),
            );

            let message = creator_claim_message_bytes<Meme>(
                *account_commitment,
                claimant,
                expiry_ms,
            );
            config.assert_creator_claim_signature(&message, &signature);
        },
    }
}

/// Produces the exact BCS bytes that the account-authentication backend must sign.
fun creator_claim_message_bytes<Meme>(
    account_commitment: vector<u8>,
    claimant: address,
    expiry_ms: u64,
): vector<u8> {
    bcs::to_bytes(&CreatorClaimMessage {
        meme: type_name::with_original_ids<Meme>(),
        account_commitment,
        claimant,
        expiry_ms,
    })
}

/// Parses canonical BCS `(expiry_ms: u64, signature: vector<u8>)` call data.
fun parse_creator_claim_attestation(attestation: vector<u8>): (u64, vector<u8>) {
    assert!(
        attestation.length() == constants::creator_claim_attestation_length!()
            && attestation[constants::creator_claim_expiry_bcs_length!()]
                == constants::ed25519_signature_length!(),
        blast_fun::errors::invalid_creator_claim_attestation!(),
    );

    let mut expiry_ms = 0u64;
    let mut index = constants::creator_claim_expiry_bcs_length!();
    while (index > 0) {
        index = index - 1;
        expiry_ms = (expiry_ms << 8) | (attestation[index] as u64);
    };

    (expiry_ms, attestation.skip(constants::creator_claim_signature_offset!()))
}

// === Test-Only Functions ===

#[test_only]
/// Produces canonical claim bytes for the independent signature fixture test.
public fun creator_claim_message_bytes_for_testing<Meme>(
    account_commitment: vector<u8>,
    claimant: address,
    expiry_ms: u64,
): vector<u8> {
    creator_claim_message_bytes<Meme>(account_commitment, claimant, expiry_ms)
}

#[test_only]
/// Constructs account-claim call data without adding a production constructor to the interface.
public fun new_creator_claim_attestation_for_testing(
    expiry_ms: u64,
    signature: vector<u8>,
): vector<u8> {
    let mut attestation = bcs::to_bytes(&expiry_ms);

    attestation.push_back(constants::ed25519_signature_length!());
    attestation.append(signature);

    attestation
}
