#[test_only]
module blast_fun_auto_lp::vault_tests;

use blast_fun::{
    acl,
    creator_authority,
    launch::{Self, Launch},
    launch_config,
    launch_ticket,
    package_version::{Self, PackageVersion},
    runtime_config
};
use blast_fun_auto_lp::vault::{Self, Control, Vault};
use blast_fun_dex::{migration::{Self, LockedLpVault, Witness}, pool::{Self, Factory, Pool}};
use std::{bcs, unit_test::{assert_eq, destroy}};
use sui::{clock::{Self, Clock}, coin, coin_registry::Currency, test_scenario::{Self, Scenario}};

// === Test-Only Types ===

public struct VAULT_TESTS() has drop;
public struct QUOTE() has drop;
public struct EXTERNAL_WITNESS() has drop;

public struct AutoLpFixture {
    scenario: Scenario,
    version: PackageVersion,
    control: Control,
    factory: Factory,
    pool: Pool<VAULT_TESTS, QUOTE>,
    vault: Vault<VAULT_TESTS, QUOTE>,
    launch: Launch<VAULT_TESTS, QUOTE>,
    clock: Clock,
    cap_id: ID,
    locked: Option<LockedLpVault<VAULT_TESTS, QUOTE>>,
    runtime: runtime_config::RuntimeConfig,
    authority: acl::ProtocolAuthority,
    admin: acl::AdminCap,
    root: acl::SuperAdminCap,
}

// === Tests ===

#[test]
fun third_party_collects_and_authorized_executor_compounds_without_extracting_children() {
    let mut f = start();
    let (cap_id, position_id, meme, quote) = f.vault.snapshot_for_testing();
    assert_eq!(cap_id, f.cap_id);
    assert!(position_id != object::id_from_address(@0x0));
    assert_eq!(meme, 0);
    assert_eq!(quote, 0);
    f.next_tx!(@0xB, |f| f.collect!());
    f.next_tx!(@0xC, |_| ());
    let (_, _, meme, quote) = f.vault.snapshot_for_testing();
    assert!(meme > 0 && quote > 0);
    let (meme_used, quote_used, shares) = f.pool.deposit_amounts(meme, quote);
    assert!(shares > 0);
    f.compound_bounded!(shares, meme_used, quote_used, 0);
    let (after_cap, after_position, remaining_meme, remaining_quote) = f
        .vault
        .snapshot_for_testing();
    assert_eq!(after_cap, cap_id);
    assert_eq!(after_position, position_id);
    assert_eq!(remaining_meme + meme_used, meme);
    assert_eq!(remaining_quote + quote_used, quote);
    let events = sui::event::events_by_type<vault::Compounded>();
    assert_eq!(events.length(), 1);
    let mut expected = bcs::to_bytes(&object::id(&f.vault));
    expected.append(bcs::to_bytes(&meme_used));
    expected.append(bcs::to_bytes(&quote_used));
    expected.append(bcs::to_bytes(&shares));
    expected.append(bcs::to_bytes(&remaining_meme));
    expected.append(bcs::to_bytes(&remaining_quote));
    assert_eq!(bcs::to_bytes(&events[0]), expected);
    f.end();
}

#[test]
fun quote_only_contributions_wait_and_dust_compound_preserves_every_atom() {
    let mut f = start();
    f.contribute!(0, 100);
    let events = sui::event::events_by_type<vault::Contributed>();
    let mut expected = bcs::to_bytes(&object::id(&f.vault));
    expected.append(bcs::to_bytes(&0u64));
    expected.append(bcs::to_bytes(&100u64));
    expected.append(bcs::to_bytes(&0u64));
    expected.append(bcs::to_bytes(&100u64));
    assert_eq!(bcs::to_bytes(&events[0]), expected);
    f.compound!(1, 0);
    let (_, _, meme, quote) = f.vault.snapshot_for_testing();
    assert_eq!(meme, 0);
    assert_eq!(quote, 100);
    f.contribute!(1, 0);
    f.compound!(1, 0);
    let (_, _, meme, quote) = f.vault.snapshot_for_testing();
    assert_eq!(meme, 1);
    assert_eq!(quote, 100);
    assert!(sui::event::events_by_type<vault::Compounded>().is_empty());
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EWrongVersion, location = blast_fun_auto_lp::vault)]
fun stale_generation_rejects_collection() {
    let mut f = start();
    f.control.set_version_for_testing(2);
    f.collect!();
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EWrongVersion, location = blast_fun_auto_lp::vault)]
fun stale_generation_precedes_expired_deadline_and_dust() {
    let mut f = start();
    f.control.set_version_for_testing(2);
    f.clock.increment_for_testing(1);
    f.compound!(0, 0);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EDeadlineExpired, location = blast_fun_auto_lp::vault)]
fun expired_deadline_rejects_even_an_empty_deposit() {
    let mut f = start();
    f.clock.increment_for_testing(1);
    f.compound!(0, 0);
    f.end();
}

#[test]
fun activation_restores_access_only_to_the_compiled_next_generation() {
    let mut f = start();
    f.control.set_version_for_testing(0);
    let witness = f.authority.sign_in(&f.version, &f.admin);
    f.control.activate(&witness);
    f.collect!();
    let events = sui::event::events_by_type<vault::VersionActivated>();
    let mut expected = bcs::to_bytes(&0u64);
    expected.append(bcs::to_bytes(&1u64));
    assert_eq!(bcs::to_bytes(&events[0]), expected);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EWrongVersion, location = blast_fun_auto_lp::vault)]
fun activation_cannot_select_an_unimplemented_generation() {
    let mut f = start();
    let witness = f.authority.sign_in(&f.version, &f.admin);
    f.control.activate(&witness);
    f.end();
}

#[test]
fun enrollment_and_collection_events_reconcile_all_custody_fields() {
    let mut f = start();
    // Enrollment occurred in a prior transaction; the preserved children prove identity.
    let (cap_id, _, _, _) = f.vault.snapshot_for_testing();
    assert_eq!(cap_id, f.cap_id);
    f.collect!();
    let (_, _, meme, quote) = f.vault.snapshot_for_testing();
    let events = sui::event::events_by_type<vault::FeesCollected>();
    assert_eq!(events.length(), 1);
    let mut expected = bcs::to_bytes(&object::id(&f.vault));
    expected.append(bcs::to_bytes(&object::id(&f.launch)));
    expected.append(bcs::to_bytes(&meme));
    expected.append(bcs::to_bytes(&quote));
    expected.append(bcs::to_bytes(&meme));
    expected.append(bcs::to_bytes(&quote));
    assert_eq!(bcs::to_bytes(&events[0]), expected);
    f.end();
}

#[test]
fun native_and_own_position_fees_enter_custody_without_new_meme() {
    let mut f = start();
    f.collect!();
    f.compound!(1, 0);
    let (_, _, meme_before, quote_before) = f.vault.snapshot_for_testing();
    let input = coin::mint_for_testing<QUOTE>(1_000_000, f.ctx!());
    let (bought, refund) = f.buy!(input);
    destroy(bought);
    destroy(refund);
    f.harvest_native!();
    let (_, _, _, creator_fees) = f.locked.borrow().snapshot_for_testing();
    assert!(creator_fees > 0);
    f.collect_native!();
    let (_, _, meme_after, quote_after) = f.vault.snapshot_for_testing();
    assert_eq!(meme_after, meme_before);
    assert_eq!(quote_after, quote_before + creator_fees);
    f.collect_own!();
    let (_, _, meme_after_own, quote_after_own) = f.vault.snapshot_for_testing();
    assert_eq!(meme_after_own, meme_before);
    assert!(quote_after_own > quote_after);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EMinimumShares, location = blast_fun_dex::pool)]
fun compound_enforces_minimum_shares_for_a_positive_deposit() {
    let mut f = start();
    f.collect!();
    let (_, _, meme, quote) = f.vault.snapshot_for_testing();
    let (_, _, shares) = f.pool.deposit_amounts(meme, quote);
    f.compound!(shares + 1, 0);
    f.end();
}

#[test]
#[expected_failure(abort_code = pool::EWrongVersion, location = blast_fun_dex::pool)]
fun retired_dex_generation_rejects_even_empty_compound() {
    let mut f = start();
    f.factory.set_version_for_testing(2);
    f.compound!(0, 0);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EVersionOverflow, location = blast_fun_auto_lp::vault)]
fun activation_rejects_generation_overflow() {
    let mut f = start();
    f.control.set_version_for_testing(std::u64::max_value!());
    let witness = f.authority.sign_in(&f.version, &f.admin);
    f.control.activate(&witness);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EUnauthorizedExecutor, location = blast_fun_auto_lp::vault)]
fun public_collector_cannot_execute_a_deposit_at_attacker_selected_price() {
    let mut f = start();
    f.next_tx!(@0xB, |f| {
        f.collect!();
        let input = coin::mint_for_testing<QUOTE>(25_000_000, f.ctx!());
        let (bought, refund) = f.buy!(input);
        assert!(bought.value() > 0);
        destroy(bought);
        destroy(refund);
        f.compound!(0, 0);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EWrongPool, location = blast_fun_auto_lp::vault)]
fun wrong_pool_is_rejected_even_when_balances_are_empty() {
    let mut f = start();
    f.vault.set_pool_id_for_testing(object::id_from_address(@0x99));
    f.compound!(0, 0);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EInvalidExecutor, location = blast_fun_auto_lp::vault)]
fun enrollment_rejects_an_unusable_zero_executor() {
    let f = start_with_control(1, @0x0);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EWrongVersion, location = blast_fun_auto_lp::vault)]
fun enrollment_rejects_retired_generation_before_consuming_creator_authority() {
    let f = start_with_control(2, @0xC);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EMaximumInput, location = blast_fun_auto_lp::vault)]
fun honest_executor_maximum_quote_rejects_price_pump_even_when_minimum_shares_passes() {
    let mut f = start();
    let (meme_reserve, quote_reserve, _) = f.pool.balances_for_testing();
    f.contribute!(meme_reserve / 20, quote_reserve / 2);
    let (meme_max, quote_max, minimum) = f
        .pool
        .deposit_amounts(meme_reserve / 20, quote_reserve / 2);
    f.next_tx!(@0xB, |f| {
        let input = coin::mint_for_testing<QUOTE>(quote_reserve / 2, f.ctx!());
        let (bought, refund) = f.pool.buy(&f.factory, input, 1, 500, 0, &f.clock, f.ctx!());
        destroy(bought);
        destroy(refund);
    });
    f.next_tx!(@0xC, |f| {
        let (_, increased_quote, increased_shares) = f
            .pool
            .deposit_amounts(meme_reserve / 20, quote_reserve / 2);
        assert!(increased_quote > quote_max);
        assert!(increased_shares >= minimum);
        f.compound_bounded!(minimum, meme_max, quote_max, 0);
    });
    f.end();
}

#[test]
fun external_creator_fees_enter_custody_with_the_correct_source_and_amounts() {
    let mut f = start();
    let meme = coin::mint_for_testing<VAULT_TESTS>(1000, f.ctx!()).into_balance();
    let quote = coin::mint_for_testing<QUOTE>(2000, f.ctx!()).into_balance();
    let share = f.runtime.protocol_fee_share_bps();
    let expected_meme = 1000 - (1000 * share + 9999) / 10000;
    let expected_quote = 2000 - (2000 * share + 9999) / 10000;
    let mut source = blast_fun_migrators::vault::funded_for_testing(
        object::id(&f.pool),
        meme,
        quote,
        &f.runtime,
        f.ctx!(),
    );
    f.next_tx!(@0xB, |f| {
        f.vault.collect_external_lp(&f.control, &mut source, f.ctx!());
    });
    let (_, _, retained_meme, retained_quote) = f.vault.snapshot_for_testing();
    assert_eq!(retained_meme, expected_meme);
    assert_eq!(retained_quote, expected_quote);
    let events = sui::event::events_by_type<vault::FeesCollected>();
    assert_eq!(events.length(), 1);
    let mut expected = bcs::to_bytes(&object::id(&f.vault));
    expected.append(bcs::to_bytes(&object::id(&source)));
    expected.append(bcs::to_bytes(&expected_meme));
    expected.append(bcs::to_bytes(&expected_quote));
    expected.append(bcs::to_bytes(&expected_meme));
    expected.append(bcs::to_bytes(&expected_quote));
    assert_eq!(bcs::to_bytes(&events[0]), expected);
    destroy(source);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::ENothingAccrued, location = blast_fun::fees)]
fun repeated_curve_collection_preserves_the_source_empty_claim_policy() {
    let mut f = start();
    f.collect!();
    f.collect!();
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EMaximumInput, location = blast_fun_auto_lp::vault)]
fun maximum_meme_is_enforced_independently_of_minimum_shares() {
    let mut f = start();
    f.collect!();
    let (_, _, meme, quote) = f.vault.snapshot_for_testing();
    let (used_meme, used_quote, shares) = f.pool.deposit_amounts(meme, quote);
    f.compound_bounded!(shares, used_meme - 1, used_quote, 0);
    f.end();
}

#[test]
fun compound_accepts_the_exact_deadline() {
    let mut f = start();
    f.collect!();
    f.clock.increment_for_testing(1234);
    f.compound!(1, 1234);
    assert_eq!(sui::event::events_by_type<vault::Compounded>().length(), 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EInvalidAdminCap, location = blast_fun::acl)]
fun revoked_administrator_cannot_activate_auto_lp() {
    let mut f = start();
    f.control.set_version_for_testing(0);
    revoke_admin(&mut f);
    let witness = f.authority.sign_in(&f.version, &f.admin);
    f.control.activate(&witness);
    f.end();
}

#[test]
fun external_witness_creator_funded_pool_supports_enrollment_and_fee_collection() {
    let mut f = start_with_route(1, @0xC, true);
    assert!(sui::event::events_by_type<migration::Migrated>().is_empty());
    assert!(f.locked.is_none());
    let meme = coin::mint_for_testing<VAULT_TESTS>(1000, f.ctx!()).into_balance();
    let quote = coin::mint_for_testing<QUOTE>(1000, f.ctx!()).into_balance();
    let mut source = blast_fun_migrators::vault::funded_for_testing(
        object::id(&f.pool),
        meme,
        quote,
        &f.runtime,
        f.ctx!(),
    );
    f.next_tx!(@0xB, |f| {
        f.vault.collect_external_lp(&f.control, &mut source, f.ctx!());
    });
    let (_, _, meme, quote) = f.vault.snapshot_for_testing();
    assert!(meme > 0 && quote > 0);
    destroy(source);
    f.end();
}

// === Private Test Helpers ===

macro fun ctx($f: &mut AutoLpFixture): &mut TxContext { let f = $f; f.scenario.ctx() }

macro fun next_tx($f: &mut AutoLpFixture, $sender: address, $fn: |&mut AutoLpFixture|) {
    let f = $f;
    f.scenario.next_tx($sender);
    $fn(f);
}

macro fun buy(
    $f: &mut AutoLpFixture,
    $input: coin::Coin<QUOTE>,
): (coin::Coin<VAULT_TESTS>, coin::Coin<QUOTE>) {
    let f = $f;
    f.pool.buy(&f.factory, $input, 1, 500, 0, &f.clock, f.ctx!())
}

macro fun harvest_native($f: &mut AutoLpFixture) {
    let f = $f;
    f.locked.borrow_mut().collect(&mut f.pool, &f.factory, &f.runtime, f.ctx!());
}

macro fun collect_native($f: &mut AutoLpFixture) {
    let f = $f;
    f.vault.collect_native_lp(&f.control, f.locked.borrow_mut(), &f.factory, f.ctx!());
}

macro fun collect_own($f: &mut AutoLpFixture) {
    let f = $f;
    f.vault.collect_own_lp(&f.control, &mut f.pool, &f.factory, f.ctx!());
}

macro fun collect($f: &mut AutoLpFixture) {
    let f = $f;
    f.vault.collect_curve(&f.control, &mut f.launch, &f.version, f.ctx!());
}

macro fun compound($f: &mut AutoLpFixture, $minimum: u128, $deadline: u64) {
    let f = $f;
    f
        .vault
        .compound(
            &f.control,
            &mut f.pool,
            &f.factory,
            std::u64::max_value!(),
            std::u64::max_value!(),
            $minimum,
            $deadline,
            &f.clock,
            f.ctx!(),
        );
}

macro fun contribute($f: &mut AutoLpFixture, $meme: u64, $quote: u64) {
    let f = $f;
    let meme = coin::mint_for_testing<VAULT_TESTS>($meme, f.ctx!());
    let quote = coin::mint_for_testing<QUOTE>($quote, f.ctx!());
    f.vault.contribute(&f.control, meme, quote);
}

fun start(): AutoLpFixture { start_with_control(1, @0xC) }

fun start_with_control(generation: u64, executor: address): AutoLpFixture {
    start_with_route(generation, executor, false)
}

fun start_with_route(generation: u64, executor: address, external: bool): AutoLpFixture {
    let mut scenario = test_scenario::begin(@0xA);
    let version = package_version::new_for_testing(scenario.ctx());
    let (root, mut authority) = acl::new_protocol_for_testing(scenario.ctx());
    authority.grant_admin(&version, &root, @0xA, scenario.ctx());
    launch_config::init_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let admin = scenario.take_from_sender<acl::AdminCap>();
    let witness = authority.sign_in(&version, &admin);
    let mut config = scenario.take_shared<launch_config::LaunchConfig>();
    config.allow_quote<QUOTE>(&version, &witness, 5_000_000, 25_000_000);
    if (external) {
        config.allow_migration_witness<EXTERNAL_WITNESS>(&version, &witness);
    } else {
        config.allow_migration_witness<Witness>(&version, &witness);
    };
    config.set_trade_fees(&version, &witness, 100, 100);
    config.set_graduation_defaults(&version, &witness, 0, 0, 2_000);
    let runtime = runtime_config::new_disabled_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let ticket = launch_ticket::new(
        VAULT_TESTS(),
        b"TEST".to_string(),
        b"Test".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(@0xA),
        false,
        0,
        scenario.ctx(),
    );
    let mut launch = if (external) {
        launch::new<VAULT_TESTS, QUOTE, EXTERNAL_WITNESS>(ticket, &version, &config, scenario.ctx())
    } else {
        launch::new<VAULT_TESTS, QUOTE, Witness>(ticket, &version, &config, scenario.ctx())
    };
    let (cap, metadata) = launch.claim_creator_cap(
        &version,
        &runtime,
        option::none(),
        &clock,
        scenario.ctx(),
    );
    let cap_id = object::id(&cap);
    transfer::public_transfer(metadata, @0xA);
    let quote = coin::mint_for_testing<QUOTE>(30_000_000, scenario.ctx());
    let (bought, refund) = launch.buy(&version, &runtime, quote, 1, scenario.ctx());
    destroy(bought);
    destroy(refund);
    let mut factory = pool::new_for_testing(scenario.ctx());
    scenario.next_tx(@0xB);
    let mut currency = scenario.take_from_address<Currency<VAULT_TESTS>>(@0xc);
    if (external) {
        let payload = launch.migrate<VAULT_TESTS, QUOTE, EXTERNAL_WITNESS>(
            &version,
            &mut currency,
            scenario.ctx(),
        );
        let (meme, quote) = payload.redeem_migration(EXTERNAL_WITNESS());
        let meme = meme.into_coin(scenario.ctx());
        let quote = quote.into_coin(scenario.ctx());
        let (pool, position) = factory.create(
            &cap,
            &launch,
            &currency,
            meme,
            quote,
            0,
            &clock,
            scenario.ctx(),
        );
        pool.share();
        transfer::public_transfer(position, @0xA);
    } else {
        migration::migrate(
            &mut launch,
            &version,
            &mut factory,
            &mut currency,
            &clock,
            scenario.ctx(),
        );
    };
    scenario.next_tx(@0xA);
    let pool = scenario.take_shared<Pool<VAULT_TESTS, QUOTE>>();
    let mut control = vault::new_control_for_testing(scenario.ctx());
    control.set_version_for_testing(generation);
    let vault = vault::new(&control, cap, &pool, &factory, executor, scenario.ctx());
    let (_, position_id, _, _) = vault.snapshot_for_testing();
    let events = sui::event::events_by_type<vault::Enrolled>();
    let mut expected = bcs::to_bytes(&object::id(&vault));
    expected.append(bcs::to_bytes(&object::id(&pool)));
    expected.append(bcs::to_bytes(&cap_id));
    expected.append(bcs::to_bytes(&position_id));
    expected.append(bcs::to_bytes(&executor));
    assert_eq!(bcs::to_bytes(&events[0]), expected);
    vault.share();
    test_scenario::return_shared(pool);
    scenario.next_tx(@0xC);
    let pool = scenario.take_shared<Pool<VAULT_TESTS, QUOTE>>();
    let vault = scenario.take_shared<Vault<VAULT_TESTS, QUOTE>>();
    let locked = if (external) {
        option::none()
    } else {
        option::some(scenario.take_shared<LockedLpVault<VAULT_TESTS, QUOTE>>())
    };
    test_scenario::return_shared(config);
    destroy(currency);
    AutoLpFixture {
        scenario,
        version,
        control,
        factory,
        pool,
        vault,
        launch,
        clock,
        cap_id,
        locked,
        runtime,
        authority,
        admin,
        root,
    }
}

fun end(f: AutoLpFixture) {
    let AutoLpFixture {
        scenario,
        version,
        control,
        factory,
        pool,
        vault,
        launch,
        clock,
        cap_id: _,
        locked,
        runtime,
        authority,
        admin,
        root,
    } = f;
    test_scenario::return_shared(pool);
    test_scenario::return_shared(vault);
    locked.do!(|locked| test_scenario::return_shared(locked));
    destroy(runtime);
    destroy(launch);
    destroy(version);
    destroy(control);
    destroy(factory);
    destroy(authority);
    destroy(admin);
    destroy(root);
    clock.destroy_for_testing();
    scenario.end();
}

macro fun compound_bounded(
    $f: &mut AutoLpFixture,
    $minimum: u128,
    $meme: u64,
    $quote: u64,
    $deadline: u64,
) {
    let f = $f;
    f
        .vault
        .compound(
            &f.control,
            &mut f.pool,
            &f.factory,
            $meme,
            $quote,
            $minimum,
            $deadline,
            &f.clock,
            f.ctx!(),
        );
}

fun revoke_admin(f: &mut AutoLpFixture) {
    let AutoLpFixture { authority, version, root, admin, .. } = f;
    authority.revoke_admin(version, root, object::id(admin));
}
