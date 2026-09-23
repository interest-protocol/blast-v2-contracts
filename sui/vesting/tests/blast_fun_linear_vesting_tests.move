// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_vesting::blast_fun_linear_vesting_tests;

// === Constants ===

const FUNDER: address = @0xF00D;

const BENEFICIARY: address = @0xB0B;

const REFUND_RECIPIENT: address = @0xCAFE;

const CALLER: address = @0xC11;

const CANCELER: address = @0xCA11;

const TOTAL_AMOUNT: u64 = 1_001;

const START_MS: u64 = 100;

const CLIFF_MS: u64 = 200;

const PERIOD_MS: u64 = 100;

const PERIODS: u64 = 4;

// === Test-Only Types ===

public struct TEST_COIN() has drop;

/// Single-transaction construction and focused failure-path fixture.
public struct UnitFixture {
    scenario: Scenario,
    clock: Clock,
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
fun irrevocable_lifecycle_matches_vectors_and_replays_events() {
    let mut fixture = start_claim();

    fixture.next_tx!(CALLER, |f| {
        f.assert_created();
        let vesting_id = f.vesting_id();
        let coin_type = std::type_name::with_original_ids<TEST_COIN>();

        assert_eq!(f.vested_at(99), 0);
        assert_eq!(f.vested_at(100), 0);
        assert_eq!(f.vested_at(299), 0);
        assert_eq!(f.vested_at(300), 500);
        assert_eq!(f.vested_at(399), 500);
        assert_eq!(f.vested_at(400), 750);
        assert_eq!(f.vested_at(499), 750);
        assert_eq!(f.vested_at(500), TOTAL_AMOUNT);

        f.claim_at(300);

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
        assert_eq!(amount, 500);
        assert_eq!(released_total, 500);
        assert_eq!(remaining_balance, 501);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_beneficiary_payout(), 500);
    });

    fixture.next_tx!(CALLER, |f| {
        assert_eq!(f.releasable_at(399), 0);
        f.claim_at(400);

        let claimed = collect_one<VestingClaimed>();
        let (_, _, _, _, amount, released_total, remaining_balance) =
            claimed.vesting_claimed_fields();
        assert_eq!(amount, 250);
        assert_eq!(released_total, 750);
        assert_eq!(remaining_balance, 251);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_beneficiary_payout(), 250);
    });

    fixture.next_tx!(CALLER, |f| {
        f.claim_at(500);
        f.close_at(500);

        let claimed = collect_one<VestingClaimed>();
        let (_, _, _, _, amount, released_total, remaining_balance) =
            claimed.vesting_claimed_fields();
        let closed = collect_one<VestingClosed>();
        let (closed_id, _, caller, closed_released_total) =
            closed.vesting_closed_fields();

        assert_eq!(amount, 251);
        assert_eq!(released_total, TOTAL_AMOUNT);
        assert_eq!(remaining_balance, 0);
        assert_eq!(closed_id, f.vesting_id());
        assert_eq!(caller, CALLER);
        assert_eq!(closed_released_total, TOTAL_AMOUNT);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_beneficiary_payout(), 251);
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
            _,
            _,
            _,
            _,
        ) = f.created.vesting_created_fields();

        assert_eq!(vesting_id, f.vesting_id());
        assert_eq!(f.cancel_cap_vesting_id(), vesting_id);
        assert_eq!(funder, FUNDER);
        assert_eq!(beneficiary, BENEFICIARY);
        assert_eq!(refund_recipient.destroy_some(), REFUND_RECIPIENT);
        assert_eq!(cancel_cap_id.destroy_some(), f.cancel_cap_id());
        assert_eq!(total_amount, TOTAL_AMOUNT);

        f.claim_at(200);

        let claimed = collect_one<VestingClaimed>();
        let (_, _, caller, _, amount, released_total, remaining_balance) =
            claimed.vesting_claimed_fields();
        assert_eq!(caller, CALLER);
        assert_eq!(amount, 250);
        assert_eq!(released_total, 250);
        assert_eq!(remaining_balance, 751);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_beneficiary_payout(), 250);
    });

    fixture.next_tx!(CANCELER, |f| {
        f.cancel_at(350);

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
        assert_eq!(beneficiary_amount, 250);
        assert_eq!(refund_amount, 501);
        assert_eq!(released_total, 500);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_beneficiary_payout(), 250);
    });

    fixture.next_tx!(REFUND_RECIPIENT, |f| {
        assert_eq!(f.take_refund(), 501);
    });

    fixture.end();
}

#[test]
fun cancellation_before_the_first_period_returns_the_full_allocation() {
    let mut fixture = start_cancel();

    fixture.next_tx!(CANCELER, |f| {
        f.cancel_at(START_MS);

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
fun cancellation_after_full_vesting_has_no_refund() {
    let mut fixture = start_cancel();

    fixture.next_tx!(CANCELER, |f| {
        f.cancel_at(START_MS + PERIOD_MS * PERIODS);

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
fun maximum_width_schedule_uses_wide_multiplication() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(
        std::u64::max_value!(),
        BENEFICIARY,
        0,
        0,
        1,
        std::u64::max_value!(),
    );

    assert_eq!(
        fixture.vesting().vested_at_for_testing(std::u64::max_value!() - 1),
        std::u64::max_value!() - 1,
    );
    assert_eq!(
        fixture.vesting().vested_at_for_testing(std::u64::max_value!()),
        std::u64::max_value!(),
    );

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EInvalidBeneficiary,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_zero_beneficiary_before_other_invalid_inputs() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(0, @0x0, 0, 0, 0, 0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EInvalidRefundRecipient,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun cancelable_constructor_rejects_zero_refund_before_zero_allocation() {
    let mut fixture = start_unit(0);
    fixture.create_cancelable(
        0,
        BENEFICIARY,
        @0x0,
        0,
        0,
        PERIOD_MS,
        PERIODS,
    );

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EZeroAllocation,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_zero_allocation() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(
        0,
        BENEFICIARY,
        0,
        0,
        PERIOD_MS,
        PERIODS,
    );

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EZeroPeriod,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_zero_period_before_zero_period_count() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(1, BENEFICIARY, 0, 0, 0, 0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EZeroPeriods,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_zero_period_count() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(1, BENEFICIARY, 0, 0, 1, 0);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EInvalidCliff,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_cliff_after_end() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(1, BENEFICIARY, 0, 5, 1, 4);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EScheduleOverflow,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_duration_multiplication_overflow() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(
        1,
        BENEFICIARY,
        0,
        0,
        std::u64::max_value!(),
        2,
    );

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EScheduleOverflow,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_end_time_overflow() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(
        1,
        BENEFICIARY,
        std::u64::max_value!(),
        0,
        1,
        1,
    );

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EStartInPast,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun constructor_rejects_a_start_before_the_current_clock_time() {
    let mut fixture = start_unit(100);
    fixture.create_irrevocable(1, BENEFICIARY, 99, 0, 1, 1);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::ENothingClaimable,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun claim_rejects_zero_release_before_the_cliff() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(
        TOTAL_AMOUNT,
        BENEFICIARY,
        START_MS,
        CLIFF_MS,
        PERIOD_MS,
        PERIODS,
    );
    fixture.set_clock(299);

    fixture.claim();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EInvalidCancelCap,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun cancellation_rejects_a_cap_for_another_schedule() {
    let mut fixture = start_unit(0);
    fixture.cancel_with_mismatched_cap();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EScheduleNotEnded,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun close_rejects_a_schedule_before_its_end() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(1, BENEFICIARY, 0, 0, 1, 1);

    fixture.close_irrevocable();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::EScheduleNotEmpty,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun close_rejects_unclaimed_custody_after_the_end() {
    let mut fixture = start_unit(0);
    fixture.create_irrevocable(1, BENEFICIARY, 0, 0, 1, 1);
    fixture.set_clock(1);

    fixture.close_irrevocable();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::ECancelCapRequired,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
fun irrevocable_close_rejects_a_cancellable_schedule_before_time_checks() {
    let mut fixture = start_unit(0);
    fixture.create_cancelable(
        1,
        BENEFICIARY,
        REFUND_RECIPIENT,
        0,
        0,
        1,
        1,
    );

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

fun start_unit(timestamp_ms: u64): UnitFixture {
    let mut scenario = test_scenario::begin(FUNDER);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(timestamp_ms);

    UnitFixture {
        scenario,
        clock,
        vesting: option::none(),
        cancel_cap: option::none(),
    }
}

fun unit_create_irrevocable(
    self: &mut UnitFixture,
    amount: u64,
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
) {
    let funds = coin::mint_for_testing<TEST_COIN>(amount, self.scenario.ctx());
    let vesting = linear::new_irrevocable(
        funds,
        beneficiary,
        start_ms,
        cliff_ms,
        period_ms,
        periods,
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
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
) {
    let funds = coin::mint_for_testing<TEST_COIN>(amount, self.scenario.ctx());
    let (vesting, cancel_cap) = linear::new_cancelable(
        funds,
        beneficiary,
        refund_recipient,
        start_ms,
        cliff_ms,
        period_ms,
        periods,
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
    let (first, first_cap) = linear::new_cancelable(
        first_funds,
        BENEFICIARY,
        REFUND_RECIPIENT,
        0,
        0,
        1,
        1,
        &self.clock,
        self.scenario.ctx(),
    );
    let (second, second_cap) = linear::new_cancelable(
        second_funds,
        BENEFICIARY,
        REFUND_RECIPIENT,
        0,
        0,
        1,
        1,
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
    let vesting = linear::new_irrevocable(
        funds,
        BENEFICIARY,
        START_MS,
        CLIFF_MS,
        PERIOD_MS,
        PERIODS,
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
    let (vesting, cancel_cap) = linear::new_cancelable(
        funds,
        BENEFICIARY,
        REFUND_RECIPIENT,
        START_MS,
        0,
        PERIOD_MS,
        PERIODS,
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

fun claim_fixture_vested_at(self: &ClaimFixture, timestamp_ms: u64): u64 {
    self.vesting.borrow().vested_at_for_testing(timestamp_ms)
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
        start_ms,
        cliff_ms,
        period_ms,
        periods,
    ) = self.created.vesting_created_fields();

    assert_eq!(vesting_id, self.vesting_id);
    assert_eq!(coin_type, std::type_name::with_original_ids<TEST_COIN>());
    assert_eq!(funder, FUNDER);
    assert_eq!(beneficiary, BENEFICIARY);
    assert!(refund_recipient.is_none());
    assert!(cancel_cap_id.is_none());
    assert_eq!(total_amount, TOTAL_AMOUNT);
    assert_eq!(start_ms, START_MS);
    assert_eq!(cliff_ms, CLIFF_MS);
    assert_eq!(period_ms, PERIOD_MS);
    assert_eq!(periods, PERIODS);
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

use blast_fun_vesting::blast_fun_linear_vesting::{
    Self as linear,
    CancelCap,
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

use fun claim_fixture_claim_at as ClaimFixture.claim_at;

use fun claim_fixture_close_at as ClaimFixture.close_at;

use fun claim_fixture_assert_created as ClaimFixture.assert_created;

use fun claim_fixture_releasable_at as ClaimFixture.releasable_at;

use fun claim_fixture_take_beneficiary_payout as ClaimFixture.take_beneficiary_payout;

use fun claim_fixture_vested_at as ClaimFixture.vested_at;

use fun claim_fixture_vesting_id as ClaimFixture.vesting_id;

use fun unit_cancel_with_mismatched_cap as UnitFixture.cancel_with_mismatched_cap;

use fun unit_claim as UnitFixture.claim;

use fun unit_close_irrevocable as UnitFixture.close_irrevocable;

use fun unit_create_cancelable as UnitFixture.create_cancelable;

use fun unit_create_irrevocable as UnitFixture.create_irrevocable;

use fun unit_end as UnitFixture.end;

use fun unit_set_clock as UnitFixture.set_clock;

use fun unit_vesting as UnitFixture.vesting;
