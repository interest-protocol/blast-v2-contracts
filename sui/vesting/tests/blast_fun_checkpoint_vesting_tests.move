// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_vesting::blast_fun_checkpoint_vesting_tests;

// === Constants ===

const FUNDER: address = @0xF00D;

const BENEFICIARY: address = @0xB0B;

const REFUND_RECIPIENT: address = @0xCAFE;

const CALLER: address = @0xC11;

const CANCELER: address = @0xCA11;

const TOTAL_AMOUNT: u64 = 1_000;

const FIRST_MS: u64 = 100;

const SECOND_MS: u64 = 250;

const FINAL_MS: u64 = 700;

const FIRST_AMOUNT: u64 = 100;

const SECOND_AMOUNT: u64 = 400;

// === Test-Only Types ===

public struct TEST_COIN() has drop;

/// Single-transaction construction and focused failure-path fixture.
public struct UnitFixture {
    scenario: Scenario,
    clock: Clock,
    schedule: Option<Schedule>,
    vesting: Option<Vesting<TEST_COIN>>,
    cancel_cap: Option<CancelCap<TEST_COIN>>,
}

/// Shared irrevocable lifecycle with beneficiary payout inspection.
public struct ClaimFixture {
    scenario: Scenario,
    clock: Clock,
    vesting: Option<Vesting<TEST_COIN>>,
    created: VestingCreated,
    vesting_id: ID,
}

/// Shared cancellable lifecycle with a transferred cancellation capability.
public struct CancelFixture {
    scenario: Scenario,
    clock: Clock,
    vesting: Option<Vesting<TEST_COIN>>,
    cancel_cap: Option<CancelCap<TEST_COIN>>,
    created: VestingCreated,
    vesting_id: ID,
    cancel_cap_id: ID,
}

// === Tests ===

#[test]
fun irrevocable_lifecycle_releases_irregular_amounts_and_replays_events() {
    let mut fixture = start_claim();

    fixture.next_tx!(CALLER, |f| {
        f.assert_created();
        let vesting_id = f.vesting_id();
        let coin_type = std::type_name::with_original_ids<TEST_COIN>();

        assert_eq!(f.vested_at(FIRST_MS - 1), 0);
        assert_eq!(f.vested_at(FIRST_MS), FIRST_AMOUNT);
        assert_eq!(f.vested_at(SECOND_MS - 1), FIRST_AMOUNT);
        assert_eq!(f.vested_at(SECOND_MS), SECOND_AMOUNT);
        assert_eq!(f.vested_at(FINAL_MS - 1), SECOND_AMOUNT);
        assert_eq!(f.vested_at(FINAL_MS), TOTAL_AMOUNT);
        assert_eq!(f.vested_at(FINAL_MS + 1), TOTAL_AMOUNT);

        f.claim_at(FIRST_MS);

        let claimed = collect_one<VestingClaimed>();
        let (
            emitted_id,
            emitted_coin_type,
            caller,
            emitted_beneficiary,
            amount,
            released_total,
            remaining_balance,
        ) = claimed.vesting_claimed_fields();
        assert_eq!(emitted_id, vesting_id);
        assert_eq!(emitted_coin_type, coin_type);
        assert_eq!(caller, CALLER);
        assert_eq!(emitted_beneficiary, BENEFICIARY);
        assert_eq!(amount, FIRST_AMOUNT);
        assert_eq!(released_total, FIRST_AMOUNT);
        assert_eq!(remaining_balance, TOTAL_AMOUNT - FIRST_AMOUNT);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_beneficiary_payout(), FIRST_AMOUNT);
    });

    fixture.next_tx!(CALLER, |f| {
        assert_eq!(f.releasable_at(SECOND_MS - 1), 0);
        f.claim_at(SECOND_MS);

        let claimed = collect_one<VestingClaimed>();
        let (_, _, _, _, amount, released_total, remaining_balance) =
            claimed.vesting_claimed_fields();
        assert_eq!(amount, SECOND_AMOUNT - FIRST_AMOUNT);
        assert_eq!(released_total, SECOND_AMOUNT);
        assert_eq!(remaining_balance, TOTAL_AMOUNT - SECOND_AMOUNT);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_beneficiary_payout(), SECOND_AMOUNT - FIRST_AMOUNT);
    });

    fixture.next_tx!(CALLER, |f| {
        f.claim_at(FINAL_MS);
        f.close_at(FINAL_MS);

        let claimed = collect_one<VestingClaimed>();
        let (_, _, _, _, amount, released_total, remaining_balance) =
            claimed.vesting_claimed_fields();
        let closed = collect_one<VestingClosed>();
        let (closed_id, _, caller, closed_released_total) =
            closed.vesting_closed_fields();

        assert_eq!(amount, TOTAL_AMOUNT - SECOND_AMOUNT);
        assert_eq!(released_total, TOTAL_AMOUNT);
        assert_eq!(remaining_balance, 0);
        assert_eq!(closed_id, f.vesting_id());
        assert_eq!(caller, CALLER);
        assert_eq!(closed_released_total, TOTAL_AMOUNT);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_beneficiary_payout(), TOTAL_AMOUNT - SECOND_AMOUNT);
    });

    fixture.end();
}

#[test]
fun cancelable_schedule_preserves_prior_and_unclaimed_vested_value() {
    let mut fixture = start_cancel();

    fixture.next_tx!(CALLER, |f| {
        let (
            vesting_id,
            _,
            funder,
            beneficiary,
            refund_recipient,
            cancel_cap_id,
            total_amount,
            checkpoint_count,
        ) = f.created.vesting_created_fields();

        assert_eq!(vesting_id, f.vesting_id());
        assert_eq!(f.cancel_cap_vesting_id(), vesting_id);
        assert_eq!(funder, FUNDER);
        assert_eq!(beneficiary, BENEFICIARY);
        assert_eq!(refund_recipient.destroy_some(), REFUND_RECIPIENT);
        assert_eq!(cancel_cap_id.destroy_some(), f.cancel_cap_id());
        assert_eq!(total_amount, TOTAL_AMOUNT);
        assert_eq!(checkpoint_count, 3);

        f.claim_at(FIRST_MS);

        let claimed = collect_one<VestingClaimed>();
        let (_, _, caller, _, amount, released_total, remaining_balance) =
            claimed.vesting_claimed_fields();
        assert_eq!(caller, CALLER);
        assert_eq!(amount, FIRST_AMOUNT);
        assert_eq!(released_total, FIRST_AMOUNT);
        assert_eq!(remaining_balance, TOTAL_AMOUNT - FIRST_AMOUNT);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_beneficiary_payout(), FIRST_AMOUNT);
    });

    fixture.next_tx!(CANCELER, |f| {
        f.cancel_at(SECOND_MS);

        let canceled = collect_one<VestingCanceled>();
        let (
            vesting_id,
            coin_type,
            caller,
            beneficiary,
            refund_recipient,
            beneficiary_amount,
            refund_amount,
            released_total,
        ) = canceled.vesting_canceled_fields();

        assert_eq!(vesting_id, f.vesting_id());
        assert_eq!(coin_type, std::type_name::with_original_ids<TEST_COIN>());
        assert_eq!(caller, CANCELER);
        assert_eq!(beneficiary, BENEFICIARY);
        assert_eq!(refund_recipient, REFUND_RECIPIENT);
        assert_eq!(beneficiary_amount, SECOND_AMOUNT - FIRST_AMOUNT);
        assert_eq!(refund_amount, TOTAL_AMOUNT - SECOND_AMOUNT);
        assert_eq!(released_total, SECOND_AMOUNT);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_beneficiary_payout(), SECOND_AMOUNT - FIRST_AMOUNT);
    });

    fixture.next_tx!(REFUND_RECIPIENT, |f| {
        assert_eq!(f.take_refund(), TOTAL_AMOUNT - SECOND_AMOUNT);
    });

    fixture.end();
}

#[test]
fun cancellation_before_first_checkpoint_returns_the_full_allocation() {
    let mut fixture = start_cancel();

    fixture.next_tx!(CANCELER, |f| {
        f.cancel_at(FIRST_MS - 1);

        let canceled = collect_one<VestingCanceled>();
        let (_, _, caller, beneficiary, refund_recipient, beneficiary_amount, refund_amount, released_total) =
            canceled.vesting_canceled_fields();
        assert_eq!(caller, CANCELER);
        assert_eq!(beneficiary, BENEFICIARY);
        assert_eq!(refund_recipient, REFUND_RECIPIENT);
        assert_eq!(beneficiary_amount, 0);
        assert_eq!(refund_amount, TOTAL_AMOUNT);
        assert_eq!(released_total, 0);
    });

    fixture.next_tx!(REFUND_RECIPIENT, |f| {
        assert_eq!(f.take_refund(), TOTAL_AMOUNT);
    });

    fixture.end();
}

#[test]
fun cancellation_after_final_checkpoint_has_no_refund() {
    let mut fixture = start_cancel();

    fixture.next_tx!(CANCELER, |f| {
        f.cancel_at(FINAL_MS);

        let canceled = collect_one<VestingCanceled>();
        let (_, _, caller, beneficiary, refund_recipient, beneficiary_amount, refund_amount, released_total) =
            canceled.vesting_canceled_fields();
        assert_eq!(caller, CANCELER);
        assert_eq!(beneficiary, BENEFICIARY);
        assert_eq!(refund_recipient, REFUND_RECIPIENT);
        assert_eq!(beneficiary_amount, TOTAL_AMOUNT);
        assert_eq!(refund_amount, 0);
        assert_eq!(released_total, TOTAL_AMOUNT);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_beneficiary_payout(), TOTAL_AMOUNT);
    });

    fixture.end();
}

#[test]
fun one_checkpoint_schedule_is_supported() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 1);
    fixture.create_irrevocable(1, BENEFICIARY);

    assert_eq!(fixture.vesting().vested_at_for_testing(9), 0);
    assert_eq!(fixture.vesting().vested_at_for_testing(10), 1);

    fixture.end();
}

#[test]
fun maximum_checkpoint_count_searches_every_boundary() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint_range(256);
    fixture.create_irrevocable(256, BENEFICIARY);

    let mut timestamp_ms = 0;
    while (timestamp_ms < 256) {
        assert_eq!(
            fixture.vesting().vested_at_for_testing(timestamp_ms),
            timestamp_ms + 1,
        );
        timestamp_ms = timestamp_ms + 1;
    };

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::EInvalidBeneficiary,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun constructor_rejects_zero_beneficiary_before_other_invalid_inputs() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(0, @0x0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::EInvalidRefundRecipient,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun cancelable_constructor_rejects_zero_refund_before_zero_allocation() {
    let mut fixture = start_unit(0);
    fixture.create_cancelable(0, BENEFICIARY, @0x0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::EZeroAllocation,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun constructor_rejects_zero_allocation_before_empty_checkpoints() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(0, BENEFICIARY);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ENoCheckpoints,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun constructor_rejects_empty_checkpoints() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(1, BENEFICIARY);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ETooManyCheckpoints,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun schedule_rejects_more_than_256_checkpoints() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint_range(257);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ECheckpointInPast,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun constructor_rejects_first_checkpoint_before_current_clock_time() {
    let mut fixture = start_unit(100);
    fixture.add_checkpoint(99, 1);
    fixture.create_irrevocable(1, BENEFICIARY);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ECheckpointTimesNotIncreasing,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun schedule_rejects_checkpoint_times_that_do_not_increase() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 1);
    fixture.add_checkpoint(10, 2);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ECheckpointAmountsNotIncreasing,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun schedule_rejects_zero_first_checkpoint_amount() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ECheckpointAmountsNotIncreasing,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun schedule_rejects_checkpoint_amounts_that_do_not_increase() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 1);
    fixture.add_checkpoint(20, 1);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::EFinalAmountMismatch,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun constructor_rejects_final_amount_different_from_funding() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 1);
    fixture.create_irrevocable(2, BENEFICIARY);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ENothingClaimable,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun claim_rejects_zero_release_before_first_checkpoint() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(FIRST_MS, FIRST_AMOUNT);
    fixture.add_checkpoint(SECOND_MS, SECOND_AMOUNT);
    fixture.add_checkpoint(FINAL_MS, TOTAL_AMOUNT);
    fixture.create_irrevocable(TOTAL_AMOUNT, BENEFICIARY);
    fixture.set_clock(FIRST_MS - 1);

    fixture.claim();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::EInvalidCancelCap,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun cancellation_rejects_a_cap_for_another_schedule() {
    let mut fixture = start_unit(0);
    fixture.cancel_with_mismatched_cap();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::EScheduleNotEnded,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun close_rejects_a_schedule_before_its_final_checkpoint() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 1);
    fixture.create_irrevocable(1, BENEFICIARY);

    fixture.close_irrevocable();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::EScheduleNotEmpty,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun close_rejects_unclaimed_custody_after_the_final_checkpoint() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 1);
    fixture.create_irrevocable(1, BENEFICIARY);
    fixture.set_clock(10);

    fixture.close_irrevocable();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_checkpoint_vesting::ECancelCapRequired,
    location = blast_fun_vesting::blast_fun_checkpoint_vesting,
)]
fun irrevocable_close_rejects_a_cancellable_schedule_before_time_checks() {
    let mut fixture = start_unit(0);
    fixture.add_checkpoint(10, 1);
    fixture.create_cancelable(1, BENEFICIARY, REFUND_RECIPIENT);

    fixture.close_irrevocable();

    fixture.end();
}

// === Test Helpers ===

macro fun claim_next_tx(
    $fixture: &mut ClaimFixture,
    $sender: address,
    $fn: |&mut ClaimFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun cancel_next_tx(
    $fixture: &mut CancelFixture,
    $sender: address,
    $fn: |&mut CancelFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun standard_schedule(): Schedule {
    let mut schedule = checkpoints::new_schedule();
    schedule.add(FIRST_MS, FIRST_AMOUNT);
    schedule.add(SECOND_MS, SECOND_AMOUNT);
    schedule.add(FINAL_MS, TOTAL_AMOUNT);
    schedule
}

fun one_checkpoint_schedule(
    timestamp_ms: u64,
    cumulative_amount: u64,
): Schedule {
    let mut schedule = checkpoints::new_schedule();
    schedule.add(timestamp_ms, cumulative_amount);
    schedule
}

fun add_checkpoint_range(self: &mut Schedule, length: u64) {
    let mut index = 0;
    while (index < length) {
        self.add(index, index + 1);
        index = index + 1;
    };
}

fun start_unit(timestamp_ms: u64): UnitFixture {
    let mut scenario = test_scenario::begin(FUNDER);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(timestamp_ms);
    let schedule = checkpoints::new_schedule();

    UnitFixture {
        scenario,
        clock,
        schedule: option::some(schedule),
        vesting: option::none(),
        cancel_cap: option::none(),
    }
}

fun unit_add_checkpoint(
    self: &mut UnitFixture,
    timestamp_ms: u64,
    cumulative_amount: u64,
) {
    self.schedule.borrow_mut().add(timestamp_ms, cumulative_amount);
}

fun unit_add_checkpoint_range(self: &mut UnitFixture, length: u64) {
    self.schedule.borrow_mut().add_checkpoint_range(length);
}

fun unit_create_irrevocable(
    self: &mut UnitFixture,
    amount: u64,
    beneficiary: address,
) {
    let funds = coin::mint_for_testing<TEST_COIN>(amount, self.scenario.ctx());
    let schedule = self.schedule.extract();
    let vesting = checkpoints::new_irrevocable(
        funds,
        beneficiary,
        schedule,
        &self.clock,
        self.scenario.ctx(),
    );
    self.vesting.fill(vesting);
}

fun unit_create_cancelable(
    self: &mut UnitFixture,
    amount: u64,
    beneficiary: address,
    refund_recipient: address,
) {
    let funds = coin::mint_for_testing<TEST_COIN>(amount, self.scenario.ctx());
    let schedule = self.schedule.extract();
    let (vesting, cancel_cap) = checkpoints::new_cancelable(
        funds,
        beneficiary,
        refund_recipient,
        schedule,
        &self.clock,
        self.scenario.ctx(),
    );
    self.vesting.fill(vesting);
    self.cancel_cap.fill(cancel_cap);
}

fun unit_set_clock(self: &mut UnitFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
}

fun unit_vesting(self: &UnitFixture): &Vesting<TEST_COIN> {
    self.vesting.borrow()
}

fun unit_claim(self: &mut UnitFixture) {
    self.vesting.borrow_mut().claim(&self.clock, self.scenario.ctx());
}

fun unit_cancel_with_mismatched_cap(self: &mut UnitFixture) {
    let first_funds = coin::mint_for_testing<TEST_COIN>(1, self.scenario.ctx());
    let second_funds = coin::mint_for_testing<TEST_COIN>(1, self.scenario.ctx());
    let first_schedule = one_checkpoint_schedule(1, 1);
    let second_schedule = one_checkpoint_schedule(1, 1);
    let (first, first_cap) = checkpoints::new_cancelable(
        first_funds,
        BENEFICIARY,
        REFUND_RECIPIENT,
        first_schedule,
        &self.clock,
        self.scenario.ctx(),
    );
    let (second, second_cap) = checkpoints::new_cancelable(
        second_funds,
        BENEFICIARY,
        REFUND_RECIPIENT,
        second_schedule,
        &self.clock,
        self.scenario.ctx(),
    );

    first.cancel(second_cap, &self.clock, self.scenario.ctx());

    destroy(first_cap);
    destroy(second);
}

fun unit_close_irrevocable(self: &mut UnitFixture) {
    self.vesting.extract().close_irrevocable(&self.clock, self.scenario.ctx());
}

fun unit_end(self: UnitFixture) {
    destroy(self);
}

fun start_claim(): ClaimFixture {
    let mut scenario = test_scenario::begin(FUNDER);
    let clock = clock::create_for_testing(scenario.ctx());
    let funds = coin::mint_for_testing<TEST_COIN>(TOTAL_AMOUNT, scenario.ctx());
    let schedule = standard_schedule();
    let vesting = checkpoints::new_irrevocable(
        funds,
        BENEFICIARY,
        schedule,
        &clock,
        scenario.ctx(),
    );
    let vesting_id = object::id(&vesting);
    let created = collect_one<VestingCreated>();

    vesting.share();
    scenario.next_tx(CALLER);
    let vesting = scenario.take_shared<Vesting<TEST_COIN>>();

    ClaimFixture {
        scenario,
        clock,
        vesting: option::some(vesting),
        created,
        vesting_id,
    }
}

fun start_cancel(): CancelFixture {
    let mut scenario = test_scenario::begin(FUNDER);
    let clock = clock::create_for_testing(scenario.ctx());
    let funds = coin::mint_for_testing<TEST_COIN>(TOTAL_AMOUNT, scenario.ctx());
    let schedule = standard_schedule();
    let (vesting, cancel_cap) = checkpoints::new_cancelable(
        funds,
        BENEFICIARY,
        REFUND_RECIPIENT,
        schedule,
        &clock,
        scenario.ctx(),
    );
    let vesting_id = object::id(&vesting);
    let cancel_cap_id = object::id(&cancel_cap);
    let created = collect_one<VestingCreated>();

    vesting.share();
    transfer::public_transfer(cancel_cap, CANCELER);
    scenario.next_tx(CANCELER);
    let vesting = scenario.take_shared<Vesting<TEST_COIN>>();
    let cancel_cap = scenario.take_from_sender<CancelCap<TEST_COIN>>();

    CancelFixture {
        scenario,
        clock,
        vesting: option::some(vesting),
        cancel_cap: option::some(cancel_cap),
        created,
        vesting_id,
        cancel_cap_id,
    }
}

fun collect_one<T: copy + drop>(): T {
    let mut events = event::events_by_type<T>();
    assert!(events.length() == 1);
    events.pop_back()
}

fun claim_fixture_assert_created(self: &ClaimFixture) {
    let (
        vesting_id,
        coin_type,
        funder,
        beneficiary,
        refund_recipient,
        cancel_cap_id,
        total_amount,
        checkpoint_count,
    ) = self.created.vesting_created_fields();

    assert_eq!(vesting_id, self.vesting_id);
    assert_eq!(coin_type, std::type_name::with_original_ids<TEST_COIN>());
    assert_eq!(funder, FUNDER);
    assert_eq!(beneficiary, BENEFICIARY);
    assert!(refund_recipient.is_none());
    assert!(cancel_cap_id.is_none());
    assert_eq!(total_amount, TOTAL_AMOUNT);
    assert_eq!(checkpoint_count, 3);
}

fun claim_fixture_vested_at(self: &ClaimFixture, timestamp_ms: u64): u64 {
    self.vesting.borrow().vested_at_for_testing(timestamp_ms)
}

fun claim_fixture_releasable_at(self: &ClaimFixture, timestamp_ms: u64): u64 {
    self.vesting.borrow().releasable_at_for_testing(timestamp_ms)
}

fun claim_fixture_claim_at(self: &mut ClaimFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
    self.vesting.borrow_mut().claim(&self.clock, self.scenario.ctx());
}

fun claim_fixture_close_at(self: &mut ClaimFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
    self.vesting.extract().close_irrevocable(&self.clock, self.scenario.ctx());
}

fun claim_fixture_vesting_id(self: &ClaimFixture): ID {
    self.vesting_id
}

fun claim_fixture_take_beneficiary_payout(self: &ClaimFixture): u64 {
    self.scenario.take_from_sender<Coin<TEST_COIN>>().burn_for_testing()
}

fun claim_end(self: ClaimFixture) {
    assert!(self.vesting.is_none());
    destroy(self);
}

fun cancel_fixture_claim_at(self: &mut CancelFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
    self.vesting.borrow_mut().claim(&self.clock, self.scenario.ctx());
}

fun cancel_fixture_cancel_at(self: &mut CancelFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
    self.vesting.extract().cancel(
        self.cancel_cap.extract(),
        &self.clock,
        self.scenario.ctx(),
    );
}

fun cancel_fixture_vesting_id(self: &CancelFixture): ID {
    self.vesting_id
}

fun cancel_fixture_cancel_cap_id(self: &CancelFixture): ID {
    self.cancel_cap_id
}

fun cancel_fixture_cancel_cap_vesting_id(self: &CancelFixture): ID {
    self.cancel_cap.borrow().vesting_id()
}

fun cancel_fixture_take_beneficiary_payout(self: &CancelFixture): u64 {
    self.scenario.take_from_sender<Coin<TEST_COIN>>().burn_for_testing()
}

fun cancel_fixture_take_refund(self: &CancelFixture): u64 {
    self.scenario.take_from_sender<Coin<TEST_COIN>>().burn_for_testing()
}

fun cancel_end(self: CancelFixture) {
    assert!(self.vesting.is_none());
    assert!(self.cancel_cap.is_none());
    destroy(self);
}

// === Imports ===

use blast_fun_vesting::blast_fun_checkpoint_vesting::{
    Self as checkpoints,
    CancelCap,
    Schedule,
    Vesting,
    VestingCanceled,
    VestingClaimed,
    VestingClosed,
    VestingCreated,
};

use std::unit_test::{assert_eq, destroy};

use sui::{clock::{Self, Clock}, coin::{Self, Coin}, event, test_scenario::{Self, Scenario}};

use fun cancel_end as CancelFixture.end;

use fun cancel_next_tx as CancelFixture.next_tx;

use fun claim_end as ClaimFixture.end;

use fun claim_next_tx as ClaimFixture.next_tx;

use fun cancel_fixture_cancel_at as CancelFixture.cancel_at;

use fun cancel_fixture_cancel_cap_id as CancelFixture.cancel_cap_id;

use fun cancel_fixture_cancel_cap_vesting_id as CancelFixture.cancel_cap_vesting_id;

use fun cancel_fixture_claim_at as CancelFixture.claim_at;

use fun cancel_fixture_take_beneficiary_payout as CancelFixture.take_beneficiary_payout;

use fun cancel_fixture_take_refund as CancelFixture.take_refund;

use fun cancel_fixture_vesting_id as CancelFixture.vesting_id;

use fun claim_fixture_assert_created as ClaimFixture.assert_created;

use fun claim_fixture_claim_at as ClaimFixture.claim_at;

use fun claim_fixture_close_at as ClaimFixture.close_at;

use fun claim_fixture_releasable_at as ClaimFixture.releasable_at;

use fun claim_fixture_take_beneficiary_payout as ClaimFixture.take_beneficiary_payout;

use fun claim_fixture_vested_at as ClaimFixture.vested_at;

use fun claim_fixture_vesting_id as ClaimFixture.vesting_id;

use fun add_checkpoint_range as Schedule.add_checkpoint_range;

use fun unit_cancel_with_mismatched_cap as UnitFixture.cancel_with_mismatched_cap;

use fun unit_add_checkpoint as UnitFixture.add_checkpoint;

use fun unit_add_checkpoint_range as UnitFixture.add_checkpoint_range;

use fun unit_claim as UnitFixture.claim;

use fun unit_close_irrevocable as UnitFixture.close_irrevocable;

use fun unit_create_cancelable as UnitFixture.create_cancelable;

use fun unit_create_irrevocable as UnitFixture.create_irrevocable;

use fun unit_end as UnitFixture.end;

use fun unit_set_clock as UnitFixture.set_clock;

use fun unit_vesting as UnitFixture.vesting;
