// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Recovery accepts a narrow reduction shape; it never replaces the ordinary drift gate.
module blast_boosts_aftermath::rebaseline_checkpoint_tests;

// === Test-Only Types ===

public struct Observed has copy, drop {
    free: u64,
    allocated: u256,
    base: u256,
    quote: u256,
    snapshot_long: u256,
    snapshot_short: u256,
    market_long: u256,
    market_short: u256,
    lot: u64,
    ask: u256,
    bid: u256,
    orders: u64,
    pause: u8,
    frozen: bool,
    position_imr: u256,
    market_imr: u256,
    market_mmr: u256,
}

// === Tests ===

#[test]
fun partial_and_full_reductions_are_accepted_for_both_sides() {
    vector[false, true].do!(|short| {
        let mut before = stored();
        let mut after = reduced();
        if (short) {
            before.base = negative(before.base);
            before.quote = negative(before.quote);
            after.base = negative(after.base);
            after.quote = negative(after.quote);
        };
        before.checkpoint().assert_forced_reduction(&after.checkpoint());
        after.base = 0;
        after.quote = 0;
        before.checkpoint().assert_forced_reduction(&after.checkpoint());
    });
}

#[test]
fun a_reduction_can_keep_collateral_and_inherit_current_market_policy() {
    let mut after = reduced();
    after.allocated = stored().allocated;
    after.pause = 1;
    after.frozen = true;
    after.market_imr = 3;
    after.market_mmr = 2;
    stored().checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
fun recovery_accepts_realized_losses_across_the_collateral_sign_boundary() {
    let mut before = stored();
    let mut after = reduced();
    after.allocated = negative(10);
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
    before.allocated = negative(5);
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
fun forced_reductions_remain_unexpected_to_permissionless_synchronization() {
    let change = stored().checkpoint().classify_preexisting(&reduced().checkpoint());
    assert!(change.is_unexpected_for_testing());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_free_cash_credit() {
    let before = stored();
    let mut after = reduced();
    after.free = 1;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
fun recovery_accepts_realized_profit_from_adl() {
    let before = stored();
    let mut after = reduced();
    after.allocated = stored().allocated + 1;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
fun recovery_accepts_realized_credit_against_negative_collateral() {
    let mut before = stored();
    let mut after = reduced();
    before.allocated = negative(10); after.allocated = negative(5);
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_no_reduction() {
    let before = stored();
    let mut after = reduced();
    after.base = before.base;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_position_growth() {
    let before = stored();
    let mut after = reduced();
    after.base = before.base + 1;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_position_flip() {
    let before = stored();
    let mut after = reduced();
    after.base = negative(after.base); after.quote = negative(after.quote);
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_flat_origin() {
    let mut before = stored();
    let after = reduced();
    before.base = 0; before.quote = 0;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_quote_growth() {
    let before = stored();
    let mut after = reduced();
    after.quote = before.quote + 1;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_quote_flip() {
    let before = stored();
    let mut after = reduced();
    after.quote = negative(after.quote);
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_zero_quote_on_open_position() {
    let before = stored();
    let mut after = reduced();
    after.quote = 0;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_quote_left_on_flat_position() {
    let before = stored();
    let mut after = reduced();
    after.base = 0;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_changed_lot() {
    let before = stored();
    let mut after = reduced();
    after.lot = 2;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_changed_position_margin() {
    let before = stored();
    let mut after = reduced();
    after.position_imr = 2;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_ask_exposure() {
    let before = stored();
    let mut after = reduced();
    after.ask = 1;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_bid_exposure() {
    let before = stored();
    let mut after = reduced();
    after.bid = 1;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_pending_order_count() {
    let before = stored();
    let mut after = reduced();
    after.orders = 1;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_orders_in_stored_checkpoint() {
    let mut before = stored();
    let after = reduced();
    before.orders = 1;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_unsettled_long_funding() {
    let before = stored();
    let mut after = reduced();
    after.snapshot_long = after.market_long - 1;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_unsettled_short_funding() {
    let before = stored();
    let mut after = reduced();
    after.snapshot_short = after.market_short - 1;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

#[test]
#[expected_failure(abort_code = errors::EInvalidRebaseline, location = blast_boosts_aftermath::checkpoint)]
fun recovery_rejects_free_cash_loss() {
    let mut before = stored();
    let mut after = reduced();
    before.free = 2; after.free = 1;
    before.checkpoint().assert_forced_reduction(&after.checkpoint());
}

// === Test Helpers ===

fun stored(): Observed {
    Observed {
        free: 0, allocated: 1_000, base: 1_800, quote: 1_800,
        snapshot_long: 10, snapshot_short: 20, market_long: 10, market_short: 20,
        lot: 1, ask: 0, bid: 0, orders: 0, pause: 0, frozen: false,
        position_imr: 1, market_imr: 1, market_mmr: 1,
    }
}

fun reduced(): Observed {
    let mut after = stored();
    after.allocated = 550;
    after.base = 900;
    after.quote = 900;
    after.market_long = 11;
    after.market_short = 21;
    after.snapshot_long = 11;
    after.snapshot_short = 21;
    after
}

fun checkpoint(self: &Observed): Checkpoint {
    checkpoint::checkpoint_for_testing(
        self.free, self.allocated, self.base, self.quote,
        self.snapshot_long, self.snapshot_short, self.market_long, self.market_short,
        self.lot, self.ask, self.bid, self.orders, self.pause, self.frozen,
        self.position_imr, self.market_imr, self.market_mmr,
    )
}

fun negative(magnitude: u256): u256 {
    std::u256::max_value!() - magnitude + 1
}

// === Imports ===

use blast_boosts_aftermath::{checkpoint::{Self, Checkpoint}, errors};
