// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[allow(unused_const)]
module blast_sui::errors;

// === Errors ===

#[test_only]
/// An operation requires a positive atomic coin amount.
const EZeroAmount: u64 = 0;

#[test_only]
/// The number of shares exceeds the live blastSUI supply.
const EInvalidShareAmount: u64 = 1;

#[test_only]
/// A positive SUI deposit rounded down to zero blastSUI shares.
const EZeroBlastShares: u64 = 2;

#[test_only]
/// A positive blastSUI redemption rounded down to zero SUI.
const EZeroSuiRedemption: u64 = 3;

#[test_only]
/// The supplied Publisher was not claimed by this package's canonical module.
const EInvalidPackagePublisher: u64 = 4;

#[test_only]
/// The validator left the active set, so the vault accepts redemptions only.
const EUnwindOnly: u64 = 5;

#[test_only]
/// The fixed validator is not in the active validator set.
const EValidatorNotActive: u64 = 6;

#[test_only]
/// A treasury cap entering vault custody already has supply.
const ENonzeroInitialSupply: u64 = 7;

#[test_only]
/// The output is below the caller's minimum.
const ESlippageExceeded: u64 = 8;

#[test_only]
/// Native redemption returned less SUI than the custody ledger's conservative valuation.
const EInsufficientNativeRedemption: u64 = 9;

#[test_only]
/// blastSUI shares exist but blast custody holds no assets to price them.
const EBlastAssetsDepleted: u64 = 10;

#[test_only]
/// The protocol bootstrap deposit is below the native one-SUI stake minimum.
const EBootstrapBelowNativeMinimum: u64 = 11;

#[test_only]
/// The requested redemption fee exceeds the immutable maximum.
const ERedeemFeeAboveMaximum: u64 = 12;

#[test_only]
/// The requested redemption fee equals the live rate.
const ERedeemFeeUnchanged: u64 = 13;

#[test_only]
/// Fun custody's conservative assets fell below the funSUI supply.
const EFunBackingBelowSupply: u64 = 14;

#[test_only]
/// The staking pool has no exchange-rate entry for the current epoch.
const EStaleExchangeRate: u64 = 15;

#[test_only]
/// A blastSUI deposit is below the native one-SUI staking minimum.
const EBlastDepositBelowNativeMinimum: u64 = 16;

#[test_only]
/// A blastSUI deposit receipt has not reached its native activation epoch.
const EBlastDepositNotActive: u64 = 17;

#[test_only]
/// A blastSUI deposit receipt belongs to another vault.
const EWrongReceiptVault: u64 = 18;

#[test_only]
/// A blastSUI deposit receipt contains stake from another validator pool.
const EWrongReceiptPool: u64 = 19;

#[test_only]
/// The blastSUI redemption fee consumed the complete atomic payout.
const EZeroSuiAfterFee: u64 = 20;

#[test_only]
/// Native delegation returned stake from a pool other than the vault's immutable pool.
const EWrongDelegationPool: u64 = 21;

#[test_only]
/// PackageAdmin cannot be shared before every required capability is attached.
const EMissingPackageCapability: u64 = 22;

#[test_only]
/// PackageAdmin already owns a capability object of this exact type.
const EPackageCapabilityAlreadyExists: u64 = 23;

macro public(package) fun zero_amount(): u64 { 0 }

macro public(package) fun invalid_share_amount(): u64 { 1 }

macro public(package) fun zero_blast_shares(): u64 { 2 }

macro public(package) fun zero_sui_redemption(): u64 { 3 }

macro public(package) fun invalid_package_publisher(): u64 { 4 }

macro public(package) fun unwind_only(): u64 { 5 }

macro public(package) fun validator_not_active(): u64 { 6 }

macro public(package) fun nonzero_initial_supply(): u64 { 7 }

macro public(package) fun slippage_exceeded(): u64 { 8 }

macro public(package) fun insufficient_native_redemption(): u64 { 9 }

macro public(package) fun blast_assets_depleted(): u64 { 10 }

macro public(package) fun bootstrap_below_native_minimum(): u64 { 11 }

macro public(package) fun redeem_fee_above_maximum(): u64 { 12 }

macro public(package) fun redeem_fee_unchanged(): u64 { 13 }

macro public(package) fun fun_backing_below_supply(): u64 { 14 }

macro public(package) fun stale_exchange_rate(): u64 { 15 }

macro public(package) fun blast_deposit_below_native_minimum(): u64 { 16 }

macro public(package) fun blast_deposit_not_active(): u64 { 17 }

macro public(package) fun wrong_receipt_vault(): u64 { 18 }

macro public(package) fun wrong_receipt_pool(): u64 { 19 }

macro public(package) fun zero_sui_after_fee(): u64 { 20 }

macro public(package) fun wrong_delegation_pool(): u64 { 21 }

macro public(package) fun missing_package_capability(): u64 { 22 }

macro public(package) fun package_capability_already_exists(): u64 { 23 }
