// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// One ledger of native SUI custody delegated across the vault's admitted staking pools.
///
/// A ledger holds one liquid balance and one position per admitted pool. A position holds up
/// to `max_pending_stakes` pending `StakedSui` receipts — each worth exactly its principal
/// until conversion, ordered by strictly increasing activation epoch because same-epoch
/// requests join — and at most one active `FungibleStakedSui` of that pool. `active_sui` is the
/// conservative SUI valuation of the active tokens: the floor value at the pool's last applied
/// exchange rate, reduced by exact native output between refreshes. The vault owns the applied
/// rates; a ledger never reads them from the system state.
module blast_sui::custody;

// === Public Types ===

/// A pool's last applied exchange-rate entry. `epoch` is the entry's table key; a refresh in
/// an epoch without a usable entry keeps the previous one, so `epoch` may trail the transaction.
public struct PoolRate has copy, drop, store {
    epoch: u64,
    sui: u64,
    pool_tokens: u64,
}

/// One internal native-asset ledger: liquid SUI and a position per admitted pool.
public struct Custody has store {
    liquid_sui: Balance<SUI>,
    positions: VecMap<ID, Position>,
}

/// One ledger's native stake in one pool, with pending and active layers.
public struct Position has store {
    pending_stakes: vector<StakedSui>,
    active_stake: Option<FungibleStakedSui>,
    active_sui: u64,
}

// === Package Functions ===

/// Constructs a pool's applied exchange-rate entry.
public(package) fun new_rate(epoch: u64, sui: u64, pool_tokens: u64): PoolRate {
    PoolRate { epoch, sui, pool_tokens }
}

/// Returns the epoch this rate was read at.
public(package) fun epoch(self: &PoolRate): u64 {
    self.epoch
}

/// Returns the rate's SUI component.
public(package) fun sui(self: &PoolRate): u64 {
    self.sui
}

/// Returns the rate's pool-token component.
public(package) fun pool_tokens(self: &PoolRate): u64 {
    self.pool_tokens
}

/// Creates an empty custody ledger.
public(package) fun new(): Custody {
    Custody { liquid_sui: balance::zero(), positions: vec_map::empty() }
}

/// Opens an empty position for a newly admitted pool.
public(package) fun add_position(self: &mut Custody, pool_id: ID) {
    self
        .positions
        .insert(
            pool_id,
            Position { pending_stakes: vector[], active_stake: option::none(), active_sui: 0 },
        );
}

/// Withdraws a pool's whole position into liquid SUI and destroys it.
public(package) fun retire_position(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    pool_id: &ID,
    ctx: &mut TxContext,
) {
    self.unwind_position(system_state, pool_id, ctx);

    let (_, position) = self.positions.remove(pool_id);
    let Position { pending_stakes, active_stake, active_sui: _ } = position;
    pending_stakes.destroy_empty();
    active_stake.destroy_none();
}

/// Adds liquid SUI without changing any position.
public(package) fun deposit(self: &mut Custody, sui: Balance<SUI>) {
    self.liquid_sui.join(sui);
}

/// Conservative backing: liquid plus every position's pending principal and active valuation.
public(package) fun assets(self: &Custody): u64 {
    let mut total = self.liquid_sui.value();
    self.positions.length().do!(|index| {
        let (_, position) = self.positions.get_entry_by_idx(index);
        total = total + position.value();
    });

    total
}

/// Returns liquid SUI held at face value.
public(package) fun liquid_sui(self: &Custody): u64 {
    self.liquid_sui.value()
}

/// Returns the oldest pending receipt's activation epoch in a pool, if any receipt exists.
public(package) fun oldest_pending_activation_epoch(self: &Custody, pool_id: &ID): Option<u64> {
    let position = &self.positions[pool_id];
    if (position.pending_stakes.is_empty()) {
        option::none()
    } else {
        option::some(position.pending_stakes[0].activation_epoch())
    }
}

/// Returns a pool's active fungible pool-token units, or zero when it has no active stake.
public(package) fun active_pool_tokens(self: &Custody, pool_id: &ID): u64 {
    self.positions[pool_id].active_tokens()
}

/// Whether any position holds active stake.
public(package) fun has_active_stake(self: &Custody): bool {
    let mut has_active = false;
    self.positions.length().do!(|index| {
        let (_, position) = self.positions.get_entry_by_idx(index);
        has_active = has_active || position.active_stake.is_some();
    });

    has_active
}

/// Returns the canonical event snapshot of one pool's position.
public(package) fun position_custody(self: &Custody, pool_id: &ID): events::PositionCustody {
    let position = &self.positions[pool_id];

    events::position_custody(position.pending_sui(), position.active_tokens(), position.active_sui)
}

/// Delegates up to `amount` of liquid SUI above `retain_liquid` to the picked pool and returns
/// how much it delegated.
///
/// Delegates nothing, without aborting, when the stakeable amount is below the native minimum,
/// the pool has no rate for this epoch, or its pending slots are full. Only `amount` can move,
/// so a pick never redirects SUI that was already idle.
public(package) fun stake_pick(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    pool_id: &ID,
    rate: PoolRate,
    amount: u64,
    retain_liquid: u64,
    ctx: &mut TxContext,
): u64 {
    let stakeable = amount.min(self.liquid_sui.value().saturating_sub(retain_liquid));
    if (
        stakeable < constants::native_min_stake_mist!()
            || rate.epoch != ctx.epoch()
            || !self.positions[pool_id].accepts_stake(ctx)
    ) return 0;

    self.stake_position(system_state, pool_id, stakeable, ctx);

    stakeable
}

/// Delegates liquid SUI above `retain_liquid` across the pools that can take it now.
///
/// Eligible pools have a rate for this epoch and a free pending slot. When an even split gives
/// each at least the native minimum, each takes its share and the last in list order also
/// takes the remainder. Otherwise, all of it goes to the eligible pool with the smallest
/// position, the earliest on a tie. Below the native minimum, or with no eligible pool, it
/// stays liquid — still counted at face value — rather than aborting the calling operation.
public(package) fun stake_idle(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    pool_rates: &VecMap<ID, PoolRate>,
    retain_liquid: u64,
    ctx: &mut TxContext,
) {
    let minimum = constants::native_min_stake_mist!();
    let stakeable = self.liquid_sui.value().saturating_sub(retain_liquid);
    if (stakeable < minimum) return;

    let eligible = self.pools_accepting_stake(pool_rates, ctx);
    if (eligible.is_empty()) return;

    let count = eligible.length();
    let even_share = stakeable / count;
    if (even_share < minimum) {
        let smallest = self.smallest_position(&eligible);
        return self.stake_position(system_state, &smallest, stakeable, ctx)
    };

    count.do!(|index| {
        let share = if (index == count - 1) stakeable - even_share * (count - 1) else even_share;
        self.stake_position(system_state, &eligible[index], share, ctx);
    });
}

/// Converts every pending receipt of a pool whose activation epoch has arrived.
public(package) fun activate_pending(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    pool_id: &ID,
    ctx: &mut TxContext,
) {
    while (
        self.oldest_pending_activation_epoch(pool_id).is_some_and!(|epoch| *epoch <= ctx.epoch())
    ) {
        self.activate_oldest_pending(system_state, pool_id, ctx);
    }
}

/// Converts only a pool's oldest pending receipt into its active position.
///
/// Callers guard on a present receipt whose activation epoch has arrived and budget one
/// conversion's floor loss per call.
public(package) fun activate_oldest_pending(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    pool_id: &ID,
    ctx: &mut TxContext,
) {
    let position = &mut self.positions[pool_id];
    let converted = system_state.convert_to_fungible_staked_sui(
        position.pending_stakes.remove(0),
        ctx,
    );
    position.join_active(converted);
}

/// Withdraws a pool's oldest pending receipt to liquid SUI, realizing its rewards.
///
/// This recovery path avoids conversion to pool tokens when fun conversion rounding would
/// consume its buffer. Callers guard on a present receipt.
public(package) fun realize_oldest_pending(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    pool_id: &ID,
    ctx: &mut TxContext,
) {
    let pending = self.positions[pool_id].pending_stakes.remove(0);
    self.liquid_sui.join(system_state.request_withdraw_stake_non_entry(pending, ctx));
}

/// Joins externally activated pool tokens and revalues the pool's combined position.
public(package) fun join_active_at_rate(
    self: &mut Custody,
    pool_id: &ID,
    stake: FungibleStakedSui,
    rate: PoolRate,
) {
    self.positions[pool_id].join_active(stake);
    self.revalue(pool_id, rate);
}

/// Revalues a pool's active position at its exchange rate.
public(package) fun revalue(self: &mut Custody, pool_id: &ID, rate: PoolRate) {
    self.positions[pool_id].revalue_active(rate);
}

/// Moves exactly `amount` MIST out of custody in the vault's order, never the caller's.
///
/// Liquid first, then pending stake across pools by pending principal, largest first, then
/// active stake by `active_sui`, largest first, the earliest on a tie. Each position is touched
/// at most once per phase, so an exit loses at most one native margin per position.
///
/// The native rounding margin carries headroom above the proven three-MIST bound, so bounded
/// rounding drift in a live system upgrade cannot starve an exact redemption. Sufficiency still
/// assumes pool exchange rates never decrease (the framework accrues rewards only and never
/// slashes principal). If a rate ever decreased, `active_sui` could overstate the position and
/// this function would abort with `insufficient_native_redemption` instead of underpaying
/// remaining holders: redemptions fail closed until a package upgrade reprices the ledger.
public(package) fun withdraw_exact(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    amount: u64,
    pool_rates: &VecMap<ID, PoolRate>,
    ctx: &mut TxContext,
): Balance<SUI> {
    self.withdraw_pending_largest_first(system_state, amount, ctx);
    self.redeem_active_largest_first(system_state, amount, pool_rates, ctx);

    assert!(
        self.liquid_sui.value() >= amount,
        blast_sui::errors::insufficient_native_redemption!(),
    );

    self.liquid_sui.split(amount)
}

/// Withdraws every position's native stake into liquid SUI, keeping the positions.
public(package) fun unwind(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
) {
    self.positions.keys().do!(|pool_id| self.unwind_position(system_state, &pool_id, ctx));
}

/// Moves exact liquid SUI between two internal ledgers.
public(package) fun transfer_liquid(self: &mut Custody, to: &mut Custody, amount: u64) {
    to.liquid_sui.join(self.liquid_sui.split(amount));
}

/// Moves `pool_tokens` active tokens of one pool into `to` and revalues both positions.
public(package) fun transfer_active_tokens(
    self: &mut Custody,
    to: &mut Custody,
    pool_id: &ID,
    pool_tokens: u64,
    rate: PoolRate,
    ctx: &mut TxContext,
) {
    let position = &mut self.positions[pool_id];
    let moved = if (pool_tokens >= position.active_tokens()) {
        position.active_stake.extract()
    } else {
        position.active_stake.borrow_mut().split(pool_tokens, ctx)
    };
    position.revalue_active(rate);

    let destination = &mut to.positions[pool_id];
    destination.join_active(moved);
    destination.revalue_active(rate);
}

// === Private Functions ===

/// Delegates exactly `amount` of liquid SUI to a pool that can take it.
fun stake_position(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    pool_id: &ID,
    amount: u64,
    ctx: &mut TxContext,
) {
    let validator = system_state.validator_address_by_pool_id(pool_id);
    let staked = system_state.request_add_stake_non_entry(
        self.liquid_sui.split(amount).into_coin(ctx),
        validator,
        ctx,
    );
    assert!(staked.pool_id() == *pool_id, blast_sui::errors::wrong_delegation_pool!());

    let position = &mut self.positions[pool_id];
    if (position.joins_newest(ctx)) {
        let newest = position.pending_stakes.length() - 1;
        position.pending_stakes[newest].join(staked);
    } else {
        position.pending_stakes.push_back(staked);
    };
}

/// The pools with a rate for this epoch and room for a request, in list order.
fun pools_accepting_stake(
    self: &Custody,
    pool_rates: &VecMap<ID, PoolRate>,
    ctx: &TxContext,
): vector<ID> {
    self.positions.keys().filter!(|pool_id| {
        pool_rates[pool_id].epoch == ctx.epoch() && self.positions[pool_id].accepts_stake(ctx)
    })
}

/// The pool in `pools` with the least staked value, the earliest on a tie.
fun smallest_position(self: &Custody, pools: &vector<ID>): ID {
    let mut smallest = pools[0];
    pools.do_ref!(|pool_id| {
        if (self.positions[pool_id].value() < self.positions[&smallest].value()) {
            smallest = *pool_id;
        };
    });

    smallest
}

/// Funds `amount` from pending principal, visiting each position once, largest first.
fun withdraw_pending_largest_first(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    amount: u64,
    ctx: &mut TxContext,
) {
    let mut pools = self.positions.keys();
    while (self.liquid_sui.value() < amount && !pools.is_empty()) {
        let pool_id = take_largest!(&mut pools, |pool_id| self.positions[pool_id].pending_sui());
        let needed = amount - self.liquid_sui.value();
        self.withdraw_pending(system_state, &pool_id, needed, ctx);
    };
}

/// Funds `amount` from active stake, visiting each position once, largest first.
fun redeem_active_largest_first(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    amount: u64,
    pool_rates: &VecMap<ID, PoolRate>,
    ctx: &mut TxContext,
) {
    let mut pools = self.positions.keys();
    while (self.liquid_sui.value() < amount && !pools.is_empty()) {
        let pool_id = take_largest!(&mut pools, |pool_id| self.positions[pool_id].active_sui);
        if (self.positions[&pool_id].active_stake.is_some()) {
            let position = &self.positions[&pool_id];
            let pool_tokens = math::pool_tokens_for_sui_up(
                amount - self.liquid_sui.value()
                    + constants::native_redemption_rounding_margin!(),
                position.active_tokens(),
                position.active_sui,
            );
            self.redeem_active(system_state, &pool_id, pool_tokens, pool_rates[&pool_id], ctx);
        };
    };
}

/// Withdraws a pool's native stake into liquid SUI, leaving the position empty.
fun unwind_position(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    pool_id: &ID,
    ctx: &mut TxContext,
) {
    while (!self.positions[pool_id].pending_stakes.is_empty()) {
        self.realize_oldest_pending(system_state, pool_id, ctx);
    };
    if (self.positions[pool_id].active_stake.is_some()) {
        self.redeem_all_active(system_state, pool_id, ctx);
    };
}

/// Redeems up to `pool_tokens` of a pool's active tokens and re-floors any remaining position.
fun redeem_active(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    pool_id: &ID,
    pool_tokens: u64,
    rate: PoolRate,
    ctx: &mut TxContext,
) {
    let position = &mut self.positions[pool_id];
    if (pool_tokens >= position.active_tokens()) {
        return self.redeem_all_active(system_state, pool_id, ctx)
    };

    let redeemed = position.active_stake.borrow_mut().split(pool_tokens, ctx);
    let sui_out = system_state.redeem_fungible_staked_sui(redeemed, ctx);

    position.revalue_active(rate);
    self.liquid_sui.join(sui_out);
}

/// Redeems a pool's whole active position, which leaves nothing to revalue.
fun redeem_all_active(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    pool_id: &ID,
    ctx: &TxContext,
) {
    let position = &mut self.positions[pool_id];
    let sui_out = system_state.redeem_fungible_staked_sui(position.active_stake.extract(), ctx);

    position.active_sui = 0;
    self.liquid_sui.join(sui_out);
}

/// Withdraws enough of a pool's pending principal to fund `needed`, newest receipt first so
/// the oldest, soonest-earning receipts stay delegated, preserving a receipt when both native
/// halves can remain at or above the one-SUI minimum.
fun withdraw_pending(
    self: &mut Custody,
    system_state: &mut SuiSystemState,
    pool_id: &ID,
    needed: u64,
    ctx: &mut TxContext,
) {
    let minimum = constants::native_min_stake_mist!();
    let position = &mut self.positions[pool_id];
    let mut remaining = needed;

    while (remaining > 0 && !position.pending_stakes.is_empty()) {
        let newest = position.pending_stakes.length() - 1;
        let receipt_sui = position.pending_stakes[newest].amount();
        let split_amount = remaining.max(minimum);
        let withdrawn = if (split_amount <= receipt_sui.saturating_sub(minimum)) {
            position.pending_stakes[newest].split(split_amount, ctx)
        } else {
            position.pending_stakes.pop_back()
        };
        let sui_out = system_state.request_withdraw_stake_non_entry(withdrawn, ctx);
        remaining = remaining.saturating_sub(sui_out.value());
        self.liquid_sui.join(sui_out);
    }
}

/// Removes and returns the pool with the largest `$value`, the earliest on a tie.
macro fun take_largest($pools: &mut vector<ID>, $value: |&ID| -> u64): ID {
    let pools = $pools;
    let mut largest_index = 0;
    let mut largest_value = 0;
    pools.length().do!(|index| {
        let value = $value(&pools[index]);
        if (value > largest_value) {
            largest_index = index;
            largest_value = value;
        };
    });

    pools.remove(largest_index)
}

/// The summed principal of a position's pending receipts.
fun pending_sui(self: &Position): u64 {
    let mut total = 0;
    self.pending_stakes.do_ref!(|stake| total = total + stake.amount());

    total
}

/// A position's conservative staked value: pending principal plus the active valuation.
fun value(self: &Position): u64 {
    self.pending_sui() + self.active_sui
}

fun active_tokens(self: &Position): u64 {
    if (self.active_stake.is_some()) self.active_stake.borrow().value() else 0
}

/// Whether a request made now joins the newest receipt, which activates next epoch.
fun joins_newest(self: &Position, ctx: &TxContext): bool {
    let count = self.pending_stakes.length();

    count > 0 && self.pending_stakes[count - 1].activation_epoch() == ctx.epoch() + 1
}

/// Whether a request made now joins the newest receipt or fits in a free slot.
fun accepts_stake(self: &Position, ctx: &TxContext): bool {
    self.joins_newest(ctx) || self.pending_stakes.length() < constants::max_pending_stakes!()
}

fun join_active(self: &mut Position, converted: FungibleStakedSui) {
    if (self.active_stake.is_some()) {
        self.active_stake.borrow_mut().join(converted);
    } else {
        self.active_stake.fill(converted);
    };
}

fun revalue_active(self: &mut Position, rate: PoolRate) {
    self.active_sui = math::sui_at_rate_down(self.active_tokens(), rate.sui, rate.pool_tokens);
}

// === Imports ===

use blast_sui::{constants, events, math};

use sui::{balance::{Self, Balance}, sui::SUI, vec_map::{Self, VecMap}};

use sui_system::{staking_pool::{FungibleStakedSui, StakedSui}, sui_system::SuiSystemState};
