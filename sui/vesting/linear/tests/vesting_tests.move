#[test_only]
module blast_fun_vesting_linear::vesting_tests;

use blast_fun_vesting_linear::{events, vesting::{Self, CancelCap, Vesting}};
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
use fun cancel_fixture_vesting_id_before_cancel as CancelFixture.vesting_id_before_cancel;
use fun claim_fixture_claim_at as ClaimFixture.claim_at;
use fun claim_fixture_close_at as ClaimFixture.close_at;
use fun claim_fixture_assert_created as ClaimFixture.assert_created;
use fun claim_fixture_releasable_at as ClaimFixture.releasable_at;
use fun claim_fixture_take_beneficiary_payout as ClaimFixture.take_beneficiary_payout;
use fun claim_fixture_vested_at as ClaimFixture.vested_at;
use fun claim_fixture_vesting_id as ClaimFixture.vesting_id;
use fun claim_fixture_vesting_id_before_close as ClaimFixture.vesting_id_before_close;

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

/// Shared irrevocable lifecycle with beneficiary payout inspection.
public struct ClaimFixture {
    scenario: Scenario,
    clock: Clock,
    vesting: Option<Vesting<TEST_COIN>>,
    created: events::VestingCreated,
    vesting_id: ID,
}

/// Shared cancellable lifecycle with a transferred cancellation capability.
public struct CancelFixture {
    scenario: Scenario,
    clock: Clock,
    vesting: Option<Vesting<TEST_COIN>>,
    cancel_cap: Option<CancelCap<TEST_COIN>>,
    created: events::VestingCreated,
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

        let claimed = events::collect_one<events::VestingClaimed>(0);
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
        assert!(event::events_by_type<events::VestingClaimed>().is_empty());
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        assert_eq!(f.take_beneficiary_payout(), 500);
    });

    fixture.next_tx!(CALLER, |f| {
        assert_eq!(f.releasable_at(399), 0);
        f.claim_at(400);

        let claimed = events::collect_one<events::VestingClaimed>(0);
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

        let claimed = events::collect_one<events::VestingClaimed>(0);
        let (_, _, _, _, amount, released_total, remaining_balance) =
            claimed.vesting_claimed_fields();
        let closed = events::collect_one<events::VestingClosed>(0);
        let (closed_id, _, caller, closed_released_total) =
            closed.vesting_closed_fields();

        assert_eq!(amount, 251);
        assert_eq!(released_total, TOTAL_AMOUNT);
        assert_eq!(remaining_balance, 0);
        assert_eq!(closed_id, f.vesting_id_before_close());
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

        let claimed = events::collect_one<events::VestingClaimed>(0);
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

        let canceled = events::collect_one<events::VestingCanceled>(0);
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

        assert_eq!(vesting_id, f.vesting_id_before_cancel());
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
fun maximum_width_schedule_uses_wide_multiplication() {
    let mut ctx = tx_context::dummy();
    let funds = coin::mint_for_testing<TEST_COIN>(std::u64::max_value!(), &mut ctx);
    let vesting = vesting::new_irrevocable(
        funds,
        BENEFICIARY,
        0,
        0,
        1,
        std::u64::max_value!(),
        &mut ctx,
    );

    assert_eq!(
        vesting.vested_at_for_testing(std::u64::max_value!() - 1),
        std::u64::max_value!() - 1,
    );
    assert_eq!(
        vesting.vested_at_for_testing(std::u64::max_value!()),
        std::u64::max_value!(),
    );

    destroy(vesting);
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting_linear::errors::EInvalidBeneficiary,
    location = blast_fun_vesting_linear::vesting,
)]
fun constructor_rejects_zero_beneficiary_before_other_invalid_inputs() {
    let mut ctx = tx_context::dummy();
    let funds = coin::mint_for_testing<TEST_COIN>(0, &mut ctx);
    let vesting = vesting::new_irrevocable(funds, @0x0, 0, 0, 0, 0, &mut ctx);

    destroy(vesting);
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting_linear::errors::EInvalidRefundRecipient,
    location = blast_fun_vesting_linear::vesting,
)]
fun cancelable_constructor_rejects_zero_refund_before_zero_allocation() {
    let mut ctx = tx_context::dummy();
    let funds = coin::mint_for_testing<TEST_COIN>(0, &mut ctx);
    let (vesting, cancel_cap) = vesting::new_cancelable(
        funds,
        BENEFICIARY,
        @0x0,
        0,
        0,
        PERIOD_MS,
        PERIODS,
        &mut ctx,
    );

    destroy(vesting);
    destroy(cancel_cap);
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting_linear::errors::EZeroAllocation,
    location = blast_fun_vesting_linear::vesting,
)]
fun constructor_rejects_zero_allocation() {
    let mut ctx = tx_context::dummy();
    let funds = coin::mint_for_testing<TEST_COIN>(0, &mut ctx);
    let vesting = vesting::new_irrevocable(
        funds,
        BENEFICIARY,
        0,
        0,
        PERIOD_MS,
        PERIODS,
        &mut ctx,
    );

    destroy(vesting);
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting_linear::errors::EZeroPeriod,
    location = blast_fun_vesting_linear::vesting,
)]
fun constructor_rejects_zero_period_before_zero_period_count() {
    let mut ctx = tx_context::dummy();
    let funds = coin::mint_for_testing<TEST_COIN>(1, &mut ctx);
    let vesting = vesting::new_irrevocable(funds, BENEFICIARY, 0, 0, 0, 0, &mut ctx);

    destroy(vesting);
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting_linear::errors::EZeroPeriods,
    location = blast_fun_vesting_linear::vesting,
)]
fun constructor_rejects_zero_period_count() {
    let mut ctx = tx_context::dummy();
    let funds = coin::mint_for_testing<TEST_COIN>(1, &mut ctx);
    let vesting = vesting::new_irrevocable(funds, BENEFICIARY, 0, 0, 1, 0, &mut ctx);

    destroy(vesting);
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting_linear::errors::EInvalidCliff,
    location = blast_fun_vesting_linear::vesting,
)]
fun constructor_rejects_cliff_after_end() {
    let mut ctx = tx_context::dummy();
    let funds = coin::mint_for_testing<TEST_COIN>(1, &mut ctx);
    let vesting = vesting::new_irrevocable(funds, BENEFICIARY, 0, 5, 1, 4, &mut ctx);

    destroy(vesting);
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting_linear::errors::EScheduleOverflow,
    location = blast_fun_vesting_linear::vesting,
)]
fun constructor_rejects_duration_multiplication_overflow() {
    let mut ctx = tx_context::dummy();
    let funds = coin::mint_for_testing<TEST_COIN>(1, &mut ctx);
    let vesting = vesting::new_irrevocable(
        funds,
        BENEFICIARY,
        0,
        0,
        std::u64::max_value!(),
        2,
        &mut ctx,
    );

    destroy(vesting);
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting_linear::errors::EScheduleOverflow,
    location = blast_fun_vesting_linear::vesting,
)]
fun constructor_rejects_end_time_overflow() {
    let mut ctx = tx_context::dummy();
    let funds = coin::mint_for_testing<TEST_COIN>(1, &mut ctx);
    let vesting = vesting::new_irrevocable(
        funds,
        BENEFICIARY,
        std::u64::max_value!(),
        0,
        1,
        1,
        &mut ctx,
    );

    destroy(vesting);
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting_linear::errors::ENothingClaimable,
    location = blast_fun_vesting_linear::vesting,
)]
fun claim_rejects_zero_release_before_the_cliff() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    let funds = coin::mint_for_testing<TEST_COIN>(TOTAL_AMOUNT, &mut ctx);
    let mut vesting = vesting::new_irrevocable(
        funds,
        BENEFICIARY,
        START_MS,
        CLIFF_MS,
        PERIOD_MS,
        PERIODS,
        &mut ctx,
    );
    clock.set_for_testing(299);

    vesting.claim(&clock, &mut ctx);

    destroy(vesting);
    destroy(clock);
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting_linear::errors::EInvalidCancelCap,
    location = blast_fun_vesting_linear::vesting,
)]
fun cancellation_rejects_a_cap_for_another_schedule() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let first_funds = coin::mint_for_testing<TEST_COIN>(1, &mut ctx);
    let second_funds = coin::mint_for_testing<TEST_COIN>(1, &mut ctx);
    let (first, first_cap) = vesting::new_cancelable(
        first_funds,
        BENEFICIARY,
        REFUND_RECIPIENT,
        0,
        0,
        1,
        1,
        &mut ctx,
    );
    let (second, second_cap) = vesting::new_cancelable(
        second_funds,
        BENEFICIARY,
        REFUND_RECIPIENT,
        0,
        0,
        1,
        1,
        &mut ctx,
    );

    first.cancel(second_cap, &clock, &mut ctx);

    destroy(first_cap);
    destroy(second);
    destroy(clock);
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting_linear::errors::EScheduleNotEnded,
    location = blast_fun_vesting_linear::vesting,
)]
fun close_rejects_a_schedule_before_its_end() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let funds = coin::mint_for_testing<TEST_COIN>(1, &mut ctx);
    let vesting = vesting::new_irrevocable(funds, BENEFICIARY, 0, 0, 1, 1, &mut ctx);

    vesting.close_irrevocable(&clock, &mut ctx);

    destroy(clock);
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting_linear::errors::EScheduleNotEmpty,
    location = blast_fun_vesting_linear::vesting,
)]
fun close_rejects_unclaimed_custody_after_the_end() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    let funds = coin::mint_for_testing<TEST_COIN>(1, &mut ctx);
    let vesting = vesting::new_irrevocable(funds, BENEFICIARY, 0, 0, 1, 1, &mut ctx);
    clock.set_for_testing(1);

    vesting.close_irrevocable(&clock, &mut ctx);

    destroy(clock);
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting_linear::errors::ECancelCapRequired,
    location = blast_fun_vesting_linear::vesting,
)]
fun irrevocable_close_rejects_a_cancellable_schedule_before_time_checks() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let funds = coin::mint_for_testing<TEST_COIN>(1, &mut ctx);
    let (vesting, cancel_cap) = vesting::new_cancelable(
        funds,
        BENEFICIARY,
        REFUND_RECIPIENT,
        0,
        0,
        1,
        1,
        &mut ctx,
    );

    vesting.close_irrevocable(&clock, &mut ctx);

    destroy(cancel_cap);
    destroy(clock);
}

// === Private Test Helpers ===

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

fun start_claim(): ClaimFixture {
    let mut scenario = test_scenario::begin(FUNDER);
    let clock = clock::create_for_testing(scenario.ctx());
    let funds = coin::mint_for_testing<TEST_COIN>(TOTAL_AMOUNT, scenario.ctx());
    let vesting = vesting::new_irrevocable(
        funds,
        BENEFICIARY,
        START_MS,
        CLIFF_MS,
        PERIOD_MS,
        PERIODS,
        scenario.ctx(),
    );
    let vesting_id = object::id(&vesting);
    let created = events::collect_one<events::VestingCreated>(0);

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
    let (vesting, cancel_cap) = vesting::new_cancelable(
        funds,
        BENEFICIARY,
        REFUND_RECIPIENT,
        START_MS,
        0,
        PERIOD_MS,
        PERIODS,
        scenario.ctx(),
    );
    let vesting_id = object::id(&vesting);
    let cancel_cap_id = object::id(&cancel_cap);
    let created = events::collect_one<events::VestingCreated>(0);

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
    let vesting = self.vesting.extract();
    vesting.close_irrevocable(&self.clock, self.scenario.ctx());
}

fun claim_fixture_vesting_id(self: &ClaimFixture): ID {
    self.vesting_id
}

fun claim_fixture_vesting_id_before_close(self: &ClaimFixture): ID {
    self.vesting_id
}

fun claim_fixture_take_beneficiary_payout(self: &ClaimFixture): u64 {
    coin::burn_for_testing(self.scenario.take_from_sender<Coin<TEST_COIN>>())
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
    let vesting = self.vesting.extract();
    let cancel_cap = self.cancel_cap.extract();
    vesting.cancel(cancel_cap, &self.clock, self.scenario.ctx());
}

fun cancel_fixture_vesting_id(self: &CancelFixture): ID {
    self.vesting_id
}

fun cancel_fixture_vesting_id_before_cancel(self: &CancelFixture): ID {
    self.vesting_id
}

fun cancel_fixture_cancel_cap_id(self: &CancelFixture): ID {
    self.cancel_cap_id
}

fun cancel_fixture_cancel_cap_vesting_id(self: &CancelFixture): ID {
    self.cancel_cap.borrow().cancel_cap_vesting_id()
}

fun cancel_fixture_take_beneficiary_payout(self: &CancelFixture): u64 {
    coin::burn_for_testing(self.scenario.take_from_sender<Coin<TEST_COIN>>())
}

fun cancel_fixture_take_refund(self: &CancelFixture): u64 {
    coin::burn_for_testing(self.scenario.take_from_sender<Coin<TEST_COIN>>())
}

fun cancel_end(self: CancelFixture) {
    assert!(self.vesting.is_none());
    assert!(self.cancel_cap.is_none());
    destroy(self);
}
