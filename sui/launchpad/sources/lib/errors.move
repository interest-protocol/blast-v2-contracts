// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[allow(unused_const)]
/// Package error registry: numeric macros and matching test-only constants.
module blast_fun::errors;

// === Errors ===

#[test_only]
/// A basis-points value is above 10,000.
const EInvalidBps: u64 = 0;

#[test_only]
/// A trade fee is above the launch configuration's ceiling.
const EInvalidTradeFeeBps: u64 = 1;

#[test_only]
/// The Meme decimals are not admitted for new launches.
const EDecimalsNotAllowed: u64 = 2;

#[test_only]
/// The migration adapter is not admitted for new launches.
const EMigrationWitnessNotAllowed: u64 = 3;

#[test_only]
/// A framework type cannot be a migration witness.
const EInvalidMigrationWitnessType: u64 = 4;

#[test_only]
/// Blast's allocation is already set or leaves no room for the curve and pool.
const EInvalidProtocolAllocation: u64 = 5;

#[test_only]
/// A recipient address is zero.
const EInvalidDestination: u64 = 6;

#[test_only]
/// The shares do not sum to 10,000, or the curve or pool Meme share is zero.
const EInvalidShares: u64 = 7;

#[test_only]
/// A split has more than sixteen recipients.
const ERecipientCapacityReached: u64 = 8;

#[test_only]
/// The sell-burn rate is above its ceiling.
const EInvalidSellBurnBps: u64 = 9;

#[test_only]
/// The ticket's supply is not the canonical one billion tokens.
const EInvalidInitialMemeSupply: u64 = 10;

#[test_only]
/// Meme and Quote are the same type.
const EInvalidMemeQuotePair: u64 = 11;

#[test_only]
/// The Meme symbol is longer than 32 bytes.
const EMemeSymbolTooLong: u64 = 12;

#[test_only]
/// The opening round is neither zero nor within its bounds.
const EInvalidOpeningRound: u64 = 13;

#[test_only]
/// The pool's Quote share of the graduation target rounds to zero.
const EInvalidGraduationTarget: u64 = 14;

#[test_only]
/// The launch is not in the state this operation needs.
const EInvalidLaunchLifecycle: u64 = 15;

#[test_only]
/// The output is below the caller's minimum.
const ESlippageExceeded: u64 = 16;

#[test_only]
/// The trade's net output is zero.
const EZeroTradeOutput: u64 = 17;

#[test_only]
/// The opening round has ended.
const EOpeningRoundEnded: u64 = 18;

#[test_only]
/// The opening round has not ended.
const EOpeningRoundNotEnded: u64 = 19;

#[test_only]
/// There are no fees to claim.
const ENothingAccrued: u64 = 20;

#[test_only]
/// The witness is not the launch's migration adapter.
const EInvalidMigrationWitness: u64 = 21;

#[test_only]
/// The creator cap is not the one the launch honors.
const ECreatorCapNotLive: u64 = 22;

#[test_only]
/// A setter was called with the value already in place.
const EUnchanged: u64 = 23;

#[test_only]
/// A fee split names the same recipient twice.
const EDuplicateDestination: u64 = 24;

#[test_only]
/// The creator recipient address is zero.
const EInvalidCreatorRecipient: u64 = 25;

#[test_only]
/// The account commitment is not 32 bytes.
const EInvalidAccountCommitment: u64 = 26;

#[test_only]
/// The claim signer key is neither empty nor 32 bytes.
const EInvalidCreatorClaimPublicKey: u64 = 27;

#[test_only]
/// The claim attestation is unexpected or malformed.
const EInvalidCreatorClaimAttestation: u64 = 28;

#[test_only]
/// The claim attestation has expired.
const ECreatorClaimExpired: u64 = 29;

#[test_only]
/// The sender is not the creator recipient.
const ECreatorNotSender: u64 = 30;

#[test_only]
/// The claim attestation's signature does not verify.
const EInvalidCreatorClaimSignature: u64 = 31;

#[test_only]
/// The Quote is not admitted for new launches.
const EQuoteNotAllowed: u64 = 32;

#[test_only]
/// The virtual Quote reserve is zero, which would let the first purchase take the whole curve.
const EInvalidVirtualQuote: u64 = 33;

#[test_only]
/// An opening-round bid is zero.
const EZeroOpeningRoundBid: u64 = 34;

macro public(package) fun invalid_bps(): u64 { 0 }

macro public(package) fun invalid_trade_fee_bps(): u64 { 1 }

macro public(package) fun decimals_not_allowed(): u64 { 2 }

macro public(package) fun migration_witness_not_allowed(): u64 { 3 }

macro public(package) fun invalid_migration_witness_type(): u64 { 4 }

macro public(package) fun invalid_protocol_allocation(): u64 { 5 }

macro public(package) fun invalid_destination(): u64 { 6 }

macro public(package) fun invalid_shares(): u64 { 7 }

macro public(package) fun recipient_capacity_reached(): u64 { 8 }

macro public(package) fun invalid_sell_burn_bps(): u64 { 9 }

macro public(package) fun invalid_initial_meme_supply(): u64 { 10 }

macro public(package) fun invalid_meme_quote_pair(): u64 { 11 }

macro public(package) fun meme_symbol_too_long(): u64 { 12 }

macro public(package) fun invalid_opening_round(): u64 { 13 }

macro public(package) fun invalid_graduation_target(): u64 { 14 }

macro public(package) fun invalid_launch_lifecycle(): u64 { 15 }

macro public(package) fun slippage_exceeded(): u64 { 16 }

macro public(package) fun zero_trade_output(): u64 { 17 }

macro public(package) fun opening_round_ended(): u64 { 18 }

macro public(package) fun opening_round_not_ended(): u64 { 19 }

macro public(package) fun nothing_accrued(): u64 { 20 }

macro public(package) fun invalid_migration_witness(): u64 { 21 }

macro public(package) fun creator_cap_not_live(): u64 { 22 }

macro public(package) fun unchanged(): u64 { 23 }

macro public(package) fun duplicate_destination(): u64 { 24 }

macro public(package) fun invalid_creator_recipient(): u64 { 25 }

macro public(package) fun invalid_account_commitment(): u64 { 26 }

macro public(package) fun invalid_creator_claim_public_key(): u64 { 27 }

macro public(package) fun invalid_creator_claim_attestation(): u64 { 28 }

macro public(package) fun creator_claim_expired(): u64 { 29 }

macro public(package) fun creator_not_sender(): u64 { 30 }

macro public(package) fun invalid_creator_claim_signature(): u64 { 31 }

macro public(package) fun quote_not_allowed(): u64 { 32 }

macro public(package) fun invalid_virtual_quote(): u64 { 33 }

macro public(package) fun zero_opening_round_bid(): u64 { 34 }
