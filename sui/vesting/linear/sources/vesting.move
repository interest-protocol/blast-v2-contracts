// The package error module deliberately inlines stable numeric codes at their owning checks.
#[allow(lint(abort_without_constant))]
/// Fully funded, fixed-beneficiary stepped-linear vesting.
module blast_fun_vesting_linear::vesting;

use blast_fun_vesting_linear::events;
use sui::{balance::Balance, clock::Clock, coin::Coin};

// === Public Structs ===

/// Key-only shared custody for one immutable vesting schedule.
public struct Vesting<phantom CoinType> has key {
    id: UID,
    balance: Balance<CoinType>,
    beneficiary: address,
    cancel_refund_recipient: Option<address>,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
    released: u64,
}

/// Transferable authority to cancel one exact schedule and return only unvested value.
public struct CancelCap<phantom CoinType> has key, store {
    id: UID,
    vesting_id: ID,
}

// === Public Functions ===

/// Creates a fully funded schedule with no cancellation authority.
public fun new_irrevocable<CoinType>(
    funds: Coin<CoinType>,
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
    ctx: &mut TxContext,
): Vesting<CoinType> {
    let total_amount = funds.value();
    let vesting = new(
        funds,
        beneficiary,
        option::none(),
        start_ms,
        cliff_ms,
        period_ms,
        periods,
        ctx,
    );

    events::vesting_created<CoinType>(
        object::id(&vesting),
        ctx.sender(),
        beneficiary,
        option::none(),
        option::none(),
        total_amount,
        start_ms,
        cliff_ms,
        period_ms,
        periods,
    );

    vesting
}

/// Creates a fully funded schedule and its exact cancellation capability.
public fun new_cancelable<CoinType>(
    funds: Coin<CoinType>,
    beneficiary: address,
    refund_recipient: address,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
    ctx: &mut TxContext,
): (Vesting<CoinType>, CancelCap<CoinType>) {
    let total_amount = funds.value();
    let vesting = new(
        funds,
        beneficiary,
        option::some(refund_recipient),
        start_ms,
        cliff_ms,
        period_ms,
        periods,
        ctx,
    );
    let vesting_id = object::id(&vesting);
    let cancel_cap = CancelCap {
        id: object::new(ctx),
        vesting_id,
    };

    events::vesting_created<CoinType>(
        vesting_id,
        ctx.sender(),
        beneficiary,
        option::some(refund_recipient),
        option::some(object::id(&cancel_cap)),
        total_amount,
        start_ms,
        cliff_ms,
        period_ms,
        periods,
    );

    (vesting, cancel_cap)
}

/// Publishes a newly constructed schedule as top-level shared state.
public fun share<CoinType>(self: Vesting<CoinType>) {
    transfer::share_object(self);
}

/// Transfers all newly vested value to the fixed beneficiary.
public fun claim<CoinType>(
    self: &mut Vesting<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount = self.releasable_at(clock.timestamp_ms());
    assert!(amount > 0, blast_fun_vesting_linear::errors::nothing_claimable!());

    let vesting_id = object::id(self);
    let caller = ctx.sender();
    let beneficiary = self.beneficiary;
    self.released = self.released + amount;
    let payout = self.balance.split(amount).into_coin(ctx);
    let remaining_balance = self.balance.value();
    let released_total = self.released;

    transfer::public_transfer(payout, beneficiary);

    events::vesting_claimed<CoinType>(
        vesting_id,
        caller,
        beneficiary,
        amount,
        released_total,
        remaining_balance,
    );
}

/// Settles vested value to the beneficiary and unvested value to the fixed refund recipient.
public fun cancel<CoinType>(
    self: Vesting<CoinType>,
    cap: CancelCap<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let vesting_id = object::id(&self);
    assert!(
        cap.vesting_id == vesting_id,
        blast_fun_vesting_linear::errors::invalid_cancel_cap!(),
    );

    let beneficiary = self.beneficiary;
    // A matching cap can only be minted by `new_cancelable`, which stores `Some`.
    let refund_recipient = *self.cancel_refund_recipient.borrow();
    let vested_total = self.vested_at(clock.timestamp_ms());
    let beneficiary_amount = vested_total - self.released;
    let refund_amount = self.balance.value() - beneficiary_amount;
    let caller = ctx.sender();
    let Vesting {
        id,
        mut balance,
        cancel_refund_recipient: _,
        start_ms: _,
        cliff_ms: _,
        period_ms: _,
        periods: _,
        released: _,
        beneficiary: _,
    } = self;
    let CancelCap { id: cap_id, vesting_id: _ } = cap;

    if (beneficiary_amount > 0) {
        let payout = balance.split(beneficiary_amount).into_coin(ctx);
        transfer::public_transfer(payout, beneficiary);
    };
    if (refund_amount > 0) {
        let refund = balance.split(refund_amount).into_coin(ctx);
        transfer::public_transfer(refund, refund_recipient);
    };

    balance.destroy_zero();
    id.delete();
    cap_id.delete();

    events::vesting_canceled<CoinType>(
        vesting_id,
        caller,
        beneficiary,
        refund_recipient,
        beneficiary_amount,
        refund_amount,
        vested_total,
    );
}

/// Deletes a drained irrevocable schedule after its final vesting boundary.
public fun close_irrevocable<CoinType>(
    self: Vesting<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(
        self.cancel_refund_recipient.is_none(),
        blast_fun_vesting_linear::errors::cancel_cap_required!(),
    );
    assert!(
        clock.timestamp_ms() >= self.end_ms(),
        blast_fun_vesting_linear::errors::schedule_not_ended!(),
    );
    assert!(
        self.balance.value() == 0,
        blast_fun_vesting_linear::errors::schedule_not_empty!(),
    );

    let vesting_id = object::id(&self);
    let released_total = self.released;
    let Vesting {
        id,
        balance,
        beneficiary: _,
        cancel_refund_recipient: _,
        start_ms: _,
        cliff_ms: _,
        period_ms: _,
        periods: _,
        released: _,
    } = self;

    balance.destroy_zero();
    id.delete();

    events::vesting_closed<CoinType>(vesting_id, ctx.sender(), released_total);
}

// === Private Functions ===

fun new<CoinType>(
    funds: Coin<CoinType>,
    beneficiary: address,
    cancel_refund_recipient: Option<address>,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
    ctx: &mut TxContext,
): Vesting<CoinType> {
    assert!(
        beneficiary != @0x0,
        blast_fun_vesting_linear::errors::invalid_beneficiary!(),
    );
    if (cancel_refund_recipient.is_some()) {
        assert!(
            *cancel_refund_recipient.borrow() != @0x0,
            blast_fun_vesting_linear::errors::invalid_refund_recipient!(),
        );
    };
    assert!(
        funds.value() > 0,
        blast_fun_vesting_linear::errors::zero_allocation!(),
    );
    assert!(
        period_ms > 0,
        blast_fun_vesting_linear::errors::zero_period!(),
    );
    assert!(
        periods > 0,
        blast_fun_vesting_linear::errors::zero_periods!(),
    );

    let max = std::u64::max_value!();
    assert!(
        period_ms <= max / periods,
        blast_fun_vesting_linear::errors::schedule_overflow!(),
    );
    let duration_ms = period_ms * periods;
    assert!(
        cliff_ms <= duration_ms,
        blast_fun_vesting_linear::errors::invalid_cliff!(),
    );
    assert!(
        duration_ms <= max - start_ms,
        blast_fun_vesting_linear::errors::schedule_overflow!(),
    );

    Vesting {
        id: object::new(ctx),
        balance: funds.into_balance(),
        beneficiary,
        cancel_refund_recipient,
        start_ms,
        cliff_ms,
        period_ms,
        periods,
        released: 0,
    }
}

fun vested_at<CoinType>(self: &Vesting<CoinType>, timestamp_ms: u64): u64 {
    if (timestamp_ms < self.start_ms || timestamp_ms < self.start_ms + self.cliff_ms) {
        return 0
    };

    // Conservation keeps this sum equal to the original u64 funding amount.
    let total_amount = self.balance.value() + self.released;
    if (timestamp_ms >= self.end_ms()) {
        return total_amount
    };

    let elapsed_periods = (timestamp_ms - self.start_ms) / self.period_ms;
    total_amount.mul_div(elapsed_periods, self.periods)
}

fun releasable_at<CoinType>(self: &Vesting<CoinType>, timestamp_ms: u64): u64 {
    self.vested_at(timestamp_ms) - self.released
}

fun end_ms<CoinType>(self: &Vesting<CoinType>): u64 {
    self.start_ms + self.period_ms * self.periods
}

// === Test-Only Functions ===

#[test_only]
public fun vested_at_for_testing<CoinType>(
    self: &Vesting<CoinType>,
    timestamp_ms: u64,
): u64 {
    self.vested_at(timestamp_ms)
}

#[test_only]
public fun releasable_at_for_testing<CoinType>(
    self: &Vesting<CoinType>,
    timestamp_ms: u64,
): u64 {
    self.releasable_at(timestamp_ms)
}

#[test_only]
public fun balance<CoinType>(self: &Vesting<CoinType>): u64 {
    self.balance.value()
}

#[test_only]
public fun released<CoinType>(self: &Vesting<CoinType>): u64 {
    self.released
}

#[test_only]
public fun cancel_cap_vesting_id<CoinType>(self: &CancelCap<CoinType>): ID {
    self.vesting_id
}
