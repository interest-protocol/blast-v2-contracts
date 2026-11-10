// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// The abort lint sees the shared error macros as numeric literals after expansion.
#[allow(lint(abort_without_constant))]
/// A pool's LP fee settings and the marginal rate along the swap path.
///
/// Pools store a fixed tier or a bounded quadratic schedule at creation.
/// Dynamic rates use price bands anchored to a pool-local reference. Tier
/// additions affect future pool creation.
module blast_fun_dex::lp_fee;

// === Constants ===

const DEFAULT_FEE_TIERS_PPM: vector<u32> = vector[1_000, 3_000, 10_000, 20_000];
const FEE_TIER_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;
/// Pending entries are stored inline in the registry.
const MAX_PENDING_FEE_TIERS: u64 = 32;
/// Upper bound for a registered tier and for a pool's dynamic maximum: 10%.
const MAX_LP_FEE_PPM: u32 = 100_000;
/// Sensitivity bounds, in ppm of fee per unit of squared price gap.
const MIN_SENSITIVITY_PPM: u32 = 100_000;
const MAX_SENSITIVITY_PPM: u32 = 100_000_000;
const BANDS_PER_SIDE: u256 = 512;
const ONE_X32: u128 = 1 << 32;
/// 1.0 in Q128.
const ONE_X128: u256 = 340_282_366_920_938_463_463_374_607_431_768_211_456;
/// Square-root price ratio 512 in Q64 (2^73): a price gap of 262,143, where a
/// sensitivity of 1 ppm already adds more than 100%.
const MAX_SQRT_PRICE_RATIO_X64: u256 = 9_444_732_965_739_290_427_392;

// === Public Types ===

/// A pool's LP fee settings, validated at construction.
public enum LpFee has copy, drop, store {
    /// Charges `fee_ppm`, a fee tier, on every swap.
    Fixed { fee_ppm: Ppm },
    /// Charges `base_fee_ppm`, a fee tier, plus a surcharge of `sensitivity_ppm`
    /// times the squared price gap, up to `max_fee_ppm`.
    Dynamic { base_fee_ppm: Ppm, max_fee_ppm: Ppm, sensitivity_ppm: u32 },
}

/// The shared set of rates allowed for fixed and base fees. Entries are permanent.
public struct BlastDexFeeTiers has key {
    id: UID,
    additions: DelayedMap<FeeTierKey, u32, bool>,
}

/// Keys the delayed admission of a new LP fee tier.
public struct FeeTierKey() has copy, drop, store;

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
    rate: Ppm,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new_fee_tiers(ctx));
}

// === Public Functions ===

/// Whether a new pool can use this rate as its fixed or base fee.
public fun is_fee_tier(self: &BlastDexFeeTiers, fee_ppm: u32): bool {
    let default_rates = DEFAULT_FEE_TIERS_PPM;
    default_rates.contains(&fee_ppm) || self.additions.contains(&fee_ppm)
}

/// Proposes a distinct tier between 1 and 100,000 ppm, inclusive, and returns its
/// deadline. Rescheduling the same tier restarts its 48-hour wait.
public fun schedule_fee_tier(
    self: &mut BlastDexFeeTiers,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    _: &AdminWitness<BlastDexFeeTierAdmin>,
    fee_ppm: u32,
    clock: &Clock,
): u64 {
    package_version.assert_current(constants::version!());

    assert!(fee_ppm > 0 && fee_ppm <= MAX_LP_FEE_PPM, blast_fun_dex::errors::invalid_fee_tier_rate!());
    assert!(!self.is_fee_tier(fee_ppm), blast_fun_dex::errors::fee_tier_already_exists!());
    assert!(
        self.additions.pending_count() < MAX_PENDING_FEE_TIERS || self.additions.is_pending(&fee_ppm),
        blast_fun_dex::errors::too_many_pending_fee_tiers!(),
    );

    self.additions.schedule(fee_ppm, option::some(true), clock)
}

/// Permissionlessly registers the proposed tier at or after its deadline.
public fun apply_fee_tier(
    self: &mut BlastDexFeeTiers,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    fee_ppm: u32,
    clock: &Clock,
) {
    package_version.assert_current(constants::version!());

    self.additions.apply(fee_ppm, clock);
    blast_events::fee_tier_added(fee_ppm);
}

/// Cancels the pending tier, including once it is ready.
public fun cancel_fee_tier(
    self: &mut BlastDexFeeTiers,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    _: &AdminWitness<CancelAdmin<BLAST_FUN_DEX>>,
    fee_ppm: u32,
) {
    package_version.assert_current(constants::version!());

    self.additions.cancel(fee_ppm);
}

public fun is_dynamic(self: &LpFee): bool {
    match (self) {
        LpFee::Fixed { .. } => false,
        LpFee::Dynamic { .. } => true,
    }
}

/// The fee at a zero price gap: the fixed fee, or the dynamic base fee.
public fun base_fee_ppm(self: &LpFee): u32 {
    self.base_fee().value()
}

/// The highest fee a swap can pay: the fixed fee, or the dynamic maximum.
public fun max_fee_ppm(self: &LpFee): u32 {
    self.max_fee().value()
}

/// Fee ppm per unit of squared price gap. Fixed fees return `none`.
public fun sensitivity_ppm(self: &LpFee): Option<u32> {
    match (*self) {
        LpFee::Fixed { .. } => option::none(),
        LpFee::Dynamic { sensitivity_ppm, .. } => option::some(sensitivity_ppm),
    }
}

// === Package Functions ===

public(package) fun new_fixed(tiers: &BlastDexFeeTiers, fee_ppm: u32): LpFee {
    assert!(tiers.is_fee_tier(fee_ppm), blast_fun_dex::errors::not_fee_tier!());

    LpFee::Fixed { fee_ppm: ppm::new(fee_ppm) }
}

/// `base_fee_ppm` must be a fee tier, `max_fee_ppm` between it and 100,000 ppm,
/// and `sensitivity_ppm` between 100,000 and 100,000,000 ppm.
public(package) fun new_dynamic(
    tiers: &BlastDexFeeTiers,
    base_fee_ppm: u32,
    max_fee_ppm: u32,
    sensitivity_ppm: u32,
): LpFee {
    assert!(tiers.is_fee_tier(base_fee_ppm), blast_fun_dex::errors::not_fee_tier!());
    assert!(
        max_fee_ppm >= base_fee_ppm && max_fee_ppm <= MAX_LP_FEE_PPM,
        blast_fun_dex::errors::invalid_max_fee!(),
    );
    assert!(
        sensitivity_ppm >= MIN_SENSITIVITY_PPM && sensitivity_ppm <= MAX_SENSITIVITY_PPM,
        blast_fun_dex::errors::invalid_sensitivity!(),
    );

    LpFee::Dynamic {
        base_fee_ppm: ppm::new(base_fee_ppm),
        max_fee_ppm: ppm::new(max_fee_ppm),
        sensitivity_ppm,
    }
}

/// The marginal rate at a price, sampled at the outer edge of a fee band.
/// A fixed fee ignores both prices. A dynamic fee is
///
/// ```text
/// gap = abs(price_at_band_edge - reference_price) / reference_price
/// fee = min(max_fee, base_fee + floor(sensitivity * gap^2))
/// ```
///
/// Prices are the squares of the square-root prices. The exact formula treats
/// equal gaps above and below the reference alike. This table illustrates the
/// formula using a hypothetical base of 2,000 ppm, sensitivity of 1,000,000
/// and maximum of 10,000 ppm.
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
/// The calculation is safe for in-range Q64.96 square-root prices. The gap
/// rounds down by at most (2 * r + 2) / 2^64 for an unclamped square-root price
/// ratio r. With valid settings the fee equals the exact integer fee or falls
/// short by one ppm. A gap of 262,143 already reaches the maximum, so the
/// ratio is clamped at 512.
public(package) fun fee_at_price(
    self: &LpFee,
    reference_sqrt_price_x96: u256,
    sqrt_price_x96: u256,
): Ppm {
    match (*self) {
        LpFee::Fixed { fee_ppm } => fee_ppm,
        LpFee::Dynamic { base_fee_ppm, max_fee_ppm, sensitivity_ppm } => {
            let gap_x64 = price_gap_x64_down(reference_sqrt_price_x96, sqrt_price_x96);
            // At most 2^32 * (2^82)^2 = 2^196, then clamped to the validated maximum.
            let extra_fee_ppm = ((sensitivity_ppm as u256) * gap_x64 * gap_x64) >> 128;
            let fee_ppm = (base_fee_ppm.value() as u256) + extra_fee_ppm;

            ppm::new(fee_ppm.min(max_fee_ppm.value() as u256) as u32)
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
        let sensitivity = settings.sensitivity_ppm().destroy_some() as u128;
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
        return FeeStep { limit_x96: curve_limit_x96, rate: self.settings.base_fee() }
    };

    let reference_x96 = self.reference_x96;
    let up = curve_limit_x96 > start_x96;
    let above = start_x96 > reference_x96 || (start_x96 == reference_x96 && up);
    let away = above == up;
    let width = if (above) self.upper_width_x96 else self.lower_width_x96;
    let distance = start_x96.diff(reference_x96);
    let band = if (away) distance / width + 1 else distance.div_ceil(width);
    let max_rate = self.settings.max_fee();
    if (band > BANDS_PER_SIDE) {
        let boundary_x96 = price_at_distance(reference_x96, BANDS_PER_SIDE * width, above);
        let limit_x96 = if (away) curve_limit_x96 else clip_limit(curve_limit_x96, boundary_x96, up);
        return FeeStep { limit_x96, rate: max_rate }
    };

    let edge = if (away) band else band - 1;
    let boundary_x96 = price_at_distance(reference_x96, edge * width, above);
    let limit_x96 = clip_limit(curve_limit_x96, boundary_x96, up);
    let rate = if (band == BANDS_PER_SIDE) max_rate else {
        let outer_x96 = price_at_distance(reference_x96, band * width, above);
        self.settings.fee_at_price(reference_x96, outer_x96)
    };
    FeeStep { limit_x96, rate }
}

#[allow(unused_function)]
public(package) fun limit_x96(self: &FeeStep): u256 { self.limit_x96 }

#[allow(unused_function)]
/// Maximum net input affordable at this step's rate.
public(package) fun net_budget_down(self: &FeeStep, gross_budget: u64): u64 {
    let rate = self.rate.value() as u64;
    let denominator = ppm::denominator() as u64;

    gross_budget.mul_div(denominator - rate, denominator)
}

#[allow(unused_function)]
/// Fee on net input, rounded up. The curve rounds the net input delta up
/// and checks it against its net budget before adding this fee.
public(package) fun fee_up(self: &FeeStep, net_input: u64): u64 {
    let rate = self.rate.value() as u64;
    let denominator = ppm::denominator() as u64;

    net_input.mul_div_ceil(rate, denominator - rate)
}

// === Private Functions ===

fun new_fee_tiers(ctx: &mut TxContext): BlastDexFeeTiers {
    let id = object::new(ctx);
    let additions = delayed_map::new(FeeTierKey(), &id, FEE_TIER_DELAY_MS, ctx);
    BlastDexFeeTiers { id, additions }
}

fun base_fee(self: &LpFee): Ppm {
    match (*self) {
        LpFee::Fixed { fee_ppm } => fee_ppm,
        LpFee::Dynamic { base_fee_ppm, .. } => base_fee_ppm,
    }
}

fun max_fee(self: &LpFee): Ppm {
    match (*self) {
        LpFee::Fixed { fee_ppm } => fee_ppm,
        LpFee::Dynamic { max_fee_ppm, .. } => max_fee_ppm,
    }
}

fun sqrt_up(value: u128): u128 { (value - 1).sqrt() + 1 }

fun price_at_distance(reference_x96: u256, distance_x96: u256, above: bool): u256 {
    if (above) reference_x96 + distance_x96 else reference_x96 - distance_x96
}

fun clip_limit(curve_limit_x96: u256, boundary_x96: u256, up: bool): u256 {
    if (up) curve_limit_x96.min(boundary_x96) else curve_limit_x96.max(boundary_x96)
}

/// abs(projected^2 - reference^2) / reference^2 in Q64, rounded down, from the
/// square-root price ratio in Q64. Above the reference the ratio rounds down
/// and is clamped at 512; below it the ratio rounds up, so both sides
/// underestimate the gap. Shifting a sqrt price below 2^161 by 64 bits and
/// squaring a ratio of at most 2^73 both fit in u256.
fun price_gap_x64_down(reference_sqrt_price_x96: u256, sqrt_price_x96: u256): u256 {
    if (sqrt_price_x96 >= reference_sqrt_price_x96) {
        let ratio_x64 = ((sqrt_price_x96 << 64) / reference_sqrt_price_x96).min(MAX_SQRT_PRICE_RATIO_X64);
        (ratio_x64 * ratio_x64 - ONE_X128) >> 64
    } else {
        let ratio_x64 = (sqrt_price_x96 << 64).div_ceil(reference_sqrt_price_x96);
        (ONE_X128 - ratio_x64 * ratio_x64) >> 64
    }
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_fee_tiers_for_testing(ctx: &mut TxContext): BlastDexFeeTiers {
    new_fee_tiers(ctx)
}

#[test_only]
public fun destroy_default_fee_tiers_for_testing(self: BlastDexFeeTiers) {
    let BlastDexFeeTiers { id, additions } = self;
    additions.destroy();
    id.delete();
}

/// Bypasses LP policy bounds while keeping both rates valid ppm values.
#[test_only]
public fun new_dynamic_unchecked_for_testing(base_fee_ppm: u32, max_fee_ppm: u32, sensitivity_ppm: u32): LpFee {
    LpFee::Dynamic {
        base_fee_ppm: ppm::new(base_fee_ppm),
        max_fee_ppm: ppm::new(max_fee_ppm),
        sensitivity_ppm,
    }
}

// === Imports ===

use blast_admin::{
    blast_acl::AdminWitness,
    delayed_map::{Self, DelayedMap},
    package_admin::CancelAdmin,
    package_version::PackageVersion,
};
use blast_fun_dex::{
    blast_events,
    blast_fun_dex::BLAST_FUN_DEX,
    blast_fun_dex_domain::BlastDexFeeTierAdmin,
    constants,
    ppm::{Self, Ppm},
};
use sui::clock::Clock;
