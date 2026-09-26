// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[allow(unused_const)]
/// Package error registry: numeric macros and matching test-only constants.
module blast_presale::errors;

// === Errors ===

#[test_only]
/// The fee is above its ceiling.
const EInvalidFeeBps: u64 = 0;

#[test_only]
/// The fee destination is the zero address.
const EInvalidDestination: u64 = 1;

#[test_only]
/// A setter was called with the value already in place.
const EUnchanged: u64 = 2;

#[test_only]
/// Token and Quote are the same type.
const EInvalidTokenQuotePair: u64 = 3;

#[test_only]
/// A presale has no tranche or more than the maximum.
const EInvalidTrancheCount: u64 = 4;

#[test_only]
/// A tranche sells no tokens, raises no Quote, or ends before it starts.
const EInvalidTranche: u64 = 5;

#[test_only]
/// A whitelist root is not 32 bytes or has no leaves.
const EInvalidWhitelist: u64 = 6;

#[test_only]
/// A tranche ends before the presale is created.
const ETrancheAlreadyEnded: u64 = 7;

#[test_only]
/// The deposited tokens are not exactly the tokens the tranches sell.
const ETokenDepositMismatch: u64 = 8;

#[test_only]
/// The claim time is before a tranche ends.
const EInvalidClaimTime: u64 = 9;

#[test_only]
/// The minimum raise is above what every tranche can raise.
const EInvalidMinRaise: u64 = 10;

#[test_only]
/// The tranche index is past the last tranche.
const EUnknownTranche: u64 = 11;

#[test_only]
/// A public commit targets a whitelisted tranche, or a whitelisted commit a public one.
const ETrancheAccessMismatch: u64 = 12;

#[test_only]
/// The tranche has not started or has ended.
const ETrancheNotOpen: u64 = 13;

#[test_only]
/// The commit is zero.
const EZeroCommit: u64 = 14;

#[test_only]
/// The whitelist proof does not verify for the sender.
const EInvalidWhitelistProof: u64 = 15;

#[test_only]
/// A first-come tranche has no Quote left to accept.
const ETrancheSoldOut: u64 = 16;

#[test_only]
/// The address has committed its whole allowance to the tranche.
const EWalletCapReached: u64 = 17;

#[test_only]
/// A tranche is still open, so the presale cannot be finalized.
const EPresaleNotEnded: u64 = 18;

#[test_only]
/// The presale is already finalized.
const EPresaleFinalized: u64 = 19;

#[test_only]
/// The presale is not finalized yet.
const EPresaleNotFinalized: u64 = 20;

#[test_only]
/// The position has nothing claimable now.
const ENothingToClaim: u64 = 21;

#[test_only]
/// The commit buys less than one token atom at the tranche's price.
const EZeroPurchase: u64 = 22;

#[test_only]
/// A recipient's address is zero or its share is zero.
const EInvalidRecipient: u64 = 23;

#[test_only]
/// More than sixteen recipients, or the recipients' and liquidity's shares do not sum to 10,000.
const EInvalidPayout: u64 = 24;

#[test_only]
/// The liquidity share is zero or above 10,000, its listing price has a zero side, or it is for
/// another pair.
const EInvalidLiquidity: u64 = 25;

#[test_only]
/// The liquidity adapter is not admitted.
const EAdapterNotAllowed: u64 = 26;

#[test_only]
/// The presale has no liquidity to hand off.
const ENoLiquidity: u64 = 27;

#[test_only]
/// The witness is not the adapter the presale named.
const EInvalidAdapter: u64 = 28;

#[test_only]
/// The liquidity is handed off only from the claim time.
const ELiquidityNotOpen: u64 = 29;

#[test_only]
/// A framework type cannot be a liquidity adapter.
const EInvalidAdapterType: u64 = 30;

macro public(package) fun invalid_fee_bps(): u64 { 0 }

macro public(package) fun invalid_destination(): u64 { 1 }

macro public(package) fun unchanged(): u64 { 2 }

macro public(package) fun invalid_token_quote_pair(): u64 { 3 }

macro public(package) fun invalid_tranche_count(): u64 { 4 }

macro public(package) fun invalid_tranche(): u64 { 5 }

macro public(package) fun invalid_whitelist(): u64 { 6 }

macro public(package) fun tranche_already_ended(): u64 { 7 }

macro public(package) fun token_deposit_mismatch(): u64 { 8 }

macro public(package) fun invalid_claim_time(): u64 { 9 }

macro public(package) fun invalid_min_raise(): u64 { 10 }

macro public(package) fun unknown_tranche(): u64 { 11 }

macro public(package) fun tranche_access_mismatch(): u64 { 12 }

macro public(package) fun tranche_not_open(): u64 { 13 }

macro public(package) fun zero_commit(): u64 { 14 }

macro public(package) fun invalid_whitelist_proof(): u64 { 15 }

macro public(package) fun tranche_sold_out(): u64 { 16 }

macro public(package) fun wallet_cap_reached(): u64 { 17 }

macro public(package) fun presale_not_ended(): u64 { 18 }

macro public(package) fun presale_finalized(): u64 { 19 }

macro public(package) fun presale_not_finalized(): u64 { 20 }

macro public(package) fun nothing_to_claim(): u64 { 21 }

macro public(package) fun zero_purchase(): u64 { 22 }

macro public(package) fun invalid_recipient(): u64 { 23 }

macro public(package) fun invalid_payout(): u64 { 24 }

macro public(package) fun invalid_liquidity(): u64 { 25 }

macro public(package) fun adapter_not_allowed(): u64 { 26 }

macro public(package) fun no_liquidity(): u64 { 27 }

macro public(package) fun invalid_adapter(): u64 { 28 }

macro public(package) fun liquidity_not_open(): u64 { 29 }

macro public(package) fun invalid_adapter_type(): u64 { 30 }
