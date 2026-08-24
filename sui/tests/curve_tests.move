#[test_only]
module blast_fun::curve_tests;

use blast_fun::curve;

// === Constants ===

const MEME_RESERVE: u64 = 800_000_000_000_000_000;
const VIRTUAL_QUOTE: u64 = 1_000_000_000_000;
const TERMINAL_THRESHOLD: u64 = 3_000_000_000_000;
const QUOTE_FEE_BPS: u64 = 100;
const MIN_PROPERTY_QUOTE_IN: u64 = 1_000_000_000;
const PROPERTY_SEED: u64 = 314_159;
const PROPERTY_OPERATION_COUNT: u64 = 256;

// === Tests ===

#[test]
fun buy_first_one_quote_unit_matches_the_committed_vector() {
    let (
        quote_fee,
        quote_in_net,
        _,
        _,
        meme_out,
        meme_reserve_after,
        real_quote_after,
        crossed_threshold,
    ) = curve::quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000,
        QUOTE_FEE_BPS,
        0,
    );

    std::unit_test::assert_eq!(quote_fee, 10_000_000);
    std::unit_test::assert_eq!(quote_in_net, 990_000_000);
    std::unit_test::assert_eq!(meme_out, 791_216_695_471_483);
    std::unit_test::assert_eq!(meme_reserve_after, 799_208_783_304_528_517);
    std::unit_test::assert_eq!(real_quote_after, 990_000_000);
    assert!(!crossed_threshold);
}

#[test]
fun buy_can_charge_meme_fee_without_quote_fee() {
    let (
        quote_fee,
        quote_in_net,
        meme_out_gross,
        meme_fee,
        meme_out_net,
        meme_reserve_after,
        real_quote_after,
        crossed_threshold,
    ) = curve::quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000,
        0,
        100,
    );

    std::unit_test::assert_eq!(quote_fee, 0);
    std::unit_test::assert_eq!(quote_in_net, 1_000_000_000);
    std::unit_test::assert_eq!(meme_out_gross, 799_200_799_200_799);
    std::unit_test::assert_eq!(meme_fee, 7_992_007_992_008);
    std::unit_test::assert_eq!(meme_out_net, 791_208_791_208_791);
    std::unit_test::assert_eq!(meme_reserve_after, 799_200_799_200_799_201);
    std::unit_test::assert_eq!(real_quote_after, 1_000_000_000);
    assert!(!crossed_threshold);
}

#[test]
fun buy_can_charge_both_asset_fees() {
    let (
        quote_fee,
        quote_in_net,
        meme_out_gross,
        meme_fee,
        meme_out_net,
        meme_reserve_after,
        real_quote_after,
        crossed_threshold,
    ) = curve::quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000,
        QUOTE_FEE_BPS,
        100,
    );

    std::unit_test::assert_eq!(quote_fee, 10_000_000);
    std::unit_test::assert_eq!(quote_in_net, 990_000_000);
    std::unit_test::assert_eq!(meme_out_gross, 791_216_695_471_483);
    std::unit_test::assert_eq!(meme_fee, 7_912_166_954_715);
    std::unit_test::assert_eq!(meme_out_net, 783_304_528_516_768);
    std::unit_test::assert_eq!(meme_reserve_after, 799_208_783_304_528_517);
    std::unit_test::assert_eq!(real_quote_after, 990_000_000);
    assert!(!crossed_threshold);
}

#[test]
fun consecutive_buys_match_mid_and_threshold_vectors() {
    let (
        _,
        _,
        _,
        _,
        meme_out_mid,
        meme_reserve_mid,
        real_quote_mid,
        crossed_mid,
    ) = curve::quote_buy(
        799_208_783_304_528_517,
        990_000_000,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        500_000_000_000,
        QUOTE_FEE_BPS,
        0,
    );

    std::unit_test::assert_eq!(meme_out_mid, 264_445_850_397_222_986);
    std::unit_test::assert_eq!(meme_reserve_mid, 534_762_932_907_305_531);
    std::unit_test::assert_eq!(real_quote_mid, 495_990_000_000);
    assert!(!crossed_mid);

    let (
        quote_fee,
        quote_in_net,
        _,
        _,
        meme_out_crossing,
        meme_reserve_after,
        real_quote_after,
        crossed_threshold,
    ) = curve::quote_buy(
        230_215_827_338_129_497,
        2_475_000_000_000,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        600_000_000_000,
        QUOTE_FEE_BPS,
        0,
    );

    std::unit_test::assert_eq!(quote_fee, 6_000_000_000);
    std::unit_test::assert_eq!(quote_in_net, 594_000_000_000);
    std::unit_test::assert_eq!(meme_out_crossing, 33_607_324_020_361_003);
    std::unit_test::assert_eq!(meme_reserve_after, 196_608_503_317_768_494);
    std::unit_test::assert_eq!(real_quote_after, 3_069_000_000_000);
    assert!(crossed_threshold);
}

#[test]
fun threshold_flag_changes_at_the_exact_real_quote_boundary() {
    let (_, _, _, _, _, _, quote_below, crossed_below) = curve::quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        TERMINAL_THRESHOLD - 1,
        0,
        0,
    );
    let (_, _, _, _, _, _, quote_at, crossed_at) = curve::quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        TERMINAL_THRESHOLD,
        0,
        0,
    );

    std::unit_test::assert_eq!(quote_below, TERMINAL_THRESHOLD - 1);
    assert!(!crossed_below);
    std::unit_test::assert_eq!(quote_at, TERMINAL_THRESHOLD);
    assert!(crossed_at);
}

#[test]
fun buy_output_is_monotonic_in_input_and_existing_quote() {
    let (_, _, _, _, small_input_out, _, _, _) = curve::quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000,
        QUOTE_FEE_BPS,
        0,
    );
    let (_, _, _, _, large_input_out, _, _, _) = curve::quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        2_000_000_000,
        QUOTE_FEE_BPS,
        0,
    );
    let (_, _, _, _, later_curve_out, _, _, _) = curve::quote_buy(
        MEME_RESERVE,
        1_000_000_000,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        2_000_000_000,
        QUOTE_FEE_BPS,
        0,
    );

    assert!(large_input_out >= small_input_out);
    assert!(later_curve_out <= large_input_out);
}

#[test]
fun buy_math_supports_maximum_u64_operands_without_intermediate_overflow() {
    let (
        quote_fee,
        quote_in_net,
        _,
        _,
        meme_out,
        meme_reserve_after,
        real_quote_after,
        crossed_threshold,
    ) = curve::quote_buy(
        std::u64::max_value!(),
        0,
        1,
        std::u64::max_value!(),
        std::u64::max_value!(),
        0,
        0,
    );

    std::unit_test::assert_eq!(quote_fee, 0);
    std::unit_test::assert_eq!(quote_in_net, std::u64::max_value!());
    std::unit_test::assert_eq!(meme_out, std::u64::max_value!() - 1);
    std::unit_test::assert_eq!(meme_reserve_after, 1);
    std::unit_test::assert_eq!(real_quote_after, std::u64::max_value!());
    assert!(crossed_threshold);
}

#[test]
#[expected_failure(abort_code = 29)]
fun buy_validates_reserves_before_every_other_guard() {
    curve::quote_buy(0, 0, 0, 0, 0, 10_001, 10_001);
}

#[test]
#[expected_failure(abort_code = 29)]
fun buy_rejects_zero_virtual_quote_reserve() {
    curve::quote_buy(MEME_RESERVE, 0, 0, TERMINAL_THRESHOLD, 1, 0, 0);
}

#[test]
#[expected_failure(abort_code = 30)]
fun buy_rejects_zero_terminal_threshold() {
    curve::quote_buy(MEME_RESERVE, 0, VIRTUAL_QUOTE, 0, 1, 0, 0);
}

#[test]
#[expected_failure(abort_code = 31)]
fun buy_rejects_quote_fee_above_one_hundred_percent() {
    curve::quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1,
        10_001,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 37)]
fun buy_rejects_meme_fee_above_one_hundred_percent() {
    curve::quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1,
        0,
        10_001,
    );
}

#[test]
#[expected_failure(abort_code = 33)]
fun buy_rejects_zero_input() {
    curve::quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        0,
        QUOTE_FEE_BPS,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 34)]
fun buy_one_atomic_unit_rejects_zero_output() {
    curve::quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1,
        QUOTE_FEE_BPS,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 34)]
fun buy_rejects_a_meme_output_rounded_to_zero() {
    curve::quote_buy(
        1,
        0,
        std::u64::max_value!(),
        1,
        1,
        0,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 34)]
fun buy_rejects_an_output_consumed_entirely_by_the_meme_fee() {
    curve::quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000,
        0,
        10_000,
    );
}

#[test]
#[expected_failure(abort_code = 35)]
fun buy_rejects_post_trade_real_quote_overflow() {
    curve::quote_buy(
        std::u64::max_value!(),
        std::u64::max_value!(),
        1,
        std::u64::max_value!(),
        2,
        0,
        0,
    );
}

#[test]
fun sell_mid_with_progress_burn_matches_the_committed_vector() {
    let (
        _,
        _,
        progress_bps,
        burn_bps,
        meme_pending_burn,
        meme_in_effective,
        quote_out_gross,
        quote_fee,
        quote_out_net,
        meme_reserve_after,
        real_quote_after,
    ) = curve::quote_sell(
        534_762_932_907_305_531,
        495_990_000_000,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000_000_000,
        QUOTE_FEE_BPS,
        0,
        100,
    );

    std::unit_test::assert_eq!(progress_bps, 1_653);
    std::unit_test::assert_eq!(burn_bps, 16);
    std::unit_test::assert_eq!(meme_pending_burn, 1_600_000_000_000);
    std::unit_test::assert_eq!(meme_in_effective, 998_400_000_000_000);
    std::unit_test::assert_eq!(quote_out_gross, 2_787_801_814);
    std::unit_test::assert_eq!(quote_fee, 27_878_019);
    std::unit_test::assert_eq!(quote_out_net, 2_759_923_795);
    std::unit_test::assert_eq!(meme_reserve_after, 535_761_332_907_305_531);
    std::unit_test::assert_eq!(real_quote_after, 493_202_198_186);
}

#[test]
fun sell_can_charge_both_asset_fees_before_and_after_curve_math() {
    let (
        meme_fee,
        meme_in_after_fee,
        progress_bps,
        burn_bps,
        meme_pending_burn,
        meme_in_effective,
        quote_out_gross,
        quote_fee,
        quote_out_net,
        meme_reserve_after,
        real_quote_after,
    ) = curve::quote_sell(
        534_762_932_907_305_531,
        495_990_000_000,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000_000_000,
        100,
        100,
        100,
    );

    std::unit_test::assert_eq!(meme_fee, 10_000_000_000_000);
    std::unit_test::assert_eq!(meme_in_after_fee, 990_000_000_000_000);
    std::unit_test::assert_eq!(progress_bps, 1_653);
    std::unit_test::assert_eq!(burn_bps, 16);
    std::unit_test::assert_eq!(meme_pending_burn, 1_584_000_000_000);
    std::unit_test::assert_eq!(meme_in_effective, 988_416_000_000_000);
    std::unit_test::assert_eq!(quote_out_gross, 2_759_975_228);
    std::unit_test::assert_eq!(quote_fee, 27_599_753);
    std::unit_test::assert_eq!(quote_out_net, 2_732_375_475);
    std::unit_test::assert_eq!(meme_reserve_after, 535_751_348_907_305_531);
    std::unit_test::assert_eq!(real_quote_after, 493_230_024_772);
}

#[test]
fun sell_progress_boundaries_match_the_committed_vectors() {
    let (
        _,
        _,
        full_progress_bps,
        full_burn_bps,
        full_meme_pending_burn,
        _,
        full_quote_out_gross,
        _,
        full_quote_out_net,
        _,
        full_real_quote_after,
    ) = curve::quote_sell(
        196_608_503_317_768_494,
        3_069_000_000_000,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000_000_000,
        QUOTE_FEE_BPS,
        0,
        100,
    );

    std::unit_test::assert_eq!(full_progress_bps, 10_000);
    std::unit_test::assert_eq!(full_burn_bps, 100);
    std::unit_test::assert_eq!(full_meme_pending_burn, 10_000_000_000_000);
    std::unit_test::assert_eq!(full_quote_out_gross, 20_386_338_622);
    std::unit_test::assert_eq!(full_quote_out_net, 20_182_475_235);
    std::unit_test::assert_eq!(full_real_quote_after, 3_048_613_661_378);

    let (
        _,
        _,
        live_progress_bps,
        live_burn_bps,
        live_meme_pending_burn,
        live_meme_in_effective,
        live_quote_out_gross,
        live_quote_fee,
        live_quote_out_net,
        live_meme_reserve_after,
        live_real_quote_after,
    ) = curve::quote_sell(
        200_000_000_000_050_001,
        TERMINAL_THRESHOLD - 1,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000_000_000,
        QUOTE_FEE_BPS,
        0,
        100,
    );

    std::unit_test::assert_eq!(live_progress_bps, 9_999);
    std::unit_test::assert_eq!(live_burn_bps, 99);
    std::unit_test::assert_eq!(live_meme_pending_burn, 9_900_000_000_000);
    std::unit_test::assert_eq!(live_meme_in_effective, 990_100_000_000_000);
    std::unit_test::assert_eq!(live_quote_out_gross, 19_704_453_104);
    std::unit_test::assert_eq!(live_quote_fee, 197_044_532);
    std::unit_test::assert_eq!(live_quote_out_net, 19_507_408_572);
    std::unit_test::assert_eq!(live_meme_reserve_after, 200_990_100_000_050_001);
    std::unit_test::assert_eq!(live_real_quote_after, 2_980_295_546_895);
}

#[test]
fun immediate_round_trip_pins_fees_and_one_atomic_unit_of_curve_dust() {
    let (
        _,
        _,
        _,
        _,
        meme_out,
        meme_reserve_after_buy,
        real_quote_after_buy,
        _,
    ) = curve::quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000,
        QUOTE_FEE_BPS,
        0,
    );
    let (
        _,
        _,
        progress_bps,
        burn_bps,
        meme_pending_burn,
        _,
        quote_out_gross,
        quote_fee,
        quote_out_net,
        meme_reserve_after_sell,
        real_quote_after_sell,
    ) = curve::quote_sell(
        meme_reserve_after_buy,
        real_quote_after_buy,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        meme_out,
        QUOTE_FEE_BPS,
        0,
        100,
    );

    std::unit_test::assert_eq!(progress_bps, 3);
    std::unit_test::assert_eq!(burn_bps, 0);
    std::unit_test::assert_eq!(meme_pending_burn, 0);
    std::unit_test::assert_eq!(quote_out_gross, 989_999_999);
    std::unit_test::assert_eq!(quote_fee, 9_900_000);
    std::unit_test::assert_eq!(quote_out_net, 980_099_999);
    std::unit_test::assert_eq!(meme_reserve_after_sell, MEME_RESERVE);
    std::unit_test::assert_eq!(real_quote_after_sell, 1);
    std::unit_test::assert_eq!(1_000_000_000 - quote_out_net, 19_900_001);
}

#[test]
fun sell_math_supports_maximum_u64_operands_without_intermediate_overflow() {
    let (
        _,
        _,
        progress_bps,
        burn_bps,
        meme_pending_burn,
        meme_in_effective,
        quote_out_gross,
        quote_fee,
        quote_out_net,
        meme_reserve_after,
        real_quote_after,
    ) = curve::quote_sell(
        1,
        std::u64::max_value!(),
        1,
        std::u64::max_value!(),
        std::u64::max_value!() - 1,
        0,
        0,
        0,
    );

    std::unit_test::assert_eq!(progress_bps, 10_000);
    std::unit_test::assert_eq!(burn_bps, 0);
    std::unit_test::assert_eq!(meme_pending_burn, 0);
    std::unit_test::assert_eq!(meme_in_effective, std::u64::max_value!() - 1);
    std::unit_test::assert_eq!(quote_out_gross, std::u64::max_value!() - 1);
    std::unit_test::assert_eq!(quote_fee, 0);
    std::unit_test::assert_eq!(quote_out_net, std::u64::max_value!() - 1);
    std::unit_test::assert_eq!(meme_reserve_after, std::u64::max_value!());
    std::unit_test::assert_eq!(real_quote_after, 1);
}

#[test]
fun seeded_sell_back_invariant_holds_for_reachable_buy_then_sell() {
    let mut entropy = PROPERTY_SEED;
    let mut operation = 0;

    while (operation < PROPERTY_OPERATION_COUNT) {
        entropy = next_property_entropy(entropy);
        let fee_rate_bps = 1 + entropy % 1_000;
        let fee_mode = operation % 4;
        let quote_fee_bps = if (fee_mode == 1 || fee_mode == 3) {
            fee_rate_bps
        } else {
            0
        };
        let meme_fee_bps = if (fee_mode == 2 || fee_mode == 3) {
            fee_rate_bps
        } else {
            0
        };

        entropy = next_property_entropy(entropy);
        let quote_in = MIN_PROPERTY_QUOTE_IN
            + entropy % (TERMINAL_THRESHOLD - MIN_PROPERTY_QUOTE_IN);
        let (_, _, _, _, meme_out, meme_reserve, real_quote, crossed) = curve::quote_buy(
            MEME_RESERVE,
            0,
            VIRTUAL_QUOTE,
            TERMINAL_THRESHOLD,
            quote_in,
            quote_fee_bps,
            meme_fee_bps,
        );

        entropy = next_property_entropy(entropy);
        let minimum_sell = meme_out / 100;
        let sell_span = meme_out - minimum_sell + 1;
        let meme_in = minimum_sell + entropy % sell_span;

        assert!(!crossed);
        assert_sell_back_invariant_with_trace(
            operation,
            quote_in,
            meme_out,
            meme_reserve,
            real_quote,
            meme_in,
            quote_fee_bps,
            meme_fee_bps,
        );

        let (_, _, _, _, _, _, quote_out_gross, _, _, _, _) = curve::quote_sell(
            meme_reserve,
            real_quote,
            VIRTUAL_QUOTE,
            TERMINAL_THRESHOLD,
            meme_in,
            quote_fee_bps,
            meme_fee_bps,
            100,
        );

        assert!(quote_out_gross <= real_quote);
        operation = operation + 1;
    };
}

#[test]
#[expected_failure(abort_code = 29)]
fun sell_rejects_zero_meme_reserve_before_every_other_guard() {
    curve::quote_sell(0, 0, 0, 0, 0, 10_001, 10_001, 10_001);
}

#[test]
#[expected_failure(abort_code = 29)]
fun sell_rejects_zero_virtual_quote_reserve() {
    curve::quote_sell(MEME_RESERVE, 1, 0, TERMINAL_THRESHOLD, 1, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = 30)]
fun sell_rejects_zero_terminal_threshold() {
    curve::quote_sell(MEME_RESERVE, 1, VIRTUAL_QUOTE, 0, 1, 0, 0, 0);
}

#[test]
#[expected_failure(abort_code = 31)]
fun sell_validates_quote_fee_before_meme_fee_and_max_burn() {
    curve::quote_sell(
        MEME_RESERVE,
        1,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1,
        10_001,
        10_001,
        10_001,
    );
}

#[test]
#[expected_failure(abort_code = 37)]
fun sell_validates_meme_fee_before_max_burn() {
    curve::quote_sell(
        MEME_RESERVE,
        1,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1,
        0,
        10_001,
        10_001,
    );
}

#[test]
#[expected_failure(abort_code = 32)]
fun sell_rejects_max_burn_above_one_hundred_percent() {
    curve::quote_sell(
        MEME_RESERVE,
        1,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1,
        0,
        0,
        10_001,
    );
}

#[test]
#[expected_failure(abort_code = 33)]
fun sell_rejects_zero_input() {
    curve::quote_sell(
        MEME_RESERVE,
        1,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        0,
        QUOTE_FEE_BPS,
        0,
        100,
    );
}

#[test]
#[expected_failure(abort_code = 34)]
fun sell_rejects_an_input_consumed_entirely_by_the_burn() {
    curve::quote_sell(
        MEME_RESERVE,
        TERMINAL_THRESHOLD,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1,
        0,
        0,
        10_000,
    );
}

#[test]
#[expected_failure(abort_code = 34)]
fun sell_rejects_an_input_consumed_entirely_by_the_meme_fee() {
    curve::quote_sell(
        MEME_RESERVE,
        1,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1,
        0,
        10_000,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 34)]
fun sell_rejects_a_gross_output_rounded_to_zero() {
    curve::quote_sell(
        MEME_RESERVE,
        1,
        1,
        TERMINAL_THRESHOLD,
        1,
        0,
        0,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 34)]
fun sell_rejects_a_net_output_consumed_entirely_by_the_fee() {
    curve::quote_sell(1, 1, 1, 1, 1, 10_000, 0, 0);
}

#[test]
#[expected_failure(abort_code = 35)]
fun sell_rejects_post_trade_meme_reserve_overflow() {
    curve::quote_sell(
        std::u64::max_value!(),
        std::u64::max_value!(),
        1,
        std::u64::max_value!(),
        1,
        0,
        0,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 36)]
fun sell_rejects_an_unreachable_state_instead_of_clamping_the_payout() {
    curve::quote_sell(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000,
        QUOTE_FEE_BPS,
        0,
        100,
    );
}

// === Private Functions ===

fun next_property_entropy(entropy: u64): u64 {
    let modulus = (std::u64::max_value!() as u256) + 1;

    (
        ((entropy as u256) * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407)
            % modulus
    ) as u64
}

/// Asserts the sell-back inequality before calling production. On failure, `assert_eq!` prints
/// `[operation, quote_fee_bps, meme_fee_bps, quote_in, meme_out, meme_reserve,
/// real_quote, meme_in, invariant_lhs]` and the corresponding maximum valid trace, which
/// reproduces the generated scenario from one line.
fun assert_sell_back_invariant_with_trace(
    operation: u64,
    quote_in: u64,
    meme_out: u64,
    meme_reserve: u64,
    real_quote: u64,
    meme_in: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
) {
    let invariant_lhs =
        ((VIRTUAL_QUOTE as u256) + (real_quote as u256)) * (meme_in as u256);
    let invariant_rhs =
        ((real_quote as u256) + 1)
            * ((meme_reserve as u256) + (meme_in as u256));
    let actual_trace = vector[
        operation as u256,
        quote_fee_bps as u256,
        meme_fee_bps as u256,
        quote_in as u256,
        meme_out as u256,
        meme_reserve as u256,
        real_quote as u256,
        meme_in as u256,
        invariant_lhs,
    ];
    let expected_trace = vector[
        operation as u256,
        quote_fee_bps as u256,
        meme_fee_bps as u256,
        quote_in as u256,
        meme_out as u256,
        meme_reserve as u256,
        real_quote as u256,
        meme_in as u256,
        invariant_lhs.min(invariant_rhs - 1),
    ];

    std::unit_test::assert_eq!(actual_trace, expected_trace);
}
