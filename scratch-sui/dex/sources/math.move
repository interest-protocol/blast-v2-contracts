// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Quote-denominated integrated fees and conservative constant-product accounting.
module blast_fun_dex::math;

// === Constants ===

const X32: u256 = 4_294_967_296;
const X64: u256 = 18_446_744_073_709_551_616;
/// ceil(2^64 * 2^(-1/1800)), generated with 110 decimal digits of precision.
const DECAY_SECOND_X64: u256 = 18_439_641_936_446_208_054;
const HALF_LIFE_SECONDS: u64 = 1800;
const IDLE_RESET_SECONDS: u64 = 129 * 1800;
const MAX_FEE_BPS: u64 = 500;

// === Errors ===

#[error(code = 0)]
const EZeroTarget: vector<u8> = b"Fee volume target must be positive.";
#[error(code = 1)]
const EFeeCap: vector<u8> = b"Maximum fee must not exceed 500 basis points.";
#[error(code = 2)]
const EVolumeCap: vector<u8> = b"Volume score must not exceed the target in Q32 units.";
#[error(code = 3)]
const EShareOverflow: vector<u8> = b"Deposit must keep total shares within u128.";

// === Package Functions ===

/// Integral of the capped linear fee ramp, rounded up once to a Quote atom.
/// Intermediates use at most 203 bits for full-width u64 target and principal.
public(package) fun fee_up(volume_x32: u128, target: u64, quote: u64, max_bps: u64): u64 {
    assert!(target > 0, EZeroTarget);
    assert!(max_bps <= MAX_FEE_BPS, EFeeCap);
    assert!((volume_x32 as u256) <= (target as u256) * X32, EVolumeCap);

    let cap = (target as u256) * X32;
    let volume = volume_x32 as u256;
    let input = (quote as u256) * X32;
    let ramp_input = input.min(cap - volume);
    let integral = ramp_input * (2 * volume + ramp_input) + 2 * cap * (input - ramp_input);
    // Fee <= ceil(quote / 20), so this narrowing always fits u64.
    ((integral * (max_bps as u256)).div_ceil(2 * cap * X32 * 10_000) as u64)
}

/// Maximal principal whose principal plus rounded fee fits gross; refunds dust.
/// Upper-midpoint binary search performs at most 64 iterations for u64 gross.
public(package) fun buy_principal(
    volume_x32: u128,
    target: u64,
    gross: u64,
    max_bps: u64,
): (u64, u64, u64) {
    // Validate even an empty or zero-fee purchase.
    let _ = fee_up(volume_x32, target, 0, max_bps);
    if (max_bps == 0) return (gross, 0, 0);

    let mut low = 0;
    let mut high = gross;
    while (low < high) {
        let mid = low + (high - low) / 2 + (high - low) % 2;
        let fee = fee_up(volume_x32, target, mid, max_bps);
        if ((mid as u128) + (fee as u128) <= (gross as u128)) {
            low = mid;
        } else {
            high = mid - 1;
        };
    };
    let fee = fee_up(volume_x32, target, low, max_bps);
    (low, fee, gross - low - fee)
}

/// Half-life decay in Q32 score units. Whole half-lives are exact; fractional
/// seconds use upward Q64 products, then one final floor loses <1 Q32 unit.
/// Fractional factor excess is <3600/2^64; it is not a one-unit absolute bound
/// on the resulting score. Exact half-lives avoid a Q64 long-tail plateau.
public(package) fun decay(volume_x32: u128, elapsed_seconds: u64): u128 {
    if (elapsed_seconds == 0) return volume_x32;
    if (elapsed_seconds >= IDLE_RESET_SECONDS) return 0;

    let half_lives = elapsed_seconds / HALF_LIFE_SECONDS;
    // Every admitted score is <2^96; even arbitrary u128 scores vanish at 128.
    if (half_lives >= 128) return 0;
    let mut seconds = elapsed_seconds % HALF_LIFE_SECONDS;
    let mut base = DECAY_SECOND_X64;
    let mut factor = X64;
    while (seconds > 0) {
        if (seconds % 2 == 1) factor = (factor * base).div_ceil(X64);
        seconds = seconds / 2;
        if (seconds > 0) base = (base * base).div_ceil(X64);
    };
    // At most 192 numerator bits and 191 denominator bits for u128 inputs.
    (((volume_x32 as u256) * factor / (X64 << (half_lives as u8))) as u128)
}

/// Adds the exact Quote principal leg and saturates at the target score.
public(package) fun next_volume(volume_x32: u128, target: u64, quote: u64): u128 {
    assert!(target > 0, EZeroTarget);
    let cap = (target as u256) * X32;
    assert!((volume_x32 as u256) <= cap, EVolumeCap);

    (((volume_x32 as u256) + (quote as u256) * X32).min(cap) as u128)
}

/// Constant-product output rounds down, retaining the remainder in reserves.
/// Caller owns positive input/reserves and nonzero output validation.
public(package) fun amount_out(input: u64, reserve_in: u64, reserve_out: u64): u64 {
    (((input as u256) * (reserve_out as u256) / ((reserve_in as u256) + (input as u256))) as u64)
}

/// Initial LP supply is the floor square root of the reserve product.
public(package) fun initial_shares(meme: u64, quote: u64): u128 {
    ((meme as u128) * (quote as u128)).sqrt()
}

/// Mints against the limiting side, rounding both actual contributions up.
/// Caller owns positive reserves, supply, and minted shares; unused maxima refund.
public(package) fun deposit_amounts(
    meme_max: u64,
    quote_max: u64,
    meme_reserve: u64,
    quote_reserve: u64,
    total_shares: u128,
): (u64, u64, u128) {
    let supply = total_shares as u256;
    let shares = ((meme_max as u256) * supply / (meme_reserve as u256)).min(
        (quote_max as u256) * supply / (quote_reserve as u256),
    );
    assert!(shares + supply <= (std::u128::max_value!() as u256), EShareOverflow);

    let meme = (shares * (meme_reserve as u256)).div_ceil(supply);
    let quote = (shares * (quote_reserve as u256)).div_ceil(supply);
    // Each rounded contribution is <= its u64 input maximum by construction.
    (meme as u64, quote as u64, shares as u128)
}
