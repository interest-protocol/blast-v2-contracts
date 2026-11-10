// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_dex::lp_fee_tests;

// === Constants ===

/// Price 1.0 in Q64.96, the reference in every gap test.
const SQRT_PRICE_ONE_X96: u256 = 79_228_162_514_264_337_593_543_950_336;
const MIN_SQRT_PRICE_X96: u256 = 4_295_128_739;
const MAX_SQRT_PRICE_X96: u256 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
/// Square-root prices for price 1.0 plus or minus each gap, moved a further 1e-12
/// away from 1.0 so the downward rounding cannot shrink the gap below its row.
const PRICE_UP_1_PERCENT_X96: u256 = 79_623_317_895_870_331_994_746_477_655;
const PRICE_UP_2_PERCENT_X96: u256 = 80_016_521_857_055_818_174_744_290_778;
const PRICE_UP_4_PERCENT_X96: u256 = 80_797_189_337_305_695_018_359_337_904;
const PRICE_UP_8_PERCENT_X96: u256 = 82_336_321_719_055_997_228_953_866_587;
const PRICE_UP_10_PERCENT_X96: u256 = 83_095_197_869_260_928_440_546_288_933;
const PRICE_DOWN_1_PERCENT_X96: u256 = 78_831_026_366_694_838_653_989_738_461;
const PRICE_DOWN_2_PERCENT_X96: u256 = 78_431_879_364_660_579_621_242_713_210;
const PRICE_DOWN_4_PERCENT_X96: u256 = 77_627_428_567_259_243_148_980_294_874;
const PRICE_DOWN_8_PERCENT_X96: u256 = 75_992_983_863_969_107_875_071_309_058;
/// Square-root price 1.02, exactly 51/50 of 1.0: a 4.04% price gap.
const SQRT_PRICE_UP_2_PERCENT_X96: u256 = 80_812_725_764_549_624_345_414_829_342;
/// The documented table uses 2,000 ppm, which requires tier registration.
const TABLE_BASE_FEE_PPM: u32 = 2_000;
const TABLE_MAX_FEE_PPM: u32 = 10_000;
const TABLE_SENSITIVITY_PPM: u32 = 1_000_000;

// === Tests ===

// Calculation.

#[test]
fun zero_gap_charges_the_base_fee() {
    let fee = table_fee();

    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, SQRT_PRICE_ONE_X96).value(), TABLE_BASE_FEE_PPM);
    assert_eq!(fee.fee_at_price(MIN_SQRT_PRICE_X96, MIN_SQRT_PRICE_X96).value(), TABLE_BASE_FEE_PPM);
    assert_eq!(fee.fee_at_price(MAX_SQRT_PRICE_X96 - 1, MAX_SQRT_PRICE_X96 - 1).value(), TABLE_BASE_FEE_PPM);
}

#[test]
fun fee_matches_the_documented_table() {
    let fee = table_fee();

    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, SQRT_PRICE_ONE_X96).value(), 2_000);
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_UP_2_PERCENT_X96).value(), 2_400);
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_UP_4_PERCENT_X96).value(), 3_600);
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_UP_8_PERCENT_X96).value(), 8_400);
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_UP_10_PERCENT_X96).value(), 10_000);
}

#[test]
fun equal_gaps_above_and_below_the_reference_charge_equal_fees() {
    let fee = table_fee();

    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_DOWN_1_PERCENT_X96).value(), 2_100);
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_UP_1_PERCENT_X96).value(), 2_100);
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_DOWN_2_PERCENT_X96).value(), 2_400);
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_UP_2_PERCENT_X96).value(), 2_400);
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_DOWN_4_PERCENT_X96).value(), 3_600);
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_UP_4_PERCENT_X96).value(), 3_600);
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_DOWN_8_PERCENT_X96).value(), 8_400);
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_UP_8_PERCENT_X96).value(), 8_400);
}

#[test]
fun doubling_the_gap_quadruples_the_extra_fee() {
    // The maximum stays out of reach, so only the surcharge changes.
    let fee = lp_fee::new_dynamic_unchecked_for_testing(TABLE_BASE_FEE_PPM, 1_000_000, 100_000_000);

    let extra_1_percent = fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_UP_1_PERCENT_X96).value() - TABLE_BASE_FEE_PPM;
    let extra_2_percent = fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_UP_2_PERCENT_X96).value() - TABLE_BASE_FEE_PPM;
    let extra_4_percent = fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_UP_4_PERCENT_X96).value() - TABLE_BASE_FEE_PPM;
    let extra_8_percent = fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_UP_8_PERCENT_X96).value() - TABLE_BASE_FEE_PPM;

    assert_eq!(extra_1_percent, 10_000);
    assert_eq!(extra_2_percent, 4 * extra_1_percent);
    assert_eq!(extra_4_percent, 4 * extra_2_percent);
    assert_eq!(extra_8_percent, 4 * extra_4_percent);
}

#[test]
fun fee_is_capped_at_the_maximum() {
    let fee = table_fee();

    // 10% adds exactly the 8,000 ppm headroom; anything further stays at the cap.
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, PRICE_UP_10_PERCENT_X96).value(), TABLE_MAX_FEE_PPM);
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, 2 * SQRT_PRICE_ONE_X96).value(), TABLE_MAX_FEE_PPM);
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, SQRT_PRICE_ONE_X96 / 2).value(), TABLE_MAX_FEE_PPM);
}

#[test]
fun extreme_in_range_prices_saturate_at_the_maximum_without_aborting() {
    let low_sensitivity = dynamic_fee(1_000, 100_000, 100_000);
    let high_sensitivity = dynamic_fee(20_000, 20_000, 100_000_000);
    let table = table_fee();
    // A 1 ppm sensitivity still saturates the largest ppm rate above the reference.
    let widest = lp_fee::new_dynamic_unchecked_for_testing(1_000, 1_000_000, 1);

    let highest = MAX_SQRT_PRICE_X96 - 1;
    assert_eq!(low_sensitivity.fee_at_price(MIN_SQRT_PRICE_X96, highest).value(), 100_000);
    assert_eq!(low_sensitivity.fee_at_price(highest, MIN_SQRT_PRICE_X96).value(), 100_000);
    assert_eq!(high_sensitivity.fee_at_price(MIN_SQRT_PRICE_X96, highest).value(), 20_000);
    assert_eq!(high_sensitivity.fee_at_price(highest, MIN_SQRT_PRICE_X96).value(), 20_000);
    assert_eq!(table.fee_at_price(MIN_SQRT_PRICE_X96, highest).value(), TABLE_MAX_FEE_PPM);
    assert_eq!(table.fee_at_price(highest, MIN_SQRT_PRICE_X96).value(), TABLE_MAX_FEE_PPM);
    assert_eq!(widest.fee_at_price(MIN_SQRT_PRICE_X96, highest).value(), 1_000_000);
}

#[test]
fun gap_is_measured_in_price_not_square_root_price() {
    let fee = table_fee();

    // A 2% square-root move is a 4.04% price move: 1,000,000 * 0.0404^2 = 1,632.16 ppm.
    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, SQRT_PRICE_UP_2_PERCENT_X96).value(), 3_632);
}

#[test]
fun rate_rounding_can_reduce_the_fee_by_one_ppm_at_an_exact_boundary() {
    let fee = dynamic_fee(3_000, 100_000, 100_035);
    let reference_sqrt_price_x96 = 3 * SQRT_PRICE_ONE_X96;

    // The exact gaps are 7/9 and 5/9. Rounding them down puts each surcharge
    // just below its exact integer value of 60,515 and 30,875 ppm, respectively.
    assert_eq!(fee.fee_at_price(reference_sqrt_price_x96, 4 * SQRT_PRICE_ONE_X96).value(), 63_514);
    assert_eq!(fee.fee_at_price(reference_sqrt_price_x96, 2 * SQRT_PRICE_ONE_X96).value(), 33_874);
}

#[test]
fun fixed_fee_ignores_the_price_gap() {
    let fee = fixed_fee(3_000);

    assert_eq!(fee.fee_at_price(SQRT_PRICE_ONE_X96, SQRT_PRICE_ONE_X96).value(), 3_000);
    assert_eq!(fee.fee_at_price(MIN_SQRT_PRICE_X96, MAX_SQRT_PRICE_X96 - 1).value(), 3_000);
}

// Fixed settings.

#[test]
fun new_fixed_accepts_every_fee_tier() {
    let tiers = vector[1_000, 3_000, 10_000, 20_000];

    tiers.do!(|tier| {
        let fee = fixed_fee(tier);
        assert!(!fee.is_dynamic());
        assert_eq!(fee.base_fee_ppm(), tier);
        assert_eq!(fee.max_fee_ppm(), tier);
        assert_eq!(fee.sensitivity_ppm(), option::none());
    });
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::ENotFeeTier, location = blast_fun_dex::lp_fee)]
fun new_fixed_rejects_zero() {
    fixed_fee(0);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::ENotFeeTier, location = blast_fun_dex::lp_fee)]
fun new_fixed_rejects_a_fee_next_to_a_tier() {
    fixed_fee(2_999);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::ENotFeeTier, location = blast_fun_dex::lp_fee)]
fun new_fixed_rejects_a_fee_above_the_highest_tier() {
    fixed_fee(20_001);
}

// Dynamic settings.

#[test]
fun new_dynamic_accepts_every_bound_at_its_edge() {
    let tiers = vector[1_000, 3_000, 10_000, 20_000];
    tiers.do!(|tier| {
        dynamic_fee(tier, tier, 100_000);
    });

    let fee = dynamic_fee(1_000, 100_000, 100_000_000);

    assert!(fee.is_dynamic());
    assert_eq!(fee.base_fee_ppm(), 1_000);
    assert_eq!(fee.max_fee_ppm(), 100_000);
    assert_eq!(fee.sensitivity_ppm(), option::some(100_000_000));
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::ENotFeeTier, location = blast_fun_dex::lp_fee)]
fun new_dynamic_rejects_a_base_fee_off_the_tiers() {
    dynamic_fee(2_000, 10_000, 1_000_000);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidMaxFee, location = blast_fun_dex::lp_fee)]
fun new_dynamic_rejects_a_maximum_below_the_base_fee() {
    dynamic_fee(3_000, 2_999, 1_000_000);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidMaxFee, location = blast_fun_dex::lp_fee)]
fun new_dynamic_rejects_a_maximum_above_ten_percent() {
    dynamic_fee(3_000, 100_001, 1_000_000);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidSensitivity, location = blast_fun_dex::lp_fee)]
fun new_dynamic_rejects_a_sensitivity_below_the_minimum() {
    dynamic_fee(3_000, 10_000, 99_999);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidSensitivity, location = blast_fun_dex::lp_fee)]
fun new_dynamic_rejects_a_sensitivity_above_the_maximum() {
    dynamic_fee(3_000, 10_000, 100_000_001);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::ENotFeeTier, location = blast_fun_dex::lp_fee)]
fun new_dynamic_checks_the_base_fee_before_the_other_bounds() {
    dynamic_fee(2_000, 100_001, 0);
}

// === Test Helpers ===

fun fixed_fee(fee_ppm: u32): LpFee {
    let tiers = lp_fee::new_fee_tiers_for_testing(&mut tx_context::dummy());
    let fee = lp_fee::new_fixed(&tiers, fee_ppm);
    tiers.destroy_default_fee_tiers_for_testing();

    fee
}

fun dynamic_fee(base_fee_ppm: u32, max_fee_ppm: u32, sensitivity_ppm: u32): LpFee {
    let tiers = lp_fee::new_fee_tiers_for_testing(&mut tx_context::dummy());
    let fee = lp_fee::new_dynamic(&tiers, base_fee_ppm, max_fee_ppm, sensitivity_ppm);
    tiers.destroy_default_fee_tiers_for_testing();

    fee
}

fun table_fee(): LpFee {
    lp_fee::new_dynamic_unchecked_for_testing(TABLE_BASE_FEE_PPM, TABLE_MAX_FEE_PPM, TABLE_SENSITIVITY_PPM)
}

// === Imports ===

use blast_fun_dex::lp_fee::{Self, LpFee};
use std::unit_test::assert_eq;
