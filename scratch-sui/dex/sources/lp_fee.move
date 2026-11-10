// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// A pool's LP fee settings and the fee each swap pays under them.
///
/// The settings are chosen when the pool is created and never change; hooks
/// cannot set or override them. A fixed-fee pool charges one protocol fee tier
/// on every swap. A dynamic-fee pool charges its base fee plus a surcharge that
/// grows with the square of the gap between the swap's projected price and a
/// reference price, up to its maximum. The reference is the pool's own
/// time-weighted price, moved by `moved_reference_sqrt_price_x96`. Fees are in
/// parts per million; 1,000,000 is 100%. The tiers, bounds and window below are
/// placeholders the protocol will tune.
module blast_fun_dex::lp_fee;

// === Constants ===

/// Fee tiers a fixed fee or a dynamic base fee must use: 0.1%, 0.3%, 1% and 2%.
const FEE_TIERS_PPM: vector<u32> = vector[1_000, 3_000, 10_000, 20_000];
/// Highest maximum a dynamic fee may set: 10%.
const MAX_DYNAMIC_FEE_PPM: u32 = 100_000;
/// Sensitivity bounds, in ppm of fee per unit of squared price gap.
const MIN_SENSITIVITY_PPM: u32 = 100_000;
const MAX_SENSITIVITY_PPM: u32 = 100_000_000;
/// Time over which the reference price catches up with the pool's price: 10 minutes.
const REFERENCE_WINDOW_MS: u64 = 600_000;
/// 1.0 in Q128.
const ONE_X128: u256 = 340_282_366_920_938_463_463_374_607_431_768_211_456;
/// Square-root price ratio 512 in Q64 (2^73): a price gap of 262,143, where a
/// sensitivity of 1 ppm already adds more than any u32 maximum.
const MAX_SQRT_PRICE_RATIO_X64: u256 = 9_444_732_965_739_290_427_392;

// === Public Types ===

/// A pool's LP fee settings, validated at construction.
public enum LpFee has copy, drop, store {
    /// Charges `fee_ppm`, a fee tier, on every swap.
    Fixed { fee_ppm: u32 },
    /// Charges `base_fee_ppm`, a fee tier, plus a surcharge of `sensitivity_ppm`
    /// times the squared price gap, up to `max_fee_ppm`.
    Dynamic { base_fee_ppm: u32, max_fee_ppm: u32, sensitivity_ppm: u32 },
}

// === Public Functions ===

public fun is_dynamic(self: &LpFee): bool {
    match (self) {
        LpFee::Fixed { .. } => false,
        LpFee::Dynamic { .. } => true,
    }
}

/// The fee at a zero price gap: the fixed fee, or the dynamic base fee.
public fun base_fee_ppm(self: &LpFee): u32 {
    match (*self) {
        LpFee::Fixed { fee_ppm } => fee_ppm,
        LpFee::Dynamic { base_fee_ppm, .. } => base_fee_ppm,
    }
}

/// The highest fee a swap can pay: the fixed fee, or the dynamic maximum.
public fun max_fee_ppm(self: &LpFee): u32 {
    match (*self) {
        LpFee::Fixed { fee_ppm } => fee_ppm,
        LpFee::Dynamic { max_fee_ppm, .. } => max_fee_ppm,
    }
}

/// Fee ppm per unit of squared price gap; zero for a fixed fee.
public fun sensitivity_ppm(self: &LpFee): u32 {
    match (*self) {
        LpFee::Fixed { .. } => 0,
        LpFee::Dynamic { sensitivity_ppm, .. } => sensitivity_ppm,
    }
}

// === Package Functions ===

public(package) fun new_fixed(fee_ppm: u32): LpFee {
    assert!(is_fee_tier(fee_ppm), ENotFeeTier);

    LpFee::Fixed { fee_ppm }
}

/// `base_fee_ppm` must be a fee tier, `max_fee_ppm` between it and 100,000 ppm,
/// and `sensitivity_ppm` between 100,000 and 100,000,000 ppm.
public(package) fun new_dynamic(base_fee_ppm: u32, max_fee_ppm: u32, sensitivity_ppm: u32): LpFee {
    assert!(is_fee_tier(base_fee_ppm), ENotFeeTier);
    assert!(max_fee_ppm >= base_fee_ppm && max_fee_ppm <= MAX_DYNAMIC_FEE_PPM, EInvalidMaxFee);
    assert!(
        sensitivity_ppm >= MIN_SENSITIVITY_PPM && sensitivity_ppm <= MAX_SENSITIVITY_PPM,
        EInvalidSensitivity,
    );

    LpFee::Dynamic { base_fee_ppm, max_fee_ppm, sensitivity_ppm }
}

/// The fee for a swap that moves the price from the reference to the projected
/// price. A fixed fee ignores both prices. A dynamic fee is
///
/// ```text
/// gap = abs(projected_price - reference_price) / reference_price
/// fee = min(max_fee, base_fee + floor(sensitivity * gap^2))
/// ```
///
/// with prices the squares of the square-root prices, so the same gap above or
/// below the reference pays the same fee. With base 2,000, sensitivity
/// 1,000,000 and maximum 10,000 ppm:
///
/// ```text
/// Price gap    Extra fee    Total fee
///    0%           0 bps       20 bps
///    2%           4 bps       24 bps
///    4%          16 bps       36 bps
///    8%          64 bps       84 bps
///   10%         100 bps      100 bps (capped)
/// ```
///
/// Both prices must be in-range Q64.96 square-root prices; then the result
/// never aborts. Every step rounds the gap down, so the fee never exceeds the
/// exact formula. The gap carries at most (2 * ratio + 1) / 2^64 error, where
/// ratio is the square-root price ratio; for valid settings below the maximum
/// that moves the surcharge by under 1e-10 ppm, so the fee is the exact floor,
/// or one ppm less only when the exact value lies within that error above a
/// whole ppm. Gaps beyond 262,143 are clamped, where any nonzero sensitivity
/// already reaches any maximum.
public(package) fun fee_ppm_at_price(
    self: &LpFee,
    reference_sqrt_price_x96: u256,
    projected_sqrt_price_x96: u256,
): u32 {
    match (*self) {
        LpFee::Fixed { fee_ppm } => fee_ppm,
        LpFee::Dynamic { base_fee_ppm, max_fee_ppm, sensitivity_ppm } => {
            let gap_x64 = price_gap_x64_down(reference_sqrt_price_x96, projected_sqrt_price_x96);
            // At most 2^32 * (2^82)^2 = 2^196, then narrowed below `max_fee_ppm`.
            let extra_fee_ppm = ((sensitivity_ppm as u256) * gap_x64 * gap_x64) >> 128;

            ((base_fee_ppm as u256) + extra_fee_ppm).min(max_fee_ppm as u256) as u32
        },
    }
}

/// The reference square-root price after `elapsed_ms` at the pool's
/// square-root price: it moves `elapsed_ms / 600,000` of the way toward the pool
/// price, and lands exactly on it once a full window has passed. The step is
/// rounded down, toward the old reference, so it never overshoots. The product
/// of a price gap below 2^161 and an elapsed time below the window fits in u256.
public(package) fun moved_reference_sqrt_price_x96(
    reference_sqrt_price_x96: u256,
    pool_sqrt_price_x96: u256,
    elapsed_ms: u64,
): u256 {
    if (elapsed_ms >= REFERENCE_WINDOW_MS) return pool_sqrt_price_x96;

    let step_x96 =
        reference_sqrt_price_x96.diff(pool_sqrt_price_x96) * (elapsed_ms as u256) / (REFERENCE_WINDOW_MS as u256);
    if (pool_sqrt_price_x96 >= reference_sqrt_price_x96) reference_sqrt_price_x96 + step_x96
    else reference_sqrt_price_x96 - step_x96
}

// === Private Functions ===

fun is_fee_tier(fee_ppm: u32): bool {
    let fee_tiers_ppm = FEE_TIERS_PPM;

    fee_tiers_ppm.contains(&fee_ppm)
}

/// abs(projected^2 - reference^2) / reference^2 in Q64, rounded down, from the
/// square-root price ratio in Q64. Above the reference the ratio rounds down
/// and is clamped at 512; below it the ratio rounds up, so both sides
/// underestimate the gap. Shifting a sqrt price below 2^161 by 64 bits and
/// squaring a ratio of at most 2^73 both fit in u256.
fun price_gap_x64_down(reference_sqrt_price_x96: u256, projected_sqrt_price_x96: u256): u256 {
    if (projected_sqrt_price_x96 >= reference_sqrt_price_x96) {
        let ratio_x64 = ((projected_sqrt_price_x96 << 64) / reference_sqrt_price_x96).min(MAX_SQRT_PRICE_RATIO_X64);
        (ratio_x64 * ratio_x64 - ONE_X128) >> 64
    } else {
        let ratio_x64 = (projected_sqrt_price_x96 << 64).div_ceil(reference_sqrt_price_x96);
        (ONE_X128 - ratio_x64 * ratio_x64) >> 64
    }
}

// === Test-Only Functions ===

/// Dynamic settings without validation, for exercising the calculation alone.
#[test_only]
public fun new_dynamic_unchecked_for_testing(base_fee_ppm: u32, max_fee_ppm: u32, sensitivity_ppm: u32): LpFee {
    LpFee::Dynamic { base_fee_ppm, max_fee_ppm, sensitivity_ppm }
}

// === Errors ===

#[error(code = 0)]
const ENotFeeTier: vector<u8> = b"LP fee must be 1,000, 3,000, 10,000 or 20,000 ppm.";
#[error(code = 1)]
const EInvalidMaxFee: vector<u8> = b"Dynamic maximum fee must be at least the base fee and at most 100,000 ppm.";
#[error(code = 2)]
const EInvalidSensitivity: vector<u8> = b"Dynamic fee sensitivity must be between 100,000 and 100,000,000 ppm.";
