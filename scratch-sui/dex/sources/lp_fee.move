// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// A pool's LP fee settings and the fee each swap pays under them.
///
/// The settings are chosen when the pool is created and never change; hooks
/// cannot set or override them. Fixed fees use one rate. Dynamic fees charge
/// a marginal rate along the fill, using price bands fixed by the reference.
/// The rate rises with the squared price gap up to the configured maximum.
module blast_fun_dex::lp_fee;

// === Constants ===

/// Fee tiers a fixed fee or a dynamic base fee must use: 0.1%, 0.3%, 1% and 2%.
const FEE_TIERS_PPM: vector<u32> = vector[1_000, 3_000, 10_000, 20_000];
/// Highest maximum a dynamic fee may set: 10%.
const MAX_DYNAMIC_FEE_PPM: u32 = 100_000;
/// Sensitivity bounds, in ppm of fee per unit of squared price gap.
const MIN_SENSITIVITY_PPM: u32 = 100_000;
const MAX_SENSITIVITY_PPM: u32 = 100_000_000;
const PPM_DENOMINATOR: u64 = 1_000_000;
const BANDS_PER_SIDE: u256 = 512;
const ONE_X32: u128 = 1 << 32;
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

/// The fee schedule with its reference fixed for one fill.
public struct FeePath has drop {
    settings: LpFee,
    reference_x96: u256,
    upper_width_x96: u256,
    lower_width_x96: u256,
}

/// A constant-rate segment clipped to the curve's range or price limit.
public struct FeeStep has drop {
    limit_x96: u256,
    rate_ppm: u32,
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

/// The marginal rate at a price, before the curve selects the outer edge of
/// its fee band. A fixed fee ignores both prices. A dynamic fee is
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

/// Freeze the reference and construct a grid on each side out to the cap.
public(package) fun new_fee_path(settings: LpFee, reference_x96: u256): FeePath {
    let headroom = (settings.max_fee_ppm() - settings.base_fee_ppm()) as u128;
    let (upper_width_x96, lower_width_x96) = if (headroom == 0) {
        (0, 0)
    } else {
        // Validated settings give cap_gap < 1, so both sides have a positive price.
        let sensitivity = settings.sensitivity_ppm() as u128;
        let gap_x32 = sqrt_up((headroom << 64).div_ceil(sensitivity));
        let upper_x32 = sqrt_up((ONE_X32 + gap_x32) << 32) - ONE_X32;
        let lower_x32 = ONE_X32 - ((ONE_X32 - gap_x32) << 32).sqrt();
        let scale = (ONE_X32 as u256) * BANDS_PER_SIDE;
        (
            (reference_x96 * (upper_x32 as u256)).div_ceil(scale),
            (reference_x96 * (lower_x32 as u256)).div_ceil(scale),
        )
    };
    FeePath { settings, reference_x96, upper_width_x96, lower_width_x96 }
}

// The curve stub does not walk these steps yet. The fee harness exercises them.
#[allow(unused_function)]
/// The curve supplies the nearer of the next initialized tick and the user's
/// limit. An additional split inside this segment always uses the same rate.
public(package) fun next_step(self: &FeePath, start_x96: u256, curve_limit_x96: u256): FeeStep {
    if (self.upper_width_x96 == 0) {
        return FeeStep { limit_x96: curve_limit_x96, rate_ppm: self.settings.base_fee_ppm() }
    };

    let reference_x96 = self.reference_x96;
    let up = curve_limit_x96 > start_x96;
    let above = start_x96 > reference_x96 || (start_x96 == reference_x96 && up);
    let away = above == up;
    let width = if (above) self.upper_width_x96 else self.lower_width_x96;
    let distance = start_x96.diff(reference_x96);
    let band = if (away) distance / width + 1 else distance.div_ceil(width);
    let max_rate = self.settings.max_fee_ppm();
    if (band > BANDS_PER_SIDE) {
        let boundary_x96 = price_at_distance(reference_x96, BANDS_PER_SIDE * width, above);
        let limit_x96 = if (away) curve_limit_x96 else clip_limit(curve_limit_x96, boundary_x96, up);
        return FeeStep { limit_x96, rate_ppm: max_rate }
    };

    let edge = if (away) band else band - 1;
    let boundary_x96 = price_at_distance(reference_x96, edge * width, above);
    let limit_x96 = clip_limit(curve_limit_x96, boundary_x96, up);
    let rate_ppm = if (band == BANDS_PER_SIDE) max_rate else {
        let outer_x96 = price_at_distance(reference_x96, band * width, above);
        self.settings.fee_ppm_at_price(reference_x96, outer_x96)
    };
    FeeStep { limit_x96, rate_ppm }
}

#[allow(unused_function)]
public(package) fun limit_x96(self: &FeeStep): u256 { self.limit_x96 }

#[allow(unused_function)]
/// Maximum net input affordable at this step's rate.
public(package) fun net_budget_down(self: &FeeStep, gross_budget: u64): u64 {
    let rate = self.rate_ppm as u64;

    gross_budget.mul_div(PPM_DENOMINATOR - rate, PPM_DENOMINATOR)
}

#[allow(unused_function)]
/// Fee on net input, rounded up. The curve rounds the net input delta up
/// and checks it against its net budget before adding this fee.
public(package) fun fee_up(self: &FeeStep, net_input: u64): u64 {
    let rate = self.rate_ppm as u64;
    net_input.mul_div_ceil(rate, PPM_DENOMINATOR - rate)
}

// === Private Functions ===

fun sqrt_up(value: u128): u128 { (value - 1).sqrt() + 1 }

fun price_at_distance(reference_x96: u256, distance_x96: u256, above: bool): u256 {
    if (above) reference_x96 + distance_x96 else reference_x96 - distance_x96
}

fun clip_limit(curve_limit_x96: u256, boundary_x96: u256, up: bool): u256 {
    if (up) curve_limit_x96.min(boundary_x96) else curve_limit_x96.max(boundary_x96)
}

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
