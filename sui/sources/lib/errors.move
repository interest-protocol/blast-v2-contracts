#[allow(unused_const)]
module blast_fun::errors;

// === Constants ===

// Append-only package error registry. Never reuse a retired numeric code.
// These names exist only in test builds and source tooling; production callers use the
// package macros below so the numeric code is inlined at the owning assertion.

#[test_only]
/// The supplied AdminCap is not active in the singleton protocol authority.
const EInvalidAdminCap: u64 = 0;

// Code 1 retired: mutable chain-id validation was removed by ADR 0015.

#[test_only]
/// The X claim signer public key is not 32 bytes.
const EInvalidXClaimPublicKey: u64 = 2;

#[test_only]
/// X claims are disabled because no signer public key is configured.
const EXClaimSignerInactive: u64 = 3;

// Codes 4 and 5 retired with first-config and signer-generation state.

#[test_only]
/// The Ed25519 signature does not verify against the canonical claim bytes.
const EInvalidXClaimSignature: u64 = 6;

// Codes 7 and 8 retired with first-config and signer-generation state.

#[test_only]
/// An address creator identity cannot target the zero address.
const EInvalidCreator: u64 = 9;

#[test_only]
/// An X identity commitment must be exactly 32 bytes.
const EInvalidXIdentityHash: u64 = 10;

#[test_only]
/// An address creator claim included an X attestation.
const EUnexpectedXClaimAttestation: u64 = 11;

// Code 12 retired: consuming CreatorAuthority makes a repeat claim unrepresentable.

// Code 13 retired: the X claimant is now always TxContext::sender.

#[test_only]
/// The X claim attestation has expired.
const EXClaimExpired: u64 = 14;

#[test_only]
/// The supplied SuperAdminCap is no longer the active root capability.
const EInvalidSuperAdminCap: u64 = 15;

#[test_only]
/// A routine administrator cannot be delivered to the zero address.
const EInvalidAdminRecipient: u64 = 16;

#[test_only]
/// The bounded active-admin registry is full.
const EAdminCapacityReached: u64 = 17;

#[test_only]
/// A root transfer must target a nonzero address other than the current sender.
const EInvalidSuperAdminRecipient: u64 = 18;

#[test_only]
/// No pending super-admin transfer exists.
const ENoPendingSuperAdminTransfer: u64 = 19;

#[test_only]
/// The transaction sender is not the proposed super-admin recipient.
const ENotPendingSuperAdminRecipient: u64 = 20;

#[test_only]
/// The root transfer's seven-day delay has not elapsed.
const ESuperAdminTransferNotReady: u64 = 21;

#[test_only]
/// The root-transfer ready timestamp would overflow u64.
const ESuperAdminTransferTimeOverflow: u64 = 22;

#[test_only]
/// The currently active root capability cannot be destroyed.
const ESuperAdminCapStillActive: u64 = 23;

#[test_only]
/// Signer rotation must provide a key different from the current key.
const EXClaimSignerUnchanged: u64 = 24;

#[test_only]
/// An X creator claim did not include its required attestation.
const EMissingXClaimAttestation: u64 = 25;

#[test_only]
/// The transaction sender is not the address creator recorded by the launch.
const ECreatorNotSender: u64 = 26;

#[test_only]
/// X claim call data is not canonical BCS `(u64, vector<u8>)` for a 64-byte signature.
const EInvalidXClaimAttestation: u64 = 27;

#[test_only]
/// A root-transfer proposal targeted the already pending recipient.
const ESuperAdminTransferUnchanged: u64 = 28;

#[test_only]
/// Meme inventory or virtual quote reserve cannot represent a valid constant-product market.
const EInvalidCurveReserve: u64 = 29;

#[test_only]
/// The real-quote terminal threshold must be nonzero.
const EInvalidTerminalThreshold: u64 = 30;

#[test_only]
/// The quote-asset fee exceeds one hundred percent.
const EInvalidQuoteFeeBps: u64 = 31;

#[test_only]
/// The sell-side maximum burn exceeds one hundred percent.
const EInvalidMaxBurnBps: u64 = 32;

#[test_only]
/// A curve quote requires a nonzero trade input.
const EZeroTradeInput: u64 = 33;

#[test_only]
/// Rounding or fees reduced the user's quoted output to zero.
const EZeroTradeOutput: u64 = 34;

#[test_only]
/// A post-trade curve reserve cannot be represented as u64.
const ECurveReserveOverflow: u64 = 35;

#[test_only]
/// A sell quote requested more real quote than the curve holds.
const ESellBackInvariantViolated: u64 = 36;

#[test_only]
/// The meme-asset fee exceeds one hundred percent.
const EInvalidMemeFeeBps: u64 = 37;

#[test_only]
/// Neither asset has an accrued balance for the presented claim authority.
const ENothingAccrued: u64 = 38;

#[test_only]
/// A fee accrual cannot contain zero meme and zero quote simultaneously.
const EZeroFeeAccrual: u64 = 39;

#[test_only]
/// The global protocol share exceeds one hundred percent.
const EInvalidProtocolFeeShareBps: u64 = 40;

#[test_only]
/// A protocol-share update supplied the currently active value.
const EProtocolFeeShareUnchanged: u64 = 41;

// === Package Error Codes ===

macro public(package) fun invalid_admin_cap(): u64 {
    0
}

macro public(package) fun invalid_x_claim_public_key(): u64 {
    2
}

macro public(package) fun x_claim_signer_inactive(): u64 {
    3
}

macro public(package) fun invalid_x_claim_signature(): u64 {
    6
}

macro public(package) fun invalid_creator(): u64 {
    9
}

macro public(package) fun invalid_x_identity_hash(): u64 {
    10
}

macro public(package) fun unexpected_x_claim_attestation(): u64 {
    11
}

macro public(package) fun x_claim_expired(): u64 {
    14
}

macro public(package) fun invalid_super_admin_cap(): u64 {
    15
}

macro public(package) fun invalid_admin_recipient(): u64 {
    16
}

macro public(package) fun admin_capacity_reached(): u64 {
    17
}

macro public(package) fun invalid_super_admin_recipient(): u64 {
    18
}

macro public(package) fun no_pending_super_admin_transfer(): u64 {
    19
}

macro public(package) fun not_pending_super_admin_recipient(): u64 {
    20
}

macro public(package) fun super_admin_transfer_not_ready(): u64 {
    21
}

macro public(package) fun super_admin_transfer_time_overflow(): u64 {
    22
}

macro public(package) fun super_admin_cap_still_active(): u64 {
    23
}

macro public(package) fun x_claim_signer_unchanged(): u64 {
    24
}

macro public(package) fun missing_x_claim_attestation(): u64 {
    25
}

macro public(package) fun creator_not_sender(): u64 {
    26
}

macro public(package) fun invalid_x_claim_attestation(): u64 {
    27
}

macro public(package) fun super_admin_transfer_unchanged(): u64 {
    28
}

macro public(package) fun invalid_curve_reserve(): u64 {
    29
}

macro public(package) fun invalid_terminal_threshold(): u64 {
    30
}

macro public(package) fun invalid_quote_fee_bps(): u64 {
    31
}

macro public(package) fun invalid_max_burn_bps(): u64 {
    32
}

macro public(package) fun zero_trade_input(): u64 {
    33
}

macro public(package) fun zero_trade_output(): u64 {
    34
}

macro public(package) fun curve_reserve_overflow(): u64 {
    35
}

macro public(package) fun sell_back_invariant_violated(): u64 {
    36
}

macro public(package) fun invalid_meme_fee_bps(): u64 {
    37
}

macro public(package) fun nothing_accrued(): u64 {
    38
}

macro public(package) fun zero_fee_accrual(): u64 {
    39
}

macro public(package) fun invalid_protocol_fee_share_bps(): u64 {
    40
}

macro public(package) fun protocol_fee_share_unchanged(): u64 {
    41
}
