// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::curve_tests;

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
fun buy_and_sell_outputs_round_down() {
    let (_, _, meme_out_gross, _, _, _, _, _) = quote_buy(10, 0, 3, TERMINAL_THRESHOLD, 1, 0, 0);
    let (_, _, _, _, _, _, quote_out_gross, _, _, _, _) = quote_sell(
        3,
        5,
        5,
        TERMINAL_THRESHOLD,
        1,
        0,
        0,
        0,
    );

    assert_eq!(meme_out_gross, 2);
    assert_eq!(quote_out_gross, 2);
}

#[test]
fun buy_and_sell_quotes_do_not_decrease_the_constant_product() {
    let k_before_buy = constant_product(MEME_RESERVE, 0);
    let (_, _, _, _, meme_out, meme_reserve, real_quote, _) = quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000,
        QUOTE_FEE_BPS,
        0,
    );
    let k_after_buy = constant_product(meme_reserve, real_quote);
    let (_, _, _, _, _, _, _, _, _, meme_reserve, real_quote) = quote_sell(
        meme_reserve,
        real_quote,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        meme_out,
        QUOTE_FEE_BPS,
        0,
        100,
    );
    let k_after_sell = constant_product(meme_reserve, real_quote);

    assert!(k_after_buy >= k_before_buy);
    assert!(k_after_sell >= k_after_buy);
}

#[test]
fun buy_input_cap_accepts_a_nonterminal_coin_without_refund() {
    let (quote_in_gross, quote_refund) = cap_buy_quote_input(
        0,
        TERMINAL_THRESHOLD,
        1_000_000_000,
        QUOTE_FEE_BPS,
    );

    assert_eq!(quote_in_gross, 1_000_000_000);
    assert_eq!(quote_refund, 0);
}

#[test]
fun buy_input_cap_reaches_the_exact_post_fee_target_and_refunds_excess() {
    let (quote_in_gross, quote_refund) = cap_buy_quote_input(
        TERMINAL_THRESHOLD - 1_000_000_000,
        TERMINAL_THRESHOLD,
        2_000_000_000,
        QUOTE_FEE_BPS,
    );

    assert_eq!(quote_in_gross, 1_010_101_011);
    assert_eq!(quote_refund, 989_898_989);
}

#[test]
fun buy_input_cap_accepts_a_total_fee_without_dividing_by_its_complement() {
    let (quote_in_gross, quote_refund) = cap_buy_quote_input(
        TERMINAL_THRESHOLD - 1,
        TERMINAL_THRESHOLD,
        std::u64::max_value!(),
        10_000,
    );

    assert_eq!(quote_in_gross, std::u64::max_value!());
    assert_eq!(quote_refund, 0);
}

#[test]
fun buy_input_cap_is_exact_and_minimal_for_every_admitted_fee() {
    let max = std::u64::max_value!();
    let reals = vector[0u64, 1, 7, 24_999_999, 12_345_678, max - 1_000_000_001, 0];
    let targets = vector[25_000_000u64, 2, 1_000, 25_000_000, 25_000_000, max, max];
    let supplies = vector[30_000_000u64, max, 1_001, 1, 100_000_000, max, max];

    (blast_fun::constants::max_launch_fee_bps!() + 1).do!(|fee| {
        let fee = bps::new(fee);
        reals.length().do!(|i| {
            let (real, target, supplied) = (reals[i], targets[i], supplies[i]);
            let remaining = target - real;
            let (gross, refund) = curve::cap_buy_quote_input(real, target, supplied, fee);

            assert_eq!(gross + refund, supplied);
            if (supplied - fee.apply_up(supplied) <= remaining) {
                assert_eq!(gross, supplied);
            } else {
                assert_eq!(gross - fee.apply_up(gross), remaining);
                assert!((gross - 1) - fee.apply_up(gross - 1) < remaining);
            };
        });
    });
}

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
    ) = quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000,
        QUOTE_FEE_BPS,
        0,
    );

    assert_eq!(quote_fee, 10_000_000);
    assert_eq!(quote_in_net, 990_000_000);
    assert_eq!(meme_out, 791_216_695_471_483);
    assert_eq!(meme_reserve_after, 799_208_783_304_528_517);
    assert_eq!(real_quote_after, 990_000_000);
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
    ) = quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000,
        0,
        100,
    );

    assert_eq!(quote_fee, 0);
    assert_eq!(quote_in_net, 1_000_000_000);
    assert_eq!(meme_out_gross, 799_200_799_200_799);
    assert_eq!(meme_fee, 7_992_007_992_008);
    assert_eq!(meme_out_net, 791_208_791_208_791);
    assert_eq!(meme_reserve_after, 799_200_799_200_799_201);
    assert_eq!(real_quote_after, 1_000_000_000);
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
    ) = quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000,
        QUOTE_FEE_BPS,
        100,
    );

    assert_eq!(quote_fee, 10_000_000);
    assert_eq!(quote_in_net, 990_000_000);
    assert_eq!(meme_out_gross, 791_216_695_471_483);
    assert_eq!(meme_fee, 7_912_166_954_715);
    assert_eq!(meme_out_net, 783_304_528_516_768);
    assert_eq!(meme_reserve_after, 799_208_783_304_528_517);
    assert_eq!(real_quote_after, 990_000_000);
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
    ) = quote_buy(
        799_208_783_304_528_517,
        990_000_000,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        500_000_000_000,
        QUOTE_FEE_BPS,
        0,
    );

    assert_eq!(meme_out_mid, 264_445_850_397_222_986);
    assert_eq!(meme_reserve_mid, 534_762_932_907_305_531);
    assert_eq!(real_quote_mid, 495_990_000_000);
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
    ) = quote_buy(
        230_215_827_338_129_497,
        2_475_000_000_000,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        600_000_000_000,
        QUOTE_FEE_BPS,
        0,
    );

    assert_eq!(quote_fee, 6_000_000_000);
    assert_eq!(quote_in_net, 594_000_000_000);
    assert_eq!(meme_out_crossing, 33_607_324_020_361_003);
    assert_eq!(meme_reserve_after, 196_608_503_317_768_494);
    assert_eq!(real_quote_after, 3_069_000_000_000);
    assert!(crossed_threshold);
}

#[test]
fun threshold_flag_changes_at_the_exact_real_quote_boundary() {
    let (_, _, _, _, _, _, quote_below, crossed_below) = quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        TERMINAL_THRESHOLD - 1,
        0,
        0,
    );
    let (_, _, _, _, _, _, quote_at, crossed_at) = quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        TERMINAL_THRESHOLD,
        0,
        0,
    );

    assert_eq!(quote_below, TERMINAL_THRESHOLD - 1);
    assert!(!crossed_below);
    assert_eq!(quote_at, TERMINAL_THRESHOLD);
    assert!(crossed_at);
}

#[test]
fun buy_output_is_monotonic_in_input_and_existing_quote() {
    let (_, _, _, _, small_input_out, _, _, _) = quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000,
        QUOTE_FEE_BPS,
        0,
    );
    let (_, _, _, _, large_input_out, _, _, _) = quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        2_000_000_000,
        QUOTE_FEE_BPS,
        0,
    );
    let (_, _, _, _, later_curve_out, _, _, _) = quote_buy(
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
    ) = quote_buy(
        std::u64::max_value!(),
        0,
        1,
        std::u64::max_value!(),
        std::u64::max_value!(),
        0,
        0,
    );

    assert_eq!(quote_fee, 0);
    assert_eq!(quote_in_net, std::u64::max_value!());
    assert_eq!(meme_out, std::u64::max_value!() - 1);
    assert_eq!(meme_reserve_after, 1);
    assert_eq!(real_quote_after, std::u64::max_value!());
    assert!(crossed_threshold);
}

#[test]
fun buy_quotes_zero_input_as_zero_output() {
    let (_, _, _, _, meme_out_net, _, _, _) = quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        0,
        QUOTE_FEE_BPS,
        0,
    );

    assert_eq!(meme_out_net, 0);
}

#[test]
fun buy_quotes_one_atomic_unit_as_zero_output() {
    let (_, _, _, _, meme_out_net, _, _, _) = quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1,
        QUOTE_FEE_BPS,
        0,
    );

    assert_eq!(meme_out_net, 0);
}

#[test]
fun buy_quotes_a_meme_output_rounded_to_zero() {
    let (_, _, _, _, meme_out_net, _, _, _) = quote_buy(
        1,
        0,
        std::u64::max_value!(),
        1,
        1,
        0,
        0,
    );

    assert_eq!(meme_out_net, 0);
}

#[test]
fun buy_quotes_an_output_consumed_entirely_by_the_meme_fee() {
    let (_, _, meme_out_gross, _, meme_out_net, _, _, _) = quote_buy(
        MEME_RESERVE,
        0,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000,
        0,
        10_000,
    );

    assert!(meme_out_gross > 0);
    assert_eq!(meme_out_net, 0);
}

#[test]
fun sell_mid_with_fixed_burn_matches_the_committed_vector() {
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
    ) = quote_sell(
        534_762_932_907_305_531,
        495_990_000_000,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000_000_000,
        QUOTE_FEE_BPS,
        0,
        100,
    );

    assert_eq!(progress_bps, 1_653);
    assert_eq!(burn_bps, 100);
    assert_eq!(meme_pending_burn, 10_000_000_000_000);
    assert_eq!(meme_in_effective, 990_000_000_000_000);
    assert_eq!(quote_out_gross, 2_764_390_092);
    assert_eq!(quote_fee, 27_643_901);
    assert_eq!(quote_out_net, 2_736_746_191);
    assert_eq!(meme_reserve_after, 535_752_932_907_305_531);
    assert_eq!(real_quote_after, 493_225_609_908);
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
    ) = quote_sell(
        534_762_932_907_305_531,
        495_990_000_000,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000_000_000,
        100,
        100,
        100,
    );

    assert_eq!(meme_fee, 10_000_000_000_000);
    assert_eq!(meme_in_after_fee, 990_000_000_000_000);
    assert_eq!(progress_bps, 1_653);
    assert_eq!(burn_bps, 100);
    assert_eq!(meme_pending_burn, 9_900_000_000_000);
    assert_eq!(meme_in_effective, 980_100_000_000_000);
    assert_eq!(quote_out_gross, 2_736_796_764);
    assert_eq!(quote_fee, 27_367_968);
    assert_eq!(quote_out_net, 2_709_428_796);
    assert_eq!(meme_reserve_after, 535_743_032_907_305_531);
    assert_eq!(real_quote_after, 493_253_203_236);
}

#[test]
fun sell_max_burn_applies_to_post_fee_input() {
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
    ) = quote_sell(1_000, 500, 1_000, 1_000, 1_000, 0, 100, 5_000);

    assert_eq!(meme_fee, 10);
    assert_eq!(meme_in_after_fee, 990);
    assert_eq!(progress_bps, 5_000);
    assert_eq!(burn_bps, 5_000);
    assert_eq!(meme_pending_burn, 495);
    assert_eq!(meme_in_effective, 495);
    assert_eq!(quote_out_gross, 496);
    assert_eq!(quote_fee, 0);
    assert_eq!(quote_out_net, 496);
    assert_eq!(meme_reserve_after, 1_495);
    assert_eq!(real_quote_after, 4);
}

#[test]
fun sell_burn_is_fixed_across_progress_boundaries() {
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
    ) = quote_sell(
        196_608_503_317_768_494,
        3_069_000_000_000,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000_000_000,
        QUOTE_FEE_BPS,
        0,
        100,
    );

    assert_eq!(full_progress_bps, 10_000);
    assert_eq!(full_burn_bps, 100);
    assert_eq!(full_meme_pending_burn, 10_000_000_000_000);
    assert_eq!(full_quote_out_gross, 20_386_338_622);
    assert_eq!(full_quote_out_net, 20_182_475_235);
    assert_eq!(full_real_quote_after, 3_048_613_661_378);

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
    ) = quote_sell(
        200_000_000_000_050_001,
        TERMINAL_THRESHOLD - 1,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        1_000_000_000_000_000,
        QUOTE_FEE_BPS,
        0,
        100,
    );

    assert_eq!(live_progress_bps, 9_999);
    assert_eq!(live_burn_bps, 100);
    assert_eq!(live_meme_pending_burn, 10_000_000_000_000);
    assert_eq!(live_meme_in_effective, 990_000_000_000_000);
    assert_eq!(live_quote_out_gross, 19_702_472_759);
    assert_eq!(live_quote_fee, 197_024_728);
    assert_eq!(live_quote_out_net, 19_505_448_031);
    assert_eq!(live_meme_reserve_after, 200_990_000_000_050_001);
    assert_eq!(live_real_quote_after, 2_980_297_527_240);
}

#[test]
fun immediate_round_trip_applies_fixed_burn_after_fees() {
    let (
        _,
        _,
        _,
        _,
        meme_out,
        meme_reserve_after_buy,
        real_quote_after_buy,
        _,
    ) = quote_buy(
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
    ) = quote_sell(
        meme_reserve_after_buy,
        real_quote_after_buy,
        VIRTUAL_QUOTE,
        TERMINAL_THRESHOLD,
        meme_out,
        QUOTE_FEE_BPS,
        0,
        100,
    );

    assert_eq!(progress_bps, 3);
    assert_eq!(burn_bps, 100);
    assert_eq!(meme_pending_burn, 7_912_166_954_715);
    assert_eq!(quote_out_gross, 980_109_693);
    assert_eq!(quote_fee, 9_801_097);
    assert_eq!(quote_out_net, 970_308_596);
    assert_eq!(meme_reserve_after_sell, 799_992_087_833_045_285);
    assert_eq!(real_quote_after_sell, 9_890_307);
    assert_eq!(1_000_000_000 - quote_out_net, 29_691_404);
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
    ) = quote_sell(
        1,
        std::u64::max_value!(),
        1,
        std::u64::max_value!(),
        std::u64::max_value!() - 1,
        0,
        0,
        0,
    );

    assert_eq!(progress_bps, 10_000);
    assert_eq!(burn_bps, 0);
    assert_eq!(meme_pending_burn, 0);
    assert_eq!(meme_in_effective, std::u64::max_value!() - 1);
    assert_eq!(quote_out_gross, std::u64::max_value!() - 1);
    assert_eq!(quote_fee, 0);
    assert_eq!(quote_out_net, std::u64::max_value!() - 1);
    assert_eq!(meme_reserve_after, std::u64::max_value!());
    assert_eq!(real_quote_after, 1);
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
        let (_, _, _, _, meme_out, meme_reserve, real_quote, crossed) = quote_buy(
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
            meme_out,
            quote_fee_bps,
            meme_fee_bps,
        );
        let (_, _, _, _, _, _, full_quote_out_gross, _, _, _, _) = quote_sell(
            meme_reserve,
            real_quote,
            VIRTUAL_QUOTE,
            TERMINAL_THRESHOLD,
            meme_out,
            quote_fee_bps,
            meme_fee_bps,
            100,
        );
        assert!(full_quote_out_gross <= real_quote);

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

        let (_, _, _, _, _, _, quote_out_gross, _, _, _, _) = quote_sell(
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
#[expected_failure(
    abort_code = blast_fun::errors::EZeroTradeOutput,
    location = blast_fun::curve,
)]
fun sell_rejects_zero_input_as_zero_output() {
    quote_sell(
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
#[expected_failure(
    abort_code = blast_fun::errors::EZeroTradeOutput,
    location = blast_fun::curve,
)]
fun sell_rejects_an_input_consumed_entirely_by_the_burn() {
    quote_sell(
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
#[expected_failure(
    abort_code = blast_fun::errors::EZeroTradeOutput,
    location = blast_fun::curve,
)]
fun sell_rejects_an_input_consumed_entirely_by_the_meme_fee() {
    quote_sell(
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
#[expected_failure(
    abort_code = blast_fun::errors::EZeroTradeOutput,
    location = blast_fun::curve,
)]
fun sell_rejects_a_gross_output_rounded_to_zero() {
    quote_sell(
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
#[expected_failure(
    abort_code = blast_fun::errors::EZeroTradeOutput,
    location = blast_fun::curve,
)]
fun sell_rejects_a_net_output_consumed_entirely_by_the_fee() {
    quote_sell(1, 1, 1, 1, 1, 10_000, 0, 0);
}

// === Test Helpers ===

fun cap_buy_quote_input(
    real_quote: u64,
    terminal_threshold: u64,
    quote_supplied: u64,
    quote_fee_bps: u64,
): (u64, u64) {
    curve::cap_buy_quote_input(
        real_quote,
        terminal_threshold,
        quote_supplied,
        bps::new(quote_fee_bps),
    )
}

fun quote_buy(
    meme_reserve: u64,
    real_quote: u64,
    virtual_quote: u64,
    terminal_threshold: u64,
    quote_in_gross: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
): (u64, u64, u64, u64, u64, u64, u64, bool) {
    let (quote_fee, meme_out_gross, meme_fee, meme_out_net) = curve::quote_buy(
        meme_reserve,
        real_quote,
        virtual_quote,
        quote_in_gross,
        bps::new(quote_fee_bps),
        bps::new(meme_fee_bps),
    );
    let quote_in_net = quote_in_gross - quote_fee;
    let real_quote_after = real_quote + quote_in_net;

    (
        quote_fee,
        quote_in_net,
        meme_out_gross,
        meme_fee,
        meme_out_net,
        meme_reserve - meme_out_gross,
        real_quote_after,
        real_quote_after >= terminal_threshold,
    )
}

fun quote_sell(
    meme_reserve: u64,
    real_quote: u64,
    virtual_quote: u64,
    terminal_threshold: u64,
    meme_in_gross: u64,
    quote_fee_bps: u64,
    meme_fee_bps: u64,
    sell_burn_bps: u64,
): (u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64) {
    let (meme_fee, pending_burn, quote_out_gross, quote_fee, quote_out_net) = curve::quote_sell(
        meme_reserve,
        real_quote,
        virtual_quote,
        meme_in_gross,
        bps::new(quote_fee_bps),
        bps::new(meme_fee_bps),
        bps::new(sell_burn_bps),
    );
    let meme_after_fee = meme_in_gross - meme_fee;
    let meme_to_curve = meme_after_fee - pending_burn;
    let progress_bps = if (real_quote >= terminal_threshold) {
        10_000
    } else {
        ((real_quote as u128) * 10_000 / (terminal_threshold as u128)) as u64
    };

    (
        meme_fee,
        meme_after_fee,
        progress_bps,
        sell_burn_bps,
        pending_burn,
        meme_to_curve,
        quote_out_gross,
        quote_fee,
        quote_out_net,
        meme_reserve + meme_to_curve,
        real_quote - quote_out_gross,
    )
}

/// The curve's constant product over the fixture's virtual Quote reserve, widened to u256.
fun constant_product(meme_reserve: u64, real_quote: u64): u256 {
    (meme_reserve as u256) * ((VIRTUAL_QUOTE as u256) + (real_quote as u256))
}

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

    assert_eq!(actual_trace, expected_trace);
}

// === Imports ===

use blast_fun::{bps, curve};

use std::unit_test::assert_eq;
