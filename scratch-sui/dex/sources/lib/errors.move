// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Abort codes shared by the scratch DEX modules.
module blast_fun_dex::errors;

// === Errors ===

#[test_only]
const EIdenticalTokens: u64 = 0;

#[test_only]
const EInvalidTickSpacing: u64 = 1;

#[test_only]
const EInvalidSqrtPrice: u64 = 2;

#[test_only]
const EInvalidHookFlags: u64 = 3;

#[test_only]
const EHookSlotTaken: u64 = 4;

#[test_only]
const EInvalidTickRange: u64 = 5;

#[test_only]
const EPositionNotEmpty: u64 = 6;

#[test_only]
const EPoolInOperation: u64 = 7;

#[test_only]
const EWrongPool: u64 = 8;

#[test_only]
const EWrongPosition: u64 = 9;

#[test_only]
const EZeroAmount: u64 = 10;

#[test_only]
const EInvalidPriceLimit: u64 = 11;

#[test_only]
const EZeroLiquidity: u64 = 12;

#[test_only]
const EInsufficientLiquidity: u64 = 13;

#[test_only]
const EHookNotBound: u64 = 14;

#[test_only]
const EAlreadyApproved: u64 = 15;

#[test_only]
const EMissingApproval: u64 = 16;

#[test_only]
const EInsufficientPayment: u64 = 17;

#[test_only]
const EInsufficientOutput: u64 = 18;

#[test_only]
const ELiquidityLimit: u64 = 19;

#[test_only]
const ENotFeeTier: u64 = 20;

#[test_only]
const EInvalidMaxFee: u64 = 21;

#[test_only]
const EInvalidSensitivity: u64 = 22;

#[test_only]
const EInvalidFeeTierRate: u64 = 23;

#[test_only]
const EFeeTierAlreadyExists: u64 = 24;

#[test_only]
const EPrimitiveWitness: u64 = 25;

#[test_only]
const EVersionNotIncreasing: u64 = 26;

#[test_only]
const EInvalidPpm: u64 = 27;

#[test_only]
const EMagnitudeTooLarge: u64 = 28;

#[test_only]
const ETooManyPendingFeeTiers: u64 = 29;

/// Pool tokens must be different types.
macro public(package) fun identical_tokens(): u64 { 0 }

/// Tick spacing must be between 1 and 32,767.
macro public(package) fun invalid_tick_spacing(): u64 { 1 }

/// Square-root price is outside the supported range.
macro public(package) fun invalid_sqrt_price(): u64 { 2 }

/// Hook registration must select at least one slot.
macro public(package) fun invalid_hook_flags(): u64 { 3 }

/// Another hook is already bound to this slot.
macro public(package) fun hook_slot_taken(): u64 { 4 }

/// Ticks must be ordered, in range and multiples of the tick spacing.
macro public(package) fun invalid_tick_range(): u64 { 5 }

/// Position still holds liquidity.
macro public(package) fun position_not_empty(): u64 { 6 }

/// Pool is already running an operation in this transaction.
macro public(package) fun pool_in_operation(): u64 { 7 }

/// Value belongs to a different pool.
macro public(package) fun wrong_pool(): u64 { 8 }

/// Position does not match the request.
macro public(package) fun wrong_position(): u64 { 9 }

/// Payment must not be zero.
macro public(package) fun zero_amount(): u64 { 10 }

/// Price limit is on the wrong side of the current price or out of range.
macro public(package) fun invalid_price_limit(): u64 { 11 }

/// Liquidity must not be zero.
macro public(package) fun zero_liquidity(): u64 { 12 }

/// Position holds less liquidity than requested.
macro public(package) fun insufficient_liquidity(): u64 { 13 }

/// Witness is not the hook bound to this slot.
macro public(package) fun hook_not_bound(): u64 { 14 }

/// Hook has already approved this step.
macro public(package) fun already_approved(): u64 { 15 }

/// The bound hook has not approved this step.
macro public(package) fun missing_approval(): u64 { 16 }

/// Payment is less than the liquidity requires.
macro public(package) fun insufficient_payment(): u64 { 17 }

/// Output is below the caller's minimum.
macro public(package) fun insufficient_output(): u64 { 18 }

/// Total registered liquidity would exceed the u128 limit.
macro public(package) fun liquidity_limit(): u64 { 19 }

/// A pool's fixed or base LP fee must be a registered tier.
macro public(package) fun not_fee_tier(): u64 { 20 }

/// Dynamic maximum fee must be at least the base fee and at most 100,000 ppm.
macro public(package) fun invalid_max_fee(): u64 { 21 }

/// Dynamic fee sensitivity must be between 100,000 and 100,000,000 ppm.
macro public(package) fun invalid_sensitivity(): u64 { 22 }

/// A fee tier must be between 1 and 100,000 ppm.
macro public(package) fun invalid_fee_tier_rate(): u64 { 23 }

/// This fee tier is already registered.
macro public(package) fun fee_tier_already_exists(): u64 { 24 }

/// Hook witness must be a struct type, not a primitive or vector.
macro public(package) fun primitive_witness(): u64 { 25 }

/// Hook version must increase.
macro public(package) fun version_not_increasing(): u64 { 26 }

/// A ppm rate must be at most 1,000,000.
macro public(package) fun invalid_ppm(): u64 { 27 }

/// Magnitude does not fit the requested signed 32-bit value.
macro public(package) fun magnitude_too_large(): u64 { 28 }

/// The pending fee tier queue is full.
macro public(package) fun too_many_pending_fee_tiers(): u64 { 29 }
