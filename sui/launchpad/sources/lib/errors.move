// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[allow(unused_const)]
/// Package error registry: numeric macros and matching test-only constants.
module blast_fun::errors;

// === Errors ===

#[test_only]
/// The creator-claim signer public key is not 32 bytes.
const EInvalidCreatorClaimPublicKey: u64 = 0;

#[test_only]
/// Account claims are disabled because no signer public key is configured.
const ECreatorClaimSignerInactive: u64 = 1;

#[test_only]
/// The Ed25519 signature does not verify against the canonical claim bytes.
const EInvalidCreatorClaimSignature: u64 = 2;

#[test_only]
/// An address creator recipient cannot target the zero address.
const EInvalidCreatorRecipient: u64 = 3;

#[test_only]
/// A Blast account commitment must be exactly 32 bytes.
const EInvalidAccountCommitment: u64 = 4;

#[test_only]
/// An address creator claim included an account attestation.
const EUnexpectedCreatorClaimAttestation: u64 = 5;

#[test_only]
/// The creator claim attestation has expired.
const ECreatorClaimExpired: u64 = 6;

#[test_only]
/// Signer rotation must provide a key different from the current key.
const ECreatorClaimSignerUnchanged: u64 = 7;

#[test_only]
/// An account creator claim did not include its required attestation.
const EMissingCreatorClaimAttestation: u64 = 8;

#[test_only]
/// The transaction sender is not the address creator recorded by the launch.
const ECreatorNotSender: u64 = 9;

#[test_only]
/// Creator claim data is not canonical BCS `(u64, vector<u8>)` for a 64-byte signature.
const EInvalidCreatorClaimAttestation: u64 = 10;

#[test_only]
/// Meme inventory or virtual quote reserve cannot represent a valid constant-product market.
const EInvalidCurveReserve: u64 = 11;

#[test_only]
/// The quote-asset launch fee exceeds ten percent.
const EInvalidQuoteFeeBps: u64 = 12;

#[test_only]
/// A curve quote requires a nonzero trade input.
const EZeroTradeInput: u64 = 13;

#[test_only]
/// Rounding or fees reduced the user's quoted output to zero.
const EZeroTradeOutput: u64 = 14;

#[test_only]
/// A sell quote requested more real quote than the curve holds.
const ESellBackInvariantViolated: u64 = 15;

#[test_only]
/// The meme-asset launch fee exceeds ten percent.
const EInvalidMemeFeeBps: u64 = 16;

#[test_only]
/// Neither asset has an accrued balance for the presented claim authority.
const ENothingAccrued: u64 = 17;

#[test_only]
/// A fee accrual cannot contain zero meme and zero quote simultaneously.
const EZeroFeeAccrual: u64 = 18;

#[test_only]
/// A protocol-share update supplied the currently active value.
const EProtocolFeeShareUnchanged: u64 = 19;

#[test_only]
/// The quote type is not admitted for new launches.
const EQuoteNotAllowed: u64 = 20;

#[test_only]
/// The migration witness type is already admitted.
const EMigrationWitnessAlreadyAllowed: u64 = 21;

#[test_only]
/// The bounded migration-witness whitelist is full.
const EMigrationWitnessCapacityReached: u64 = 22;

#[test_only]
/// The migration witness type is not admitted, or the ticket is not bound to one for the Quote.
const EMigrationWitnessNotAllowed: u64 = 23;

#[test_only]
/// Supplied Publisher or UpgradeCap provenance does not match the expected package.
const EInvalidPackagePublisher: u64 = 24;

#[test_only]
/// A Quote policy's virtual reserve must be nonzero.
const EInvalidVirtualQuote: u64 = 25;

#[test_only]
/// A Quote policy update supplied the active virtual Quote reserve.
const EQuoteParametersUnchanged: u64 = 26;

#[test_only]
/// The launch has no pending creator authority to claim.
const ECreatorAuthorityUnavailable: u64 = 27;

#[test_only]
/// A trade-fee update supplied the complete active rate pair.
const ETradeFeeDefaultsUnchanged: u64 = 28;

#[test_only]
/// The launch lifecycle does not permit the requested operation.
const EInvalidLaunchLifecycle: u64 = 29;

#[test_only]
/// The returned user amount is below the caller's minimum.
const ESlippageExceeded: u64 = 30;

#[test_only]
/// The witness is not the adapter witness the launch stores or the ticket is bound to.
const EInvalidMigrationWitness: u64 = 31;

#[test_only]
/// A basis-points value exceeds one hundred percent.
const EInvalidBps: u64 = 32;

#[test_only]
/// A launch cannot use the generated Meme type as its own Quote type.
const EInvalidMemeQuotePair: u64 = 33;

#[test_only]
/// The ticket balance or the currency's minted supply is not the canonical Meme supply.
const EInvalidInitialMemeSupply: u64 = 34;

#[test_only]
/// A migration witness must be an adapter-defined struct outside the `0x1` and `0x2` frameworks.
const EInvalidMigrationWitnessType: u64 = 35;

#[test_only]
/// The creator-selected sell burn exceeds fifty percent.
const EInvalidSellBurnBps: u64 = 36;

#[test_only]
/// A completed trade reduced the curve's constant product.
const EConstantProductInvariantDecreased: u64 = 37;

#[test_only]
/// The curve-fee capability is not the one the launch currently honors.
const ECurveFeeCapNotLive: u64 = 38;

#[test_only]
/// A coin metadata update supplied the current value.
const EMetadataUnchanged: u64 = 39;

#[test_only]
/// The metadata capability is not the one the launch currently honors.
const EMetadataCapNotLive: u64 = 40;

#[test_only]
/// A curve fee rate is one hundred percent, leaving no complement to divide by.
const EInvalidCurveFee: u64 = 41;

#[test_only]
/// The ticket's Meme decimal precision is not admitted by the launch configuration.
const EDecimalsNotAllowed: u64 = 42;

#[test_only]
const EAllocationSumInvalid: u64 = 43;

#[test_only]
const EDuplicateMigrationChannel: u64 = 44;

#[test_only]
const EUnknownMigrationChannel: u64 = 45;

#[test_only]
const EMigrationChannelCapacityReached: u64 = 46;

#[test_only]
const EInvalidLiquidityChannel: u64 = 47;

#[test_only]
const EProtocolChannelMismatch: u64 = 48;

#[test_only]
/// The graduation target leaves the liquidity channel with no Quote to hand off.
const EInvalidGraduationTarget: u64 = 49;

#[test_only]
/// Launch protection is neither all zeros nor a nonzero window with a positive cumulative rate.
const EInvalidProtection: u64 = 50;

#[test_only]
/// A protected purchase's gross Meme curve output exceeds the per-transaction limit, which checks
/// each purchase call on its own; repeated purchases in one transaction are bounded in total only
/// by the cumulative limit.
const EPerTransactionLimitExceeded: u64 = 51;

#[test_only]
/// A protected purchase would take its sender's cumulative gross Meme curve output past the limit.
const ECumulativeLimitExceeded: u64 = 52;

#[test_only]
/// A pre-share operation targeted a launch that has already been shared.
const ELaunchAlreadyShared: u64 = 53;

#[test_only]
/// The launch has already completed its single permitted pre-share purchase.
const EPreShareBuyAlreadyCompleted: u64 = 54;

#[test_only]
/// The pre-share purchase would reach the migration target and close trading.
const EPreShareBuyWouldGraduate: u64 = 55;

#[test_only]
/// The migration value, supplied and residual amounts, or liquidity did not match the launch.
const EMigrationSettlementMismatch: u64 = 56;

#[test_only]
/// The LP-fee split names more than sixteen recipients.
const ERouteCapacityReached: u64 = 57;

#[test_only]
/// A recipient share is zero, or the LP-fee split does not sum to 10,000.
const ERouteSumInvalid: u64 = 58;

#[test_only]
/// The LP-fee split names the same recipient twice.
const ERouteDuplicateDestination: u64 = 59;

#[test_only]
/// A recipient is the zero address.
const ERouteInvalidDestination: u64 = 60;

#[test_only]
/// The Meme symbol is longer than the launch intake bound.
const EMemeSymbolTooLong: u64 = 61;

#[test_only]
/// Launch finalization found no graduation target, allocation plan, or LP-fee split.
const ELaunchSettingsIncomplete: u64 = 62;

macro public(package) fun invalid_creator_claim_public_key(): u64 { 0 }

macro public(package) fun creator_claim_signer_inactive(): u64 { 1 }

macro public(package) fun invalid_creator_claim_signature(): u64 { 2 }

macro public(package) fun invalid_creator_recipient(): u64 { 3 }

macro public(package) fun invalid_account_commitment(): u64 { 4 }

macro public(package) fun unexpected_creator_claim_attestation(): u64 { 5 }

macro public(package) fun creator_claim_expired(): u64 { 6 }

macro public(package) fun creator_claim_signer_unchanged(): u64 { 7 }

macro public(package) fun missing_creator_claim_attestation(): u64 { 8 }

macro public(package) fun creator_not_sender(): u64 { 9 }

macro public(package) fun invalid_creator_claim_attestation(): u64 { 10 }

macro public(package) fun invalid_curve_reserve(): u64 { 11 }

macro public(package) fun invalid_quote_fee_bps(): u64 { 12 }

macro public(package) fun zero_trade_input(): u64 { 13 }

macro public(package) fun zero_trade_output(): u64 { 14 }

macro public(package) fun sell_back_invariant_violated(): u64 { 15 }

macro public(package) fun invalid_meme_fee_bps(): u64 { 16 }

macro public(package) fun nothing_accrued(): u64 { 17 }

macro public(package) fun zero_fee_accrual(): u64 { 18 }

macro public(package) fun protocol_fee_share_unchanged(): u64 { 19 }

macro public(package) fun quote_not_allowed(): u64 { 20 }

macro public(package) fun migration_witness_already_allowed(): u64 { 21 }

macro public(package) fun migration_witness_capacity_reached(): u64 { 22 }

macro public(package) fun migration_witness_not_allowed(): u64 { 23 }

/// Shared package-provenance mismatch for Publisher and UpgradeCap checks.
macro public(package) fun invalid_package_publisher(): u64 { 24 }

macro public(package) fun invalid_virtual_quote(): u64 { 25 }

macro public(package) fun quote_parameters_unchanged(): u64 { 26 }

macro public(package) fun creator_authority_unavailable(): u64 { 27 }

macro public(package) fun trade_fee_defaults_unchanged(): u64 { 28 }

macro public(package) fun invalid_launch_lifecycle(): u64 { 29 }

macro public(package) fun slippage_exceeded(): u64 { 30 }

macro public(package) fun invalid_migration_witness(): u64 { 31 }

macro public(package) fun invalid_bps(): u64 { 32 }

macro public(package) fun invalid_meme_quote_pair(): u64 { 33 }

macro public(package) fun invalid_initial_meme_supply(): u64 { 34 }

macro public(package) fun invalid_migration_witness_type(): u64 { 35 }

macro public(package) fun invalid_sell_burn_bps(): u64 { 36 }

macro public(package) fun constant_product_invariant_decreased(): u64 { 37 }

macro public(package) fun curve_fee_cap_not_live(): u64 { 38 }

macro public(package) fun metadata_unchanged(): u64 { 39 }

macro public(package) fun metadata_cap_not_live(): u64 { 40 }

macro public(package) fun invalid_curve_fee(): u64 { 41 }

macro public(package) fun decimals_not_allowed(): u64 { 42 }

macro public(package) fun allocation_sum_invalid(): u64 { 43 }

macro public(package) fun duplicate_migration_channel(): u64 { 44 }

macro public(package) fun unknown_migration_channel(): u64 { 45 }

macro public(package) fun migration_channel_capacity_reached(): u64 { 46 }

macro public(package) fun invalid_liquidity_channel(): u64 { 47 }

macro public(package) fun protocol_channel_mismatch(): u64 { 48 }

macro public(package) fun invalid_graduation_target(): u64 { 49 }

macro public(package) fun invalid_protection(): u64 { 50 }

macro public(package) fun per_transaction_limit_exceeded(): u64 { 51 }

macro public(package) fun cumulative_limit_exceeded(): u64 { 52 }

macro public(package) fun launch_already_shared(): u64 { 53 }

macro public(package) fun pre_share_buy_already_completed(): u64 { 54 }

macro public(package) fun pre_share_buy_would_graduate(): u64 { 55 }

macro public(package) fun migration_settlement_mismatch(): u64 { 56 }

macro public(package) fun route_capacity_reached(): u64 { 57 }

macro public(package) fun route_sum_invalid(): u64 { 58 }

macro public(package) fun route_duplicate_destination(): u64 { 59 }

macro public(package) fun route_invalid_destination(): u64 { 60 }

macro public(package) fun meme_symbol_too_long(): u64 { 61 }

macro public(package) fun launch_settings_incomplete(): u64 { 62 }
