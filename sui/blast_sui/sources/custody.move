// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// One ledger of native SUI custody delegated to the vault's fixed staking pool.
///
/// A ledger holds liquid SUI, at most one pending `StakedSui` — the native
/// pre-activation receipt, worth exactly its principal until the next epoch —
/// and at most one active `FungibleStakedSui` of the fixed pool. `active_sui`
/// is the conservative SUI valuation of the active tokens: the floor value at
/// the last applied pool exchange rate, reduced by exact native output between
/// refreshes. The vault owns the applied rate; a ledger never reads the pool.
module blast_sui::custody;

use blast_sui::{constants, events, math};
use sui::{balance::{Self, Balance}, sui::SUI};
use sui_system::{staking_pool::{FungibleStakedSui, StakedSui}, sui_system::SuiSystemState};

// === Public Structs ===

public struct Custody has store {
    liquid_sui: Balance<SUI>,
    pending_stake: Option<StakedSui>,
    active_stake: Option<FungibleStakedSui>,
    active_sui: u64,
}

// === Package Functions ===

public(package) fun new(): Custody {
    Custody {
        liquid_sui: balance::zero(),
        pending_stake: option::none(),
        active_stake: option::none(),
        active_sui: 0,
    }
}

public(package) fun deposit(self: &mut Custody, sui: Balance<SUI>) {
    self.liquid_sui.join(sui);
}

/// Conservative backing: liquid, pending principal, and the active valuation.
public(package) fun assets(self: &Custody): u64 {
    self.liquid_sui.value() + self.pending_sui() + self.active_sui
}

public(package) fun liquid_sui(self: &Custody): u64 {
    self.liquid_sui.value()
}

public(package) fun pending_sui(self: &Custody): u64 {
    if (self.pending_stake.is_some()) self.pending_stake.borrow().amount() else 0
}

public(package) fun pending_activation_epoch(self: &Custody): Option<u64> {
    if (self.pending_stake.is_some()) {
        option::some(self.pending_stake.borrow().activation_epoch())
    } else {
        option::none()
    }
}

public(package) fun active_pool_tokens(self: &Custody): u64 {
    if (self.active_stake.is_some()) self.active_stake.borrow().value() else 0
}

public(package) fun active_sui(self: &Custody): u64 {
    self.active_sui
}

public(package) fun snapshot(self: &Custody): events::PoolCustody {
    events::pool_custody(
        self.liquid_sui.value(),
        self.pending_sui(),
        self.active_pool_tokens(),
        self.active_sui,
    )
}

/// Delegates liquid SUI above `retain_liquid` to `validator` when that excess reaches the native minimum stake.
public(package) fun stake_idle(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    validator: address,
    expected_pool_id: &ID,
    retain_liquid: u64,
    ctx: &mut TxContext,
) {
    let stakeable = self.liquid_sui.value().saturating_sub(retain_liquid);
    if (stakeable < constants::native_min_stake_mist!()) return;
    if (
        self.pending_stake.is_some()
            && self.pending_stake.borrow().activation_epoch() != ctx.epoch() + 1
    ) return;

    let stake = self.liquid_sui.split(stakeable).into_coin(ctx);
    let staked = system_state.request_add_stake_non_entry(stake, validator, ctx);
    assert!(
        staked.pool_id() == *expected_pool_id,
        blast_sui::errors::wrong_delegation_pool!(),
    );
    if (self.pending_stake.is_some()) {
        self.pending_stake.borrow_mut().join(staked);
    } else {
        self.pending_stake.fill(staked);
    };
}

/// Converts the pending receipt into the active position once its activation epoch arrives.
public(package) fun activate_pending(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
) {
    if (
        self.pending_stake.is_none()
            || self.pending_stake.borrow().activation_epoch() > ctx.epoch()
    ) return;

    let pending = self.pending_stake.extract();
    let converted = system_state.convert_to_fungible_staked_sui(pending, ctx);
    self.join_active(converted);
}

/// Withdraws a pending or activated native receipt to liquid SUI.
///
/// This realizes rewards without requiring conversion to pool tokens. It is
/// the recovery path when fun conversion rounding would consume its buffer.
public(package) fun realize_pending(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
) {
    if (self.pending_stake.is_some()) self.withdraw_all_pending(system_state, ctx);
}

/// Joins externally activated pool tokens and revalues the combined position.
public(package) fun join_active_at_rate(
    self: &mut Custody,
    stake: FungibleStakedSui,
    rate_sui: u64,
    rate_pool_tokens: u64,
) {
    self.join_active(stake);
    self.revalue(rate_sui, rate_pool_tokens);
}

/// Revalues the active position at the given pool exchange rate.
public(package) fun revalue(self: &mut Custody, rate_sui: u64, rate_pool_tokens: u64) {
    self.active_sui = math::sui_at_rate_down(
        self.active_pool_tokens(),
        rate_sui,
        rate_pool_tokens,
    );
}

/// Moves exactly `amount` MIST out of custody: liquid first, then pending, then active.
public(package) fun withdraw_exact(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    amount: u64,
    rate_sui: u64,
    rate_pool_tokens: u64,
    ctx: &mut TxContext,
): Balance<SUI> {
    if (self.liquid_sui.value() < amount && self.pending_stake.is_some()) {
        let pending_deficit = amount - self.liquid_sui.value();
        self.withdraw_pending(system_state, pending_deficit, ctx);
    };
    if (self.liquid_sui.value() < amount && self.active_stake.is_some()) {
        let deficit = amount - self.liquid_sui.value();
        let tokens = math::pool_tokens_for_sui_up(
            deficit + constants::native_redemption_rounding_margin!(),
            self.active_pool_tokens(),
            self.active_sui,
        );
        self.redeem_active(system_state, tokens, rate_sui, rate_pool_tokens, ctx);
    };
    assert!(
        self.liquid_sui.value() >= amount,
        blast_sui::errors::insufficient_native_redemption!(),
    );

    self.liquid_sui.split(amount)
}

/// Withdraws every native position into liquid SUI.
public(package) fun unwind(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
) {
    if (self.pending_stake.is_some()) self.withdraw_all_pending(system_state, ctx);
    if (self.active_stake.is_some()) {
        let held = self.active_pool_tokens();
        self.redeem_active(system_state, held, 0, 0, ctx);
    };
}

public(package) fun transfer_liquid(self: &mut Custody, to: &mut Custody, amount: u64) {
    to.liquid_sui.join(self.liquid_sui.split(amount));
}

/// Moves `tokens` active pool tokens into `to` and revalues both ledgers at the rate.
public(package) fun transfer_active_tokens(
    self: &mut Custody,
    to: &mut Custody,
    tokens: u64,
    rate_sui: u64,
    rate_pool_tokens: u64,
    ctx: &mut TxContext,
) {
    let held = self.active_pool_tokens();
    let moved = if (tokens >= held) {
        self.active_stake.extract()
    } else {
        self.active_stake.borrow_mut().split(tokens, ctx)
    };
    to.join_active(moved);

    self.revalue(rate_sui, rate_pool_tokens);
    to.revalue(rate_sui, rate_pool_tokens);
}

// === Private Functions ===

fun join_active(self: &mut Custody, converted: FungibleStakedSui) {
    if (self.active_stake.is_some()) {
        self.active_stake.borrow_mut().join(converted);
    } else {
        self.active_stake.fill(converted);
    };
}

/// Redeems up to `tokens` active pool tokens and re-floors any remaining position.
fun redeem_active(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    tokens: u64,
    rate_sui: u64,
    rate_pool_tokens: u64,
    ctx: &mut TxContext,
) {
    let held = self.active_pool_tokens();
    let redeemed = if (tokens >= held) {
        self.active_stake.extract()
    } else {
        self.active_stake.borrow_mut().split(tokens, ctx)
    };
    let sui_out = system_state.redeem_fungible_staked_sui(redeemed, ctx);

    if (tokens >= held) {
        self.active_sui = 0;
    } else {
        self.revalue(rate_sui, rate_pool_tokens);
    };
    self.liquid_sui.join(sui_out);
}

/// Withdraws enough pending principal to fund `needed`, preserving the rest when both
/// native receipts can remain at or above the one-SUI minimum.
fun withdraw_pending(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    needed: u64,
    ctx: &mut TxContext,
) {
    let held = self.pending_stake.borrow().amount();
    let minimum = constants::native_min_stake_mist!();
    let split_amount = needed.max(minimum);
    let withdrawn = if (split_amount <= held.saturating_sub(minimum)) {
        self.pending_stake.borrow_mut().split(split_amount, ctx)
    } else {
        self.pending_stake.extract()
    };
    self.liquid_sui.join(system_state.request_withdraw_stake_non_entry(withdrawn, ctx));
}

fun withdraw_all_pending(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
) {
    let pending = self.pending_stake.extract();
    self.liquid_sui.join(system_state.request_withdraw_stake_non_entry(pending, ctx));
}
