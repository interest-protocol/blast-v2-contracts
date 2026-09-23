// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[allow(unused_const)]
module blast_sui::errors;

// === Errors ===

// Append-only package error registry. Never reuse a retired numeric code.

#[test_only]
/// An operation requires a positive atomic coin amount.
const EZeroAmount: u64 = 0;

#[test_only]
/// The number of shares exceeds the live blastSUI supply.
const EInvalidShareAmount: u64 = 1;

// Code 2 retired: residual-equity bootstrap state was replaced by separate custody ledgers.

#[test_only]
/// A positive SUI deposit rounded down to zero blastSUI shares.
const EZeroBlastShares: u64 = 3;

#[test_only]
/// A positive blastSUI redemption rounded down to zero SUI.
const EZeroSuiRedemption: u64 = 4;

// Code 5 retired: fun custody is settled by the yield sweep instead of asserted.

// Code 6 retired: the residual-owner guard was removed with the final-holder block.

// Code 7 retired: the package-specific UpgradeAdminCap was replaced by the local ACL.

// Code 8 retired: digest validation moved to blast_admin::upgrade_custody.

#[test_only]
/// The supplied Publisher was not claimed by this package's canonical module.
const EInvalidPackagePublisher: u64 = 9;

// Code 10 retired: native capability intake moved to blast_admin::upgrade_custody.
// Codes 11 and 12 retired: generation comparison and arithmetic moved to
// blast_admin::operational_version.
// Code 13 retired: policy narrowing moved to blast_admin::upgrade_custody.

#[test_only]
/// The validator left the active set, so the vault accepts redemptions only.
const EUnwindOnly: u64 = 14;

#[test_only]
/// The fixed validator is not in the active validator set.
const EValidatorNotActive: u64 = 15;

// Code 16 retired: the validator is derived from the immutable pool ID.

#[test_only]
/// A treasury cap entering vault custody already has supply.
const ENonzeroInitialSupply: u64 = 17;

// Code 18 retired: funSUI mints no longer require positive blastSUI supply.

#[test_only]
/// The output is below the caller's minimum.
const ESlippageExceeded: u64 = 19;

#[test_only]
/// Native redemption returned less SUI than the custody ledger's conservative valuation.
const EInsufficientNativeRedemption: u64 = 20;

// Code 21 retired: the final-holder block was replaced by the seed supply locked at `@0x0`.

#[test_only]
/// blastSUI shares exist but blast custody holds no assets to price them.
const EBlastAssetsDepleted: u64 = 22;

#[test_only]
/// The protocol bootstrap deposit is below the native one-SUI stake minimum.
const EBootstrapBelowNativeMinimum: u64 = 23;

// Codes 24 through 36 retired: the root capability lifecycle moved to
// blast_admin::acl, which owns its own append-only error registry.

#[test_only]
/// The requested redemption fee exceeds the immutable maximum.
const ERedeemFeeAboveMaximum: u64 = 37;

#[test_only]
/// The requested redemption fee equals the live rate.
const ERedeemFeeUnchanged: u64 = 38;

#[test_only]
/// Fun custody's conservative assets fell below the funSUI supply.
const EFunBackingBelowSupply: u64 = 39;

#[test_only]
/// The staking pool has no exchange-rate entry for the current epoch.
const EStaleExchangeRate: u64 = 40;

#[test_only]
/// A blastSUI deposit is below the native one-SUI staking minimum.
const EBlastDepositBelowNativeMinimum: u64 = 41;

#[test_only]
/// A blastSUI deposit receipt has not reached its native activation epoch.
const EBlastDepositNotActive: u64 = 42;

#[test_only]
/// A blastSUI deposit receipt belongs to another vault.
const EWrongReceiptVault: u64 = 43;

#[test_only]
/// A blastSUI deposit receipt contains stake from another validator pool.
const EWrongReceiptPool: u64 = 44;

#[test_only]
/// The blastSUI redemption fee consumed the complete atomic payout.
const EZeroSuiAfterFee: u64 = 45;

// Code 46 retired: Display V2 uniqueness is enforced by the framework registry.

#[test_only]
/// Native delegation returned stake from a pool other than the vault's immutable pool.
const EWrongDelegationPool: u64 = 47;

// Codes 48, 49 and 50 retired: administrator membership moved to
// blast_admin::acl.

#[test_only]
/// PackageAdmin cannot be shared before every required capability is attached.
const EMissingPackageCapability: u64 = 51;

#[test_only]
/// PackageAdmin already owns a capability object of this exact type.
const EPackageCapabilityAlreadyExists: u64 = 52;

macro public(package) fun zero_amount(): u64 {
    0
}

macro public(package) fun invalid_share_amount(): u64 {
    1
}

// Error code 2 is retired and must not be reused.

macro public(package) fun zero_blast_shares(): u64 {
    3
}

macro public(package) fun zero_sui_redemption(): u64 {
    4
}

// Error codes 5, 6, and 7 are retired and must not be reused.

// Code 8 retired: digest validation moved to blast_admin::upgrade_custody.

macro public(package) fun invalid_package_publisher(): u64 {
    9
}

// Code 10 retired: native capability intake moved to blast_admin::upgrade_custody.
// Codes 11 and 12 retired: generation comparison and arithmetic moved to
// blast_admin::operational_version.
// Code 13 retired: policy narrowing moved to blast_admin::upgrade_custody.

macro public(package) fun unwind_only(): u64 {
    14
}

macro public(package) fun validator_not_active(): u64 {
    15
}

// Error code 16 is retired and must not be reused.

macro public(package) fun nonzero_initial_supply(): u64 {
    17
}

// Error code 18 is retired and must not be reused.

macro public(package) fun slippage_exceeded(): u64 {
    19
}

macro public(package) fun insufficient_native_redemption(): u64 {
    20
}

// Error code 21 is retired and must not be reused.

macro public(package) fun blast_assets_depleted(): u64 {
    22
}

macro public(package) fun bootstrap_below_native_minimum(): u64 {
    23
}

// Error codes 24 through 36 are retired and must not be reused: the root
// capability lifecycle moved to blast_admin::acl, which owns its own
// append-only error registry.

macro public(package) fun redeem_fee_above_maximum(): u64 {
    37
}

macro public(package) fun redeem_fee_unchanged(): u64 {
    38
}

macro public(package) fun fun_backing_below_supply(): u64 {
    39
}

macro public(package) fun stale_exchange_rate(): u64 {
    40
}

macro public(package) fun blast_deposit_below_native_minimum(): u64 {
    41
}

macro public(package) fun blast_deposit_not_active(): u64 {
    42
}

macro public(package) fun wrong_receipt_vault(): u64 {
    43
}

macro public(package) fun wrong_receipt_pool(): u64 {
    44
}

macro public(package) fun zero_sui_after_fee(): u64 {
    45
}

// Error code 46 is retired and must not be reused.

macro public(package) fun wrong_delegation_pool(): u64 {
    47
}

// Error codes 48, 49 and 50 are retired and must not be reused: administrator
// membership moved to blast_admin::acl.

macro public(package) fun missing_package_capability(): u64 {
    51
}

macro public(package) fun package_capability_already_exists(): u64 {
    52
}
