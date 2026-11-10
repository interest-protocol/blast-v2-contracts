#[test_only]
module blast_fun_dex::pool_tests;

// === Constants ===

/// Price 1.0 in Q64.96.
const SQRT_PRICE_ONE_X96: u256 = 79_228_162_514_264_337_593_543_950_336;
const BELOW_PRICE_X96: u256 = 39_614_081_257_132_168_796_771_975_168;
const ABOVE_PRICE_X96: u256 = 158_456_325_028_528_675_187_087_900_672;
const MIN_SQRT_PRICE_X96: u256 = 4_295_128_739;
const MAX_SQRT_PRICE_X96: u256 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
const LP_FEE_PPM: u32 = 3_000;
/// Dynamic settings: base 0.3%, maximum 2%, sensitivity 1,000,000 ppm.
const BASE_FEE_PPM: u32 = 3_000;
const MAX_FEE_PPM: u32 = 20_000;
const SENSITIVITY_PPM: u32 = 1_000_000;
/// Prices 0.96, 1.08 and 0.92, each 1e-12 further from 1.0 so rounding cannot shrink the gap.
const PRICE_DOWN_4_PERCENT_X96: u256 = 77_627_428_567_259_243_148_980_294_874;
const PRICE_UP_8_PERCENT_X96: u256 = 82_336_321_719_055_997_228_953_866_587;
const PRICE_DOWN_8_PERCENT_X96: u256 = 75_992_983_863_969_107_875_071_309_058;
/// The reference price window, and a realistic Unix epoch timestamp.
const WINDOW_MS: u64 = 600_000;
const NOW_MS: u64 = 1_800_000_000_000;
const TICK_SPACING: u32 = 60;

// === Test-Only Types ===

public struct ASSET has drop {}
public struct QUOTE has drop {}

public struct TestHook() has drop;
public struct OtherHook() has drop;

public struct StateName() has copy, drop, store;

/// Hook namespace and one configuration per test hook.
public struct Fixture {
    namespace: HookNamespace,
    test_config: HookConfig<TestHook>,
    other_config: HookConfig<OtherHook>,
}

// === Tests ===

// Creation.

#[test]
#[expected_failure(abort_code = pool::EIdenticalTokens, location = blast_fun_dex::pool)]
fun new_rejects_identical_tokens() {
    let mut ctx = tx_context::dummy();

    let initializer = pool::new_with_fixed_fee<ASSET, ASSET>(TICK_SPACING, LP_FEE_PPM, SQRT_PRICE_ONE_X96, &mut ctx);

    destroy(initializer);
}

#[test]
#[expected_failure(abort_code = pool::EInvalidTickSpacing, location = blast_fun_dex::pool)]
fun new_rejects_zero_tick_spacing() {
    let mut ctx = tx_context::dummy();

    let initializer = pool::new_with_fixed_fee<ASSET, QUOTE>(0, LP_FEE_PPM, SQRT_PRICE_ONE_X96, &mut ctx);

    destroy(initializer);
}

#[test]
#[expected_failure(abort_code = pool::EInvalidTickSpacing, location = blast_fun_dex::pool)]
fun new_rejects_tick_spacing_above_the_maximum() {
    let mut ctx = tx_context::dummy();

    let initializer = pool::new_with_fixed_fee<ASSET, QUOTE>(32_768, LP_FEE_PPM, SQRT_PRICE_ONE_X96, &mut ctx);

    destroy(initializer);
}

#[test]
#[expected_failure(abort_code = lp_fee::ENotFeeTier, location = blast_fun_dex::lp_fee)]
fun new_with_fixed_fee_rejects_a_fee_off_the_tiers() {
    let mut ctx = tx_context::dummy();

    let initializer = pool::new_with_fixed_fee<ASSET, QUOTE>(TICK_SPACING, 2_000, SQRT_PRICE_ONE_X96, &mut ctx);

    destroy(initializer);
}

#[test]
#[expected_failure(abort_code = lp_fee::EInvalidSensitivity, location = blast_fun_dex::lp_fee)]
fun new_with_dynamic_fee_validates_its_settings() {
    let mut ctx = tx_context::dummy();

    let initializer = pool::new_with_dynamic_fee<ASSET, QUOTE>(
        TICK_SPACING,
        BASE_FEE_PPM,
        MAX_FEE_PPM,
        99_999,
        SQRT_PRICE_ONE_X96,
        &mut ctx,
    );

    destroy(initializer);
}

#[test]
#[expected_failure(abort_code = pool::EInvalidSqrtPrice, location = blast_fun_dex::pool)]
fun new_rejects_price_below_the_minimum() {
    let mut ctx = tx_context::dummy();

    let initializer = pool::new_with_fixed_fee<ASSET, QUOTE>(
        TICK_SPACING,
        LP_FEE_PPM,
        MIN_SQRT_PRICE_X96 - 1,
        &mut ctx,
    );

    destroy(initializer);
}

#[test]
#[expected_failure(abort_code = pool::EInvalidSqrtPrice, location = blast_fun_dex::pool)]
fun new_rejects_the_exclusive_maximum_price() {
    let mut ctx = tx_context::dummy();

    let initializer = pool::new_with_fixed_fee<ASSET, QUOTE>(TICK_SPACING, LP_FEE_PPM, MAX_SQRT_PRICE_X96, &mut ctx);

    destroy(initializer);
}

#[test]
fun new_accepts_every_boundary_value() {
    let mut ctx = tx_context::dummy();

    let low = pool::new_with_fixed_fee<ASSET, QUOTE>(1, 20_000, MIN_SQRT_PRICE_X96, &mut ctx).finalize();
    let high = pool::new_with_fixed_fee<ASSET, QUOTE>(32_767, 1_000, MAX_SQRT_PRICE_X96 - 1, &mut ctx).finalize();

    assert_eq!(low.lp_fee(), lp_fee::new_fixed(20_000));
    assert_eq!(high.lp_fee(), lp_fee::new_fixed(1_000));
    assert_eq!(high.sqrt_price_x96(), MAX_SQRT_PRICE_X96 - 1);
    destroy(low);
    destroy(high);
}

#[test]
fun dynamic_fee_pool_finalizes_without_a_hook_and_reports_its_settings() {
    let mut ctx = tx_context::dummy();

    let pool = dynamic_pool(&mut ctx);

    let expected = lp_fee::new_dynamic(BASE_FEE_PPM, MAX_FEE_PPM, SENSITIVITY_PPM);
    assert_eq!(pool.lp_fee(), expected);
    assert_eq!(pool.before_swap_hook_for_testing(), option::none());
    pool.assert_reference(SQRT_PRICE_ONE_X96, 0);
    let created = event::events_by_type<PoolCreated>();
    assert_eq!(created.length(), 1);
    assert_eq!(created[0].pool_created_lp_fee_for_testing(), expected);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::EInvalidHookFlags, location = blast_fun_dex::pool)]
fun register_hook_rejects_empty_flags() {
    let mut ctx = tx_context::dummy();
    let fixture = new_fixture(&mut ctx);
    let mut initializer = pool::new_with_fixed_fee<ASSET, QUOTE>(
        TICK_SPACING,
        LP_FEE_PPM,
        SQRT_PRICE_ONE_X96,
        &mut ctx,
    );

    initializer.register_hook(&fixture.test_config, TestHook(), 0);

    destroy(initializer);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = pool::EHookSlotTaken, location = blast_fun_dex::pool)]
fun register_hook_rejects_a_slot_bound_to_another_hook() {
    let mut ctx = tx_context::dummy();
    let fixture = new_fixture(&mut ctx);
    let mut initializer = pool::new_with_fixed_fee<ASSET, QUOTE>(
        TICK_SPACING,
        LP_FEE_PPM,
        SQRT_PRICE_ONE_X96,
        &mut ctx,
    );
    initializer.register_hook(&fixture.test_config, TestHook(), pool::before_swap_flag!());

    initializer.register_hook(
        &fixture.other_config,
        OtherHook(),
        pool::before_swap_flag!() | pool::after_swap_flag!(),
    );

    destroy(initializer);
    destroy(fixture);
}

#[test]
fun register_hook_binds_only_the_selected_slots() {
    let mut ctx = tx_context::dummy();
    let fixture = new_fixture(&mut ctx);

    let pool = fixture.hooked_pool(pool::before_swap_flag!(), &mut ctx);

    assert_eq!(pool.before_swap_hook_for_testing(), option::some(type_name::with_defining_ids<TestHook>()));
    assert_eq!(pool.after_donate_hook_for_testing(), option::none());
    destroy(pool);
    destroy(fixture);
}

// Positions.

#[test]
#[expected_failure(abort_code = pool::EInvalidTickRange, location = blast_fun_dex::pool)]
fun new_position_rejects_equal_ticks() {
    let mut ctx = tx_context::dummy();
    let pool = plain_pool(&mut ctx);

    let position = pool.new_position(i32::from_u32(60), i32::from_u32(60), &mut ctx);

    destroy(position);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::EInvalidTickRange, location = blast_fun_dex::pool)]
fun new_position_rejects_a_tick_off_the_spacing() {
    let mut ctx = tx_context::dummy();
    let pool = plain_pool(&mut ctx);

    let position = pool.new_position(i32::neg_from_u32(60), i32::from_u32(61), &mut ctx);

    destroy(position);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::EInvalidTickRange, location = blast_fun_dex::pool)]
fun new_position_rejects_a_tick_beyond_the_maximum() {
    let mut ctx = tx_context::dummy();
    // 887,280 is a multiple of 60 just above the 887,272 maximum.
    let pool = plain_pool(&mut ctx);

    let position = pool.new_position(i32::neg_from_u32(887_280), i32::from_u32(60), &mut ctx);

    destroy(position);
    destroy(pool);
}

#[test]
fun new_position_starts_empty_and_destroys() {
    let mut ctx = tx_context::dummy();
    let pool = plain_pool(&mut ctx);

    let position = pool.new_position(i32::neg_from_u32(887_220), i32::from_u32(887_220), &mut ctx);

    assert_eq!(position.pool_id(), object::id(&pool));
    assert_eq!(position.liquidity(), 0);
    position.destroy_empty();
    destroy(pool);
}

// Swap.

#[test]
fun unhooked_swap_settles_reserves_and_returns_change() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let mut pool = plain_pool(&mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(0), balance::create_for_testing(1_000));

    let request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);
    assert!(pool.is_in_operation_for_testing());
    let completion = pool.execute_swap_with_amounts_for_testing(request, 60, 55, BELOW_PRICE_X96, &clock, &mut ctx);
    let (asset_coin, quote_coin) = pool.finish(completion, 40, 55, &mut ctx);

    assert_eq!(asset_coin.burn_for_testing(), 40);
    assert_eq!(quote_coin.burn_for_testing(), 55);
    pool.assert_reserves(60, 945);
    assert_eq!(pool.sqrt_price_x96(), BELOW_PRICE_X96);
    assert!(!pool.is_in_operation_for_testing());
    destroy(pool);
    clock.destroy_for_testing();
}

#[test]
fun quote_to_asset_swap_settles_the_other_side() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let mut pool = plain_pool(&mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(1_000), balance::create_for_testing(0));

    let request = pool.begin_swap_quote_to_asset(quote(100, &mut ctx), ABOVE_PRICE_X96);
    assert!(!request.is_asset_input());
    let completion = pool.execute_swap_with_amounts_for_testing(request, 100, 90, ABOVE_PRICE_X96, &clock, &mut ctx);
    let (asset_coin, quote_coin) = pool.finish(completion, 90, 0, &mut ctx);

    assert_eq!(asset_coin.burn_for_testing(), 90);
    assert_eq!(quote_coin.burn_for_testing(), 0);
    pool.assert_reserves(910, 100);
    destroy(pool);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = pool::ECurveMathUnavailable, location = blast_fun_dex::pool)]
fun execute_swap_reaches_the_curve_seam_once_approved() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let fixture = new_fixture(&mut ctx);
    let mut pool = fixture.hooked_pool(pool::before_swap_flag!(), &mut ctx);
    let mut request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);
    request.approve(&pool, TestHook());

    let completion = pool.execute_swap(request, &clock, &mut ctx);

    destroy(completion);
    destroy(pool);
    destroy(fixture);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = pool::EPoolInOperation, location = blast_fun_dex::pool)]
fun begin_rejects_a_second_operation_on_a_busy_pool() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);
    let first = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);

    let second = pool.begin_donate(asset(1, &mut ctx), quote(0, &mut ctx));

    destroy(first);
    destroy(second);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::EZeroAmount, location = blast_fun_dex::pool)]
fun begin_swap_rejects_a_zero_payment() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);

    let request = pool.begin_swap_asset_to_quote(asset(0, &mut ctx), BELOW_PRICE_X96);

    destroy(request);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::EZeroAmount, location = blast_fun_dex::pool)]
fun begin_swap_checks_the_payment_before_the_price_limit() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);

    let request = pool.begin_swap_asset_to_quote(asset(0, &mut ctx), ABOVE_PRICE_X96);

    destroy(request);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::EInvalidPriceLimit, location = blast_fun_dex::pool)]
fun begin_swap_asset_to_quote_rejects_a_limit_above_the_price() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);

    let request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), ABOVE_PRICE_X96);

    destroy(request);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::EInvalidPriceLimit, location = blast_fun_dex::pool)]
fun begin_swap_asset_to_quote_rejects_the_minimum_price_limit() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);

    let request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), MIN_SQRT_PRICE_X96);

    destroy(request);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::EInvalidPriceLimit, location = blast_fun_dex::pool)]
fun begin_swap_quote_to_asset_rejects_the_current_price_as_limit() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);

    let request = pool.begin_swap_quote_to_asset(quote(100, &mut ctx), SQRT_PRICE_ONE_X96);

    destroy(request);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::EMissingApproval, location = blast_fun_dex::pool)]
fun execute_swap_rejects_a_request_the_bound_hook_did_not_approve() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let fixture = new_fixture(&mut ctx);
    let mut pool = fixture.hooked_pool(pool::before_swap_flag!(), &mut ctx);
    let request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);

    let completion = pool.execute_swap(request, &clock, &mut ctx);

    destroy(completion);
    destroy(pool);
    destroy(fixture);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = pool::EHookNotBound, location = blast_fun_dex::pool)]
fun approve_rejects_a_witness_not_bound_to_the_slot() {
    let mut ctx = tx_context::dummy();
    let fixture = new_fixture(&mut ctx);
    let mut pool = fixture.hooked_pool(pool::before_swap_flag!(), &mut ctx);
    let mut request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);

    request.approve(&pool, OtherHook());

    destroy(request);
    destroy(pool);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = pool::EHookNotBound, location = blast_fun_dex::pool)]
fun approve_rejects_any_witness_on_an_empty_slot() {
    let mut ctx = tx_context::dummy();
    let fixture = new_fixture(&mut ctx);
    let mut pool = fixture.hooked_pool(pool::after_swap_flag!(), &mut ctx);
    let mut request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);

    request.approve(&pool, TestHook());

    destroy(request);
    destroy(pool);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = pool::EAlreadyApproved, location = blast_fun_dex::pool)]
fun approve_rejects_a_second_approval() {
    let mut ctx = tx_context::dummy();
    let fixture = new_fixture(&mut ctx);
    let mut pool = fixture.hooked_pool(pool::before_swap_flag!(), &mut ctx);
    let mut request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);
    request.approve(&pool, TestHook());

    request.approve(&pool, TestHook());

    destroy(request);
    destroy(pool);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = pool::EAlreadyApproved, location = blast_fun_dex::pool)]
fun take_payment_rejects_an_approved_request() {
    let mut ctx = tx_context::dummy();
    let fixture = new_fixture(&mut ctx);
    let mut pool = fixture.hooked_pool(pool::before_swap_flag!(), &mut ctx);
    let mut request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);
    request.approve(&pool, TestHook());

    let taken = request.take_asset_payment(&pool, TestHook(), 1);

    destroy(taken);
    destroy(request);
    destroy(pool);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = pool::EWrongPool, location = blast_fun_dex::pool)]
fun approve_rejects_a_request_from_another_pool() {
    let mut ctx = tx_context::dummy();
    let fixture = new_fixture(&mut ctx);
    let mut first_pool = fixture.hooked_pool(pool::before_swap_flag!(), &mut ctx);
    let second_pool = fixture.hooked_pool(pool::before_swap_flag!(), &mut ctx);
    let mut request = first_pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);

    request.approve(&second_pool, TestHook());

    destroy(request);
    destroy(first_pool);
    destroy(second_pool);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = pool::EWrongPool, location = blast_fun_dex::pool)]
fun execute_swap_rejects_a_request_from_another_pool() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let mut first_pool = plain_pool(&mut ctx);
    let mut second_pool = plain_pool(&mut ctx);
    let request = first_pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);

    let completion = second_pool.execute_swap(request, &clock, &mut ctx);

    destroy(completion);
    destroy(first_pool);
    destroy(second_pool);
    clock.destroy_for_testing();
}

#[test]
fun before_swap_hook_takes_payment_and_the_pool_keeps_its_lp_fee() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let fixture = new_fixture(&mut ctx);
    let mut pool = fixture.hooked_pool(pool::before_swap_flag!(), &mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(0), balance::create_for_testing(1_000));
    let mut request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);

    let hook_fee = request.take_asset_payment(&pool, TestHook(), 10);
    request.approve(&pool, TestHook());

    assert_eq!(hook_fee.destroy_for_testing(), 10);
    assert_eq!(request.input_value(), 90);
    let completion = pool.execute_swap_with_amounts_for_testing(request, 90, 80, BELOW_PRICE_X96, &clock, &mut ctx);
    let (asset_coin, quote_coin) = pool.finish(completion, 0, 80, &mut ctx);
    assert_eq!(asset_coin.burn_for_testing(), 0);
    assert_eq!(quote_coin.burn_for_testing(), 80);
    assert_eq!(swapped_lp_fees_ppm(), vector[LP_FEE_PPM]);
    destroy(pool);
    destroy(fixture);
    clock.destroy_for_testing();
}

// LP fee.

#[test]
fun fixed_fee_swaps_price_once_and_never_move_the_reference() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(NOW_MS);
    let mut pool = plain_pool(&mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(1_000), balance::create_for_testing(1_000));

    let first = pool.swap_asset_to_quote_and_priced_lp_fees(
        PRICE_DOWN_8_PERCENT_X96,
        PRICE_DOWN_4_PERCENT_X96,
        &clock,
        &mut ctx,
    );
    assert_eq!(pool.sqrt_price_x96(), PRICE_DOWN_4_PERCENT_X96);

    clock.increment_for_testing(2 * WINDOW_MS);
    let second = pool.swap_asset_to_quote_and_priced_lp_fees(
        PRICE_DOWN_8_PERCENT_X96,
        PRICE_DOWN_8_PERCENT_X96,
        &clock,
        &mut ctx,
    );

    assert_eq!(first, vector[LP_FEE_PPM]);
    assert_eq!(second, vector[LP_FEE_PPM]);
    assert_eq!(swapped_lp_fees_ppm(), vector[LP_FEE_PPM, LP_FEE_PPM]);
    pool.assert_reference(SQRT_PRICE_ONE_X96, 0);
    clock.destroy_for_testing();
    destroy(pool);
}

#[test]
fun first_dynamic_swap_measures_against_the_creation_price() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(NOW_MS);
    let mut pool = dynamic_pool(&mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(1_000), balance::create_for_testing(1_000));

    // The reference starts at time zero, so the first swap moves it all the way
    // to the pre-swap price, which is still the creation price.
    let priced_lp_fees_ppm = pool.swap_asset_to_quote_and_priced_lp_fees(
        PRICE_DOWN_4_PERCENT_X96,
        PRICE_DOWN_4_PERCENT_X96,
        &clock,
        &mut ctx,
    );

    // 3,000 + 1,000,000 * 0.04^2 = 4,600 ppm.
    assert_eq!(priced_lp_fees_ppm, vector[BASE_FEE_PPM, 4_600]);
    assert_eq!(swapped_lp_fees_ppm(), vector[4_600]);
    pool.assert_reference(SQRT_PRICE_ONE_X96, NOW_MS);
    clock.destroy_for_testing();
    destroy(pool);
}

#[test]
fun dynamic_asset_to_quote_swap_previews_at_the_base_fee_and_charges_the_gap_fee() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let mut pool = dynamic_pool(&mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(0), balance::create_for_testing(1_000));
    let request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);

    // The preview drops the price 4%: 3,000 + 1,000,000 * 0.04^2 = 4,600 ppm.
    let (completion, priced_lp_fees_ppm) = pool.execute_swap_with_preview_for_testing(
        request,
        PRICE_DOWN_4_PERCENT_X96,
        100,
        90,
        PRICE_DOWN_4_PERCENT_X96 + 1,
        &clock,
        &mut ctx,
    );

    assert_eq!(priced_lp_fees_ppm, vector[BASE_FEE_PPM, 4_600]);
    assert_eq!(swapped_lp_fees_ppm(), vector[4_600]);
    assert_eq!(pool.sqrt_price_x96(), PRICE_DOWN_4_PERCENT_X96 + 1);
    let (asset_coin, quote_coin) = pool.finish(completion, 0, 90, &mut ctx);
    asset_coin.destroy_zero();
    assert_eq!(quote_coin.burn_for_testing(), 90);
    pool.assert_reserves(100, 910);
    clock.destroy_for_testing();
    destroy(pool);
}

#[test]
fun dynamic_quote_to_asset_swap_previews_at_the_base_fee_and_charges_the_gap_fee() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let mut pool = dynamic_pool(&mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(1_000), balance::create_for_testing(0));
    let request = pool.begin_swap_quote_to_asset(quote(100, &mut ctx), ABOVE_PRICE_X96);

    // The preview lifts the price 8%: 3,000 + 1,000,000 * 0.08^2 = 9,400 ppm.
    let (completion, priced_lp_fees_ppm) = pool.execute_swap_with_preview_for_testing(
        request,
        PRICE_UP_8_PERCENT_X96,
        100,
        90,
        PRICE_UP_8_PERCENT_X96 - 1,
        &clock,
        &mut ctx,
    );

    assert_eq!(priced_lp_fees_ppm, vector[BASE_FEE_PPM, 9_400]);
    assert_eq!(swapped_lp_fees_ppm(), vector[9_400]);
    assert_eq!(pool.sqrt_price_x96(), PRICE_UP_8_PERCENT_X96 - 1);
    let (asset_coin, quote_coin) = pool.finish(completion, 90, 0, &mut ctx);
    assert_eq!(asset_coin.burn_for_testing(), 90);
    quote_coin.destroy_zero();
    pool.assert_reserves(910, 100);
    clock.destroy_for_testing();
    destroy(pool);
}

#[test]
fun dynamic_swap_charges_the_maximum_for_a_preview_far_from_the_reference() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let mut pool = dynamic_pool(&mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(1_000), balance::create_for_testing(1_000));

    let priced_lp_fees_ppm = pool.swap_asset_to_quote_and_priced_lp_fees(
        BELOW_PRICE_X96,
        BELOW_PRICE_X96,
        &clock,
        &mut ctx,
    );

    assert_eq!(priced_lp_fees_ppm, vector[BASE_FEE_PPM, MAX_FEE_PPM]);
    clock.destroy_for_testing();
    destroy(pool);
}

#[test]
fun half_a_window_moves_the_reference_halfway_up() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(NOW_MS);
    let mut pool = dynamic_pool(&mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(1_000), balance::create_for_testing(1_000));
    pool.swap_quote_to_asset_and_priced_lp_fees(PRICE_UP_8_PERCENT_X96, PRICE_UP_8_PERCENT_X96, &clock, &mut ctx);

    clock.increment_for_testing(WINDOW_MS / 2);
    let priced_lp_fees_ppm = pool.swap_quote_to_asset_and_priced_lp_fees(
        PRICE_UP_8_PERCENT_X96,
        PRICE_UP_8_PERCENT_X96,
        &clock,
        &mut ctx,
    );

    let halfway = SQRT_PRICE_ONE_X96 + (PRICE_UP_8_PERCENT_X96 - SQRT_PRICE_ONE_X96) / 2;
    pool.assert_reference(halfway, NOW_MS + WINDOW_MS / 2);
    let charged_fee_ppm = pool.lp_fee().fee_ppm_at_price(halfway, PRICE_UP_8_PERCENT_X96);
    // Measured from price 1.0396, price 1.08 is 3.885% away: 3,000 + 1,509 ppm.
    assert_eq!(charged_fee_ppm, 4_509);
    assert_eq!(priced_lp_fees_ppm, vector[BASE_FEE_PPM, charged_fee_ppm]);
    clock.destroy_for_testing();
    destroy(pool);
}

#[test]
fun half_a_window_moves_the_reference_halfway_down() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(NOW_MS);
    let mut pool = dynamic_pool(&mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(1_000), balance::create_for_testing(1_000));
    pool.swap_asset_to_quote_and_priced_lp_fees(PRICE_DOWN_8_PERCENT_X96, PRICE_DOWN_8_PERCENT_X96, &clock, &mut ctx);

    clock.increment_for_testing(WINDOW_MS / 2);
    let priced_lp_fees_ppm = pool.swap_asset_to_quote_and_priced_lp_fees(
        PRICE_DOWN_8_PERCENT_X96,
        PRICE_DOWN_8_PERCENT_X96,
        &clock,
        &mut ctx,
    );

    let halfway = SQRT_PRICE_ONE_X96 - (SQRT_PRICE_ONE_X96 - PRICE_DOWN_8_PERCENT_X96) / 2;
    pool.assert_reference(halfway, NOW_MS + WINDOW_MS / 2);
    let charged_fee_ppm = pool.lp_fee().fee_ppm_at_price(halfway, PRICE_DOWN_8_PERCENT_X96);
    // Measured from price 0.9596, price 0.92 is 4.125% away: 3,000 + 1,701 ppm.
    assert_eq!(charged_fee_ppm, 4_701);
    assert_eq!(priced_lp_fees_ppm, vector[BASE_FEE_PPM, charged_fee_ppm]);
    clock.destroy_for_testing();
    destroy(pool);
}

#[test]
fun a_full_window_or_more_lands_the_reference_on_the_pool_price() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(NOW_MS);
    let mut pool = dynamic_pool(&mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(1_000), balance::create_for_testing(1_000));
    pool.swap_asset_to_quote_and_priced_lp_fees(PRICE_DOWN_4_PERCENT_X96, PRICE_DOWN_4_PERCENT_X96, &clock, &mut ctx);

    // Exactly one window: the preview at the pre-swap price has no gap.
    clock.increment_for_testing(WINDOW_MS);
    let at_one_window = pool.swap_asset_to_quote_and_priced_lp_fees(
        PRICE_DOWN_4_PERCENT_X96,
        PRICE_DOWN_8_PERCENT_X96,
        &clock,
        &mut ctx,
    );
    pool.assert_reference(PRICE_DOWN_4_PERCENT_X96, NOW_MS + WINDOW_MS);

    clock.increment_for_testing(10 * WINDOW_MS);
    let after_ten_windows = pool.swap_asset_to_quote_and_priced_lp_fees(
        PRICE_DOWN_8_PERCENT_X96,
        PRICE_DOWN_8_PERCENT_X96,
        &clock,
        &mut ctx,
    );

    assert_eq!(at_one_window, vector[BASE_FEE_PPM, BASE_FEE_PPM]);
    assert_eq!(after_ten_windows, vector[BASE_FEE_PPM, BASE_FEE_PPM]);
    pool.assert_reference(PRICE_DOWN_8_PERCENT_X96, NOW_MS + 11 * WINDOW_MS);
    clock.destroy_for_testing();
    destroy(pool);
}

#[test]
fun same_timestamp_swaps_share_the_unmoved_reference_and_later_ones_see_it_move() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(NOW_MS);
    let mut pool = dynamic_pool(&mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(1_000), balance::create_for_testing(1_000));
    pool.swap_asset_to_quote_and_priced_lp_fees(PRICE_DOWN_4_PERCENT_X96, PRICE_DOWN_4_PERCENT_X96, &clock, &mut ctx);

    // Same timestamp: the 4% move does not count, so 8% is measured from 1.0.
    let same_timestamp = pool.swap_asset_to_quote_and_priced_lp_fees(
        PRICE_DOWN_8_PERCENT_X96,
        PRICE_DOWN_8_PERCENT_X96,
        &clock,
        &mut ctx,
    );
    assert_eq!(same_timestamp, vector[BASE_FEE_PPM, 9_400]);
    pool.assert_reference(SQRT_PRICE_ONE_X96, NOW_MS);

    // A tenth of a window later the reference moves a tenth toward the 8% price.
    clock.increment_for_testing(WINDOW_MS / 10);
    let later = pool.swap_asset_to_quote_and_priced_lp_fees(
        PRICE_DOWN_8_PERCENT_X96,
        PRICE_DOWN_8_PERCENT_X96,
        &clock,
        &mut ctx,
    );

    let moved = SQRT_PRICE_ONE_X96 - (SQRT_PRICE_ONE_X96 - PRICE_DOWN_8_PERCENT_X96) / 10;
    pool.assert_reference(moved, NOW_MS + WINDOW_MS / 10);
    let charged_fee_ppm = pool.lp_fee().fee_ppm_at_price(moved, PRICE_DOWN_8_PERCENT_X96);
    assert!(charged_fee_ppm < 9_400);
    assert_eq!(later, vector[BASE_FEE_PPM, charged_fee_ppm]);
    clock.destroy_for_testing();
    destroy(pool);
}

#[test]
fun reference_moves_without_aborting_between_extreme_prices() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(NOW_MS);
    let mut pool = pool::new_with_dynamic_fee<ASSET, QUOTE>(
        TICK_SPACING,
        BASE_FEE_PPM,
        MAX_FEE_PPM,
        SENSITIVITY_PPM,
        MAX_SQRT_PRICE_X96 - 1,
        &mut ctx,
    ).finalize();
    pool.join_reserves_for_testing(balance::create_for_testing(1_000), balance::create_for_testing(1_000));
    let crash = pool.swap_asset_to_quote_and_priced_lp_fees(
        MIN_SQRT_PRICE_X96 + 1,
        MIN_SQRT_PRICE_X96 + 1,
        &clock,
        &mut ctx,
    );

    clock.increment_for_testing(WINDOW_MS - 1);
    let recovery = pool.swap_quote_to_asset_and_priced_lp_fees(
        MAX_SQRT_PRICE_X96 - 2,
        MAX_SQRT_PRICE_X96 - 2,
        &clock,
        &mut ctx,
    );

    assert_eq!(crash, vector[BASE_FEE_PPM, MAX_FEE_PPM]);
    assert_eq!(recovery, vector[BASE_FEE_PPM, MAX_FEE_PPM]);
    let (reference_sqrt_price_x96, _) = pool.reference_for_testing();
    assert!(reference_sqrt_price_x96 > MIN_SQRT_PRICE_X96 + 1);
    assert!(reference_sqrt_price_x96 < MAX_SQRT_PRICE_X96 - 1);
    clock.destroy_for_testing();
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::ECurveMathUnavailable, location = blast_fun_dex::pool)]
fun execute_dynamic_swap_reaches_the_curve_seam_for_the_preview() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let mut pool = dynamic_pool(&mut ctx);
    let request = pool.begin_swap_quote_to_asset(quote(100, &mut ctx), ABOVE_PRICE_X96);

    let completion = pool.execute_swap(request, &clock, &mut ctx);

    destroy(completion);
    clock.destroy_for_testing();
    destroy(pool);
}

#[test]
fun after_hook_adjusts_output_before_approving() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let fixture = new_fixture(&mut ctx);
    let mut pool = fixture.hooked_pool(pool::after_swap_flag!(), &mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(0), balance::create_for_testing(1_000));
    let request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);
    let mut completion = pool.execute_swap_with_amounts_for_testing(
        request,
        100,
        90,
        BELOW_PRICE_X96,
        &clock,
        &mut ctx,
    );

    let skimmed = completion.take_quote_output(&pool, TestHook(), 5);
    completion.join_asset_output(&pool, TestHook(), balance::create_for_testing(2));
    completion.approve(&pool, TestHook());

    assert_eq!(skimmed.destroy_for_testing(), 5);
    let (asset_coin, quote_coin) = pool.finish(completion, 2, 85, &mut ctx);
    assert_eq!(asset_coin.burn_for_testing(), 2);
    assert_eq!(quote_coin.burn_for_testing(), 85);
    destroy(pool);
    destroy(fixture);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = pool::EMissingApproval, location = blast_fun_dex::pool)]
fun finish_rejects_a_completion_the_after_hook_did_not_approve() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let fixture = new_fixture(&mut ctx);
    let mut pool = fixture.hooked_pool(pool::after_swap_flag!(), &mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(0), balance::create_for_testing(1_000));
    let request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);
    let completion = pool.execute_swap_with_amounts_for_testing(request, 100, 90, BELOW_PRICE_X96, &clock, &mut ctx);

    let (asset_coin, quote_coin) = pool.finish(completion, 0, 0, &mut ctx);

    destroy(asset_coin);
    destroy(quote_coin);
    destroy(pool);
    destroy(fixture);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = pool::EInsufficientOutput, location = blast_fun_dex::pool)]
fun finish_rejects_output_below_the_minimum() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let mut pool = plain_pool(&mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(0), balance::create_for_testing(1_000));
    let request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);
    let completion = pool.execute_swap_with_amounts_for_testing(request, 100, 90, BELOW_PRICE_X96, &clock, &mut ctx);

    let (asset_coin, quote_coin) = pool.finish(completion, 0, 91, &mut ctx);

    destroy(asset_coin);
    destroy(quote_coin);
    destroy(pool);
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = pool::EWrongPool, location = blast_fun_dex::pool)]
fun finish_rejects_a_completion_from_another_pool() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let mut first_pool = plain_pool(&mut ctx);
    let mut second_pool = plain_pool(&mut ctx);
    first_pool.join_reserves_for_testing(balance::create_for_testing(0), balance::create_for_testing(1_000));
    let request = first_pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);
    let completion = first_pool.execute_swap_with_amounts_for_testing(
        request,
        100,
        90,
        BELOW_PRICE_X96,
        &clock,
        &mut ctx,
    );

    let (asset_coin, quote_coin) = second_pool.finish(completion, 0, 0, &mut ctx);

    destroy(asset_coin);
    destroy(quote_coin);
    destroy(first_pool);
    destroy(second_pool);
    clock.destroy_for_testing();
}

// Liquidity.

#[test]
fun add_and_remove_liquidity_move_reserves_and_position_liquidity() {
    let mut ctx = tx_context::dummy();
    let fixture = new_fixture(&mut ctx);
    let mut pool = fixture.hooked_pool(pool::all_hook_flags!(), &mut ctx);
    let mut position = pool.new_position(i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);

    let mut add_request = pool.begin_add_liquidity(&position, 500, asset(100, &mut ctx), quote(100, &mut ctx));
    assert_eq!(add_request.liquidity(), 500);
    add_request.approve(&pool, TestHook());
    let mut added = pool.execute_add_liquidity_with_amounts_for_testing(add_request, &mut position, 70, 60);
    added.approve(&pool, TestHook());
    let (asset_refund, quote_refund) = pool.finish(added, 30, 40, &mut ctx);

    assert_eq!(asset_refund.burn_for_testing(), 30);
    assert_eq!(quote_refund.burn_for_testing(), 40);
    assert_eq!(position.liquidity(), 500);
    pool.assert_reserves(70, 60);

    let mut remove_request = pool.begin_remove_liquidity(&position, 500);
    remove_request.approve(&pool, TestHook());
    let mut removed = pool.execute_remove_liquidity_with_amounts_for_testing(remove_request, &mut position, 69, 59);
    removed.approve(&pool, TestHook());
    let (asset_out, quote_out) = pool.finish(removed, 69, 59, &mut ctx);

    assert_eq!(asset_out.burn_for_testing(), 69);
    assert_eq!(quote_out.burn_for_testing(), 59);
    pool.assert_reserves(1, 1);
    position.destroy_empty();
    destroy(pool);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = pool::ECurveMathUnavailable, location = blast_fun_dex::pool)]
fun execute_add_liquidity_reaches_the_curve_seam_once_approved() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);
    let mut position = pool.new_position(i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);
    let request = pool.begin_add_liquidity(&position, 500, asset(100, &mut ctx), quote(100, &mut ctx));

    let completion = pool.execute_add_liquidity(request, &mut position);

    destroy(completion);
    destroy(position);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::EInsufficientPayment, location = blast_fun_dex::pool)]
fun add_liquidity_rejects_a_payment_below_the_requirement() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);
    let mut position = pool.new_position(i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);
    let request = pool.begin_add_liquidity(&position, 500, asset(100, &mut ctx), quote(100, &mut ctx));

    let completion = pool.execute_add_liquidity_with_amounts_for_testing(request, &mut position, 101, 0);

    destroy(completion);
    destroy(position);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::EWrongPosition, location = blast_fun_dex::pool)]
fun execute_add_liquidity_rejects_a_different_position() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);
    let position = pool.new_position(i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);
    let mut other_position = pool.new_position(i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);
    let request = pool.begin_add_liquidity(&position, 500, asset(100, &mut ctx), quote(100, &mut ctx));

    let completion = pool.execute_add_liquidity(request, &mut other_position);

    destroy(completion);
    destroy(position);
    destroy(other_position);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::EWrongPool, location = blast_fun_dex::pool)]
fun begin_add_liquidity_rejects_a_position_of_another_pool() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);
    let other_pool = plain_pool(&mut ctx);
    let position = other_pool.new_position(i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);

    let request = pool.begin_add_liquidity(&position, 500, asset(100, &mut ctx), quote(100, &mut ctx));

    destroy(request);
    destroy(position);
    destroy(pool);
    destroy(other_pool);
}

#[test]
#[expected_failure(abort_code = pool::EZeroLiquidity, location = blast_fun_dex::pool)]
fun begin_add_liquidity_rejects_zero_liquidity() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);
    let position = pool.new_position(i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);

    let request = pool.begin_add_liquidity(&position, 0, asset(100, &mut ctx), quote(100, &mut ctx));

    destroy(request);
    destroy(position);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::EInsufficientLiquidity, location = blast_fun_dex::pool)]
fun begin_remove_liquidity_rejects_more_than_the_position_holds() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);
    let position = pool.new_position(i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);

    let request = pool.begin_remove_liquidity(&position, 1);

    destroy(request);
    destroy(position);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::EPositionNotEmpty, location = blast_fun_dex::pool)]
fun destroy_empty_position_rejects_a_position_with_liquidity() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);
    let mut position = pool.new_position(i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);
    let request = pool.begin_add_liquidity(&position, 500, asset(100, &mut ctx), quote(100, &mut ctx));
    let completion = pool.execute_add_liquidity_with_amounts_for_testing(request, &mut position, 100, 100);
    let (asset_refund, quote_refund) = pool.finish(completion, 0, 0, &mut ctx);
    asset_refund.destroy_zero();
    quote_refund.destroy_zero();

    position.destroy_empty();

    destroy(pool);
}

// Donate.

#[test]
fun donate_runs_both_hooks_and_returns_empty_coins() {
    let mut ctx = tx_context::dummy();
    let fixture = new_fixture(&mut ctx);
    let mut pool = fixture.hooked_pool(pool::before_donate_flag!() | pool::after_donate_flag!(), &mut ctx);

    let mut request = pool.begin_donate(asset(5, &mut ctx), quote(0, &mut ctx));
    assert_eq!(request.asset_value(), 5);
    assert_eq!(request.quote_value(), 0);
    request.approve(&pool, TestHook());
    let mut completion = pool.execute_donate_for_testing(request);
    completion.approve(&pool, TestHook());
    let (asset_coin, quote_coin) = pool.finish(completion, 0, 0, &mut ctx);

    asset_coin.destroy_zero();
    quote_coin.destroy_zero();
    pool.assert_reserves(5, 0);
    destroy(pool);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = pool::EZeroAmount, location = blast_fun_dex::pool)]
fun begin_donate_rejects_an_empty_donation() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);

    let request = pool.begin_donate(asset(0, &mut ctx), quote(0, &mut ctx));

    destroy(request);
    destroy(pool);
}

#[test]
#[expected_failure(abort_code = pool::ECurveMathUnavailable, location = blast_fun_dex::pool)]
fun execute_donate_reaches_the_curve_seam() {
    let mut ctx = tx_context::dummy();
    let mut pool = plain_pool(&mut ctx);
    let request = pool.begin_donate(asset(5, &mut ctx), quote(0, &mut ctx));

    let completion = pool.execute_donate(request);

    destroy(completion);
    destroy(pool);
}

// Hook state.

#[test]
fun hook_state_is_isolated_per_witness_and_writable_mid_operation() {
    let mut ctx = tx_context::dummy();
    let fixture = new_fixture(&mut ctx);
    let mut initializer = pool::new_with_fixed_fee<ASSET, QUOTE>(
        TICK_SPACING,
        LP_FEE_PPM,
        SQRT_PRICE_ONE_X96,
        &mut ctx,
    );
    initializer.register_hook(&fixture.test_config, TestHook(), pool::before_swap_flag!());
    initializer.register_hook(&fixture.other_config, OtherHook(), pool::after_swap_flag!());
    let mut pool = initializer.finalize();
    let request = pool.begin_swap_asset_to_quote(asset(100, &mut ctx), BELOW_PRICE_X96);

    pool.add_hook_state(&TestHook(), StateName(), 1u64);
    pool.add_hook_state(&OtherHook(), StateName(), 2u64);
    *pool.hook_state_mut<_, _, _, _, u64>(&TestHook(), StateName()) = 3;

    assert_eq!(*pool.hook_state<_, _, _, _, u64>(&TestHook(), StateName()), 3);
    assert_eq!(*pool.hook_state<_, _, _, _, u64>(&OtherHook(), StateName()), 2);
    assert_eq!(pool.remove_hook_state<_, _, _, _, u64>(&OtherHook(), StateName()), 2);
    assert!(!pool.has_hook_state(&OtherHook(), StateName()));
    assert!(pool.has_hook_state(&TestHook(), StateName()));
    destroy(request);
    destroy(pool);
    destroy(fixture);
}

#[test]
#[expected_failure(abort_code = pool::EHookNotBound, location = blast_fun_dex::pool)]
fun hook_state_rejects_a_hook_not_bound_to_the_pool() {
    let mut ctx = tx_context::dummy();
    let fixture = new_fixture(&mut ctx);
    let mut pool = fixture.hooked_pool(pool::before_swap_flag!(), &mut ctx);

    pool.add_hook_state(&OtherHook(), StateName(), 1u64);

    destroy(pool);
    destroy(fixture);
}

// === Test Helpers ===

fun new_fixture(ctx: &mut TxContext): Fixture {
    let mut namespace = hook_config::new_namespace_for_testing(ctx);
    let test_config = hook_config::new(&mut namespace, TestHook(), 1);
    let other_config = hook_config::new(&mut namespace, OtherHook(), 1);

    Fixture { namespace, test_config, other_config }
}

/// Fixed-fee pool with `TestHook` bound to `flags`.
fun hooked_pool(self: &Fixture, flags: u8, ctx: &mut TxContext): Pool<ASSET, QUOTE> {
    let mut initializer = pool::new_with_fixed_fee(TICK_SPACING, LP_FEE_PPM, SQRT_PRICE_ONE_X96, ctx);
    initializer.register_hook(&self.test_config, TestHook(), flags);

    initializer.finalize()
}

/// Unhooked dynamic-fee pool at price 1.0.
fun dynamic_pool(ctx: &mut TxContext): Pool<ASSET, QUOTE> {
    pool::new_with_dynamic_fee(TICK_SPACING, BASE_FEE_PPM, MAX_FEE_PPM, SENSITIVITY_PPM, SQRT_PRICE_ONE_X96, ctx)
        .finalize()
}

/// The LP fee every `Swapped` event so far reports, in order.
fun swapped_lp_fees_ppm(): vector<u32> {
    event::events_by_type<Swapped>().map!(|swapped| swapped.swapped_lp_fee_ppm_for_testing())
}

/// Swaps 100 Asset for 90 Quote through the curve seam with the given passes,
/// returning the LP fees the curve priced at.
fun swap_asset_to_quote_and_priced_lp_fees(
    pool: &mut Pool<ASSET, QUOTE>,
    preview_sqrt_price_x96: u256,
    sqrt_price_after_x96: u256,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<u32> {
    let request = pool.begin_swap_asset_to_quote(asset(100, ctx), MIN_SQRT_PRICE_X96 + 1);
    let (completion, priced_lp_fees_ppm) = pool.execute_swap_with_preview_for_testing(
        request,
        preview_sqrt_price_x96,
        100,
        90,
        sqrt_price_after_x96,
        clock,
        ctx,
    );
    let (asset_coin, quote_coin) = pool.finish(completion, 0, 90, ctx);
    asset_coin.destroy_zero();
    quote_coin.burn_for_testing();

    priced_lp_fees_ppm
}

/// Swaps 100 Quote for 90 Asset through the curve seam with the given passes,
/// returning the LP fees the curve priced at.
fun swap_quote_to_asset_and_priced_lp_fees(
    pool: &mut Pool<ASSET, QUOTE>,
    preview_sqrt_price_x96: u256,
    sqrt_price_after_x96: u256,
    clock: &Clock,
    ctx: &mut TxContext,
): vector<u32> {
    let request = pool.begin_swap_quote_to_asset(quote(100, ctx), MAX_SQRT_PRICE_X96 - 1);
    let (completion, priced_lp_fees_ppm) = pool.execute_swap_with_preview_for_testing(
        request,
        preview_sqrt_price_x96,
        100,
        90,
        sqrt_price_after_x96,
        clock,
        ctx,
    );
    let (asset_coin, quote_coin) = pool.finish(completion, 90, 0, ctx);
    asset_coin.burn_for_testing();
    quote_coin.destroy_zero();

    priced_lp_fees_ppm
}

fun assert_reference(pool: &Pool<ASSET, QUOTE>, reference_sqrt_price_x96: u256, reference_moved_at_ms: u64) {
    let (actual_reference, actual_moved_at_ms) = pool.reference_for_testing();
    assert_eq!(actual_reference, reference_sqrt_price_x96);
    assert_eq!(actual_moved_at_ms, reference_moved_at_ms);
}

fun assert_reserves(pool: &Pool<ASSET, QUOTE>, asset_reserve: u64, quote_reserve: u64) {
    let (actual_asset, actual_quote) = pool.reserves_for_testing();
    assert_eq!(actual_asset, asset_reserve);
    assert_eq!(actual_quote, quote_reserve);
}

fun plain_pool(ctx: &mut TxContext): Pool<ASSET, QUOTE> {
    pool::new_with_fixed_fee(TICK_SPACING, LP_FEE_PPM, SQRT_PRICE_ONE_X96, ctx).finalize()
}

fun asset(value: u64, ctx: &mut TxContext): Coin<ASSET> {
    coin::mint_for_testing(value, ctx)
}

fun quote(value: u64, ctx: &mut TxContext): Coin<QUOTE> {
    coin::mint_for_testing(value, ctx)
}

// === Imports ===

use blast_fun_dex::{
    hook_config::{Self, HookConfig, HookNamespace},
    i32,
    lp_fee,
    pool::{Self, Pool, PoolCreated, Swapped},
};
use std::{type_name, unit_test::{assert_eq, destroy}};
use sui::{balance, clock::{Self, Clock}, coin::{Self, Coin}, event};

use fun assert_reference as Pool.assert_reference;
use fun assert_reserves as Pool.assert_reserves;
use fun swap_asset_to_quote_and_priced_lp_fees as Pool.swap_asset_to_quote_and_priced_lp_fees;
use fun swap_quote_to_asset_and_priced_lp_fees as Pool.swap_quote_to_asset_and_priced_lp_fees;
