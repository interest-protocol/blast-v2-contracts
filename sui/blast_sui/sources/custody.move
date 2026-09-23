// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// One ledger of native SUI custody delegated to the vault's fixed staking pool.
///
/// A ledger holds liquid SUI, up to `max_pending_stakes` pending `StakedSui`
/// receipts — each worth exactly its principal until conversion, ordered by
/// strictly increasing activation epoch because same-epoch requests join —
/// and at most one active `FungibleStakedSui` of the fixed pool. `active_sui`
/// is the conservative SUI valuation of the active tokens: the floor value at
/// the last applied pool exchange rate, reduced by exact native output between
/// refreshes. The vault owns the applied rate; a ledger never reads the pool.
module blast_sui::custody;

// === Public Types ===

/// One internal native-asset ledger with liquid, pending, and active stake layers.
public struct Custody has store {
    liquid_sui: Balance<SUI>,
    pending_stakes: vector<StakedSui>,
    active_stake: Option<FungibleStakedSui>,
    active_sui: u64,
}

// === Package Functions ===

/// Creates an empty custody ledger.
public(package) fun new(): Custody {
    Custody {
        liquid_sui: balance::zero(),
        pending_stakes: vector[],
        active_stake: option::none(),
        active_sui: 0,
    }
}

/// Adds liquid SUI without changing pending or active stake.
public(package) fun deposit(self: &mut Custody, sui: Balance<SUI>) {
    self.liquid_sui.join(sui);
}

/// Conservative backing: liquid, pending principal, and the active valuation.
public(package) fun assets(self: &Custody): u64 {
    self.liquid_sui.value() + self.pending_sui() + self.active_sui
}

/// Returns liquid SUI held at face value.
public(package) fun liquid_sui(self: &Custody): u64 {
    self.liquid_sui.value()
}

/// Returns the summed principal of all pending native stake receipts.
public(package) fun pending_sui(self: &Custody): u64 {
    let mut total = 0;
    self.pending_stakes.do_ref!(|stake| total = total + stake.amount());

    total
}

/// Returns the oldest pending receipt's activation epoch, if any receipt exists.
public(package) fun oldest_pending_activation_epoch(self: &Custody): Option<u64> {
    if (self.pending_stakes.is_empty()) {
        option::none()
    } else {
        option::some(self.pending_stakes[0].activation_epoch())
    }
}

/// Returns active fungible pool-token units, or zero when no active position exists.
public(package) fun active_pool_tokens(self: &Custody): u64 {
    if (self.active_stake.is_some()) self.active_stake.borrow().value() else 0
}

/// Returns the canonical event snapshot of this ledger's custody layers.
public(package) fun pool_custody(self: &Custody): events::PoolCustody {
    events::pool_custody(
        self.liquid_sui.value(),
        self.pending_sui(),
        self.active_pool_tokens(),
        self.active_sui,
    )
}

/// Delegates liquid SUI above `retain_liquid` to `validator` when that excess reaches the native minimum stake.
///
/// A request joins the newest receipt when both activate at the next epoch;
/// otherwise it takes a free slot. When the ledger is full and the newest
/// receipt cannot join, the excess skips delegation and stays liquid — still
/// counted at face value — rather than aborting the calling operation.
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
    let receipt_count = self.pending_stakes.length();
    let joins_newest = receipt_count > 0
        && self.pending_stakes[receipt_count - 1].activation_epoch() == ctx.epoch() + 1;
    if (!joins_newest && receipt_count >= constants::max_pending_stakes!()) return;

    let stake = self.liquid_sui.split(stakeable).into_coin(ctx);
    let staked = system_state.request_add_stake_non_entry(stake, validator, ctx);
    assert!(
        staked.pool_id() == *expected_pool_id,
        blast_sui::errors::wrong_delegation_pool!(),
    );
    if (joins_newest) {
        self.pending_stakes[receipt_count - 1].join(staked);
    } else {
        self.pending_stakes.push_back(staked);
    };
}

/// Converts every pending receipt whose activation epoch has arrived.
public(package) fun activate_pending(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
) {
    while (
        !self.pending_stakes.is_empty()
            && self.pending_stakes[0].activation_epoch() <= ctx.epoch()
    ) {
        self.activate_oldest_pending(system_state, ctx);
    }
}

/// Converts only the oldest pending receipt into the active position.
///
/// Callers guard on a present receipt whose activation epoch has arrived and
/// budget one conversion's floor loss per call.
public(package) fun activate_oldest_pending(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
) {
    let pending = self.pending_stakes.remove(0);
    let converted = system_state.convert_to_fungible_staked_sui(pending, ctx);
    self.join_active(converted);
}

/// Withdraws the oldest pending receipt to liquid SUI, realizing its rewards.
///
/// This recovery path avoids conversion to pool tokens when fun conversion
/// rounding would consume its buffer. Callers guard on a present receipt.
public(package) fun realize_oldest_pending(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
) {
    let pending = self.pending_stakes.remove(0);
    self.liquid_sui.join(system_state.request_withdraw_stake_non_entry(pending, ctx));
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
///
/// The native rounding margin carries headroom above the proven three-MIST
/// bound, so bounded rounding drift in a live system upgrade cannot starve
/// an exact redemption. Sufficiency still assumes pool exchange rates never
/// decrease (the framework accrues rewards only and never slashes
/// principal). If a rate ever decreased, `active_sui` could overstate the
/// position and this function would abort with
/// `insufficient_native_redemption` instead of underpaying remaining
/// holders: redemptions fail closed until a package upgrade reprices the
/// ledger.
public(package) fun withdraw_exact(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    amount: u64,
    rate_sui: u64,
    rate_pool_tokens: u64,
    ctx: &mut TxContext,
): Balance<SUI> {
    if (self.liquid_sui.value() < amount && !self.pending_stakes.is_empty()) {
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
    while (!self.pending_stakes.is_empty()) self.realize_oldest_pending(system_state, ctx);
    if (self.active_stake.is_some()) {
        let held_pool_tokens = self.active_pool_tokens();
        self.redeem_active(system_state, held_pool_tokens, 0, 0, ctx);
    };
}

/// Moves exact liquid SUI between two internal ledgers.
public(package) fun transfer_liquid(self: &mut Custody, to: &mut Custody, amount: u64) {
    to.liquid_sui.join(self.liquid_sui.split(amount));
}

/// Moves `tokens` active pool tokens into `to` and revalues both ledgers at the rate.
public(package) fun transfer_active_tokens(
    self: &mut Custody,
    to: &mut Custody,
    pool_tokens: u64,
    rate_sui: u64,
    rate_pool_tokens: u64,
    ctx: &mut TxContext,
) {
    let held_pool_tokens = self.active_pool_tokens();
    let moved = if (pool_tokens >= held_pool_tokens) {
        self.active_stake.extract()
    } else {
        self.active_stake.borrow_mut().split(pool_tokens, ctx)
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
    pool_tokens: u64,
    rate_sui: u64,
    rate_pool_tokens: u64,
    ctx: &mut TxContext,
) {
    let held_pool_tokens = self.active_pool_tokens();
    let redeemed = if (pool_tokens >= held_pool_tokens) {
        self.active_stake.extract()
    } else {
        self.active_stake.borrow_mut().split(pool_tokens, ctx)
    };
    let sui_out = system_state.redeem_fungible_staked_sui(redeemed, ctx);

    if (pool_tokens >= held_pool_tokens) {
        self.active_sui = 0;
    } else {
        self.revalue(rate_sui, rate_pool_tokens);
    };
    self.liquid_sui.join(sui_out);
}

/// Withdraws enough pending principal to fund `needed`, newest receipt first
/// so the oldest, soonest-earning receipts stay delegated, preserving a
/// receipt when both native halves can remain at or above the one-SUI minimum.
fun withdraw_pending(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    needed: u64,
    ctx: &mut TxContext,
) {
    let minimum = constants::native_min_stake_mist!();
    let mut remaining = needed;
    while (remaining > 0 && !self.pending_stakes.is_empty()) {
        let newest = self.pending_stakes.length() - 1;
        let receipt_sui = self.pending_stakes[newest].amount();
        let split_amount = remaining.max(minimum);
        let withdrawn = if (split_amount <= receipt_sui.saturating_sub(minimum)) {
            self.pending_stakes[newest].split(split_amount, ctx)
        } else {
            self.pending_stakes.pop_back()
        };
        let sui_out = system_state.request_withdraw_stake_non_entry(withdrawn, ctx);
        remaining = remaining.saturating_sub(sui_out.value());
        self.liquid_sui.join(sui_out);
    }
}

// === Imports ===

use blast_sui::{constants, events, math};

use sui::{balance::{Self, Balance}, sui::SUI};

use sui_system::{staking_pool::{FungibleStakedSui, StakedSui}, sui_system::SuiSystemState};
