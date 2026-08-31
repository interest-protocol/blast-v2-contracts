/// Venue-neutral concentrated-liquidity price and utilization invariants.
module blast_fun_migrators::migration_math;

// === Constants ===

const Q128_SHIFT: u8 = 128;
const SQRT_UPPER_BOUND_SHIFT: u8 = 96;
const BASIS_POINTS_DENOMINATOR: u64 = 10_000;
const EInvalidBps: u64 = 75;
const EInvalidMigrationSeedBalance: u64 = 79;
const EMigrationPriceDeviationExceeded: u64 = 80;
const EMigrationResidualExceeded: u64 = 81;

// === Public Functions ===

/// Derives floor(sqrt(coin_b / coin_a) * 2^64) from migration atomic units.
///
/// When Meme is coin A, the ratio is Quote/Meme. When Meme is coin B, it is
/// Meme/Quote. Display decimals never enter this calculation.
public fun sqrt_price_x64(
    meme_amount: u64,
    quote_amount: u64,
    meme_is_coin_a: bool,
): u128 {
    integer_sqrt(ratio_q128(meme_amount, quote_amount, meme_is_coin_a))
}

/// Requires an observed CLMM price to remain within a bounded price-ratio deviation.
///
/// The comparison squares the observed Q64.64 value and compares it with the
/// exact floor Q128 rational derived from the migration balances. Both products
/// remain below u256 after first rejecting deviations larger than 100%.
public fun assert_price_within_bps(
    meme_amount: u64,
    quote_amount: u64,
    meme_is_coin_a: bool,
    actual_sqrt_price_x64: u128,
    max_deviation_bps: u64,
) {
    assert_valid_bps(max_deviation_bps);

    let expected_ratio_q128 = ratio_q128(
        meme_amount,
        quote_amount,
        meme_is_coin_a,
    );
    let actual_sqrt_price_x64 = actual_sqrt_price_x64 as u256;
    let actual_ratio_q128 = actual_sqrt_price_x64 * actual_sqrt_price_x64;
    let difference = if (actual_ratio_q128 >= expected_ratio_q128) {
        actual_ratio_q128 - expected_ratio_q128
    } else {
        expected_ratio_q128 - actual_ratio_q128
    };

    assert!(
        difference <= expected_ratio_q128
            && difference * (BASIS_POINTS_DENOMINATOR as u256)
                <= expected_ratio_q128 * (max_deviation_bps as u256),
        EMigrationPriceDeviationExceeded,
    );
}

/// Returns the minimum venue-consumed amount after a ceiling-rounded residual allowance.
public fun minimum_utilized_amount(amount: u64, max_residual_bps: u64): u64 {
    amount - maximum_residual_amount(amount, max_residual_bps)
}

/// Rejects a returned venue residual above the ceiling-rounded allowance.
public fun assert_residual_within_bps(
    source_amount: u64,
    residual_amount: u64,
    max_residual_bps: u64,
) {
    assert!(
        residual_amount <= maximum_residual_amount(source_amount, max_residual_bps),
        EMigrationResidualExceeded,
    );
}

// === Private Functions ===

fun ratio_q128(
    meme_amount: u64,
    quote_amount: u64,
    meme_is_coin_a: bool,
): u256 {
    assert!(
        meme_amount > 0 && quote_amount > 0,
        EInvalidMigrationSeedBalance,
    );

    let (numerator, denominator) = if (meme_is_coin_a) {
        (quote_amount, meme_amount)
    } else {
        (meme_amount, quote_amount)
    };

    ((numerator as u256) << Q128_SHIFT) / (denominator as u256)
}

/// Uses a fixed 96-step upper bound because a positive u64/u64 Q128 ratio is below 2^192.
fun integer_sqrt(value: u256): u128 {
    let mut low = 0u256;
    let mut high = 1u256 << SQRT_UPPER_BOUND_SHIFT;

    while (low + 1 < high) {
        let middle = (low + high) / 2;

        if (middle * middle <= value) {
            low = middle;
        } else {
            high = middle;
        };
    };

    low as u128
}

fun maximum_residual_amount(amount: u64, max_residual_bps: u64): u64 {
    assert_valid_bps(max_residual_bps);

    let numerator = (amount as u128) * (max_residual_bps as u128);
    let denominator = BASIS_POINTS_DENOMINATOR as u128;

    ((numerator + denominator - 1) / denominator) as u64
}

fun assert_valid_bps(value: u64) {
    assert!(
        value <= BASIS_POINTS_DENOMINATOR,
        EInvalidBps,
    );
}
