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
/// Square-root prices at approximately 0.96 and 0.92 of the initial price in price terms.
const PRICE_DOWN_4_PERCENT_X96: u256 = 77_627_428_567_259_243_148_980_294_874;
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
#[expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun creation_pause_precedes_fee_and_tick_validation() {
    let mut ctx = tx_context::dummy();
    let mut version = dex::version_for_testing(&mut ctx);
    version.pause_for_testing(constants::create_pause_bit!());

    let initializer = new_fixed_pool<ASSET, QUOTE>(&version, 0, 2_000, SQRT_PRICE_ONE_X96, &mut ctx);

    destroy(initializer);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EIdenticalTokens, location = blast_fun_dex::pool)]
fun new_rejects_identical_tokens() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);

    let initializer = new_fixed_pool<ASSET, ASSET>(&version, TICK_SPACING, LP_FEE_PPM, SQRT_PRICE_ONE_X96, &mut ctx);

    destroy(initializer);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidTickSpacing, location = blast_fun_dex::pool)]
fun new_rejects_zero_tick_spacing() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);

    let initializer = new_fixed_pool<ASSET, QUOTE>(&version, 0, LP_FEE_PPM, SQRT_PRICE_ONE_X96, &mut ctx);

    destroy(initializer);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidTickSpacing, location = blast_fun_dex::pool)]
fun new_rejects_tick_spacing_above_the_maximum() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);

    let initializer = new_fixed_pool<ASSET, QUOTE>(&version, 32_768, LP_FEE_PPM, SQRT_PRICE_ONE_X96, &mut ctx);

    destroy(initializer);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::ENotFeeTier, location = blast_fun_dex::lp_fee)]
fun new_with_fixed_fee_rejects_a_fee_off_the_tiers() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);

    let initializer = new_fixed_pool<ASSET, QUOTE>(&version, TICK_SPACING, 2_000, SQRT_PRICE_ONE_X96, &mut ctx);

    destroy(initializer);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidSensitivity, location = blast_fun_dex::lp_fee)]
fun new_with_dynamic_fee_validates_its_settings() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);

    let initializer = new_dynamic_pool<ASSET, QUOTE>(
        &version,
        TICK_SPACING,
        BASE_FEE_PPM,
        MAX_FEE_PPM,
        99_999,
        SQRT_PRICE_ONE_X96,
        &mut ctx,
    );

    destroy(initializer);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidSqrtPrice, location = blast_fun_dex::pool)]
fun new_rejects_price_below_the_minimum() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);

    let initializer = new_fixed_pool<ASSET, QUOTE>(
        &version,
        TICK_SPACING,
        LP_FEE_PPM,
        MIN_SQRT_PRICE_X96 - 1,
        &mut ctx,
    );

    destroy(initializer);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidSqrtPrice, location = blast_fun_dex::pool)]
fun new_rejects_the_exclusive_maximum_price() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);

    let initializer = new_fixed_pool<ASSET, QUOTE>(&version, TICK_SPACING, LP_FEE_PPM, MAX_SQRT_PRICE_X96, &mut ctx);

    destroy(initializer);
    destroy(version);
}

#[test]
fun new_accepts_every_boundary_value() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);

    let low = new_fixed_pool<ASSET, QUOTE>(&version, 1, 20_000, MIN_SQRT_PRICE_X96, &mut ctx).finalize(&version);
    let high = new_fixed_pool<ASSET, QUOTE>(&version, 32_767, 1_000, MAX_SQRT_PRICE_X96 - 1, &mut ctx).finalize(&version);

    assert_eq!(low.lp_fee().base_fee_ppm(), 20_000);
    assert_eq!(high.lp_fee().base_fee_ppm(), 1_000);
    assert_eq!(high.sqrt_price_x96(), MAX_SQRT_PRICE_X96 - 1);
    destroy(low);
    destroy(high);
    destroy(version);
}

#[test]
fun dynamic_fee_pool_finalizes_without_a_hook_and_reports_its_settings() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);

    let pool = dynamic_pool(&version, &mut ctx);

    let tiers = lp_fee::new_fee_tiers_for_testing(&mut ctx);
    let expected = lp_fee::new_dynamic(&tiers, BASE_FEE_PPM, MAX_FEE_PPM, SENSITIVITY_PPM);
    tiers.destroy_default_fee_tiers_for_testing();
    assert_eq!(pool.lp_fee(), expected);
    assert_eq!(pool.before_swap_hook_for_testing(), option::none());
    pool.assert_reference(SQRT_PRICE_ONE_X96, 0);
    let created = event::events_by_type<PoolCreated<LpFee, Hooks>>();
    assert_eq!(created.length(), 1);
    let (pool_id, asset, quote, tick_spacing, lp_fee, sqrt_price_x96, hooks) = created[0].pool_created_fields();
    assert_eq!(pool_id, object::id(&pool));
    assert_eq!(asset, type_name::with_defining_ids<ASSET>());
    assert_eq!(quote, type_name::with_defining_ids<QUOTE>());
    assert_eq!(tick_spacing, TICK_SPACING);
    assert_eq!(lp_fee, expected);
    assert_eq!(sqrt_price_x96, SQRT_PRICE_ONE_X96);
    assert_eq!(hooks, pool.hooks_for_testing());
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidHookFlags, location = blast_fun_dex::pool)]
fun register_hook_rejects_empty_flags() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut initializer = new_fixed_pool<ASSET, QUOTE>(
        &version,
        TICK_SPACING,
        LP_FEE_PPM,
        SQRT_PRICE_ONE_X96,
        &mut ctx,
    );

    initializer.register_hook(&version, &fixture.test_config, TestHook(), 0);

    destroy(initializer);
    destroy(fixture);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EHookSlotTaken, location = blast_fun_dex::pool)]
fun register_hook_rejects_a_slot_bound_to_another_hook() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut initializer = new_fixed_pool<ASSET, QUOTE>(
        &version,
        TICK_SPACING,
        LP_FEE_PPM,
        SQRT_PRICE_ONE_X96,
        &mut ctx,
    );
    initializer.register_hook(&version, &fixture.test_config, TestHook(), pool::before_swap_flag!());

    initializer.register_hook(
        &version,
        &fixture.other_config,
        OtherHook(),
        pool::before_swap_flag!() | pool::after_swap_flag!(),
    );

    destroy(initializer);
    destroy(fixture);
    destroy(version);
}

#[test]
fun register_hook_binds_only_the_selected_slots() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);

    let pool = fixture.hooked_pool(&version, pool::before_swap_flag!(), &mut ctx);

    assert_eq!(pool.before_swap_hook_for_testing(), option::some(type_name::with_defining_ids<TestHook>()));
    assert_eq!(pool.after_donate_hook_for_testing(), option::none());
    destroy(pool);
    destroy(fixture);
    destroy(version);
}

// Positions.

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidTickRange, location = blast_fun_dex::pool)]
fun new_position_rejects_equal_ticks() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let pool = plain_pool(&version, &mut ctx);

    let position = pool.new_position(&version, i32::from_u32(60), i32::from_u32(60), &mut ctx);

    destroy(position);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidTickRange, location = blast_fun_dex::pool)]
fun new_position_rejects_a_tick_off_the_spacing() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let pool = plain_pool(&version, &mut ctx);

    let position = pool.new_position(&version, i32::neg_from_u32(60), i32::from_u32(61), &mut ctx);

    destroy(position);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidTickRange, location = blast_fun_dex::pool)]
fun new_position_rejects_a_tick_beyond_the_maximum() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    // 887,280 is a multiple of 60 just above the 887,272 maximum.
    let pool = plain_pool(&version, &mut ctx);

    let position = pool.new_position(&version, i32::neg_from_u32(887_280), i32::from_u32(60), &mut ctx);

    destroy(position);
    destroy(pool);
    destroy(version);
}

#[test]
fun new_position_starts_empty_and_destroys() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let pool = plain_pool(&version, &mut ctx);

    let position = pool.new_position(&version, i32::neg_from_u32(887_220), i32::from_u32(887_220), &mut ctx);

    assert_eq!(position.pool_id(), object::id(&pool));
    assert_eq!(position.liquidity(), 0);
    position.destroy_empty();
    destroy(pool);
    destroy(version);
}

// Swap.

#[test]
#[expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun swap_pause_blocks_execution_even_if_the_request_was_opened_first() {
    let mut ctx = tx_context::dummy();
    let mut version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let request = pool.begin_swap_quote_to_asset(&version, quote(100, &mut ctx), ABOVE_PRICE_X96);
    version.pause_for_testing(constants::swap_pause_bit!());

    let completion = pool.execute_swap(&version, request, &clock, &mut ctx);

    destroy(completion);
    clock.destroy_for_testing();
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun stale_swap_bytecode_rejects_an_open_request_before_pause_or_curve_checks() {
    let mut ctx = tx_context::dummy();
    let mut version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);
    version.pause_for_testing(constants::swap_pause_bit!());
    version.set_version_for_testing(constants::version!() + 1);

    let completion = pool.execute_swap(&version, request, &clock, &mut ctx);

    destroy(completion);
    clock.destroy_for_testing();
    destroy(pool);
    destroy(version);
}

#[test]
fun unhooked_swap_settles_reserves_and_returns_change() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(0), balance::create_for_testing(1_000));

    let request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);
    assert!(pool.is_in_operation_for_testing());
    let completion = pool.execute_swap_with_amounts_for_testing(&version, request, 60, 55, BELOW_PRICE_X96, 1, &clock, &mut ctx);
    let (asset_coin, quote_coin) = pool.finish(&version, completion, 40, 55, &mut ctx);

    assert_eq!(asset_coin.burn_for_testing(), 40);
    assert_eq!(quote_coin.burn_for_testing(), 55);
    pool.assert_reserves(60, 945);
    assert_eq!(pool.sqrt_price_x96(), BELOW_PRICE_X96);
    assert!(!pool.is_in_operation_for_testing());
    destroy(pool);
    clock.destroy_for_testing();
    destroy(version);
}

#[test]
fun quote_to_asset_swap_settles_the_other_side() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(1_000), balance::create_for_testing(0));

    let request = pool.begin_swap_quote_to_asset(&version, quote(100, &mut ctx), ABOVE_PRICE_X96);
    assert!(!request.is_asset_input());
    let completion = pool.execute_swap_with_amounts_for_testing(&version, request, 100, 90, ABOVE_PRICE_X96, 1, &clock, &mut ctx);
    let (asset_coin, quote_coin) = pool.finish(&version, completion, 90, 0, &mut ctx);

    assert_eq!(asset_coin.burn_for_testing(), 90);
    assert_eq!(quote_coin.burn_for_testing(), 0);
    pool.assert_reserves(910, 100);
    destroy(pool);
    clock.destroy_for_testing();
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::ECurveMathUnavailable, location = blast_fun_dex::pool)]
fun execute_swap_reaches_the_curve_seam_once_approved() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut pool = fixture.hooked_pool(&version, pool::before_swap_flag!(), &mut ctx);
    let mut request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);
    request.approve(&version, &pool, TestHook());

    let completion = pool.execute_swap(&version, request, &clock, &mut ctx);

    destroy(completion);
    destroy(pool);
    destroy(fixture);
    clock.destroy_for_testing();
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EPoolInOperation, location = blast_fun_dex::pool)]
fun begin_rejects_a_second_operation_on_a_busy_pool() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    let first = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);

    let second = pool.begin_donate(&version, asset(1, &mut ctx), quote(0, &mut ctx));

    destroy(first);
    destroy(second);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EZeroAmount, location = blast_fun_dex::pool)]
fun begin_swap_rejects_a_zero_payment() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);

    let request = pool.begin_swap_asset_to_quote(&version, asset(0, &mut ctx), BELOW_PRICE_X96);

    destroy(request);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EZeroAmount, location = blast_fun_dex::pool)]
fun begin_swap_checks_the_payment_before_the_price_limit() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);

    let request = pool.begin_swap_asset_to_quote(&version, asset(0, &mut ctx), ABOVE_PRICE_X96);

    destroy(request);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidPriceLimit, location = blast_fun_dex::pool)]
fun begin_swap_asset_to_quote_rejects_a_limit_above_the_price() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);

    let request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), ABOVE_PRICE_X96);

    destroy(request);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidPriceLimit, location = blast_fun_dex::pool)]
fun begin_swap_asset_to_quote_rejects_the_minimum_price_limit() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);

    let request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), MIN_SQRT_PRICE_X96);

    destroy(request);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInvalidPriceLimit, location = blast_fun_dex::pool)]
fun begin_swap_quote_to_asset_rejects_the_current_price_as_limit() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);

    let request = pool.begin_swap_quote_to_asset(&version, quote(100, &mut ctx), SQRT_PRICE_ONE_X96);

    destroy(request);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EMissingApproval, location = blast_fun_dex::pool)]
fun execute_swap_rejects_a_request_the_bound_hook_did_not_approve() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut pool = fixture.hooked_pool(&version, pool::before_swap_flag!(), &mut ctx);
    let request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);

    let completion = pool.execute_swap(&version, request, &clock, &mut ctx);

    destroy(completion);
    destroy(pool);
    destroy(fixture);
    clock.destroy_for_testing();
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EHookNotBound, location = blast_fun_dex::pool)]
fun approve_rejects_a_witness_not_bound_to_the_slot() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut pool = fixture.hooked_pool(&version, pool::before_swap_flag!(), &mut ctx);
    let mut request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);

    request.approve(&version, &pool, OtherHook());

    destroy(request);
    destroy(pool);
    destroy(fixture);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EHookNotBound, location = blast_fun_dex::pool)]
fun approve_rejects_any_witness_on_an_empty_slot() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut pool = fixture.hooked_pool(&version, pool::after_swap_flag!(), &mut ctx);
    let mut request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);

    request.approve(&version, &pool, TestHook());

    destroy(request);
    destroy(pool);
    destroy(fixture);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EAlreadyApproved, location = blast_fun_dex::pool)]
fun approve_rejects_a_second_approval() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut pool = fixture.hooked_pool(&version, pool::before_swap_flag!(), &mut ctx);
    let mut request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);
    request.approve(&version, &pool, TestHook());

    request.approve(&version, &pool, TestHook());

    destroy(request);
    destroy(pool);
    destroy(fixture);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EAlreadyApproved, location = blast_fun_dex::pool)]
fun take_payment_rejects_an_approved_request() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut pool = fixture.hooked_pool(&version, pool::before_swap_flag!(), &mut ctx);
    let mut request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);
    request.approve(&version, &pool, TestHook());

    let taken = request.take_asset_payment(&version, &pool, TestHook(), 1);

    destroy(taken);
    destroy(request);
    destroy(pool);
    destroy(fixture);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EWrongPool, location = blast_fun_dex::pool)]
fun approve_rejects_a_request_from_another_pool() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut first_pool = fixture.hooked_pool(&version, pool::before_swap_flag!(), &mut ctx);
    let second_pool = fixture.hooked_pool(&version, pool::before_swap_flag!(), &mut ctx);
    let mut request = first_pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);

    request.approve(&version, &second_pool, TestHook());

    destroy(request);
    destroy(first_pool);
    destroy(second_pool);
    destroy(fixture);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EWrongPool, location = blast_fun_dex::pool)]
fun execute_swap_rejects_a_request_from_another_pool() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let mut first_pool = plain_pool(&version, &mut ctx);
    let mut second_pool = plain_pool(&version, &mut ctx);
    let request = first_pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);

    let completion = second_pool.execute_swap(&version, request, &clock, &mut ctx);

    destroy(completion);
    destroy(first_pool);
    destroy(second_pool);
    clock.destroy_for_testing();
    destroy(version);
}

#[test]
fun swap_event_reports_the_lp_fee_amount_after_the_hook_takes_payment() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut pool = fixture.hooked_pool(&version, pool::before_swap_flag!(), &mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(0), balance::create_for_testing(1_000));
    let mut request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);

    let hook_fee = request.take_asset_payment(&version, &pool, TestHook(), 10);
    request.approve(&version, &pool, TestHook());

    assert_eq!(hook_fee.destroy_for_testing(), 10);
    assert_eq!(request.input_value(), 90);
    let completion = pool.execute_swap_with_amounts_for_testing(&version, request, 90, 80, BELOW_PRICE_X96, 1, &clock, &mut ctx);
    let (asset_coin, quote_coin) = pool.finish(&version, completion, 0, 80, &mut ctx);
    assert_eq!(asset_coin.burn_for_testing(), 0);
    assert_eq!(quote_coin.burn_for_testing(), 80);
    let swaps = event::events_by_type<Swapped>();
    assert_eq!(swaps.length(), 1);
    let (pool_id, sender, is_asset_input, input_spent, output_amount, lp_fee_amount, sqrt_price_x96) = swaps[0].swapped_fields();
    assert_eq!(pool_id, object::id(&pool));
    assert_eq!(sender, ctx.sender());
    assert!(is_asset_input);
    assert_eq!(input_spent, 90);
    assert_eq!(output_amount, 80);
    assert_eq!(lp_fee_amount, 1);
    assert_eq!(sqrt_price_x96, BELOW_PRICE_X96);
    destroy(pool);
    destroy(fixture);
    clock.destroy_for_testing();
    destroy(version);
}

// LP fee.

#[test]
fun fixed_fee_swaps_leave_the_reference_unobserved() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(NOW_MS + 2 * WINDOW_MS);
    let mut pool = plain_pool(&version, &mut ctx);
    pool.join_reserves_for_testing(balance::zero(), balance::create_for_testing(1_000));

    pool.swap_asset_for_testing(&version, PRICE_DOWN_4_PERCENT_X96, &clock, &mut ctx);

    pool.assert_reference(SQRT_PRICE_ONE_X96, 0);
    clock.destroy_for_testing();
    destroy(pool);
    destroy(version);
}

#[test]
fun dynamic_swaps_observe_the_pre_swap_spot_once_per_timestamp() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(NOW_MS);
    let mut pool = dynamic_pool(&version, &mut ctx);
    pool.join_reserves_for_testing(balance::zero(), balance::create_for_testing(1_000));

    pool.swap_asset_for_testing(&version, PRICE_DOWN_4_PERCENT_X96, &clock, &mut ctx);
    pool.swap_asset_for_testing(&version, PRICE_DOWN_8_PERCENT_X96, &clock, &mut ctx);
    pool.assert_reference(SQRT_PRICE_ONE_X96, NOW_MS);

    clock.increment_for_testing(WINDOW_MS / 2);
    pool.swap_asset_for_testing(&version, PRICE_DOWN_8_PERCENT_X96, &clock, &mut ctx);
    pool.assert_reference((SQRT_PRICE_ONE_X96 + PRICE_DOWN_8_PERCENT_X96) / 2, NOW_MS + WINDOW_MS / 2);

    clock.increment_for_testing(WINDOW_MS / 2);
    pool.swap_asset_for_testing(&version, PRICE_DOWN_8_PERCENT_X96, &clock, &mut ctx);
    pool.assert_reference(PRICE_DOWN_8_PERCENT_X96, NOW_MS + WINDOW_MS);
    clock.destroy_for_testing();
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::ECurveMathUnavailable, location = blast_fun_dex::pool)]
fun execute_dynamic_swap_reaches_the_curve_seam() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let mut pool = dynamic_pool(&version, &mut ctx);
    let request = pool.begin_swap_quote_to_asset(&version, quote(100, &mut ctx), ABOVE_PRICE_X96);

    let completion = pool.execute_swap(&version, request, &clock, &mut ctx);

    destroy(completion);
    clock.destroy_for_testing();
    destroy(pool);
    destroy(version);
}

#[test]
fun after_hook_adjusts_output_before_approving() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut pool = fixture.hooked_pool(&version, pool::after_swap_flag!(), &mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(0), balance::create_for_testing(1_000));
    let request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);
    let mut completion = pool.execute_swap_with_amounts_for_testing(
        &version,
        request,
        100,
        90,
        BELOW_PRICE_X96,
        1,
        &clock,
        &mut ctx,
    );

    let skimmed = completion.take_quote_output(&version, &pool, TestHook(), 5);
    completion.join_asset_output(&version, &pool, TestHook(), balance::create_for_testing(2));
    completion.approve(&version, &pool, TestHook());

    assert_eq!(skimmed.destroy_for_testing(), 5);
    let (asset_coin, quote_coin) = pool.finish(&version, completion, 2, 85, &mut ctx);
    assert_eq!(asset_coin.burn_for_testing(), 2);
    assert_eq!(quote_coin.burn_for_testing(), 85);
    destroy(pool);
    destroy(fixture);
    clock.destroy_for_testing();
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EMissingApproval, location = blast_fun_dex::pool)]
fun finish_rejects_a_completion_the_after_hook_did_not_approve() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut pool = fixture.hooked_pool(&version, pool::after_swap_flag!(), &mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(0), balance::create_for_testing(1_000));
    let request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);
    let completion = pool.execute_swap_with_amounts_for_testing(&version, request, 100, 90, BELOW_PRICE_X96, 1, &clock, &mut ctx);

    let (asset_coin, quote_coin) = pool.finish(&version, completion, 0, 0, &mut ctx);

    destroy(asset_coin);
    destroy(quote_coin);
    destroy(pool);
    destroy(fixture);
    clock.destroy_for_testing();
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInsufficientOutput, location = blast_fun_dex::pool)]
fun finish_rejects_output_below_the_minimum() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    pool.join_reserves_for_testing(balance::create_for_testing(0), balance::create_for_testing(1_000));
    let request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);
    let completion = pool.execute_swap_with_amounts_for_testing(&version, request, 100, 90, BELOW_PRICE_X96, 1, &clock, &mut ctx);

    let (asset_coin, quote_coin) = pool.finish(&version, completion, 0, 91, &mut ctx);

    destroy(asset_coin);
    destroy(quote_coin);
    destroy(pool);
    clock.destroy_for_testing();
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EWrongPool, location = blast_fun_dex::pool)]
fun finish_rejects_a_completion_from_another_pool() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let mut first_pool = plain_pool(&version, &mut ctx);
    let mut second_pool = plain_pool(&version, &mut ctx);
    first_pool.join_reserves_for_testing(balance::create_for_testing(0), balance::create_for_testing(1_000));
    let request = first_pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);
    let completion = first_pool.execute_swap_with_amounts_for_testing(
        &version,
        request,
        100,
        90,
        BELOW_PRICE_X96,
        1,
        &clock,
        &mut ctx,
    );

    let (asset_coin, quote_coin) = second_pool.finish(&version, completion, 0, 0, &mut ctx);

    destroy(asset_coin);
    destroy(quote_coin);
    destroy(first_pool);
    destroy(second_pool);
    clock.destroy_for_testing();
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun stale_bytecode_cannot_finish_a_completed_operation() {
    let mut ctx = tx_context::dummy();
    let mut version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    let request = pool.begin_donate(&version, asset(1, &mut ctx), quote(0, &mut ctx));
    let completion = pool.execute_donate_for_testing(&version, request);
    version.set_version_for_testing(constants::version!() + 1);

    let (asset_coin, quote_coin) = pool.finish(&version, completion, 0, 0, &mut ctx);

    destroy(asset_coin);
    destroy(quote_coin);
    destroy(pool);
    destroy(version);
}

// Liquidity.

#[test]
fun liquidity_removal_settles_and_cleans_up_even_with_every_bit_paused() {
    let mut ctx = tx_context::dummy();
    let mut version = dex::version_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut pool = fixture.hooked_pool(&version, pool::all_hook_flags!(), &mut ctx);
    let mut position = pool.new_position(&version, i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);

    let mut add_request = pool.begin_add_liquidity(&version, &position, 500, asset(100, &mut ctx), quote(100, &mut ctx));
    assert_eq!(add_request.liquidity(), 500);
    add_request.approve(&version, &pool, TestHook());
    let mut added = pool.execute_add_liquidity_with_amounts_for_testing(&version, add_request, &mut position, 70, 60);
    added.approve(&version, &pool, TestHook());
    let (asset_refund, quote_refund) = pool.finish(&version, added, 30, 40, &mut ctx);

    assert_eq!(asset_refund.burn_for_testing(), 30);
    assert_eq!(quote_refund.burn_for_testing(), 40);
    assert_eq!(position.liquidity(), 500);
    pool.assert_reserves(70, 60);

    version.pause_for_testing(constants::valid_pause_bits!());
    let mut remove_request = pool.begin_remove_liquidity(&version, &position, 500);
    remove_request.approve(&version, &pool, TestHook());
    let mut removed = pool.execute_remove_liquidity_with_amounts_for_testing(&version, remove_request, &mut position, 69, 59);
    removed.approve(&version, &pool, TestHook());
    let (asset_out, quote_out) = pool.finish(&version, removed, 69, 59, &mut ctx);

    assert_eq!(asset_out.burn_for_testing(), 69);
    assert_eq!(quote_out.burn_for_testing(), 59);
    assert!(!pool.is_in_operation_for_testing());
    pool.assert_reserves(1, 1);
    let added_events = event::events_by_type<LiquidityAdded>();
    let removed_events = event::events_by_type<LiquidityRemoved>();
    assert_eq!(added_events.length(), 1);
    assert_eq!(removed_events.length(), 1);
    let (pool_id, position_id, liquidity, asset_amount, quote_amount) = added_events[0].liquidity_added_fields();
    assert_eq!(pool_id, object::id(&pool));
    assert_eq!(position_id, object::id(&position));
    assert_eq!(liquidity, 500);
    assert_eq!(asset_amount, 70);
    assert_eq!(quote_amount, 60);
    let (pool_id, position_id, liquidity, asset_amount, quote_amount) = removed_events[0].liquidity_removed_fields();
    assert_eq!(pool_id, object::id(&pool));
    assert_eq!(position_id, object::id(&position));
    assert_eq!(liquidity, 500);
    assert_eq!(asset_amount, 69);
    assert_eq!(quote_amount, 59);
    position.destroy_empty();
    destroy(pool);
    destroy(fixture);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun liquidity_in_pause_precedes_add_liquidity_validation() {
    let mut ctx = tx_context::dummy();
    let mut version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    let position = pool.new_position(&version, i32::neg_from_u32(60), i32::from_u32(60), &mut ctx);
    version.pause_for_testing(constants::liquidity_in_pause_bit!());

    let request = pool.begin_add_liquidity(&version, &position, 0, asset(0, &mut ctx), quote(0, &mut ctx));

    destroy(request);
    destroy(position);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun liquidity_in_pause_blocks_donations() {
    let mut ctx = tx_context::dummy();
    let mut version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    version.pause_for_testing(constants::liquidity_in_pause_bit!());

    let request = pool.begin_donate(&version, asset(1, &mut ctx), quote(0, &mut ctx));

    destroy(request);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::ECurveMathUnavailable, location = blast_fun_dex::pool)]
fun execute_add_liquidity_reaches_the_curve_seam_once_approved() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    let mut position = pool.new_position(&version, i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);
    let request = pool.begin_add_liquidity(&version, &position, 500, asset(100, &mut ctx), quote(100, &mut ctx));

    let completion = pool.execute_add_liquidity(&version, request, &mut position);

    destroy(completion);
    destroy(position);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInsufficientPayment, location = blast_fun_dex::pool)]
fun add_liquidity_rejects_a_payment_below_the_requirement() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    let mut position = pool.new_position(&version, i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);
    let request = pool.begin_add_liquidity(&version, &position, 500, asset(100, &mut ctx), quote(100, &mut ctx));

    let completion = pool.execute_add_liquidity_with_amounts_for_testing(&version, request, &mut position, 101, 0);

    destroy(completion);
    destroy(position);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EWrongPosition, location = blast_fun_dex::pool)]
fun execute_add_liquidity_rejects_a_different_position() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    let position = pool.new_position(&version, i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);
    let mut other_position = pool.new_position(&version, i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);
    let request = pool.begin_add_liquidity(&version, &position, 500, asset(100, &mut ctx), quote(100, &mut ctx));

    let completion = pool.execute_add_liquidity(&version, request, &mut other_position);

    destroy(completion);
    destroy(position);
    destroy(other_position);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EWrongPool, location = blast_fun_dex::pool)]
fun begin_add_liquidity_rejects_a_position_of_another_pool() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    let other_pool = plain_pool(&version, &mut ctx);
    let position = other_pool.new_position(&version, i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);

    let request = pool.begin_add_liquidity(&version, &position, 500, asset(100, &mut ctx), quote(100, &mut ctx));

    destroy(request);
    destroy(position);
    destroy(pool);
    destroy(other_pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EZeroLiquidity, location = blast_fun_dex::pool)]
fun begin_add_liquidity_rejects_zero_liquidity() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    let position = pool.new_position(&version, i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);

    let request = pool.begin_add_liquidity(&version, &position, 0, asset(100, &mut ctx), quote(100, &mut ctx));

    destroy(request);
    destroy(position);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EInsufficientLiquidity, location = blast_fun_dex::pool)]
fun begin_remove_liquidity_rejects_more_than_the_position_holds() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    let position = pool.new_position(&version, i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);

    let request = pool.begin_remove_liquidity(&version, &position, 1);

    destroy(request);
    destroy(position);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EPositionNotEmpty, location = blast_fun_dex::pool)]
fun destroy_empty_position_rejects_a_position_with_liquidity() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    let mut position = pool.new_position(&version, i32::neg_from_u32(600), i32::from_u32(600), &mut ctx);
    let request = pool.begin_add_liquidity(&version, &position, 500, asset(100, &mut ctx), quote(100, &mut ctx));
    let completion = pool.execute_add_liquidity_with_amounts_for_testing(&version, request, &mut position, 100, 100);
    let (asset_refund, quote_refund) = pool.finish(&version, completion, 0, 0, &mut ctx);
    asset_refund.destroy_zero();
    quote_refund.destroy_zero();

    position.destroy_empty();

    destroy(pool);
    destroy(version);
}

// Donate.

#[test]
fun donate_runs_both_hooks_and_returns_empty_coins() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut pool = fixture.hooked_pool(&version, pool::before_donate_flag!() | pool::after_donate_flag!(), &mut ctx);

    let mut request = pool.begin_donate(&version, asset(5, &mut ctx), quote(0, &mut ctx));
    assert_eq!(request.asset_value(), 5);
    assert_eq!(request.quote_value(), 0);
    request.approve(&version, &pool, TestHook());
    let mut completion = pool.execute_donate_for_testing(&version, request);
    completion.approve(&version, &pool, TestHook());
    let (asset_coin, quote_coin) = pool.finish(&version, completion, 0, 0, &mut ctx);

    asset_coin.destroy_zero();
    quote_coin.destroy_zero();
    pool.assert_reserves(5, 0);
    let donations = event::events_by_type<Donated>();
    assert_eq!(donations.length(), 1);
    let (pool_id, asset_amount, quote_amount) = donations[0].donated_fields();
    assert_eq!(pool_id, object::id(&pool));
    assert_eq!(asset_amount, 5);
    assert_eq!(quote_amount, 0);
    destroy(pool);
    destroy(fixture);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EZeroAmount, location = blast_fun_dex::pool)]
fun begin_donate_rejects_an_empty_donation() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);

    let request = pool.begin_donate(&version, asset(0, &mut ctx), quote(0, &mut ctx));

    destroy(request);
    destroy(pool);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::ECurveMathUnavailable, location = blast_fun_dex::pool)]
fun execute_donate_reaches_the_curve_seam() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let mut pool = plain_pool(&version, &mut ctx);
    let request = pool.begin_donate(&version, asset(5, &mut ctx), quote(0, &mut ctx));

    let completion = pool.execute_donate(&version, request);

    destroy(completion);
    destroy(pool);
    destroy(version);
}

// Hook state.

#[test]
fun hook_state_is_isolated_per_witness_and_writable_mid_operation() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut initializer = new_fixed_pool<ASSET, QUOTE>(
        &version,
        TICK_SPACING,
        LP_FEE_PPM,
        SQRT_PRICE_ONE_X96,
        &mut ctx,
    );
    initializer.register_hook(&version, &fixture.test_config, TestHook(), pool::before_swap_flag!());
    initializer.register_hook(&version, &fixture.other_config, OtherHook(), pool::after_swap_flag!());
    let mut pool = initializer.finalize(&version);
    let request = pool.begin_swap_asset_to_quote(&version, asset(100, &mut ctx), BELOW_PRICE_X96);

    pool.add_hook_state(&version, &TestHook(), StateName(), 1u64);
    pool.add_hook_state(&version, &OtherHook(), StateName(), 2u64);
    *pool.hook_state_mut<_, _, _, _, u64>(&version, &TestHook(), StateName()) = 3;

    assert_eq!(*pool.hook_state<_, _, _, _, u64>(&TestHook(), StateName()), 3);
    assert_eq!(*pool.hook_state<_, _, _, _, u64>(&OtherHook(), StateName()), 2);
    assert_eq!(pool.remove_hook_state<_, _, _, _, u64>(&version, &OtherHook(), StateName()), 2);
    assert!(!pool.has_hook_state(&OtherHook(), StateName()));
    assert!(pool.has_hook_state(&TestHook(), StateName()));
    destroy(request);
    destroy(pool);
    destroy(fixture);
    destroy(version);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EHookNotBound, location = blast_fun_dex::pool)]
fun hook_state_rejects_a_hook_not_bound_to_the_pool() {
    let mut ctx = tx_context::dummy();
    let version = dex::version_for_testing(&mut ctx);
    let fixture = new_fixture(&version, &mut ctx);
    let mut pool = fixture.hooked_pool(&version, pool::before_swap_flag!(), &mut ctx);

    pool.add_hook_state(&version, &OtherHook(), StateName(), 1u64);

    destroy(pool);
    destroy(fixture);
    destroy(version);
}

// === Test Helpers ===

fun new_fixed_pool<Asset, Quote>(
    version: &PackageVersion<BLAST_FUN_DEX>,
    tick_spacing: u32,
    fee_ppm: u32,
    sqrt_price_x96: u256,
    ctx: &mut TxContext,
): PoolInitializer<Asset, Quote> {
    let tiers = lp_fee::new_fee_tiers_for_testing(ctx);
    let initializer = pool::new_with_fixed_fee(version, &tiers, tick_spacing, fee_ppm, sqrt_price_x96, ctx);
    tiers.destroy_default_fee_tiers_for_testing();

    initializer
}

fun new_dynamic_pool<Asset, Quote>(
    version: &PackageVersion<BLAST_FUN_DEX>,
    tick_spacing: u32,
    base_fee_ppm: u32,
    max_fee_ppm: u32,
    sensitivity_ppm: u32,
    sqrt_price_x96: u256,
    ctx: &mut TxContext,
): PoolInitializer<Asset, Quote> {
    let tiers = lp_fee::new_fee_tiers_for_testing(ctx);
    let initializer = pool::new_with_dynamic_fee(
        version,
        &tiers,
        tick_spacing,
        base_fee_ppm,
        max_fee_ppm,
        sensitivity_ppm,
        sqrt_price_x96,
        ctx,
    );
    tiers.destroy_default_fee_tiers_for_testing();

    initializer
}

fun new_fixture(version: &PackageVersion<BLAST_FUN_DEX>, ctx: &mut TxContext): Fixture {
    let mut namespace = hook_config::new_namespace_for_testing(ctx);
    let test_config = hook_config::new(version, &mut namespace, TestHook(), 1);
    let other_config = hook_config::new(version, &mut namespace, OtherHook(), 1);

    Fixture { namespace, test_config, other_config }
}

/// Fixed-fee pool with `TestHook` bound to `flags`.
fun hooked_pool(
    self: &Fixture,
    version: &PackageVersion<BLAST_FUN_DEX>,
    flags: u8,
    ctx: &mut TxContext,
): Pool<ASSET, QUOTE> {
    let mut initializer = new_fixed_pool(version, TICK_SPACING, LP_FEE_PPM, SQRT_PRICE_ONE_X96, ctx);
    initializer.register_hook(version, &self.test_config, TestHook(), flags);

    initializer.finalize(version)
}

/// Unhooked dynamic-fee pool at price 1.0.
fun dynamic_pool(version: &PackageVersion<BLAST_FUN_DEX>, ctx: &mut TxContext): Pool<ASSET, QUOTE> {
    new_dynamic_pool(version, TICK_SPACING, BASE_FEE_PPM, MAX_FEE_PPM, SENSITIVITY_PPM, SQRT_PRICE_ONE_X96, ctx)
        .finalize(version)
}

/// Settles a fixture fill for 100 Asset and 90 Quote.
fun swap_asset_for_testing(
    pool: &mut Pool<ASSET, QUOTE>,
    version: &PackageVersion<BLAST_FUN_DEX>,
    sqrt_price_after_x96: u256,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let request = pool.begin_swap_asset_to_quote(version, asset(100, ctx), MIN_SQRT_PRICE_X96 + 1);
    let completion = pool.execute_swap_with_amounts_for_testing(version, request, 100, 90, sqrt_price_after_x96, 1, clock, ctx);
    let (asset_coin, quote_coin) = pool.finish(version, completion, 0, 90, ctx);
    asset_coin.destroy_zero();
    quote_coin.burn_for_testing();
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

fun plain_pool(version: &PackageVersion<BLAST_FUN_DEX>, ctx: &mut TxContext): Pool<ASSET, QUOTE> {
    new_fixed_pool(version, TICK_SPACING, LP_FEE_PPM, SQRT_PRICE_ONE_X96, ctx).finalize(version)
}

fun asset(value: u64, ctx: &mut TxContext): Coin<ASSET> {
    coin::mint_for_testing(value, ctx)
}

fun quote(value: u64, ctx: &mut TxContext): Coin<QUOTE> {
    coin::mint_for_testing(value, ctx)
}

fun pause_for_testing(version: &mut PackageVersion<BLAST_FUN_DEX>, bits: u8) {
    let pause_admin = blast_acl::witness_for_testing<PauseAdmin<BLAST_FUN_DEX>>();
    version.pause(&pause_admin, bits);
}

// === Imports ===

use blast_admin::{blast_acl, package_admin::{Self, PauseAdmin}, package_version::PackageVersion};
use blast_fun_dex::{
    blast_fun_dex::{Self as dex, BLAST_FUN_DEX},
    blast_events::{Donated, LiquidityAdded, LiquidityRemoved, PoolCreated, Swapped},
    constants,
    hook_config::{Self, HookConfig, HookNamespace},
    i32,
    lp_fee::{Self, LpFee},
    pool::{Self, Hooks, Pool, PoolInitializer},
};
use std::{type_name, unit_test::{assert_eq, destroy}};
use sui::{balance, clock::{Self, Clock}, coin::{Self, Coin}, event};

use fun assert_reference as Pool.assert_reference;
use fun assert_reserves as Pool.assert_reserves;
use fun swap_asset_for_testing as Pool.swap_asset_for_testing;
use fun package_admin::pause as PackageVersion.pause;
use fun pause_for_testing as PackageVersion.pause_for_testing;
