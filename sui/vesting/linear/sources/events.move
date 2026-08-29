module blast_fun_vesting_linear::events;

use std::type_name::{Self, TypeName};

// === Public Structs ===

/// Emitted after one fully funded schedule and any cancellation cap are created.
public struct VestingCreated has copy, drop {
    vesting_id: ID,
    coin_type: TypeName,
    funder: address,
    beneficiary: address,
    refund_recipient: Option<address>,
    cancel_cap_id: Option<ID>,
    total_amount: u64,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
}

/// Emitted after newly vested value is transferred to the fixed beneficiary.
public struct VestingClaimed has copy, drop {
    vesting_id: ID,
    coin_type: TypeName,
    caller: address,
    beneficiary: address,
    amount: u64,
    released_total: u64,
    remaining_balance: u64,
}

/// Emitted after fair cancellation settles vested and unvested custody.
public struct VestingCanceled has copy, drop {
    vesting_id: ID,
    coin_type: TypeName,
    caller: address,
    beneficiary: address,
    refund_recipient: address,
    beneficiary_amount: u64,
    refund_amount: u64,
    released_total: u64,
}

/// Emitted after a drained, ended irrevocable schedule is deleted.
public struct VestingClosed has copy, drop {
    vesting_id: ID,
    coin_type: TypeName,
    caller: address,
    released_total: u64,
}

// === Package Functions ===

public(package) fun vesting_created<CoinType>(
    vesting_id: ID,
    funder: address,
    beneficiary: address,
    refund_recipient: Option<address>,
    cancel_cap_id: Option<ID>,
    total_amount: u64,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
) {
    blast_fun_vesting_linear::events_wrapper::emit_event(VestingCreated {
        vesting_id,
        coin_type: type_name::with_original_ids<CoinType>(),
        funder,
        beneficiary,
        refund_recipient,
        cancel_cap_id,
        total_amount,
        start_ms,
        cliff_ms,
        period_ms,
        periods,
    });
}

public(package) fun vesting_claimed<CoinType>(
    vesting_id: ID,
    caller: address,
    beneficiary: address,
    amount: u64,
    released_total: u64,
    remaining_balance: u64,
) {
    blast_fun_vesting_linear::events_wrapper::emit_event(VestingClaimed {
        vesting_id,
        coin_type: type_name::with_original_ids<CoinType>(),
        caller,
        beneficiary,
        amount,
        released_total,
        remaining_balance,
    });
}

public(package) fun vesting_canceled<CoinType>(
    vesting_id: ID,
    caller: address,
    beneficiary: address,
    refund_recipient: address,
    beneficiary_amount: u64,
    refund_amount: u64,
    released_total: u64,
) {
    blast_fun_vesting_linear::events_wrapper::emit_event(VestingCanceled {
        vesting_id,
        coin_type: type_name::with_original_ids<CoinType>(),
        caller,
        beneficiary,
        refund_recipient,
        beneficiary_amount,
        refund_amount,
        released_total,
    });
}

public(package) fun vesting_closed<CoinType>(
    vesting_id: ID,
    caller: address,
    released_total: u64,
) {
    blast_fun_vesting_linear::events_wrapper::emit_event(VestingClosed {
        vesting_id,
        coin_type: type_name::with_original_ids<CoinType>(),
        caller,
        released_total,
    });
}

// === Test-Only Functions ===

#[test_only]
public fun collect<T: copy + drop>(): vector<T> {
    let mut out = vector[];

    sui::event::events_by_type<blast_fun_vesting_linear::events_wrapper::Event<T>>().do!(
        |event| out.push_back(event.unwrap()),
    );

    out
}

#[test_only]
#[allow(lint(abort_without_constant))]
public fun collect_one<T: copy + drop>(abort_code: u64): T {
    let mut events = collect<T>();

    assert!(events.length() == 1, abort_code);

    events.pop_back()
}

#[test_only]
public fun vesting_created_fields(
    self: &VestingCreated,
): (ID, TypeName, address, address, Option<address>, Option<ID>, u64, u64, u64, u64, u64) {
    (
        self.vesting_id,
        self.coin_type,
        self.funder,
        self.beneficiary,
        self.refund_recipient,
        self.cancel_cap_id,
        self.total_amount,
        self.start_ms,
        self.cliff_ms,
        self.period_ms,
        self.periods,
    )
}

#[test_only]
public fun vesting_claimed_fields(
    self: &VestingClaimed,
): (ID, TypeName, address, address, u64, u64, u64) {
    (
        self.vesting_id,
        self.coin_type,
        self.caller,
        self.beneficiary,
        self.amount,
        self.released_total,
        self.remaining_balance,
    )
}

#[test_only]
public fun vesting_canceled_fields(
    self: &VestingCanceled,
): (ID, TypeName, address, address, address, u64, u64, u64) {
    (
        self.vesting_id,
        self.coin_type,
        self.caller,
        self.beneficiary,
        self.refund_recipient,
        self.beneficiary_amount,
        self.refund_amount,
        self.released_total,
    )
}

#[test_only]
public fun vesting_closed_fields(self: &VestingClosed): (ID, TypeName, address, u64) {
    (
        self.vesting_id,
        self.coin_type,
        self.caller,
        self.released_total,
    )
}
