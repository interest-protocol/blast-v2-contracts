// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[allow(unused_const)]
/// Package error registry.
module blast_fun_dex::errors;

// === Errors ===

// Pool.

#[test_only]
/// Pool tokens must be different types.
const EIdenticalTokens: u64 = 0;

#[test_only]
/// Tick spacing must be between 1 and 32,767.
const EInvalidTickSpacing: u64 = 1;

#[test_only]
/// Square-root price is outside the supported range.
const EInvalidSqrtPrice: u64 = 2;

#[test_only]
/// Hook registration must select at least one slot.
const EInvalidHookFlags: u64 = 3;

#[test_only]
/// Another hook is already bound to this slot.
const EHookSlotTaken: u64 = 4;

#[test_only]
/// Ticks must be ordered, in range and multiples of the tick spacing.
const EInvalidTickRange: u64 = 5;

#[test_only]
/// Position still holds liquidity.
const EPositionNotEmpty: u64 = 6;

#[test_only]
/// Pool is already running an operation in this transaction.
const EPoolInOperation: u64 = 7;

#[test_only]
/// Value belongs to a different pool.
const EWrongPool: u64 = 8;

#[test_only]
/// Position does not match the request.
const EWrongPosition: u64 = 9;

#[test_only]
/// Payment must not be zero.
const EZeroAmount: u64 = 10;

#[test_only]
/// Price limit is on the wrong side of the current price or out of range.
const EInvalidPriceLimit: u64 = 11;

#[test_only]
/// Liquidity must not be zero.
const EZeroLiquidity: u64 = 12;

#[test_only]
/// Position holds less liquidity than requested.
const EInsufficientLiquidity: u64 = 13;

#[test_only]
/// Witness is not the hook bound to this slot.
const EHookNotBound: u64 = 14;

#[test_only]
/// Hook has already approved this step.
const EAlreadyApproved: u64 = 15;

#[test_only]
/// The bound hook has not approved this step.
const EMissingApproval: u64 = 16;

#[test_only]
/// Payment is less than the liquidity requires.
const EInsufficientPayment: u64 = 17;

#[test_only]
/// Output is below the caller's minimum.
const EInsufficientOutput: u64 = 18;

#[test_only]
/// Curve math is not implemented; do not publish this package.
const ECurveMathUnavailable: u64 = 19;

// Hook configuration.

#[test_only]
/// Hook witness must be a struct type, not a primitive or vector.
const EPrimitiveWitness: u64 = 20;

#[test_only]
/// Hook version must increase.
const EVersionNotIncreasing: u64 = 21;

// LP fee policy.

#[test_only]
/// A pool's fixed or base LP fee must be a registered tier.
const ENotFeeTier: u64 = 22;

#[test_only]
/// Dynamic maximum fee must be at least the base fee and at most 100,000 ppm.
const EInvalidMaxFee: u64 = 23;

#[test_only]
/// Dynamic fee sensitivity must be between 100,000 and 100,000,000 ppm.
const EInvalidSensitivity: u64 = 24;

// Signed integers.

#[test_only]
/// Magnitude does not fit the requested signed 32-bit value.
const EMagnitudeTooLarge: u64 = 25;

// Rates.

#[test_only]
/// A ppm rate must be at most 1,000,000.
const EInvalidPpm: u64 = 26;

// LP fee tier registration.

#[test_only]
/// A fee tier must be between 1 and 100,000 ppm.
const EInvalidFeeTierRate: u64 = 27;

#[test_only]
/// This fee tier is already registered.
const EFeeTierAlreadyExists: u64 = 28;

macro public(package) fun identical_tokens(): u64 { 0 }

macro public(package) fun invalid_tick_spacing(): u64 { 1 }

macro public(package) fun invalid_sqrt_price(): u64 { 2 }

macro public(package) fun invalid_hook_flags(): u64 { 3 }

macro public(package) fun hook_slot_taken(): u64 { 4 }

macro public(package) fun invalid_tick_range(): u64 { 5 }

macro public(package) fun position_not_empty(): u64 { 6 }

macro public(package) fun pool_in_operation(): u64 { 7 }

macro public(package) fun wrong_pool(): u64 { 8 }

macro public(package) fun wrong_position(): u64 { 9 }

macro public(package) fun zero_amount(): u64 { 10 }

macro public(package) fun invalid_price_limit(): u64 { 11 }

macro public(package) fun zero_liquidity(): u64 { 12 }

macro public(package) fun insufficient_liquidity(): u64 { 13 }

macro public(package) fun hook_not_bound(): u64 { 14 }

macro public(package) fun already_approved(): u64 { 15 }

macro public(package) fun missing_approval(): u64 { 16 }

macro public(package) fun insufficient_payment(): u64 { 17 }

macro public(package) fun insufficient_output(): u64 { 18 }

macro public(package) fun curve_math_unavailable(): u64 { 19 }

macro public(package) fun primitive_witness(): u64 { 20 }

macro public(package) fun version_not_increasing(): u64 { 21 }

macro public(package) fun not_fee_tier(): u64 { 22 }

macro public(package) fun invalid_max_fee(): u64 { 23 }

macro public(package) fun invalid_sensitivity(): u64 { 24 }

macro public(package) fun magnitude_too_large(): u64 { 25 }

macro public(package) fun invalid_ppm(): u64 { 26 }

macro public(package) fun invalid_fee_tier_rate(): u64 { 27 }

macro public(package) fun fee_tier_already_exists(): u64 { 28 }
