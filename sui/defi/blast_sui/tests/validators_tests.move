// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_sui::validators_tests;

// === Constants ===

const OWNER: address = @0xAD;

const USER: address = @0xA11CE;

const MIST_PER_SUI: u64 = 1_000_000_000;

/// OWNER's blast bootstrap, staked to the first listed pool.
const BOOTSTRAP: u64 = 10 * MIST_PER_SUI;

/// The 48-hour delay the runbook sets before deposits are released.
const DELAY_MS: u64 = 172_800_000;

// === Test-Only Types ===

/// A live vault over several genesis validators. `next_tx!` borrows the shared vault and
/// system state for exactly one transaction.
public struct Fixture {
    runner: TestRunner,
    version: PackageVersion<BLAST_SUI_PACKAGE>,
    vault: Option<Vault>,
    system_state: Option<SuiSystemState>,
}

// === Tests ===

// List

#[test]
fun a_new_vault_lists_only_its_bootstrap_pool() {
    let mut fixture = start(2, 1);

    assert_eq!(fixture.pools().length(), 1);

    fixture.end();
}

#[test]
fun the_list_fills_to_the_cap() {
    let max = constants::max_validators!();
    let mut fixture = start(max, max);

    assert_eq!(fixture.pools().length(), max);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EMaxValidatorsReached, location = blast_sui::vault)]
fun the_first_validator_over_the_cap_is_rejected() {
    let max = constants::max_validators!();
    let mut fixture = start(max + 1, max);
    let extra = fixture.pool_of(max);

    fixture.schedule(extra);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EMaxValidatorsReached, location = blast_sui::vault)]
fun pending_admissions_count_against_the_cap() {
    let max = constants::max_validators!();
    let mut fixture = start(max + 1, max - 1);
    let pending = fixture.pool_of(max - 1);
    let extra = fixture.pool_of(max);

    fixture.schedule(pending);
    fixture.schedule(extra);

    fixture.end();
}

#[test]
fun rescheduling_a_pending_admission_at_the_cap_takes_no_new_slot() {
    let max = constants::max_validators!();
    let mut fixture = start(max, max - 1);
    let pending = fixture.pool_of(max - 1);

    fixture.schedule(pending);
    fixture.schedule(pending);
    fixture.apply(pending);
    assert_eq!(fixture.pools().length(), max);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed_set)]
fun a_listed_validator_cannot_be_scheduled_again() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();

    fixture.schedule(pools[1]);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed_set)]
fun a_listed_validator_at_the_cap_reports_unchanged_before_the_cap() {
    let max = constants::max_validators!();
    let mut fixture = start(max, max);
    let pools = fixture.pools();

    fixture.schedule(pools[0]);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_set)]
fun applying_an_unknown_pool_reports_no_pending_before_any_native_read() {
    let mut fixture = start(1, 1);

    fixture.apply(object::id_from_address(@0xDEAD));

    fixture.end();
}

#[test]
fun an_admission_records_the_new_pool_in_a_final_snapshot() {
    let mut fixture = start(2, 1);
    let pool = fixture.pool_of(1);

    fixture.admit(pool);
    let custody = events::collect_one<events::VaultSynced>(0).vault_synced_custody();
    assert_position(&custody.fun_position(pool), 0, 0, 0);
    assert_eq!(custody, fixture.snapshot());

    fixture.end();
}

#[test]
fun a_removed_validator_can_be_admitted_again_with_empty_positions() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();
    fixture.mint(pools[1], 2 * MIST_PER_SUI);

    fixture.remove(pools[1]);
    assert_eq!(fixture.pools(), vector[pools[0]]);

    fixture.admit(pools[1]);
    assert_eq!(fixture.pools(), pools);
    let custody = fixture.snapshot();
    assert_position(&custody.fun_position(pools[1]), 0, 0, 0);
    assert_position(&custody.blast_position(pools[1]), 0, 0, 0);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EValidatorNotActive, location = blast_sui::vault)]
fun a_pending_admission_whose_validator_departs_cannot_apply() {
    let mut fixture = start(3, 1);
    let departing = fixture.pool_of(2);

    fixture.schedule(departing);
    fixture.depart(2);
    fixture.advance_epoch();
    fixture.apply(departing);

    fixture.end();
}

#[test]
fun a_pending_admission_whose_validator_departed_can_be_removed() {
    let mut fixture = start(3, 1);
    let departing = fixture.pool_of(2);

    fixture.schedule(departing);
    fixture.depart(2);
    fixture.advance_epoch();
    fixture.remove(departing);
    fixture.next_tx!(USER, |f| {
        assert_eq!(f.vault!().validators_for_testing().pending_count(), 0);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EStaleExchangeRate, location = blast_sui::vault)]
fun admission_during_safe_mode_is_rejected_for_lack_of_a_current_rate() {
    let mut fixture = start(2, 1);
    let pool = fixture.pool_of(1);

    fixture.schedule(pool);
    fixture.advance_epoch_safe_mode();
    fixture.apply(pool);

    fixture.end();
}

// Delays

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed_set)]
fun an_admission_cannot_apply_before_its_delay() {
    let mut fixture = start(2, 1);
    let pool = fixture.pool_of(1);

    fixture.set_validator_delay(DELAY_MS);
    fixture.schedule(pool);
    fixture.apply_at(pool, DELAY_MS - 1);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed_set)]
fun an_early_admission_reports_not_ready_before_its_validator_departure() {
    let mut fixture = start(3, 1);
    let departing = fixture.pool_of(2);

    fixture.set_validator_delay(DELAY_MS);
    fixture.schedule(departing);
    fixture.depart(2);
    fixture.advance_epoch();
    fixture.apply_at(departing, DELAY_MS - 1);

    fixture.end();
}

#[test]
fun anyone_can_apply_an_admission_once_its_delay_elapses() {
    let mut fixture = start(2, 1);
    let pool = fixture.pool_of(1);

    fixture.set_validator_delay(DELAY_MS);
    fixture.schedule(pool);
    fixture.apply_at(pool, DELAY_MS);
    assert_eq!(fixture.pools().length(), 2);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_set)]
fun a_cancelled_admission_cannot_apply() {
    let mut fixture = start(2, 1);
    let pool = fixture.pool_of(1);

    fixture.schedule(pool);
    fixture.next_tx!(OWNER, |f| {
        f.vault!().cancel_validator(&f.version, &cancel_admin(), pool);
    });
    fixture.apply(pool);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_set)]
fun a_cancelled_validator_delay_cannot_apply() {
    let mut fixture = start(1, 1);

    fixture.next_tx!(OWNER, |f| {
        let clock = clock::create_for_testing(f.ctx!());
        f.vault!().schedule_validator_delay(&f.version, &validator_admin(), DELAY_MS, &clock);
        f.vault!().cancel_validator_delay(&f.version, &cancel_admin());
        f.vault!().apply_validator_delay(&f.version, &clock);
        clock.destroy_for_testing();
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnchanged, location = blast_admin::delayed_set)]
fun an_unchanged_validator_delay_is_rejected() {
    let mut fixture = start(1, 1);

    fixture.next_tx!(OWNER, |f| {
        let clock = clock::create_for_testing(f.ctx!());
        f.vault!().schedule_validator_delay(&f.version, &validator_admin(), 0, &clock);
        clock.destroy_for_testing();
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun a_validator_delay_change_waits_the_applied_delay() {
    let mut fixture = start(1, 1);

    fixture.set_validator_delay(DELAY_MS);
    fixture.next_tx!(OWNER, |f| {
        let clock = clock::create_for_testing(f.ctx!());
        f.vault!().schedule_validator_delay(&f.version, &validator_admin(), 1, &clock);
        f.vault!().apply_validator_delay(&f.version, &clock);
        clock.destroy_for_testing();
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EUnguardedDelay, location = blast_sui::vault)]
fun unpause_refuses_while_the_validator_delay_is_zero() {
    let mut fixture = start(1, 1);

    fixture.unpause();

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EUnguardedDelay, location = blast_sui::vault)]
fun unpause_refuses_while_an_admission_is_pending() {
    let mut fixture = start(2, 1);
    let pool = fixture.pool_of(1);

    fixture.schedule(pool);
    fixture.set_validator_delay(DELAY_MS);
    fixture.unpause();

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EUnguardedDelay, location = blast_sui::vault)]
fun unpause_refuses_a_pending_change_to_a_zero_validator_delay() {
    let mut fixture = start(1, 1);

    fixture.set_validator_delay(DELAY_MS);
    fixture.next_tx!(OWNER, |f| {
        let clock = clock::create_for_testing(f.ctx!());
        f.vault!().schedule_validator_delay(&f.version, &validator_admin(), 0, &clock);
        clock.destroy_for_testing();
    });
    fixture.unpause();

    fixture.end();
}

#[test]
fun unpause_succeeds_once_the_validator_delay_is_guarded_and_nothing_is_pending() {
    let mut fixture = start(1, 1);

    fixture.set_validator_delay(DELAY_MS);
    fixture.unpause();

    fixture.end();
}

// Removal

#[test]
fun removal_unwinds_the_pool_in_the_same_call_and_splits_it_across_the_rest() {
    let mut fixture = start(4, 4);
    let pools = fixture.pools();
    fixture.advance_epoch();
    fixture.sync();

    let custody = fixture.remove(pools[0]);
    let unwound = events::collect_one<events::PoolUnwound>(0);
    let (unwound_pool, _) = unwound.pool_unwound_fields();
    assert_eq!(unwound_pool, pools[0]);

    let share = BOOTSTRAP / 3;
    assert_position(&custody.blast_position(pools[1]), share, 0, 0);
    assert_position(&custody.blast_position(pools[2]), share, 0, 0);
    assert_position(&custody.blast_position(pools[3]), BOOTSTRAP - 2 * share, 0, 0);
    let (_, blast_liquid) = custody.vault_custody_liquid();
    assert_eq!(blast_liquid, 0);

    fixture.end();
}

#[test]
fun removal_of_a_pending_admission_touches_no_position() {
    let mut fixture = start(2, 1);
    let pending = fixture.pool_of(1);

    fixture.schedule(pending);
    let custody = fixture.remove(pending);
    assert_eq!(custody.vault_custody_pools().length(), 1);
    assert_eq!(events::collect<events::PoolUnwound>().length(), 0);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EValidatorNotAccepted, location = blast_sui::vault)]
fun removal_of_an_unlisted_pool_is_rejected() {
    let mut fixture = start(2, 1);
    let unlisted = fixture.pool_of(1);

    fixture.remove(unlisted);

    fixture.end();
}

#[test]
fun removal_of_a_member_the_refresh_finds_departed_succeeds() {
    let mut fixture = start(3, 3);
    let pools = fixture.pools();

    fixture.depart(1);
    fixture.advance_epoch();
    fixture.remove(pools[1]);
    assert_eq!(fixture.pools(), vector[pools[0], pools[2]]);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EStaleExchangeRate, location = blast_sui::vault)]
fun removal_during_safe_mode_runs_but_readmission_waits_for_a_current_rate() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_safe_mode();

    fixture.remove(pools[0]);
    assert_eq!(fixture.pools(), vector[pools[1]]);
    fixture.admit(pools[0]);

    fixture.end();
}

#[test]
fun a_pool_removed_during_safe_mode_returns_after_a_normal_epoch() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();
    fixture.advance_epoch();
    fixture.sync();
    fixture.advance_epoch_safe_mode();
    fixture.remove(pools[0]);

    fixture.advance_epoch();
    fixture.admit(pools[0]);
    assert_eq!(fixture.pools(), vector[pools[1], pools[0]]);

    fixture.end();
}

#[test]
fun removal_of_a_stale_pool_at_a_reused_address_unwinds_it() {
    let mut fixture = start(2, 1);
    let pools = fixture.pools();
    fixture.advance_epoch();
    fixture.sync();
    fixture.rejoin_at_same_address(0);

    let custody = fixture.remove(pools[0]);
    assert!(custody.vault_custody_pools().is_empty());
    let (_, blast_liquid) = custody.vault_custody_liquid();
    assert_eq!(blast_liquid, BOOTSTRAP);

    fixture.end();
}

#[test]
fun after_the_last_validator_leaves_exits_and_recovery_still_work() {
    let mut fixture = start(2, 1);
    let pools = fixture.pools();
    let (shares, _) = fixture.mint_blast(pools[0], 4 * MIST_PER_SUI);
    fixture.mint(pools[0], 3 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();

    let custody = fixture.remove(pools[0]);
    assert!(custody.vault_custody_pools().is_empty());

    let donated = fixture.donate(MIST_PER_SUI);
    let (_, blast_liquid) = donated.vault_custody_liquid();
    assert!(blast_liquid >= BOOTSTRAP + 4 * MIST_PER_SUI + MIST_PER_SUI);

    fixture.next_tx!(OWNER, |f| {
        f.vault!().top_up_fun_reserve(&f.version, coin::mint_for_testing(1, f.ctx!()));
    });
    fixture.redeem_fun(3 * MIST_PER_SUI);
    let (net, _) = fixture.redeem_blast(shares);
    assert!(net > 0);

    fixture.end();
}

// Picks

#[test]
#[expected_failure(abort_code = errors::EValidatorNotAccepted, location = blast_sui::vault)]
fun a_mint_picking_an_unlisted_pool_is_rejected() {
    let mut fixture = start(2, 1);
    let unlisted = fixture.pool_of(1);

    fixture.mint(unlisted, 2 * MIST_PER_SUI);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EValidatorNotAccepted, location = blast_sui::vault)]
fun a_request_picking_an_unlisted_pool_is_rejected() {
    let mut fixture = start(2, 1);
    let unlisted = fixture.pool_of(1);

    fixture.request(unlisted, 2 * MIST_PER_SUI);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EValidatorNotAccepted, location = blast_sui::vault)]
fun a_pick_of_a_pending_admission_is_rejected() {
    let mut fixture = start(2, 1);
    let pending = fixture.pool_of(1);

    fixture.schedule(pending);
    fixture.mint(pending, 2 * MIST_PER_SUI);

    fixture.end();
}

#[test]
fun a_mint_delegates_only_to_its_picked_pool() {
    let mut fixture = start(3, 3);
    let pools = fixture.pools();

    let (delegated, custody) = fixture.mint(pools[1], 2 * MIST_PER_SUI);
    assert_eq!(delegated, 2 * MIST_PER_SUI);
    assert_position(&custody.fun_position(pools[0]), 0, 0, 0);
    assert_position(&custody.fun_position(pools[1]), 2 * MIST_PER_SUI, 0, 0);
    assert_position(&custody.fun_position(pools[2]), 0, 0, 0);

    fixture.end();
}

#[test]
fun a_sub_minimum_mint_stays_liquid() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();
    let reserve = constants::fun_rounding_reserve_mist!();

    let (delegated, custody) = fixture.mint(pools[1], MIST_PER_SUI - 1);
    assert_eq!(delegated, 0);
    let (fun_liquid, _) = custody.vault_custody_liquid();
    assert_eq!(fun_liquid, reserve + MIST_PER_SUI - 1);

    fixture.end();
}

#[test]
fun a_pick_never_moves_sui_that_was_already_idle() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();
    let reserve = constants::fun_rounding_reserve_mist!();
    let idle = MIST_PER_SUI / 2;
    fixture.mint(pools[0], idle);

    let (delegated, custody) = fixture.mint(pools[1], MIST_PER_SUI);
    assert_eq!(delegated, MIST_PER_SUI);
    assert_position(&custody.fun_position(pools[1]), MIST_PER_SUI, 0, 0);
    let (fun_liquid, _) = custody.vault_custody_liquid();
    assert_eq!(fun_liquid, reserve + idle);

    fixture.end();
}

#[test]
fun the_reserve_refills_before_a_pick_delegates() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();
    let reserve = constants::fun_rounding_reserve_mist!();
    let gap = 1_000;
    fixture.next_tx!(USER, |f| f.vault!().consume_fun_buffer_for_testing(gap));

    let (delegated, custody) = fixture.mint(pools[1], 2 * MIST_PER_SUI);
    assert_eq!(delegated, 2 * MIST_PER_SUI - gap);
    let (fun_liquid, _) = custody.vault_custody_liquid();
    assert_eq!(fun_liquid, reserve);

    fixture.end();
}

#[test]
fun a_pick_during_safe_mode_stays_liquid() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();
    let reserve = constants::fun_rounding_reserve_mist!();
    fixture.advance_epoch_safe_mode();

    let (delegated, custody) = fixture.mint(pools[1], 2 * MIST_PER_SUI);
    assert_eq!(delegated, 0);
    let (fun_liquid, _) = custody.vault_custody_liquid();
    assert_eq!(fun_liquid, reserve + 2 * MIST_PER_SUI);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EValidatorNotAccepted, location = blast_sui::vault)]
fun a_mint_picking_a_pool_in_its_departure_epoch_is_rejected() {
    let mut fixture = start(3, 3);
    let pools = fixture.pools();

    fixture.depart(1);
    fixture.advance_epoch();
    fixture.mint(pools[1], 2 * MIST_PER_SUI);

    fixture.end();
}

#[test]
fun sync_processes_a_departure_that_a_mint_picking_it_could_not() {
    let mut fixture = start(3, 3);
    let pools = fixture.pools();

    fixture.depart(1);
    fixture.advance_epoch();
    fixture.sync();
    assert_eq!(fixture.pools(), vector[pools[0], pools[2]]);

    fixture.end();
}

// Idle Rule

#[test]
fun idle_sui_splits_evenly_at_exactly_the_per_member_minimum() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();

    let custody = fixture.donate(2 * MIST_PER_SUI);
    assert_position(&custody.blast_position(pools[0]), BOOTSTRAP + MIST_PER_SUI, 0, 0);
    assert_position(&custody.blast_position(pools[1]), MIST_PER_SUI, 0, 0);

    fixture.end();
}

#[test]
fun idle_sui_just_below_the_per_member_minimum_goes_to_the_smallest_position() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();

    let custody = fixture.donate(2 * MIST_PER_SUI - 1);
    assert_position(&custody.blast_position(pools[0]), BOOTSTRAP, 0, 0);
    assert_position(&custody.blast_position(pools[1]), 2 * MIST_PER_SUI - 1, 0, 0);

    fixture.end();
}

#[test]
fun the_last_listed_member_takes_the_even_split_remainder() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();
    let half = 3 * MIST_PER_SUI / 2;

    let custody = fixture.donate(3 * MIST_PER_SUI + 1);
    assert_position(&custody.blast_position(pools[0]), BOOTSTRAP + half, 0, 0);
    assert_position(&custody.blast_position(pools[1]), half + 1, 0, 0);

    fixture.end();
}

#[test]
fun smallest_first_breaks_ties_by_list_order() {
    let mut fixture = start(3, 3);
    let pools = fixture.pools();

    let custody = fixture.donate(MIST_PER_SUI);
    assert_position(&custody.blast_position(pools[1]), MIST_PER_SUI, 0, 0);
    assert_position(&custody.blast_position(pools[2]), 0, 0, 0);

    let custody = fixture.donate(MIST_PER_SUI);
    assert_position(&custody.blast_position(pools[1]), MIST_PER_SUI, 0, 0);
    assert_position(&custody.blast_position(pools[2]), MIST_PER_SUI, 0, 0);

    let custody = fixture.donate(MIST_PER_SUI);
    assert_position(&custody.blast_position(pools[1]), 2 * MIST_PER_SUI, 0, 0);
    assert_position(&custody.blast_position(pools[2]), MIST_PER_SUI, 0, 0);

    fixture.end();
}

// Refresh

#[test]
fun safe_mode_keeps_every_pool_at_its_cached_rate() {
    let mut fixture = start(3, 3);
    let pools = fixture.pools();
    fixture.advance_epoch();
    let before = fixture.sync();
    fixture.advance_epoch_safe_mode();

    let after = fixture.sync();
    assert_eq!(fixture.pools(), pools);
    pools.do!(|pool_id| assert_eq!(before.rate_of(pool_id), after.rate_of(pool_id)));

    fixture.end();
}

#[test]
fun one_departure_of_many_leaves_the_others_current() {
    let mut fixture = start(3, 3);
    let pools = fixture.pools();
    fixture.depart(1);
    fixture.advance_epoch();

    let custody = fixture.sync();
    assert_eq!(fixture.pools(), vector[pools[0], pools[2]]);
    let (rate_epoch, _, _) = custody.rate_of(pools[0]).exchange_rate_fields();
    let current_epoch;
    fixture.next_tx!(USER, |f| current_epoch = f.ctx!().epoch());
    assert_eq!(rate_epoch, current_epoch);

    fixture.end();
}

#[test]
fun every_listed_pool_departing_at_once_leaves_an_empty_solvent_vault() {
    let mut fixture = start(4, 3);
    let pools = fixture.pools();
    fixture.mint(pools[1], 2 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.sync();

    fixture.depart(0);
    fixture.depart(1);
    fixture.depart(2);
    fixture.advance_epoch();
    let custody = fixture.sync();

    assert!(custody.vault_custody_pools().is_empty());
    assert_eq!(events::collect<events::PoolUnwound>().length(), 3);
    fixture.redeem_fun(2 * MIST_PER_SUI);

    fixture.end();
}

#[test]
fun address_reuse_retires_the_old_pool_when_another_pool_has_an_entry() {
    let mut fixture = start(3, 2);
    let pools = fixture.pools();
    fixture.advance_epoch();
    fixture.sync();
    fixture.rejoin_at_same_address(1);

    fixture.sync();
    assert_eq!(fixture.pools(), vector[pools[0]]);

    fixture.end();
}

#[test]
fun address_reuse_retires_the_old_pool_when_the_new_pool_is_itself_listed() {
    let mut fixture = start(2, 1);
    let pools = fixture.pools();
    fixture.advance_epoch();
    fixture.sync();
    fixture.rejoin_at_same_address(0);
    fixture.advance_epoch();
    let new_pool = fixture.pool_of(0);
    assert!(new_pool != pools[0]);

    fixture.admit(new_pool);
    fixture.sync();
    assert_eq!(fixture.pools(), vector[new_pool]);

    fixture.end();
}

#[test]
fun address_reuse_with_a_single_pool_leaves_it_stale_rather_than_retired() {
    let mut fixture = start(2, 1);
    let pools = fixture.pools();
    fixture.advance_epoch();
    fixture.sync();
    fixture.rejoin_at_same_address(0);

    fixture.sync();
    assert_eq!(fixture.pools(), pools);

    fixture.end();
}

/// Genesis entries are present but zero, so a refresh read in that epoch sees a usable-less
/// table: the pool keeps its cached rate and stays listed.
#[test]
fun a_zero_entry_is_not_a_departure() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();
    let before = fixture.snapshot();

    fixture.next_tx!(USER, |f| {
        let mut genesis_ctx = tx_context::new_from_hint(USER, 7, 0, 0, 0);
        f.vault!().sync(&f.version, f.system!(), &mut genesis_ctx);
    });

    assert_eq!(fixture.pools(), pools);
    let after = fixture.snapshot();
    pools.do!(|pool_id| assert_eq!(before.rate_of(pool_id), after.rate_of(pool_id)));

    fixture.end();
}

// Claim

#[test]
#[expected_failure(abort_code = errors::EStaleExchangeRate, location = blast_sui::vault)]
fun a_claim_is_blocked_while_any_pool_is_stale() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();

    fixture.request(pools[1], 2 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.advance_epoch_safe_mode();
    fixture.claim(0);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EStaleExchangeRate, location = blast_sui::vault)]
fun a_claim_is_blocked_by_a_stale_pool_holding_only_arrived_pending_stake() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();

    fixture.donate(2 * MIST_PER_SUI);
    fixture.request(pools[0], 2 * MIST_PER_SUI);
    fixture.advance_epoch_safe_mode();
    fixture.advance_epoch_safe_mode();
    fixture.claim(0);

    fixture.end();
}

#[test]
fun a_claim_values_stake_at_its_own_pools_rate() {
    let mut fixture = start_with_commission(vector[0, 5_000]);
    let pools = fixture.pools();
    fixture.mint_blast(pools[0], 50 * MIST_PER_SUI);
    fixture.advance_epoch_with_rewards(1_000);
    fixture.advance_epoch_with_rewards(1_000);
    fixture.sync();

    fixture.request(pools[1], 3 * MIST_PER_SUI);
    fixture.advance_epoch_with_rewards(1_000);
    fixture.claim(0);

    let claimed = events::collect_one<events::BlastSuiDepositClaimed>(0);
    let (_, _, _, contributed, pool_tokens, _, custody) = claimed.blast_sui_deposit_claimed_fields();
    let (_, picked_sui, picked_tokens) = custody.rate_of(pools[1]).exchange_rate_fields();
    let (_, other_sui, other_tokens) = custody.rate_of(pools[0]).exchange_rate_fields();
    assert_eq!(contributed, math::sui_at_rate_down(pool_tokens, picked_sui, picked_tokens));
    assert!(contributed != math::sui_at_rate_down(pool_tokens, other_sui, other_tokens));

    fixture.end();
}

#[test]
#[expected_failure(abort_code = errors::EValidatorNotAccepted, location = blast_sui::vault)]
fun a_receipt_from_a_removed_pool_cannot_be_claimed() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();

    fixture.request(pools[1], 2 * MIST_PER_SUI);
    fixture.remove(pools[1]);
    fixture.advance_epoch();
    fixture.claim(0);

    fixture.end();
}

#[test]
fun a_receipt_from_a_removed_pool_can_still_be_cancelled() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();

    fixture.request(pools[1], 2 * MIST_PER_SUI);
    fixture.remove(pools[1]);
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        let receipt = f.runner.scenario_mut().take_from_sender<BlastSuiDepositReceipt>();
        let sui_out = receipt.cancel(f.system!(), f.ctx!());
        assert!(sui_out.value() >= 2 * MIST_PER_SUI);
        transfer::public_transfer(sui_out, USER);
    });

    fixture.end();
}

// Exit Order

#[test]
fun exits_draw_pending_stake_from_the_largest_position_first() {
    let mut fixture = start(3, 3);
    let pools = fixture.pools();
    let reserve = constants::fun_rounding_reserve_mist!();
    fixture.mint(pools[0], 5 * MIST_PER_SUI);
    fixture.mint(pools[1], 7 * MIST_PER_SUI);
    fixture.mint(pools[2], 3 * MIST_PER_SUI);

    let custody = fixture.redeem_fun(2 * MIST_PER_SUI);
    assert_position(&custody.fun_position(pools[0]), 5 * MIST_PER_SUI, 0, 0);
    assert_position(&custody.fun_position(pools[1]), 5 * MIST_PER_SUI + reserve, 0, 0);
    assert_position(&custody.fun_position(pools[2]), 3 * MIST_PER_SUI, 0, 0);

    fixture.end();
}

#[test]
fun an_exit_visits_pending_positions_in_order_of_principal() {
    let mut fixture = start(3, 3);
    let pools = fixture.pools();
    let reserve = constants::fun_rounding_reserve_mist!();
    fixture.mint(pools[0], 5 * MIST_PER_SUI);
    fixture.mint(pools[1], 7 * MIST_PER_SUI);
    fixture.mint(pools[2], 3 * MIST_PER_SUI);

    let custody = fixture.redeem_fun(14 * MIST_PER_SUI);
    assert_position(&custody.fun_position(pools[0]), 0, 0, 0);
    assert_position(&custody.fun_position(pools[1]), 0, 0, 0);
    assert_position(&custody.fun_position(pools[2]), MIST_PER_SUI + reserve, 0, 0);

    fixture.end();
}

#[test]
fun exits_redeem_active_stake_from_the_largest_position_first() {
    let mut fixture = start(3, 3);
    let pools = fixture.pools();
    fixture.mint_blast(pools[1], 8 * MIST_PER_SUI);
    fixture.advance_epoch();
    let before = fixture.sync();
    assert_position(&before.blast_position(pools[0]), 0, BOOTSTRAP, BOOTSTRAP);
    assert_position(&before.blast_position(pools[1]), 0, 8 * MIST_PER_SUI, 8 * MIST_PER_SUI);

    let (_, custody) = fixture.redeem_blast(MIST_PER_SUI);
    let (_, tokens_first, _) = custody.blast_position(pools[0]).position_custody_fields();
    assert!(tokens_first < BOOTSTRAP);
    assert_position(&custody.blast_position(pools[1]), 0, 8 * MIST_PER_SUI, 8 * MIST_PER_SUI);

    fixture.end();
}

#[test]
fun a_redemption_spans_every_position_breaking_ties_by_list_order() {
    let mut fixture = start(3, 3);
    let pools = fixture.pools();
    let per_pool = 12 * MIST_PER_SUI;
    fixture.request(pools[0], per_pool - BOOTSTRAP);
    fixture.request(pools[1], per_pool);
    fixture.request(pools[2], per_pool);
    fixture.advance_epoch();
    let (first, _) = fixture.claim(0);
    let (second, _) = fixture.claim(0);
    let (third, _) = fixture.claim(0);

    let (net, custody) = fixture.redeem_blast(first + second + third);
    assert!(net > 2 * per_pool);
    assert_position(&custody.blast_position(pools[0]), 0, 0, 0);
    assert_position(&custody.blast_position(pools[1]), 0, 0, 0);
    let (_, tokens_last, _) = custody.blast_position(pools[2]).position_custody_fields();
    assert!(tokens_last > 0);

    fixture.end();
}

// Fun Math

#[test]
fun one_mist_above_the_low_water_mark_keeps_every_active_position() {
    let mut fixture = start_with_active_fun(3);
    let pools = fixture.pools();
    let reserve = constants::fun_rounding_reserve_mist!();
    let low_water = constants::fun_exit_low_water_mist!();

    fixture.next_tx!(USER, |f| {
        f.vault!().consume_fun_buffer_for_testing(reserve - low_water - 1);
    });
    let custody = fixture.sync();
    pools.do!(|pool_id| {
        let (_, tokens, _) = custody.fun_position(pool_id).position_custody_fields();
        assert!(tokens > 0);
    });

    fixture.end();
}

#[test]
fun the_low_water_mark_unwinds_every_active_position() {
    let mut fixture = start_with_active_fun(3);
    let pools = fixture.pools();
    let reserve = constants::fun_rounding_reserve_mist!();
    let low_water = constants::fun_exit_low_water_mist!();

    fixture.next_tx!(USER, |f| {
        f.vault!().consume_fun_buffer_for_testing(reserve - low_water);
    });
    let custody = fixture.sync();
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    pools.do!(|pool_id| {
        let (_, tokens, _) = custody.fun_position(pool_id).position_custody_fields();
        assert_eq!(tokens, 0);
    });
    assert!(fun_custody.pool_assets() >= fun_supply);

    fixture.end();
}

#[test]
fun a_redemption_across_every_position_at_the_cap_keeps_backing() {
    let max = constants::max_validators!();
    let mut fixture = start_with_active_fun(max);
    let pools = fixture.pools();
    let reserve = constants::fun_rounding_reserve_mist!();
    let low_water = constants::fun_exit_low_water_mist!();
    let supply = max * 5 * MIST_PER_SUI;

    fixture.next_tx!(USER, |f| {
        f.vault!().consume_fun_buffer_for_testing(reserve - low_water - 1);
    });
    let custody = fixture.redeem_fun(supply - MIST_PER_SUI);
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    assert_eq!(fun_supply, MIST_PER_SUI);
    assert!(fun_custody.pool_assets() >= fun_supply);
    let drained = pools.count!(|pool_id| {
        let (_, tokens, _) = custody.fun_position(*pool_id).position_custody_fields();
        tokens == 0
    });
    assert!(drained >= max - 1);
    fixture.redeem_fun(MIST_PER_SUI);

    fixture.end();
}

#[test]
fun every_position_at_the_cap_departing_in_one_refresh_keeps_exits_whole() {
    let max = constants::max_validators!();
    let mut fixture = start(max + 1, max);
    let pools = fixture.pools();
    let reserve = constants::fun_rounding_reserve_mist!();
    let low_water = constants::fun_exit_low_water_mist!();
    pools.do!(|pool_id| {
        fixture.mint(pool_id, 5 * MIST_PER_SUI);
    });
    fixture.advance_epoch();
    fixture.sync();
    fixture.next_tx!(USER, |f| {
        f.vault!().consume_fun_buffer_for_testing(reserve - low_water - 1);
    });

    max.do!(|index| fixture.depart(index));
    fixture.advance_epoch();
    let custody = fixture.sync();

    assert!(custody.vault_custody_pools().is_empty());
    assert_eq!(events::collect<events::PoolUnwound>().length(), max);
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    assert!(fun_custody.pool_assets() >= fun_supply);
    fixture.redeem_fun(max * 5 * MIST_PER_SUI);

    fixture.end();
}

#[test]
fun low_water_is_twice_the_cap_times_the_native_margin() {
    assert_eq!(
        constants::fun_exit_low_water_mist!(),
        2 * constants::max_validators!() * constants::native_redemption_rounding_margin!(),
    );
}

#[test]
fun a_redemption_at_the_low_water_mark_never_breaks_backing_across_positions() {
    let mut fixture = start_with_active_fun(3);
    let reserve = constants::fun_rounding_reserve_mist!();
    let low_water = constants::fun_exit_low_water_mist!();

    fixture.next_tx!(USER, |f| {
        f.vault!().consume_fun_buffer_for_testing(reserve - low_water - 1);
    });
    let custody = fixture.redeem_fun(14 * MIST_PER_SUI);
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    assert!(fun_custody.pool_assets() >= fun_supply);

    fixture.end();
}

#[test]
fun a_departure_a_multi_position_redemption_and_an_unwind_fit_one_transaction() {
    let mut fixture = start_with_active_fun(3);
    let pools = fixture.pools();
    let reserve = constants::fun_rounding_reserve_mist!();
    let low_water = constants::fun_exit_low_water_mist!();

    fixture.next_tx!(USER, |f| {
        f.vault!().consume_fun_buffer_for_testing(reserve - low_water - 1);
    });
    fixture.depart(1);
    fixture.advance_epoch();

    let custody = fixture.redeem_fun(10 * MIST_PER_SUI);
    assert_eq!(fixture.pools(), vector[pools[0], pools[2]]);
    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    assert!(fun_custody.pool_assets() >= fun_supply);

    fixture.end();
}

#[test]
fun sweeping_across_pools_keeps_the_supply_plus_reserve_and_moves_only_yield() {
    let mut fixture = start_with_active_fun(3);
    let pools = fixture.pools();
    let reserve = constants::fun_rounding_reserve_mist!();

    fixture.advance_epoch_with_rewards(77);
    fixture.sync();

    let swept = events::collect_one<events::FunYieldSwept>(0);
    let (liquid_sui, active_sui, total_sui, custody) = swept.fun_yield_swept_fields();
    assert_eq!(total_sui, liquid_sui + active_sui);
    assert!(total_sui > 0);

    let (fun_custody, _, _, fun_supply, _) = custody.vault_custody_fields();
    let retained = fun_supply + reserve;
    assert!(fun_custody.pool_assets() >= retained);
    // Each pool can leave at most one rate unit of flooring behind.
    let mut residual_bound = 0;
    pools.do!(|pool_id| {
        let (_, rate_sui, rate_tokens) = custody.rate_of(pool_id).exchange_rate_fields();
        residual_bound = residual_bound + math::fun_conversion_loss_bound_up(rate_sui, rate_tokens);
    });
    assert!(fun_custody.pool_assets() - retained <= residual_bound);

    fixture.end();
}

// Properties

/// Random operations across three pools, with churn, reconcile both ledgers and supplies.
#[test]
fun random_sequences_across_pools_reconcile_every_ledger_and_supply() {
    let mut fixture = start(8, 6);
    let spare = fixture.pool_of(7);
    let mut seed = 0x5EED_u64;
    let mut next_departure = 1;
    let mut reused = false;
    let mut safe_modes = 0u64;
    let mut fun_supply = 0;
    let mut blast_supply = BOOTSTRAP;
    let mut user_fun = 0;
    let mut user_blast = 0;

    48u64.do!(|_| {
        seed = next_random(seed);
        let pools = fixture.pools();
        let pick = pools[(seed >> 8) % pools.length()];
        let amount = MIST_PER_SUI / 2 + (seed >> 16) % (3 * MIST_PER_SUI);

        match ((seed >> 56) % 10) {
            0 => {
                fixture.mint(pick, amount);
                fun_supply = fun_supply + amount;
                user_fun = user_fun + amount;
            },
            1 => {
                if (user_fun > 0) {
                    let burned = user_fun.min(amount);
                    fixture.redeem_fun(burned);
                    fun_supply = fun_supply - burned;
                    user_fun = user_fun - burned;
                };
            },
            2 => {
                let (shares, _) = fixture.mint_blast(pick, MIST_PER_SUI + amount);
                blast_supply = blast_supply + shares;
                user_blast = user_blast + shares;
            },
            3 => {
                if (user_blast > 0) {
                    let burned = user_blast.min(amount);
                    fixture.redeem_blast(burned);
                    blast_supply = blast_supply - burned;
                    user_blast = user_blast - burned;
                };
            },
            4 => {
                fixture.donate(amount);
            },
            5 => {
                fixture.advance_epoch_with_rewards((seed >> 20) % 200);
                fixture.sync();
            },
            6 => {
                if (next_departure < 5) {
                    fixture.depart(next_departure);
                    next_departure = next_departure + 1;
                    fixture.advance_epoch();
                    fixture.sync();
                };
            },
            7 => {
                fixture.advance_epoch_safe_mode();
                fixture.sync();
                safe_modes = safe_modes + 1;
            },
            8 => {
                if (!reused && next_departure < 5) {
                    fixture.rejoin_at_same_address(next_departure);
                    next_departure = next_departure + 1;
                    reused = true;
                    fixture.sync();
                };
            },
            _ => {
                if (fixture.pools().contains(&spare)) {
                    fixture.remove(spare);
                } else {
                    // Admission needs a current rate, which a safe-mode epoch lacks.
                    fixture.advance_epoch();
                    fixture.admit(spare);
                };
            },
        };

        fixture.next_tx!(USER, |f| {
            let custody = f.vault!().custody_for_testing();
            let (fun_custody, blast_custody, _, snapshot_fun, snapshot_blast) =
                custody.vault_custody_fields();
            assert_eq!(snapshot_fun, fun_supply);
            assert_eq!(snapshot_blast, blast_supply);
            assert_eq!(fun_custody.pool_assets(), f.vault!().fun_assets_for_testing());
            assert_eq!(blast_custody.pool_assets(), f.vault!().blast_assets_for_testing());
            assert!(fun_custody.pool_assets() >= fun_supply);
            assert!(blast_custody.pool_assets() >= blast_supply);
            assert_eq!(custody.vault_custody_pools().length(), f.vault!().pools_for_testing().length());
            assert_eq!(
                f.vault!().validators_for_testing().members().into_keys(),
                f.vault!().pools_for_testing(),
            );
        });
    });

    assert!(next_departure > 1);
    assert!(safe_modes > 0);
    assert!(reused);

    fixture.end();
}

// Events

#[test]
fun a_mint_records_its_pick_and_the_delegated_amount() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();

    fixture.next_tx!(USER, |f| {
        let fun_coin = f.vault!().mint_fun_sui(
            &f.version,
            f.system!(),
            pools[1],
            coin::mint_for_testing(3 * MIST_PER_SUI, f.ctx!()),
            f.ctx!(),
        );
        transfer::public_transfer(fun_coin, USER);
    });

    let minted = events::collect_one<events::FunSuiMinted>(0);
    let (pool_id, sui_in, delegated, custody) = minted.fun_sui_minted_fields();
    assert_eq!(pool_id, pools[1]);
    assert_eq!(sui_in, 3 * MIST_PER_SUI);
    assert_eq!(delegated, 3 * MIST_PER_SUI);
    assert_position(&custody.fun_position(pools[1]), 3 * MIST_PER_SUI, 0, 0);

    fixture.end();
}

#[test]
fun a_pool_unwound_event_records_the_pool_and_the_custody_after_it() {
    let mut fixture = start(2, 2);
    let pools = fixture.pools();
    fixture.advance_epoch();
    fixture.sync();

    fixture.remove(pools[0]);
    let unwound = events::collect_one<events::PoolUnwound>(0);
    let (pool_id, custody) = unwound.pool_unwound_fields();
    assert_eq!(pool_id, pools[0]);
    assert_eq!(custody.vault_custody_pools().length(), 1);
    let (_, blast_liquid) = custody.vault_custody_liquid();
    assert_eq!(blast_liquid, BOOTSTRAP);

    fixture.end();
}

#[test]
fun event_replay_reconciles_per_pool_custody_and_both_supplies() {
    let mut fixture = start(3, 3);
    let pools = fixture.pools();
    let mut fun_supply = 0;
    let mut blast_supply = BOOTSTRAP;

    fixture.mint(pools[0], 4 * MIST_PER_SUI);
    let minted = events::collect_one<events::FunSuiMinted>(0);
    let (_, sui_in, _, _) = minted.fun_sui_minted_fields();
    fun_supply = fun_supply + sui_in;

    fixture.request(pools[1], 6 * MIST_PER_SUI);
    fixture.advance_epoch();
    fixture.claim(0);
    let claimed = events::collect_one<events::BlastSuiDepositClaimed>(0);
    let (_, _, _, _, _, blast_out, _) = claimed.blast_sui_deposit_claimed_fields();
    blast_supply = blast_supply + blast_out;

    fixture.redeem_fun(MIST_PER_SUI);
    let redeemed = events::collect_one<events::FunSuiRedeemed>(0);
    let (fun_in, _) = redeemed.fun_sui_redeemed_fields();
    fun_supply = fun_supply - fun_in;

    fixture.redeem_blast(2 * MIST_PER_SUI);
    let redeemed = events::collect_one<events::BlastSuiRedeemed>(0);
    let (blast_in, _, _, _, last_snapshot) = redeemed.blast_sui_redeemed_fields();
    blast_supply = blast_supply - blast_in;

    let (fun_custody, blast_custody, _, snapshot_fun, snapshot_blast) =
        last_snapshot.vault_custody_fields();
    assert_eq!(snapshot_fun, fun_supply);
    assert_eq!(snapshot_blast, blast_supply);
    fixture.next_tx!(USER, |f| {
        assert_eq!(last_snapshot, f.vault!().custody_for_testing());
        assert_eq!(f.vault!().fun_supply_for_testing(), fun_supply);
        assert_eq!(f.vault!().blast_supply_for_testing(), blast_supply);
        assert_eq!(f.vault!().fun_assets_for_testing(), fun_custody.pool_assets());
        assert_eq!(f.vault!().blast_assets_for_testing(), blast_custody.pool_assets());
    });

    fixture.end();
}

#[test]
fun snapshots_replay_admission_departure_and_removal() {
    let mut fixture = start(4, 2);
    let pools = fixture.pools();
    let third = fixture.pool_of(2);
    fixture.mint(pools[1], 3 * MIST_PER_SUI);

    fixture.admit(third);
    let admitted = events::collect_one<events::VaultSynced>(0).vault_synced_custody();
    assert_eq!(admitted.vault_custody_pools().length(), 3);
    assert_eq!(admitted, fixture.snapshot());

    fixture.depart(1);
    fixture.advance_epoch();
    let synced = fixture.sync();
    let unwound = events::collect_one<events::PoolUnwound>(0);
    let (departed, after_departure) = unwound.pool_unwound_fields();
    assert_eq!(departed, pools[1]);
    assert_eq!(after_departure.vault_custody_pools().length(), 2);
    assert_eq!(synced, fixture.snapshot());

    let removed = fixture.remove(third);
    let (removed_pool, after_removal) =
        events::collect_one<events::PoolUnwound>(0).pool_unwound_fields();
    assert_eq!(removed_pool, third);
    assert_eq!(after_removal.vault_custody_pools().length(), 1);
    assert_eq!(removed, fixture.snapshot());

    fixture.end();
}

// Upgrade Seam

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun stale_package_version_rejects_validator_scheduling_before_the_cap_check() {
    let max = constants::max_validators!();
    let mut fixture = start(max + 1, max);
    let extra = fixture.pool_of(max);

    fixture.next_tx!(OWNER, |f| {
        let clock = clock::create_for_testing(f.ctx!());
        f.version.set_version_for_testing(2);
        f.vault!().schedule_validator(&f.version, &validator_admin(), extra, &clock);
        clock.destroy_for_testing();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun stale_package_version_rejects_validator_application() {
    let mut fixture = start(2, 1);
    let pool = fixture.pool_of(1);

    fixture.next_tx!(USER, |f| {
        let clock = clock::create_for_testing(f.ctx!());
        f.version.set_version_for_testing(2);
        f.vault!().apply_validator(&f.version, f.system!(), pool, &clock, f.ctx!());
        clock.destroy_for_testing();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun stale_package_version_rejects_validator_cancellation() {
    let mut fixture = start(2, 1);
    let pool = fixture.pool_of(1);

    fixture.next_tx!(OWNER, |f| {
        f.version.set_version_for_testing(2);
        f.vault!().cancel_validator(&f.version, &cancel_admin(), pool);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun stale_package_version_rejects_validator_removal_before_its_membership_check() {
    let mut fixture = start(2, 1);
    let unlisted = fixture.pool_of(1);

    fixture.next_tx!(OWNER, |f| {
        f.version.set_version_for_testing(2);
        f.vault!().remove_validator(
            &f.version,
            &validator_admin(),
            f.system!(),
            unlisted,
            f.ctx!(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun stale_package_version_rejects_validator_delay_scheduling() {
    let mut fixture = start(1, 1);

    fixture.next_tx!(OWNER, |f| {
        let clock = clock::create_for_testing(f.ctx!());
        f.version.set_version_for_testing(2);
        f.vault!().schedule_validator_delay(&f.version, &validator_admin(), DELAY_MS, &clock);
        clock.destroy_for_testing();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun stale_package_version_rejects_validator_delay_application() {
    let mut fixture = start(1, 1);

    fixture.next_tx!(USER, |f| {
        let clock = clock::create_for_testing(f.ctx!());
        f.version.set_version_for_testing(2);
        f.vault!().apply_validator_delay(&f.version, &clock);
        clock.destroy_for_testing();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun stale_package_version_rejects_validator_delay_cancellation() {
    let mut fixture = start(1, 1);

    fixture.next_tx!(OWNER, |f| {
        f.version.set_version_for_testing(2);
        f.vault!().cancel_validator_delay(&f.version, &cancel_admin());
    });

    fixture.end();
}

// === Test Helpers ===

/// Runs `$fn` as one transaction with the shared vault and system state borrowed.
macro fun next_tx($fixture: &mut Fixture, $sender: address, $fn: |&mut Fixture|) {
    let fixture = $fixture;

    fixture.runner.set_sender($sender);
    fixture.system_state.fill(fixture.runner.scenario_mut().take_shared<SuiSystemState>());
    fixture.vault.fill(fixture.runner.scenario_mut().take_shared<Vault>());
    $fn(fixture);
    test_scenario::return_shared(fixture.vault.extract());
    test_scenario::return_shared(fixture.system_state.extract());
}

macro fun ctx($fixture: &mut Fixture): &mut TxContext {
    let fixture = $fixture;

    fixture.runner.ctx()
}

macro fun vault($fixture: &mut Fixture): &mut Vault {
    let fixture = $fixture;

    fixture.vault.borrow_mut()
}

macro fun system($fixture: &mut Fixture): &mut SuiSystemState {
    let fixture = $fixture;

    fixture.system_state.borrow_mut()
}

/// `validators` genesis validators with the first `members` listed, in an epoch with rates.
fun start(validators: u64, members: u64): Fixture {
    let builders = vector::tabulate!(validators, |_| {
        validator_builder::new().initial_stake(100)
    });

    start_from(builders, members)
}

/// Every validator listed, each charging its given commission in basis points.
fun start_with_commission(commissions: vector<u64>): Fixture {
    let members = commissions.length();
    let builders = commissions.map!(|commission| {
        validator_builder::new().initial_stake(100).commission_rate(commission)
    });

    start_from(builders, members)
}

/// `count` listed pools, each holding five SUI of activated fun stake.
fun start_with_active_fun(count: u64): Fixture {
    let mut fixture = start(count, count);
    let pools = fixture.pools();

    pools.do!(|pool_id| {
        fixture.mint(pool_id, 5 * MIST_PER_SUI);
    });
    fixture.advance_epoch();
    fixture.sync();

    fixture
}

fun start_from(builders: vector<ValidatorBuilder>, members: u64): Fixture {
    let mut runner = test_runner::new().validators(builders).build();
    runner.scenario_mut().create_system_objects();
    runner.advance_runner_epoch();
    let version = blast_sui_package::version_for_testing(runner.ctx());
    let first = runner.genesis_validator_addresses()[0];

    runner.set_sender(OWNER);
    let mut system_state = runner.scenario_mut().take_shared<SuiSystemState>();
    let pool_id = system_state.validator_staking_pool_id(first);
    let (fun_cap, fun_metadata_cap) = fun_sui::new_for_testing(runner.ctx());
    let (blast_cap, blast_metadata_cap) = blast_coin::new_for_testing(runner.ctx());
    let mut display_registry = runner.scenario_mut().take_shared<DisplayRegistry>();
    let clock = clock::create_for_testing(runner.ctx());
    let seed = coin::mint_for_testing(
        BOOTSTRAP + constants::fun_rounding_reserve_mist!(),
        runner.ctx(),
    );
    vault::create(
        &version,
        &mut system_state,
        &mut display_registry,
        fun_cap,
        blast_cap,
        fun_metadata_cap,
        blast_metadata_cap,
        seed,
        pool_id,
        &clock,
        runner.ctx(),
    );
    clock.destroy_for_testing();
    test_scenario::return_shared(display_registry);
    test_scenario::return_shared(system_state);
    runner.set_sender(OWNER);

    let mut fixture = Fixture {
        runner,
        version,
        vault: option::none(),
        system_state: option::none(),
    };
    (members - 1).do!(|index| {
        let pool_id = fixture.pool_of(index + 1);
        fixture.admit(pool_id);
    });

    fixture
}

fun end(self: Fixture) {
    let Fixture { runner, version, vault, system_state } = self;

    destroy(version);
    vault.destroy_none();
    system_state.destroy_none();
    runner.finish();
}

/// The listed pools, in list order.
fun pools(self: &mut Fixture): vector<ID> {
    let pools;
    self.next_tx!(USER, |f| pools = f.vault!().pools_for_testing());
    pools
}

/// The current pool of the genesis validator at `index`.
fun pool_of(self: &mut Fixture, index: u64): ID {
    let pool_id;
    self.next_tx!(USER, |f| {
        let validator = f.runner.genesis_validator_addresses()[index];
        pool_id = f.system!().validator_staking_pool_id(validator);
    });
    pool_id
}

fun snapshot(self: &mut Fixture): events::VaultCustody {
    let custody;
    self.next_tx!(USER, |f| custody = f.vault!().custody_for_testing());
    custody
}

/// Schedules `pool_id` at time zero; a zero applied delay makes it ready at once.
fun schedule(self: &mut Fixture, pool_id: ID) {
    self.next_tx!(OWNER, |f| {
        let clock = clock::create_for_testing(f.ctx!());
        f.vault!().schedule_validator(&f.version, &validator_admin(), pool_id, &clock);
        clock.destroy_for_testing();
    });
}

fun apply(self: &mut Fixture, pool_id: ID) {
    self.apply_at(pool_id, 0);
}

/// USER applies the admission at `now_ms`: application is permissionless.
fun apply_at(self: &mut Fixture, pool_id: ID, now_ms: u64) {
    self.next_tx!(USER, |f| {
        let mut clock = clock::create_for_testing(f.ctx!());
        clock.set_for_testing(now_ms);
        f.vault!().apply_validator(&f.version, f.system!(), pool_id, &clock, f.ctx!());
        clock.destroy_for_testing();
    });
}

fun admit(self: &mut Fixture, pool_id: ID) {
    self.schedule(pool_id);
    self.apply(pool_id);
}

/// `ValidatorAdmin` removes `pool_id` and returns the final snapshot.
fun remove(self: &mut Fixture, pool_id: ID): events::VaultCustody {
    self.next_tx!(OWNER, |f| {
        f.vault!().remove_validator(
            &f.version,
            &validator_admin(),
            f.system!(),
            pool_id,
            f.ctx!(),
        );
    });

    events::collect_one<events::VaultSynced>(0).vault_synced_custody()
}

/// The genesis validator at `index` requests removal, effective at the next epoch change.
fun depart(self: &mut Fixture, index: u64) {
    let validator = self.runner.genesis_validator_addresses()[index];
    self.runner.set_sender(validator);
    self.runner.remove_validator();
}

/// Removes the genesis validator at `index`, then returns its address with a fresh pool.
fun rejoin_at_same_address(self: &mut Fixture, index: u64) {
    let validator = self.runner.genesis_validator_addresses()[index];
    self.depart(index);
    self.advance_epoch();

    let replacement = validator_builder::preset(0).sui_address(validator).build(self.runner.ctx());
    self.runner.add_validator_candidate(replacement);
    self.runner.set_sender(USER).stake_with(validator, 100);
    self.runner.set_sender(validator).add_validator();
    self.advance_epoch();
}

fun advance_epoch(self: &mut Fixture) {
    self.runner.advance_runner_epoch();
}

fun advance_epoch_with_rewards(self: &mut Fixture, computation_charge: u64) {
    let options = self.runner.advance_epoch_opts().computation_charge(computation_charge);
    self.runner.advance_epoch(option::some(options)).destroy_for_testing();
}

fun advance_epoch_safe_mode(self: &mut Fixture) {
    self.runner.advance_epoch_safe_mode();
}

fun set_validator_delay(self: &mut Fixture, delay_ms: u64) {
    self.next_tx!(OWNER, |f| {
        let clock = clock::create_for_testing(f.ctx!());
        f.vault!().schedule_validator_delay(&f.version, &validator_admin(), delay_ms, &clock);
        f.vault!().apply_validator_delay(&f.version, &clock);
        clock.destroy_for_testing();
    });
}

fun unpause(self: &mut Fixture) {
    self.next_tx!(OWNER, |f| {
        let package_admin = blast_sui_package::package_admin_for_testing(f.ctx!());
        let pause_admin = blast_acl::witness_for_testing<PauseAdmin<BLAST_SUI_PACKAGE>>();
        let admin = blast_acl::witness_for_testing<UnpauseAdmin<BLAST_SUI_PACKAGE>>();
        let bit = constants::fun_mint_pause_bit!();
        package_admin::pause(&mut f.version, &pause_admin, bit);
        f.vault!().unpause(&mut f.version, &admin, &package_admin, bit);
        destroy(package_admin);
    });
}

fun validator_admin(): AdminWitness<ValidatorAdmin> {
    blast_acl::witness_for_testing()
}

fun cancel_admin(): AdminWitness<CancelAdmin> {
    blast_acl::witness_for_testing()
}

/// USER mints funSUI picking `pool_id`; returns `(delegated, custody)`.
fun mint(self: &mut Fixture, pool_id: ID, amount: u64): (u64, events::VaultCustody) {
    self.next_tx!(USER, |f| {
        let fun_coin = f.vault!().mint_fun_sui(
            &f.version,
            f.system!(),
            pool_id,
            coin::mint_for_testing(amount, f.ctx!()),
            f.ctx!(),
        );
        transfer::public_transfer(fun_coin, USER);
    });

    let minted = events::collect_one<events::FunSuiMinted>(0);
    let (_, _, delegated, custody) = minted.fun_sui_minted_fields();
    (delegated, custody)
}

/// USER delegates to `pool_id` and keeps the receipt.
fun request(self: &mut Fixture, pool_id: ID, amount: u64) {
    self.next_tx!(USER, |f| {
        let receipt = f.vault!().request_blast_sui(
            &f.version,
            f.system!(),
            pool_id,
            coin::mint_for_testing(amount, f.ctx!()),
            f.ctx!(),
        );
        receipt.keep(f.ctx!());
    });
}

/// USER claims its most recent receipt; returns `(shares, custody)`.
fun claim(self: &mut Fixture, min_blast_out: u64): (u64, events::VaultCustody) {
    let shares;
    self.next_tx!(USER, |f| {
        let receipt = f.runner.scenario_mut().take_from_sender<BlastSuiDepositReceipt>();
        let blast_coin = f.vault!().claim_blast_sui(
            &f.version,
            f.system!(),
            receipt,
            min_blast_out,
            f.ctx!(),
        );
        shares = blast_coin.value();
        transfer::public_transfer(blast_coin, USER);
    });

    let claimed = events::collect_one<events::BlastSuiDepositClaimed>(0);
    let (_, _, _, _, _, _, custody) = claimed.blast_sui_deposit_claimed_fields();
    (shares, custody)
}

fun mint_blast(self: &mut Fixture, pool_id: ID, amount: u64): (u64, events::VaultCustody) {
    self.request(pool_id, amount);
    self.advance_epoch();
    self.claim(0)
}

fun donate(self: &mut Fixture, amount: u64): events::VaultCustody {
    self.next_tx!(USER, |f| {
        f.vault!().donate_sui(
            &f.version,
            f.system!(),
            coin::mint_for_testing(amount, f.ctx!()),
            f.ctx!(),
        );
    });

    let donated = events::collect_one<events::BlastSuiDonated>(0);
    let (_, custody) = donated.blast_sui_donated_fields();
    custody
}

/// USER redeems `amount` funSUI across its received coins, merged first.
fun redeem_fun(self: &mut Fixture, amount: u64): events::VaultCustody {
    self.next_tx!(USER, |f| {
        let mut fun_coin = f.merged_coin<FUN_SUI>();
        let redeem_coin = fun_coin.split(amount, f.ctx!());
        let sui_out = f.vault!().redeem_fun_sui(&f.version, f.system!(), redeem_coin, f.ctx!());

        assert_eq!(sui_out.value(), amount);
        return_or_destroy_zero(fun_coin, USER);
        transfer::public_transfer(sui_out, USER);
    });

    let redeemed = events::collect_one<events::FunSuiRedeemed>(0);
    let (_, custody) = redeemed.fun_sui_redeemed_fields();
    custody
}

/// USER redeems `shares` blastSUI across its received coins, merged first.
fun redeem_blast(self: &mut Fixture, shares: u64): (u64, events::VaultCustody) {
    let net;
    self.next_tx!(USER, |f| {
        let mut blast_coin = f.merged_coin<BLAST_SUI>();
        let redeem_coin = blast_coin.split(shares, f.ctx!());
        let sui_out = f.vault!().redeem_blast_sui(
            &f.version,
            f.system!(),
            redeem_coin,
            0,
            f.ctx!(),
        );
        net = sui_out.value();

        return_or_destroy_zero(blast_coin, USER);
        transfer::public_transfer(sui_out, USER);
    });

    let redeemed = events::collect_one<events::BlastSuiRedeemed>(0);
    let (_, _, _, _, custody) = redeemed.blast_sui_redeemed_fields();
    (net, custody)
}

fun sync(self: &mut Fixture): events::VaultCustody {
    self.next_tx!(USER, |f| f.vault!().sync(&f.version, f.system!(), f.ctx!()));

    events::collect_one<events::VaultSynced>(0).vault_synced_custody()
}

/// Takes every coin of `CoinType` the sender owns and merges them into one.
fun merged_coin<CoinType>(self: &mut Fixture): Coin<CoinType> {
    let scenario = self.runner.scenario_mut();
    let mut merged = scenario.take_from_sender<Coin<CoinType>>();
    while (scenario.has_most_recent_for_sender<Coin<CoinType>>()) {
        merged.join(scenario.take_from_sender<Coin<CoinType>>());
    };

    merged
}

fun advance_runner_epoch(runner: &mut TestRunner) {
    runner.advance_epoch(option::none()).destroy_for_testing();
}

/// Deterministic 64-bit linear congruential step for the seeded sequence test.
fun next_random(seed: u64): u64 {
    (((seed as u128) * 6364136223846793005 + 1442695040888963407) % 18446744073709551616) as u64
}

fun return_or_destroy_zero<T>(coin: Coin<T>, recipient: address) {
    if (coin.value() == 0) {
        coin.destroy_zero();
    } else {
        transfer::public_transfer(coin, recipient);
    };
}

/// The snapshot of `pool_id` in `custody`.
fun snapshot_of(custody: &events::VaultCustody, pool_id: ID): events::PoolSnapshot {
    let pools = custody.vault_custody_pools();
    let index = pools.find_index!(|snapshot| {
        let (id, _, _, _) = snapshot.pool_snapshot_fields();
        id == pool_id
    });

    pools[index.destroy_some()]
}

fun fun_position(custody: &events::VaultCustody, pool_id: ID): events::PositionCustody {
    let (_, _, fun_position, _) = custody.snapshot_of(pool_id).pool_snapshot_fields();

    fun_position
}

fun blast_position(custody: &events::VaultCustody, pool_id: ID): events::PositionCustody {
    let (_, _, _, blast_position) = custody.snapshot_of(pool_id).pool_snapshot_fields();

    blast_position
}

fun rate_of(custody: &events::VaultCustody, pool_id: ID): events::ExchangeRate {
    let (_, rate, _, _) = custody.snapshot_of(pool_id).pool_snapshot_fields();

    rate
}

fun assert_position(
    position: &events::PositionCustody,
    pending: u64,
    tokens: u64,
    active_sui: u64,
) {
    let (actual_pending, actual_tokens, actual_active_sui) = position.position_custody_fields();
    assert_eq!(actual_pending, pending);
    assert_eq!(actual_tokens, tokens);
    assert_eq!(actual_active_sui, active_sui);
}

// === Imports ===

use blast_admin::{
    blast_acl::{Self, AdminWitness},
    package_admin::{Self, PauseAdmin, UnpauseAdmin},
    package_version::PackageVersion,
};

use blast_sui::{
    blast_sui::{Self as blast_coin, BLAST_SUI},
    blast_sui_domain::{CancelAdmin, ValidatorAdmin},
    blast_sui_package::{Self, BLAST_SUI_PACKAGE},
    constants,
    deposit_receipt::BlastSuiDepositReceipt,
    errors,
    events,
    fun_sui::{Self, FUN_SUI},
    math,
    vault::{Self, Vault},
};

use std::unit_test::{assert_eq, destroy};

use sui::{clock, coin::{Self, Coin}, display_registry::DisplayRegistry, test_scenario};

use sui_system::{
    sui_system::SuiSystemState,
    test_runner::{Self, TestRunner},
    validator_builder::{Self, ValidatorBuilder},
};

use fun advance_runner_epoch as TestRunner.advance_runner_epoch;

use fun snapshot_of as events::VaultCustody.snapshot_of;

use fun fun_position as events::VaultCustody.fun_position;

use fun blast_position as events::VaultCustody.blast_position;

use fun rate_of as events::VaultCustody.rate_of;
