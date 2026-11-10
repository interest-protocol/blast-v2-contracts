#[test_only]
module blast_fun_dex_example_hook::fee_hook_tests;

// === Constants ===

const ADMIN: address = @0xA;
/// Price 1.0 in Q64.96.
const SQRT_PRICE_ONE_X96: u256 = 79_228_162_514_264_337_593_543_950_336;
const BELOW_PRICE_X96: u256 = 39_614_081_257_132_168_796_771_975_168;
const ABOVE_PRICE_X96: u256 = 158_456_325_028_528_675_187_087_900_672;
const FEE_BPS: u64 = 100;
const FEE_CHANGE_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;
/// Price 0.96, 1e-12 further from 1.0 so rounding cannot shrink the gap.
const PRICE_DOWN_4_PERCENT_X96: u256 = 77_627_428_567_259_243_148_980_294_874;

// === Test-Only Types ===

public struct ASSET has drop {}
public struct QUOTE has drop {}

/// One transaction's view of a deployed hook.
public struct Fixture {
    scenario: Scenario,
    namespace: HookNamespace,
    admin_cap: FeeHookAdminCap,
    config: HookConfig<FeeHook>,
    clock: Clock,
    tiers: BlastDexFeeTiers,
    version: PackageVersion<BLAST_FUN_DEX>,
}

// === Tests ===

#[test]
fun config_lives_at_the_address_routers_derive() {
    let fixture = setup(FEE_BPS);

    let expected = derived_object::derive_address(
        object::id(&fixture.namespace),
        hook_config::key_for_testing(type_name::with_defining_ids<FeeHook>()),
    );
    assert_eq!(object::id(&fixture.config).to_address(), expected);

    fixture.teardown();
}

#[test]
fun swap_charges_the_hook_fee_and_counts_the_swap() {
    let mut fixture = setup(FEE_BPS);
    let mut pool = fixture.fixed_fee_pool();
    pool.join_reserves_for_testing(balance::zero(), balance::create_for_testing(1_000));

    let payment = fixture.asset(1_000);
    let mut request = pool.begin_swap_asset_to_quote(&fixture.version, payment, BELOW_PRICE_X96);
    fee_hook::before_swap(
        &mut pool,
        &fixture.version,
        &fixture.config,
        &mut request,
        vector[],
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    assert_eq!(request.input_value(), 990);
    let mut completion = pool.execute_swap_with_amounts_for_testing(
        &fixture.version,
        request,
        990,
        900,
        BELOW_PRICE_X96,
        1,
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    fee_hook::after_swap(
        &mut pool,
        &fixture.version,
        &fixture.config,
        &mut completion,
        vector[],
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    let (asset_coin, quote_coin) = pool.finish(&fixture.version, completion, 0, 900, fixture.scenario.ctx());

    assert_eq!(asset_coin.burn_for_testing(), 0);
    assert_eq!(quote_coin.burn_for_testing(), 900);
    assert_eq!(fee_hook::collected_fees<_, _, ASSET>(&pool), 10);
    assert_eq!(fee_hook::swap_count(&pool), 1);
    let fees = fee_hook::withdraw_fees<_, _, ASSET>(
        &mut pool,
        &fixture.version,
        &fixture.config,
        &fixture.admin_cap,
        fixture.scenario.ctx(),
    );
    assert_eq!(fees.burn_for_testing(), 10);
    assert_eq!(fee_hook::collected_fees<_, _, ASSET>(&pool), 0);
    destroy(pool);
    fixture.teardown();
}

#[test]
fun hook_fee_rounds_up_and_is_kept_in_the_input_coin() {
    let mut fixture = setup(FEE_BPS);
    let mut pool = fixture.fixed_fee_pool();

    // 1% of 150 is 1.5; the hook takes 2.
    let payment = fixture.quote(150);
    let mut request = pool.begin_swap_quote_to_asset(&fixture.version, payment, ABOVE_PRICE_X96);
    fee_hook::before_swap(
        &mut pool,
        &fixture.version,
        &fixture.config,
        &mut request,
        vector[],
        &fixture.clock,
        fixture.scenario.ctx(),
    );

    assert_eq!(request.input_value(), 148);
    assert_eq!(fee_hook::collected_fees<_, _, QUOTE>(&pool), 2);
    assert_eq!(fee_hook::collected_fees<_, _, ASSET>(&pool), 0);
    destroy(request);
    destroy(pool);
    fixture.teardown();
}

#[test]
fun dynamic_pool_passes_remaining_payment_to_the_swap_after_the_hook_fee() {
    let mut fixture = setup(FEE_BPS);
    let mut initializer = pool::new_with_dynamic_fee<ASSET, QUOTE>(
        &fixture.version,
        &fixture.tiers,
        60,
        3_000,
        20_000,
        1_000_000,
        SQRT_PRICE_ONE_X96,
        fixture.scenario.ctx(),
    );
    fee_hook::register(&mut initializer, &fixture.version, &fixture.config);
    let mut pool = initializer.finalize(&fixture.version);
    pool.join_reserves_for_testing(balance::zero(), balance::create_for_testing(1_000));

    let payment = fixture.asset(1_000);
    let mut request = pool.begin_swap_asset_to_quote(&fixture.version, payment, BELOW_PRICE_X96);
    fee_hook::before_swap(
        &mut pool,
        &fixture.version,
        &fixture.config,
        &mut request,
        vector[],
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    assert_eq!(request.input_value(), 990);
    let mut completion = pool.execute_swap_with_amounts_for_testing(
        &fixture.version,
        request,
        990,
        900,
        PRICE_DOWN_4_PERCENT_X96,
        1,
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    fee_hook::after_swap(
        &mut pool,
        &fixture.version,
        &fixture.config,
        &mut completion,
        vector[],
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    let (asset_coin, quote_coin) = pool.finish(&fixture.version, completion, 0, 900, fixture.scenario.ctx());

    assert_eq!(fee_hook::collected_fees<_, _, ASSET>(&pool), 10);
    asset_coin.destroy_zero();
    assert_eq!(quote_coin.burn_for_testing(), 900);
    destroy(pool);
    fixture.teardown();
}

#[test]
fun hooked_liquidity_removal_settles_while_fully_paused() {
    let mut fixture = setup(FEE_BPS);
    let mut pool = fixture.fixed_fee_pool();
    let mut position = pool.new_position(&fixture.version, i32::neg_from_u32(600), i32::from_u32(600), fixture.scenario.ctx());

    let asset_payment = fixture.asset(100);
    let quote_payment = fixture.quote(100);
    let mut add_request = pool.begin_add_liquidity(&fixture.version, &position, 500, asset_payment, quote_payment);
    fee_hook::before_add_liquidity(
        &mut pool,
        &fixture.version,
        &fixture.config,
        &mut add_request,
        &position,
        vector[],
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    let mut added = pool.execute_add_liquidity_with_amounts_for_testing(&fixture.version, add_request, &mut position, 100, 100);
    fee_hook::after_add_liquidity(
        &mut pool,
        &fixture.version,
        &fixture.config,
        &mut added,
        &position,
        vector[],
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    let (asset_refund, quote_refund) = pool.finish(&fixture.version, added, 0, 0, fixture.scenario.ctx());
    asset_refund.destroy_zero();
    quote_refund.destroy_zero();

    let donation = fixture.asset(7);
    let no_quote = fixture.quote(0);
    let mut donate_request = pool.begin_donate(&fixture.version, donation, no_quote);
    fee_hook::before_donate(
        &mut pool,
        &fixture.version,
        &fixture.config,
        &mut donate_request,
        vector[],
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    let mut donated = pool.execute_donate_for_testing(&fixture.version, donate_request);
    fee_hook::after_donate(
        &mut pool,
        &fixture.version,
        &fixture.config,
        &mut donated,
        vector[],
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    let (asset_coin, quote_coin) = pool.finish(&fixture.version, donated, 0, 0, fixture.scenario.ctx());
    asset_coin.destroy_zero();
    quote_coin.destroy_zero();

    fixture.pause_dex();
    let mut remove_request = pool.begin_remove_liquidity(&fixture.version, &position, 500);
    fee_hook::before_remove_liquidity(
        &mut pool,
        &fixture.version,
        &fixture.config,
        &mut remove_request,
        &position,
        vector[],
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    let mut removed = pool.execute_remove_liquidity_with_amounts_for_testing(&fixture.version, remove_request, &mut position, 100, 100);
    fee_hook::after_remove_liquidity(
        &mut pool,
        &fixture.version,
        &fixture.config,
        &mut removed,
        &position,
        vector[],
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    let (asset_out, quote_out) = pool.finish(&fixture.version, removed, 100, 100, fixture.scenario.ctx());
    assert_eq!(asset_out.burn_for_testing(), 100);
    assert_eq!(quote_out.burn_for_testing(), 100);

    position.destroy_empty();
    destroy(pool);
    fixture.teardown();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_dex_example_hook::fee_hook::EWrongVersion,
    location = blast_fun_dex_example_hook::fee_hook,
)]
fun before_swap_rejects_a_config_moved_to_a_newer_version() {
    let mut fixture = setup(FEE_BPS);
    let mut pool = fixture.fixed_fee_pool();
    fixture.set_hook_version(2);
    let payment = fixture.asset(1_000);
    let mut request = pool.begin_swap_asset_to_quote(&fixture.version, payment, BELOW_PRICE_X96);

    fee_hook::before_swap(
        &mut pool,
        &fixture.version,
        &fixture.config,
        &mut request,
        vector[],
        &fixture.clock,
        fixture.scenario.ctx(),
    );

    destroy(request);
    destroy(pool);
    fixture.teardown();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_dex_example_hook::fee_hook::EWrongVersion,
    location = blast_fun_dex_example_hook::fee_hook,
)]
fun register_rejects_a_config_moved_to_a_newer_version() {
    let mut fixture = setup(FEE_BPS);
    fixture.set_hook_version(2);
    let mut initializer = pool::new_with_fixed_fee<ASSET, QUOTE>(
        &fixture.version,
        &fixture.tiers,
        60,
        3_000,
        SQRT_PRICE_ONE_X96,
        fixture.scenario.ctx(),
    );

    fee_hook::register(&mut initializer, &fixture.version, &fixture.config);

    destroy(initializer);
    fixture.teardown();
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::errors::EVersionNotIncreasing, location = blast_fun_dex::hook_config)]
fun migrate_rejects_the_version_already_accepted() {
    let mut fixture = setup(FEE_BPS);

    let Fixture { config, admin_cap, version, .. } = &mut fixture;
    fee_hook::migrate(config, version, admin_cap);

    fixture.teardown();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_dex_example_hook::fee_hook::EFeeTooHigh,
    location = blast_fun_dex_example_hook::fee_hook,
)]
fun create_config_rejects_a_fee_above_ten_percent() {
    let fixture = setup(1_001);

    fixture.teardown();
}

#[test]
fun only_an_applied_fee_change_affects_later_swaps() {
    let mut fixture = setup(FEE_BPS);
    let mut pool = fixture.fixed_fee_pool();

    let Fixture { config, admin_cap, version, clock, .. } = &mut fixture;
    let ready_at_ms = config.schedule_fee_bps(version, admin_cap, 1_000, clock);
    assert_eq!(ready_at_ms, FEE_CHANGE_DELAY_MS);
    fixture.clock.set_for_testing(ready_at_ms);

    assert_eq!(fixture.swap_input_after_fee(&mut pool), 990);
    let Fixture { config, version, clock, .. } = &mut fixture;
    config.apply_fee_bps(version, clock);
    assert_eq!(fixture.swap_input_after_fee(&mut pool), 900);
    destroy(pool);
    fixture.teardown();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun a_hook_fee_cannot_apply_before_its_deadline() {
    let mut fixture = setup(FEE_BPS);
    let Fixture { config, admin_cap, version, clock, .. } = &mut fixture;
    let ready_at_ms = config.schedule_fee_bps(version, admin_cap, 1_000, clock);
    clock.set_for_testing(ready_at_ms - 1);

    config.apply_fee_bps(version, clock);

    fixture.teardown();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed)]
fun a_ready_hook_fee_can_be_cancelled() {
    let mut fixture = setup(FEE_BPS);
    let Fixture { config, admin_cap, version, clock, .. } = &mut fixture;
    let ready_at_ms = config.schedule_fee_bps(version, admin_cap, 1_000, clock);
    clock.set_for_testing(ready_at_ms);

    config.cancel_fee_bps(version, admin_cap);
    config.apply_fee_bps(version, clock);

    fixture.teardown();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_dex_example_hook::fee_hook::EFeeTooHigh,
    location = blast_fun_dex_example_hook::fee_hook,
)]
fun schedule_fee_bps_rejects_a_fee_above_ten_percent() {
    let mut fixture = setup(FEE_BPS);

    let Fixture { config, admin_cap, version, clock, .. } = &mut fixture;
    config.schedule_fee_bps(version, admin_cap, 1_001, clock);

    fixture.teardown();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_dex_example_hook::fee_hook::ENoFeesCollected,
    location = blast_fun_dex_example_hook::fee_hook,
)]
fun withdraw_fees_rejects_a_coin_with_no_fees() {
    let mut fixture = setup(FEE_BPS);
    let mut pool = fixture.fixed_fee_pool();

    let fees = fee_hook::withdraw_fees<_, _, QUOTE>(
        &mut pool,
        &fixture.version,
        &fixture.config,
        &fixture.admin_cap,
        fixture.scenario.ctx(),
    );

    destroy(fees);
    destroy(pool);
    fixture.teardown();
}

// === Test Helpers ===

/// Publishes the hook, creates its shared configuration and starts the next transaction.
fun setup(fee_bps: u64): Fixture {
    let mut scenario = test_scenario::begin(ADMIN);
    fee_hook::init_for_testing(scenario.ctx());
    let mut namespace = hook_config::new_namespace_for_testing(scenario.ctx());
    let version = dex::version_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<FeeHookAdminCap>();
    fee_hook::create_config(&mut namespace, &version, &admin_cap, fee_bps);
    scenario.next_tx(ADMIN);
    let config = scenario.take_shared<HookConfig<FeeHook>>();
    let clock = clock::create_for_testing(scenario.ctx());

    let tiers = lp_fee::new_fee_tiers_for_testing(scenario.ctx());

    Fixture { scenario, namespace, admin_cap, config, clock, tiers, version }
}

fun teardown(self: Fixture) {
    let Fixture { scenario, namespace, admin_cap, config, clock, tiers, version } = self;
    tiers.destroy_default_fee_tiers_for_testing();
    destroy(version);
    test_scenario::return_shared(config);
    destroy(admin_cap);
    destroy(namespace);
    clock.destroy_for_testing();
    scenario.end();
}

fun fixed_fee_pool(self: &mut Fixture): Pool<ASSET, QUOTE> {
    let mut initializer = pool::new_with_fixed_fee(&self.version, &self.tiers, 60, 3_000, SQRT_PRICE_ONE_X96, self.scenario.ctx());
    fee_hook::register(&mut initializer, &self.version, &self.config);

    initializer.finalize(&self.version)
}

fun swap_input_after_fee(self: &mut Fixture, pool: &mut Pool<ASSET, QUOTE>): u64 {
    let payment = self.asset(1_000);
    let mut request = pool.begin_swap_asset_to_quote(&self.version, payment, BELOW_PRICE_X96);
    fee_hook::before_swap(
        pool,
        &self.version,
        &self.config,
        &mut request,
        vector[],
        &self.clock,
        self.scenario.ctx(),
    );
    let input_value = request.input_value();
    destroy(request);
    input_value
}

fun pause_dex(self: &mut Fixture) {
    let bits = self.version.valid_pause_bits();
    let pause_admin = blast_acl::witness_for_testing<PauseAdmin<BLAST_FUN_DEX>>();
    self.version.pause(&pause_admin, bits);
}

fun set_hook_version(self: &mut Fixture, hook_version: u64) {
    let Fixture { config, version, .. } = self;
    fee_hook::set_version_for_testing(config, version, hook_version);
}

fun asset(self: &mut Fixture, value: u64): Coin<ASSET> {
    coin::mint_for_testing(value, self.scenario.ctx())
}

fun quote(self: &mut Fixture, value: u64): Coin<QUOTE> {
    coin::mint_for_testing(value, self.scenario.ctx())
}

// === Imports ===

use blast_admin::{blast_acl, package_admin::{Self, PauseAdmin}, package_version::PackageVersion};
use blast_fun_dex::{
    blast_fun_dex::{Self as dex, BLAST_FUN_DEX},
    hook_config::{Self, HookConfig, HookNamespace},
    i32,
    lp_fee::{Self, BlastDexFeeTiers},
    pool::{Self, Pool},
};
use blast_fun_dex_example_hook::fee_hook::{Self, FeeHook, FeeHookAdminCap};
use std::{type_name, unit_test::{assert_eq, destroy}};
use sui::{
    balance,
    clock::{Self, Clock},
    coin::{Self, Coin},
    derived_object,
    test_scenario::{Self, Scenario},
};

use fun package_admin::pause as PackageVersion.pause;
use fun fee_hook::schedule_fee_bps as HookConfig.schedule_fee_bps;
use fun fee_hook::apply_fee_bps as HookConfig.apply_fee_bps;
use fun fee_hook::cancel_fee_bps as HookConfig.cancel_fee_bps;
