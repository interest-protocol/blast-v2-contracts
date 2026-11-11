#!/usr/bin/env python3
"""Check DEX swap arithmetic and lifecycle contracts with Sui Prover."""
import argparse
import os
from pathlib import Path
import re
from shutil import copytree
import subprocess
from tempfile import TemporaryDirectory

from dex_cursor_specs import (
    CURSOR_GRID_SPEC, GRID_BPL, SWAP_GRID_CURVE_SPECS, SWAP_GRID_SPEC,
    SWAP_GRID_STEP_SPEC, TICK_GRID_SPECS, observe_floor_ceiling,
)
from dex_owned_specs import (
    CREDIT_TOTAL_SPEC, EMPTY_FEES_SPEC, OWNED_POSITION_SPECS, REFERENCE_TOTAL_SPECS, SWAP_BOUNDARY_SPECS,
    PROBE_MATH_SUMMARIES, PROBE_TOTAL_BPL, PROBE_TOTAL_SPEC, SWAP_SEARCH_TOTAL_SPECS,
)
from dex_principal_specs import (
    FAST_MUL_DIV_SPEC, INVERSE_SPECS, POSITION_PRICING_SPECS, PRINCIPAL_SPECS, PRINCIPAL_WRAPPER_SPECS, ROUND_BPL,
    SWAP_PRINCIPAL_BPL, SWAP_PRINCIPAL_FEE, SWAP_PRINCIPAL_MATH, SWAP_PRINCIPAL_SUMMARIES,
    SWAP_PRINCIPAL_WIRING_BPL,
)
from dex_solvency_specs import (
    CUSTODY_EVENTS, CUSTODY_SPECS, CURVE_CUSTODY_SUMMARIES, FEE_FUNDING_SPECS,
    SWAP_SETTLEMENT_TOTAL, TICK_FRAMES, TOTAL_SETTLEMENT_EVENT,
    instrument_liquidity_execution, instrument_swap_fee_funding, liquidity_execution_specs,
)
from dex_swap_progress_specs import CURSOR_ACCESSOR, LOOKUP_FOR_PROGRESS, PROGRESS_SPEC, instrument_swap_progress
from dex_tick_specs import LOOKUP_RETURN_BPL, LOOKUP_RETURN_SPECS, LOOKUP_SPECS, LOOKUP_TOTAL_SPECS, SCAN_BPL
from verify_dex_swaps import SOURCE, check_source_hashes

ROOT = Path(__file__).resolve().parents[1]

# The prover's table model looks up these spec-only natives in the framework.
# They are absent from the older framework revision pinned by the DEX.
TABLE_NATIVES = """\
#[mode(spec), ext(spec_only)]
public native fun borrow_or_unknown<K: copy + drop + store, V: store>(t: &Table<K, V>, k: K): &V;

#[mode(spec), ext(spec_only)]
public native fun add_pure<K: copy + drop + store, V: store>(t: &Table<K, V>, k: K, v: &V): &Table<K, V>;

#[mode(spec), ext(spec_only)]
public native fun remove_pure<K: copy + drop + store, V: store>(t: &Table<K, V>, k: K): &Table<K, V>;
"""

PRICE_SPEC = """\
module blast_fun_dex::sqrt_price_specs;

// === Private Functions ===

#[mode(spec), ext(spec(prove, target = sqrt_price_math::next_price))]
fun quote_input_next_price(start: u256, liquidity: u128, net: u64, up: bool): u256 {
    requires(up && start > 0 && start < (1u256 << 160) && liquidity > 0);
    // The SMT swap model discharges this bound for every u64 input.
    requires(((net as u256) << 96) < (1u256 << 160));
    asserts(true);
    let next = sqrt_price_math::next_price(start, liquidity, net, up);
    ensures(next >= start);
    ensures(next < (1u256 << 161));
    next
}

// === Imports ===

use blast_fun_dex::sqrt_price_math;
use prover::prover::{asserts, ensures, requires};

#[mode(spec), ext(spec(target = sqrt_price_math::output_delta_x64, ignore_abort))]
fun output_delta_for_budget(start: u256, end: u256, liquidity: u128, up: bool): u256 {
    sqrt_price_math::output_delta_x64(start, end, liquidity, up)
}
"""

FEE_TOTAL_SPECS = """\
#[mode(spec), ext(spec(prove, target = preceding_budget))]
fun preceding_budget_total_spec(step: &SwapStep, budget: u64): u64 {
    prover::prover::requires(step.net <= budget && step.fee <= step.net);
    let gross = (step.net as u128) + (step.fee as u128);
    prover::prover::requires(gross > (budget as u128));
    prover::prover::asserts(true);
    let next = preceding_budget(step, budget);
    let excess = gross - (budget as u128);
    let skip = if (excess > 2) (excess - 2) * 9 / 10 else 0;
    prover::prover::ensures((next as u128) + 1 + skip == (step.net as u128));
    prover::prover::ensures(next < step.net && next < budget);
    next
}

#[mode(spec), ext(spec(prove, target = fee_up))]
fun fee_up_total_spec(self: &FeeQuote): u64 {
    let unit = 1u256 << 96;
    prover::prover::requires(self.upper_x96 <= 18446744073709551615u256 * unit);
    prover::prover::asserts(true);
    let atoms = fee_up(self);
    let upper = (atoms as u256) * unit;
    prover::prover::ensures(self.upper_x96 <= upper);
    prover::prover::ensures(atoms == 0 || (upper >= unit && upper - unit < self.upper_x96));
    atoms
}

"""

FEE_SPECS = """\
#[mode(spec), ext(spec(prove, target = affordable))]
fun affordable_spec(step: &SwapStep, budget: u64): bool {
    prover::prover::asserts(true);
    let result = affordable(step, budget);
    let gross = (step.net as u128) + (step.fee as u128);
    prover::prover::ensures(result == (gross <= (budget as u128)));
    result
}

// The budget proof consumes the successful return contract. Totality on an
// admitted rejected probe is checked independently below.
#[mode(spec), ext(spec(prove, target = preceding_budget, ignore_abort))]
fun preceding_budget_spec(step: &SwapStep, budget: u64): u64 {
    let next = preceding_budget(step, budget);
    let gross = (step.net as u128) + (step.fee as u128);
    let excess = gross.saturating_sub(budget as u128);
    let skip = excess.saturating_sub(2) * 9 / 10;
    prover::prover::ensures(step.net <= budget && (budget as u128) <= gross);
    prover::prover::ensures((next as u128) + 1 + skip == (step.net as u128));
    prover::prover::ensures(next < step.net);
    next
}

#[mode(spec), ext(spec(prove, target = fee_up, ignore_abort))]
fun fee_up_spec(self: &FeeQuote): u64 {
    let unit = 1u256 << 96;
    let atoms = fee_up(self);
    let upper = (atoms as u256) * unit;
    prover::prover::ensures(self.upper_x96 <= upper);
    prover::prover::ensures(atoms == 0 || (upper >= unit && upper - unit < self.upper_x96));
    atoms
}

#[mode(spec), ext(spec(prove, target = multiply))]
fun multiply_spec(first: Interval, second: Interval): Interval {
    prover::prover::requires(first.lower == 0 || second.lower <= std::u256::max_value!() / first.lower);
    prover::prover::requires(first.upper == 0 || second.upper <= std::u256::max_value!() / first.upper);
    prover::prover::asserts(true);
    let result = multiply(first, second);
    let numerator = first.upper * second.upper;
    let rounded = numerator / ONE + if (numerator % ONE > 0) 1 else 0;
    prover::prover::ensures(result.lower == first.lower * second.lower / ONE && result.upper == rounded);
    result
}

#[mode(spec), ext(spec(prove, target = divide))]
fun divide_spec(first: Interval, second: Interval): Interval {
    prover::prover::requires(second.lower > 0 && second.upper > 0);
    prover::prover::requires(first.lower <= std::u256::max_value!() / ONE);
    prover::prover::requires(first.upper <= std::u256::max_value!() / ONE);
    prover::prover::asserts(true);
    let result = divide(first, second);
    let numerator = first.upper * ONE;
    let rounded = numerator / second.lower + if (numerator % second.lower > 0) 1 else 0;
    prover::prover::ensures(result.lower == first.lower * ONE / second.upper && result.upper == rounded);
    result
}

// Pricing is opaque here. The compiled trial checks the net before narrowing.
#[mode(spec), ext(spec(target = sqrt_price_math::next_price, ignore_abort))]
fun next_price_for_trial(start: u256, liquidity: u128, net: u64, up: bool): u256 {
    sqrt_price_math::next_price(start, liquidity, net, up)
}

#[mode(spec), ext(spec(target = sqrt_price_math::input_delta, ignore_abort))]
fun input_for_trial(start: u256, end: u256, liquidity: u128, up: bool): u256 {
    sqrt_price_math::input_delta(start, end, liquidity, up)
}

#[mode(spec), ext(spec(target = quote, ignore_abort))]
fun quote_for_trial(self: &ContinuousPath, start: u256, end: u256, net: u64): FeeQuote {
    quote(self, start, end, net)
}

#[mode(spec), ext(spec(prove, target = trial, ignore_abort, include(
    a = next_price_for_trial, b = input_for_trial, c = quote_for_trial,
)))]
fun trial_for_budget(
    self: &ContinuousPath,
    start: u256,
    limit: u256,
    liquidity: u128,
    net_budget: u64,
    up: bool,
): SwapStep {
    let result = trial(self, start, limit, liquidity, net_budget, up);
    prover::prover::ensures(result.net >= 0 && result.net <= net_budget && result.fee >= 0);
    result
}

#[mode(spec), ext(spec_only(loop_inv(target = swap_step)), no_abort)]
#[allow(unused_function)]
fun swap_step_well_formed(best: SwapStep): bool {
    best.net >= 0 && best.fee >= 0
}

#[mode(spec), ext(spec(prove, target = swap_step, ignore_abort,
    include(a = trial_for_budget, b = blast_fun_dex::sqrt_price_specs::output_delta_for_budget,
        c = preceding_budget_spec)))]
fun swap_step_budget_spec(
    self: &ContinuousPath,
    start: u256,
    limit: u256,
    liquidity: u128,
    budget: u64,
    up: bool,
): (u256, u64, u256, u64) {
    let (price, spent, output, fee) = swap_step(self, start, limit, liquidity, budget, up);
    prover::prover::ensures(fee <= spent && spent <= budget);
    (price, spent, output, fee)
}

// Constructing a fee path takes no mutable reference to the pool.
#[mode(spec), ext(spec(target = new, ignore_abort))]
fun new_for_accounting(settings: LpFee, reference_x96: u256): ContinuousPath {
    new(settings, reference_x96)
}

"""

EVENT_SPEC = """\
// The native event boundary receives only copyable event data.
#[mode(spec), ext(spec(target = swapped, ignore_abort))]
fun swapped_for_settlement(
    pool_id: ID,
    sender: address,
    is_asset_input: bool,
    input_spent: u64,
    output_amount: u64,
    lp_fee_amount: u64,
    sqrt_price_after_x96: u256,
) {
    swapped(pool_id, sender, is_asset_input, input_spent, output_amount, lp_fee_amount, sqrt_price_after_x96)
}

"""

CURVE_TRANSITION_SPECS = """\
#[mode(spec), ext(spec(prove, target = cross, ignore_abort))]
fun cross_spec(self: &mut Curve, index: u32, up: bool) {
    let present = self.ticks.contains(index);
    let tick = table::borrow_or_unknown(&self.ticks, index);
    let leaving = if (up) tick.ends else tick.starts;
    let entering = if (up) tick.starts else tick.ends;
    let liquidity = self.liquidity;
    let total = self.total_liquidity;
    let growth = self.growth;
    let outside = tick.outside;
    let starts = tick.starts;
    let ends = tick.ends;
    let price = tick.sqrt_price_x96;
    cross(self, index, up);
    prover::prover::ensures(present && (up || index > 0) && leaving <= liquidity);
    prover::prover::ensures(if (up) self.index == index else (self.index as u64) + 1 == (index as u64));
    prover::prover::ensures((self.liquidity as u256) + (leaving as u256) == (liquidity as u256) + (entering as u256));
    prover::prover::ensures(self.total_liquidity == total && self.growth == growth);
    prover::prover::ensures(self.ticks.contains(index));
    let tick = table::borrow_or_unknown(&self.ticks, index);
    prover::prover::ensures(tick.starts == starts && tick.ends == ends && tick.sqrt_price_x96 == price);
    prover::prover::ensures(tick.outside == subtract(growth, outside));
}

#[mode(spec), ext(spec(prove, target = credit, ignore_abort))]
fun credit_spec(self: &mut Curve, asset: u64, quote: u64) {
    let liquidity = self.liquidity;
    let index = self.index;
    let total = self.total_liquidity;
    let growth = self.growth;
    credit(self, asset, quote);
    prover::prover::ensures(liquidity > 0);
    prover::prover::ensures(self.liquidity == liquidity && self.index == index && self.total_liquidity == total);
    if (liquidity > 0) {
        prover::prover::ensures(self.growth.asset == wrapping_add(growth.asset, ((asset as u256) << 128) / (liquidity as u256)));
        prover::prover::ensures(self.growth.quote == wrapping_add(growth.quote, ((quote as u256) << 128) / (liquidity as u256)));
    };
}

"""

CURVE_SPECS = CURVE_TRANSITION_SPECS + """\
#[mode(spec), ext(spec(target = tick_math::sqrt_price_x96, ignore_abort))]
fun initialized_tick_price(index: u32): u256 {
    tick_math::sqrt_price_x96(index)
}
"""

BITMAP_SPECS = """\
#[mode(spec), ext(spec_only, no_abort)]
fun bitmap_with_bit(bits: u256, bit: u8, present: bool): u256 {
    let mask = 1u256 << bit;
    if (present) bits | mask else bits & (u256::max_value!() ^ mask)
}

#[mode(spec), ext(spec_only, no_abort)]
fun bitmap_after(table: &Table<u32, u256>, key: u32, bit: u8, present: bool): u256 {
    if (table.contains(key)) bitmap_with_bit(bitmap(table, key), bit, present)
    else if (present) 1u256 << bit
    else 0
}

#[mode(spec), ext(spec(prove, target = change_bitmap, ignore_abort))]
fun change_bitmap_spec(table: &mut Table<u32, u256>, key: u32, bit: u8, present: bool): bool {
    // Z3 proves positivity of the one-bit mask for every u8 bit.
    let mask_is_valid = (1u256 << bit) > 0;
    let expected = bitmap_after(table, key, bit, present);
    let other = prover::prover::fresh<u32>();
    let other_present = table.contains(other);
    let other_bits = bitmap(table, other);
    let live = change_bitmap(table, key, bit, present);
    if (mask_is_valid) {
        prover::prover::ensures(live == (expected != 0));
        prover::prover::ensures(table.contains(key) == live && bitmap(table, key) == expected);
    };
    prover::prover::ensures(other == key || (other_present == table.contains(other)
        && other_bits == bitmap(table, other)));
    live
}

#[mode(spec), ext(spec_only, no_abort)]
fun bitmap_index_is_valid(index: u32): bool {
    let word = index >> 8;
    let group = word >> 8;
    group < 256 && (1u256 << ((index % 256) as u8)) > 0 && (1u256 << ((word % 256) as u8)) > 0
}

#[mode(spec), ext(spec(prove, target = set_initialized, ignore_abort, include = change_bitmap_spec))]
fun set_initialized_spec(self: &mut Curve, index: u32, present: bool) {
    // Z3 checks that valid tick indexes satisfy this in the bitvector model.
    let valid = bitmap_index_is_valid(index);
    let word = index >> 8;
    let group = word >> 8;
    let word_bit = (index % 256) as u8;
    let group_bit = (word % 256) as u8;
    let word_after = bitmap_after(&self.words, word, word_bit, present);
    let group_after = bitmap_after(&self.groups, group, group_bit, word_after != 0);
    let top_after = if (group < 256) bitmap_with_bit(self.group_index, group as u8, group_after != 0) else 0;
    let index_before = self.index;
    let liquidity = self.liquidity;
    let total = self.total_liquidity;
    let growth = self.growth;
    let tick_present = self.ticks.contains(index);
    let tick = table::borrow_or_unknown(&self.ticks, index);
    let (starts, ends, outside, price) = (tick.starts, tick.ends, tick.outside, tick.sqrt_price_x96);
    set_initialized(self, index, present);
    if (valid) {
        prover::prover::ensures(bitmap(&self.words, word) == word_after);
        prover::prover::ensures(bitmap(&self.groups, group) == group_after);
        prover::prover::ensures(self.group_index == top_after);
    };
    prover::prover::ensures(self.index == index_before && self.liquidity == liquidity);
    prover::prover::ensures(self.total_liquidity == total && self.growth == growth);
    prover::prover::ensures(self.ticks.contains(index) == tick_present);
    if (tick_present) {
        let tick = table::borrow_or_unknown(&self.ticks, index);
        prover::prover::ensures(tick.starts == starts && tick.ends == ends);
        prover::prover::ensures(tick.outside == outside && tick.sqrt_price_x96 == price);
    };
}
"""

TICK_AND_FEE_SPECS = """\
#[mode(spec), ext(spec(prove, target = change_tick, ignore_abort, TICK_INCLUDES))]
fun change_tick_spec(self: &mut Curve, index: u32, start: bool, delta: u128, add: bool) {
    prover::prover::requires(index <= 2 * constants::max_tick!());
    let present = self.ticks.contains(index);
    let tick = table::borrow_or_unknown(&self.ticks, index);
    let starts = if (present) tick.starts else 0;
    let ends = if (present) tick.ends else 0;
    let outside = if (present) tick.outside else if (index <= self.index) self.growth else zero();
    let price = tick.sqrt_price_x96;
    let index_before = self.index;
    let liquidity = self.liquidity;
    let total = self.total_liquidity;
    let growth = self.growth;
    change_tick(self, index, start, delta, add);
    let remains = if (add) starts > 0 || ends > 0 || delta > 0
        else if (start) starts > delta || ends > 0
        else starts > 0 || ends > delta;
    prover::prover::ensures(self.index == index_before && self.liquidity == liquidity);
    prover::prover::ensures(self.total_liquidity == total && self.growth == growth);
    prover::prover::ensures(self.ticks.contains(index) == remains);
    let updated = table::borrow_or_unknown(&self.ticks, index);
    let starts_after = if (remains) updated.starts else 0;
    let ends_after = if (remains) updated.ends else 0;
    prover::prover::ensures(liquidity_delta(starts, starts_after, if (start) delta else 0, add));
    prover::prover::ensures(liquidity_delta(ends, ends_after, if (start) 0 else delta, add));
    if (remains) {
        prover::prover::ensures(updated.outside == outside && (!present || updated.sqrt_price_x96 == price));
    };
}

#[mode(spec), ext(spec(prove, target = take_fees))]
fun take_fees_spec(self: &mut PositionFees, full_exit: bool): (u64, u64) {
    let owed = self.owed_x128;
    let asset_floor = owed.asset >> 128;
    let quote_floor = owed.quote >> 128;
    prover::prover::requires(asset_floor >= 0 && asset_floor <= (std::u64::max_value!() as u256));
    prover::prover::requires(quote_floor >= 0 && quote_floor <= (std::u64::max_value!() as u256));
    prover::prover::asserts(true);
    let checkpoint = self.checkpoint;
    let (asset, quote) = take_fees(self, full_exit);
    prover::prover::ensures(self.checkpoint == checkpoint);
    prover::prover::ensures((asset as u256) == asset_floor && (quote as u256) == quote_floor);
    prover::prover::ensures(self.owed_x128.asset == if (full_exit) 0 else owed.asset % Q128);
    prover::prover::ensures(self.owed_x128.quote == if (full_exit) 0 else owed.quote % Q128);
    (asset, quote)
}

#[mode(spec), ext(spec_only, no_abort)]
fun liquidity_delta(before: u128, after: u128, delta: u128, add: bool): bool {
    if (add) (after as u256) == (before as u256) + (delta as u256)
    else (after as u256) + (delta as u256) == (before as u256)
}

#[mode(spec), ext(spec_only, no_abort)]
fun inside_snapshot(self: &Curve, lower: u32, upper: u32): Growth {
    if (!self.ticks.contains(lower) || !self.ticks.contains(upper)) return zero();
    let below = table::borrow_or_unknown(&self.ticks, lower).outside;
    let above = table::borrow_or_unknown(&self.ticks, upper).outside;
    if (!growth_is_valid(below) || !growth_is_valid(above) || !growth_is_valid(self.growth)) return zero();
    if (self.index < lower) subtract(below, above)
    else if (self.index >= upper) subtract(above, below)
    else subtract(subtract(self.growth, below), above)
}

#[mode(spec), ext(spec_only, no_abort)]
fun growth_is_valid(value: Growth): bool {
    value.asset >= 0 && value.asset <= u256::max_value!()
        && value.quote >= 0 && value.quote <= u256::max_value!()
}

#[mode(spec), ext(spec(prove, target = growth_inside, ignore_abort))]
fun growth_inside_spec(self: &Curve, lower: u32, upper: u32): Growth {
    let below = table::borrow_or_unknown(&self.ticks, lower).outside;
    let above = table::borrow_or_unknown(&self.ticks, upper).outside;
    let valid = growth_is_valid(below) && growth_is_valid(above) && growth_is_valid(self.growth);
    let inside = growth_inside(self, lower, upper);
    prover::prover::ensures(self.ticks.contains(lower) && self.ticks.contains(upper));
    prover::prover::ensures(valid && inside == inside_snapshot(self, lower, upper));
    inside
}
"""

# State the successful-return accrual equation in mathematical integers.
LIQUIDITY_BPL = """\
procedure {:inline 1} $0_curve_owed_after_accrual(after: int, before: int, delta: int, stake: int)
    returns (matches: bool) {
    matches := after == before + delta * stake;
}
"""

LIQUIDITY_SPEC = """\
#[mode(spec), ext(spec_only, no_abort)]
native fun owed_after_accrual(after: u256, before: u256, delta: u256, stake: u128): bool;

#[mode(spec), ext(spec(prove, target = change_liquidity, ignore_abort, include(
    a = change_tick_spec, b = growth_inside_spec,
), extra_bpl = b"liquidity.bpl", boogie_opt = b"vcsSplitOnEveryAssert"))]
fun change_liquidity_spec(
    self: &mut Curve, fees: &mut PositionFees, lower: u32, upper: u32, old: u128, delta: u128, add: bool,
) {
    prover::prover::requires(lower < upper && upper <= 2 * constants::max_tick!());
    let liquidity = self.liquidity;
    let total = self.total_liquidity;
    let index = self.index;
    let growth = self.growth;
    let owed = fees.owed_x128;
    let checkpoint = fees.checkpoint;
    let before = if (old > 0) inside_snapshot(self, lower, upper) else checkpoint;
    let accrued = subtract(before, checkpoint);
    change_liquidity(self, fees, lower, upper, old, delta, add);
    let active_delta = if (lower <= index && index < upper) delta else 0;
    prover::prover::ensures(liquidity_delta(total, self.total_liquidity, delta, add));
    prover::prover::ensures(liquidity_delta(liquidity, self.liquidity, active_delta, add));
    prover::prover::ensures(self.index == index && self.growth == growth);
    prover::prover::ensures(owed_after_accrual(fees.owed_x128.asset, owed.asset, accrued.asset, old));
    prover::prover::ensures(owed_after_accrual(fees.owed_x128.quote, owed.quote, accrued.quote, old));
    if (old > 0) {
        prover::prover::ensures(fees.checkpoint == before);
    } else {
        prover::prover::ensures(fees.owed_x128 == owed && fees.checkpoint == inside_snapshot(self, lower, upper));
    };
}
"""

LOOKUP_FOR_BUDGET = """\
// The pool's budget invariant holds for any tick lookup and curve update.
#[mode(spec), ext(spec(target = next_tick, ignore_abort))]
fun next_tick_for_budget(self: &Curve, up: bool): Option<u32> {
    next_tick(self, up)
}

"""

CURVE_SWAP_SUMMARIES = """\
#[mode(spec), ext(spec(target = tick_price, ignore_abort))]
fun tick_price_for_budget(self: &Curve, index: u32): u256 {
    tick_price(self, index)
}

#[mode(spec), ext(spec(target = move_inside, ignore_abort))]
fun move_inside_for_budget(self: &mut Curve, price_x96: u256, neighbor: Option<u32>, up: bool) {
    move_inside(self, price_x96, neighbor, up)
}

"""

POOL_SPECS = """\
// Object identity is a VM concern. Coin wrapping and unwrapping remain inline.
#[mode(spec), ext(spec(target = sui::object::new, ignore_abort))]
fun new_uid_for_swap(ctx: &mut TxContext): UID {
    sui::object::new(ctx)
}

#[mode(spec), ext(spec(target = sui::object::delete, ignore_abort))]
fun delete_uid_for_swap(id: UID) {
    sui::object::delete(id)
}

#[mode(spec), ext(spec(prove, target = begin_swap_asset_to_quote, ignore_abort,
    include = delete_uid_for_swap))]
fun begin_asset_swap_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    payment: Coin<Asset>,
    sqrt_price_limit_x96: u256,
): SwapRequest<Asset, Quote> {
    let amount = payment.value();
    let result = begin_swap_asset_to_quote(self, package_version, payment, sqrt_price_limit_x96);
    prover::prover::ensures(self.is_in_operation && result.is_asset_input && amount > 0);
    prover::prover::ensures(result.pool_id == self.id.to_inner());
    prover::prover::ensures(result.asset_payment.value() == amount && result.quote_payment.value() == 0);
    prover::prover::ensures(result.approval.hook == self.hooks.before_swap && !result.approval.is_approved);
    prover::prover::ensures(result.sqrt_price_limit_x96 == sqrt_price_limit_x96
        && sqrt_price_limit_x96 < self.sqrt_price_x96 && sqrt_price_limit_x96 > constants::min_sqrt_price_x96!());
    result
}

#[mode(spec), ext(spec(prove, target = begin_swap_quote_to_asset, ignore_abort,
    include = delete_uid_for_swap))]
fun begin_quote_swap_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    payment: Coin<Quote>,
    sqrt_price_limit_x96: u256,
): SwapRequest<Asset, Quote> {
    let amount = payment.value();
    let result = begin_swap_quote_to_asset(self, package_version, payment, sqrt_price_limit_x96);
    prover::prover::ensures(self.is_in_operation && !result.is_asset_input && amount > 0);
    prover::prover::ensures(result.pool_id == self.id.to_inner());
    prover::prover::ensures(result.asset_payment.value() == 0 && result.quote_payment.value() == amount);
    prover::prover::ensures(result.approval.hook == self.hooks.before_swap && !result.approval.is_approved);
    prover::prover::ensures(result.sqrt_price_limit_x96 == sqrt_price_limit_x96
        && sqrt_price_limit_x96 > self.sqrt_price_x96 && sqrt_price_limit_x96 < constants::max_sqrt_price_x96!());
    result
}

#[mode(spec), ext(spec(prove, target = finish, ignore_abort, include = new_uid_for_swap))]
fun finish_swap_spec<Asset, Quote, Operation>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    completion: Completion<Asset, Quote, Operation>,
    min_asset_output: u64,
    min_quote_output: u64,
    ctx: &mut TxContext,
): (Coin<Asset>, Coin<Quote>) {
    let amount_asset = completion.asset_output.value();
    let amount_quote = completion.quote_output.value();
    let pool_matches = completion.pool_id == self.id.to_inner();
    let approved = completion.approval.hook.is_none() || completion.approval.is_approved;
    let (asset, quote) = finish(self, package_version, completion, min_asset_output, min_quote_output, ctx);
    prover::prover::ensures(!self.is_in_operation && pool_matches && approved);
    prover::prover::ensures(asset.value() == amount_asset && amount_asset >= min_asset_output);
    prover::prover::ensures(quote.value() == amount_quote && amount_quote >= min_quote_output);
    (asset, quote)
}

#[mode(spec), ext(spec(prove, target = settle_swap, ignore_abort,
    include = blast_events::swapped_for_settlement))]
fun settle_swap_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    is_asset_input: bool,
    asset_payment: Balance<Asset>,
    quote_payment: Balance<Quote>,
    lp_fee_amount: u64,
    input_spent: u64,
    output_amount: u64,
    sqrt_price_after_x96: u256,
    ctx: &TxContext,
): Completion<Asset, Quote, Swap> {
    let asset_before = (self.asset_reserve.value() as u128)
        + (self.asset_fees.value() as u128) + (asset_payment.value() as u128);
    let quote_before = (self.quote_reserve.value() as u128)
        + (self.quote_fees.value() as u128) + (quote_payment.value() as u128);
    let payment_asset = asset_payment.value() as u128;
    let payment_quote = quote_payment.value() as u128;
    let asset_reserve = self.asset_reserve.value() as u128;
    let quote_reserve = self.quote_reserve.value() as u128;
    let asset_fees = self.asset_fees.value() as u128;
    let quote_fees = self.quote_fees.value() as u128;
    let result = settle_swap(
        self, is_asset_input, asset_payment, quote_payment, lp_fee_amount,
        input_spent, output_amount, sqrt_price_after_x96, ctx,
    );
    prover::prover::ensures(self.sqrt_price_x96 == sqrt_price_after_x96);
    prover::prover::ensures(result.pool_id == self.id.to_inner());
    prover::prover::ensures(result.approval.hook == self.hooks.after_swap && !result.approval.is_approved);
    prover::prover::ensures(asset_before == (self.asset_reserve.value() as u128)
        + (self.asset_fees.value() as u128) + (result.asset_output.value() as u128));
    prover::prover::ensures(quote_before == (self.quote_reserve.value() as u128)
        + (self.quote_fees.value() as u128) + (result.quote_output.value() as u128));
    let returned_asset = result.asset_output.value() as u128;
    let returned_quote = result.quote_output.value() as u128;
    prover::prover::ensures(if (is_asset_input) {
        returned_asset + (input_spent as u128) == payment_asset
            && returned_quote == payment_quote + (output_amount as u128)
            && (self.asset_reserve.value() as u128) + (lp_fee_amount as u128)
                == asset_reserve + (input_spent as u128)
            && (self.quote_reserve.value() as u128) + (output_amount as u128) == quote_reserve
            && (self.asset_fees.value() as u128) == asset_fees + (lp_fee_amount as u128)
            && (self.quote_fees.value() as u128) == quote_fees
    } else {
        returned_quote + (input_spent as u128) == payment_quote
            && returned_asset == payment_asset + (output_amount as u128)
            && (self.quote_reserve.value() as u128) + (lp_fee_amount as u128)
                == quote_reserve + (input_spent as u128)
            && (self.asset_reserve.value() as u128) + (output_amount as u128) == asset_reserve
            && (self.quote_fees.value() as u128) == quote_fees + (lp_fee_amount as u128)
            && (self.asset_fees.value() as u128) == asset_fees
    });
    result
}

#[mode(spec), ext(spec_only(loop_inv(target = swap_amounts)), no_abort)]
#[allow(unused_function)]
fun swap_amounts_budget_invariant<Asset, Quote>(
    self: &Pool<Asset, Quote>,
    __old_self: &Pool<Asset, Quote>,
    input_value: u64, remaining: u64, total_fee: u64, steps: u64, output_x64: u256,
): bool {
    remaining >= 0 && total_fee >= 0 && steps >= 0 && output_x64 >= 0
        && (remaining as u128) + (total_fee as u128) <= (input_value as u128)
        && steps <= constants::max_swap_steps!()
        && self.asset_reserve.value() == __old_self.asset_reserve.value()
        && self.quote_reserve.value() == __old_self.quote_reserve.value()
        && self.asset_fees.value() == __old_self.asset_fees.value()
        && self.quote_fees.value() == __old_self.quote_fees.value()
}

#[mode(spec), ext(spec(prove, target = swap_amounts, ignore_abort, include(
    a = continuous_fee::swap_step_budget_spec,
    b = blast_fun_dex::curve::next_tick_for_budget,
    c = blast_fun_dex::curve::tick_price_for_budget,
    d = blast_fun_dex::curve::credit_spec,
    e = blast_fun_dex::curve::cross_spec,
    f = blast_fun_dex::curve::move_inside_for_budget,
)))]
fun swap_amounts_budget_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    is_asset_input: bool,
    input_value: u64,
    sqrt_price_limit_x96: u256,
    fee_path: ContinuousPath,
    allow_zero_partial: bool,
): (u64, u64, u256, u64) {
    let asset_reserve = self.asset_reserve.value();
    let quote_reserve = self.quote_reserve.value();
    let asset_fees = self.asset_fees.value();
    let quote_fees = self.quote_fees.value();
    let reserve = if (is_asset_input) quote_reserve else asset_reserve;
    let (spent, output, price, fee) = swap_amounts(
        self, is_asset_input, input_value, sqrt_price_limit_x96, fee_path, allow_zero_partial,
    );
    prover::prover::ensures(fee <= spent && spent <= input_value);
    prover::prover::ensures(output <= reserve);
    prover::prover::ensures(allow_zero_partial || output > 0);
    prover::prover::ensures(self.asset_reserve.value() == asset_reserve && self.quote_reserve.value() == quote_reserve);
    prover::prover::ensures(self.asset_fees.value() == asset_fees && self.quote_fees.value() == quote_fees);
    (spent, output, price, fee)
}

#[mode(spec), ext(spec(prove, target = execute_swap_inner, ignore_abort, include(
    a = swap_amounts_budget_spec,
    b = settle_swap_spec,
    c = continuous_fee::new_for_accounting,
)))]
fun execute_swap_accounting_spec<Asset, Quote>(
    self: &mut Pool<Asset, Quote>,
    package_version: &PackageVersion<BLAST_FUN_DEX>,
    request: SwapRequest<Asset, Quote>,
    clock: &Clock,
    allow_zero_partial: bool,
    ctx: &TxContext,
): Completion<Asset, Quote, Swap> {
    let payment_asset = request.asset_payment.value();
    let payment_quote = request.quote_payment.value();
    let is_asset_input = request.is_asset_input;
    let pool_matches = request.pool_id == self.id.to_inner();
    let approved = request.approval.hook.is_none() || request.approval.is_approved;
    let asset_before = (self.asset_reserve.value() as u128)
        + (self.asset_fees.value() as u128) + (payment_asset as u128);
    let quote_before = (self.quote_reserve.value() as u128)
        + (self.quote_fees.value() as u128) + (payment_quote as u128);
    let result = execute_swap_inner(self, package_version, request, clock, allow_zero_partial, ctx);
    prover::prover::ensures(pool_matches && approved);
    prover::prover::ensures(asset_before == (self.asset_reserve.value() as u128)
        + (self.asset_fees.value() as u128) + (result.asset_output.value() as u128));
    prover::prover::ensures(quote_before == (self.quote_reserve.value() as u128)
        + (self.quote_fees.value() as u128) + (result.quote_output.value() as u128));
    prover::prover::ensures(allow_zero_partial || if (is_asset_input) {
        result.quote_output.value() > payment_quote
    } else {
        result.asset_output.value() > payment_asset
    });
    result
}

"""


def insert_specs(path, marker, specs):
    source = path.read_text()
    if source.count(marker) != 1:
        raise SystemExit(f"Could not locate the specification insertion point in {path.name}.")
    path.write_text(source.replace(marker, specs + marker, 1))


def stage_framework(checkout, work, manifest):
    source = manifest.read_text()
    pin = re.search(r'^Sui = .*rev = "([a-f0-9]{40})".*$', source, re.MULTILINE)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
    if not pin or revision != pin[1]:
        raise SystemExit("The Sui checkout must be at the framework revision pinned in the DEX manifest.")
    packages = checkout / "crates/sui-framework/packages"
    names = ("sui-framework", "move-stdlib")
    paths = [str((packages / name).relative_to(checkout)) for name in names]
    changes = subprocess.check_output(
        ["git", "status", "--porcelain", "--untracked-files=all", "--", *paths],
        cwd=checkout, text=True,
    )
    if changes:
        raise SystemExit("The pinned Sui framework packages must have clean source trees.")
    for name in names:
        copytree(packages / name, work / "framework" / name)
    table = work / "framework/sui-framework/sources/table.move"
    with table.open("a") as out:
        out.write("\n" + TABLE_NATIVES)
    manifest.write_text(source.replace(
        pin[0], 'Sui = { local = "../../framework/sui-framework", override = true }',
    ))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sui_prover", type=Path, help="path to the Sui Prover executable")
    parser.add_argument("prover_checkout", type=Path, help="path to the Sui Prover source checkout")
    parser.add_argument("sui_checkout", type=Path, help="path to the DEX-pinned Sui checkout")
    parser.add_argument("--functions", action="append", default=[], help="limit the run to a named function, repeatable")
    parser.add_argument("--timeout", type=int, default=120, help="solver time limit per prover check in seconds")
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("--timeout must be positive")
    prover_source = args.prover_checkout / "packages/prover/sources/prover.move"
    prover_executable = args.sui_prover.resolve(strict=True)
    check_source_hashes()

    with TemporaryDirectory(prefix="blast-dex-move-proof-") as directory:
        work = Path(directory)
        dex = work / "scratch-sui/dex"
        copytree(ROOT / "scratch-sui/dex", dex)
        copytree(ROOT / "sui/governance/admin", work / "sui/governance/admin")

        # Use only the proof primitives so the DEX keeps its own framework pin.
        (work / "prover/sources").mkdir(parents=True)
        (work / "prover/sources/prover.move").write_bytes(prover_source.read_bytes())
        (work / "prover/Move.toml").write_text(
            '[package]\nname = "Prover"\nedition = "2024.beta"\n\n[addresses]\nprover = "0x0"\n'
        )
        (work / "empty-framework").mkdir()
        manifest = dex / "Move.toml"
        stage_framework(args.sui_checkout, work, manifest)
        manifest.write_text(manifest.read_text().replace(
            "[dependencies]\n", '[dependencies]\nProver = { local = "../../prover" }\n', 1
        ))
        (dex / "sources/sqrt_price_specs.move").write_text(PRICE_SPEC)
        fee_path = dex / "sources/fees/continuous_fee.move"
        fee_source = fee_path.read_text()
        insert_specs(fee_path, "// === Test-Only Types ===", FEE_SPECS)
        pool_path = dex / "sources/pool.move"
        pool_source = pool_path.read_text()
        insert_specs(pool_path, "// === Test-Only Functions ===", POOL_SPECS)
        insert_specs(dex / "sources/lib/blast_events.move", "// === Imports ===", EVENT_SPEC)
        curve_path = dex / "sources/curve/curve.move"
        curve_source = curve_path.read_text()

        env = {
            **os.environ,
            "SUI_PROVER_FRAMEWORK_PATH": str(work / "empty-framework"),
            "TOKIO_WORKER_THREADS": "1",
            "RAYON_NUM_THREADS": "1",
        }
        command = [str(prover_executable), "--path", str(dex), "--skip-fetch-latest-git-deps",
                   "--ci", "--force-timeout", "--timeout", str(args.timeout), "--boogie-config", "vcsCores:1"]
        liquidity = "curve::change_liquidity_spec"
        lookup_specs = {"next_tick_spec", "new_bitmap_spec"}
        lookup_total_specs = {"stored_tick_price_total_spec", "next_tick_return_spec"}
        progress_spec = "swap_progress_spec"
        funding_spec = "swap_fee_funding_spec"
        names = {name.split("::")[-1] for name in args.functions}
        fee_total_specs = {"preceding_budget_total_spec", "fee_up_total_spec"}
        search_total_spec = "search_total_spec"
        trial_total_spec = "trial_total_spec"
        cursor_specs = {"floor_grid_spec": "tick_math", "move_inside_grid_spec": "curve", "swap_grid_spec": "pool"}
        principal_runs = (
            (FAST_MUL_DIV_SPEC, {"divide_rounding_spec", "mul_div_fast_spec"}),
            (INVERSE_SPECS, {"next_price_exact_spec"}),
            (PRINCIPAL_WRAPPER_SPECS, {"asset_delta_rounding_spec", "quote_delta_rounding_spec",
                "swap_input_rounding_spec", "swap_output_rounding_spec"}),
        )
        principal_specs = set().union(*(names for _, names in principal_runs))
        custody_specs = {"new_custody_spec", "mint_custody_spec", "burn_custody_spec", "donation_custody_spec"}
        step_principal_specs = {"trial_principal_spec", "swap_step_principal_spec"}
        pricing_spec = "position_amounts_grid_spec"
        total_settlement = "settle_swap_total_spec"
        frame_specs = {"change_tick_frame_spec", "cross_total_frame_spec"}
        owned_specs = {
            "new_owned_position_spec": "pool", "destroy_owned_position_spec": "pool",
            "mint_position_binding_spec": "pool", "burn_position_binding_spec": "pool",
            "open_mint_binding_spec": "pool", "open_burn_binding_spec": "pool",
            "open_swap_total_spec": "pool", "finish_swap_total_spec": "pool",
            "credit_total_spec": "curve", "reference_new_total_spec": "price_reference",
            "reference_observe_total_spec": "price_reference",
        }
        execution_specs = {"execute_add_backing_spec", "execute_remove_backing_spec"}
        other = [name for name in args.functions
                 if name.split("::")[-1] not in {"change_liquidity_spec", progress_spec, funding_spec}
                 | fee_total_specs | lookup_specs | lookup_total_specs | {search_total_spec, trial_total_spec}
                 | custody_specs | execution_specs | cursor_specs.keys()
                 | principal_specs | {pricing_spec, total_settlement} | step_principal_specs | frame_specs | owned_specs.keys()]
        runs = []
        if not args.functions or other:
            includes = "include(a = initialized_tick_price, b = set_initialized_spec)"
            runs.append((other, BITMAP_SPECS, includes))
        if not args.functions or "change_liquidity_spec" in names:
            # This proof uses the same tick postconditions and needs no bitmap
            # contracts in its solver context.
            curve_path.with_name("liquidity.bpl").write_text(LIQUIDITY_BPL)
            runs.append(([liquidity], LIQUIDITY_SPEC, "include = initialized_tick_price"))

        status = 0
        for functions, scoped_specs, tick_includes in runs:
            curve_path.write_text(curve_source)
            tick_specs = TICK_AND_FEE_SPECS.replace("TICK_INCLUDES", tick_includes)
            insert_specs(curve_path, "// === Imports ===",
                         CURVE_SPECS + scoped_specs + tick_specs + LOOKUP_FOR_BUDGET + CURVE_SWAP_SUMMARIES)
            filters = [arg for name in functions for arg in ("--functions", name)]
            result = subprocess.run(command + filters, cwd=work, env=env, check=False)
            status = status or result.returncode
        if not args.functions or fee_total_specs & names:
            pool_path.write_text(pool_source)
            fee_path.write_text(fee_source)
            insert_specs(fee_path, "// === Test-Only Types ===", FEE_TOTAL_SPECS)
            filters = [arg for name in sorted(fee_total_specs if not args.functions else fee_total_specs & names)
                       for arg in ("--functions", f"continuous_fee::{name}")]
            result = subprocess.run(command + filters, cwd=work, env=env, check=False)
            status = status or result.returncode
            fee_path.write_text(fee_source)
            insert_specs(fee_path, "// === Test-Only Types ===", FEE_SPECS)
        if not args.functions or search_total_spec in names:
            pool_path.write_text(pool_source)
            curve_path.write_text(curve_source)
            fee_path.write_text(fee_source)
            insert_specs(fee_path, "// === Test-Only Types ===", FEE_TOTAL_SPECS + SWAP_SEARCH_TOTAL_SPECS)
            result = subprocess.run(command + ["--functions", f"continuous_fee::{search_total_spec}"],
                                    cwd=work, env=env, check=False)
            status = status or result.returncode
            fee_path.write_text(fee_source)
            insert_specs(fee_path, "// === Test-Only Types ===", FEE_SPECS)
        if not args.functions or trial_total_spec in names:
            pool_path.write_text(pool_source)
            curve_path.write_text(curve_source)
            fee_path.write_text(fee_source)
            insert_specs(fee_path, "// === Test-Only Types ===", FEE_TOTAL_SPECS + PROBE_TOTAL_SPEC)
            fee_path.with_name("probe_total.bpl").write_text(PROBE_TOTAL_BPL)
            math_path = curve_path.with_name("sqrt_price_math.move")
            math_source = math_path.read_text()
            math_path.write_text(math_source + "\n" + PROBE_MATH_SUMMARIES)
            result = subprocess.run(command + ["--functions", f"continuous_fee::{trial_total_spec}"],
                                    cwd=work, env=env, check=False)
            status = status or result.returncode
            math_path.write_text(math_source)
            fee_path.write_text(fee_source)
            insert_specs(fee_path, "// === Test-Only Types ===", FEE_SPECS)
        if not args.functions or lookup_specs & names:
            pool_path.write_text(pool_source)
            curve_path.write_text(curve_source)
            curve_path.with_name("nearest_scan.bpl").write_text(SCAN_BPL)
            insert_specs(curve_path, "// === Imports ===", LOOKUP_SPECS)
            filters = [arg for name in sorted(lookup_specs if not args.functions else lookup_specs & names)
                       for arg in ("--functions", f"curve::{name}")]
            result = subprocess.run(command + filters, cwd=work, env=env, check=False)
            status = status or result.returncode
        if not args.functions or lookup_total_specs & names:
            pool_path.write_text(pool_source)
            curve_path.write_text(curve_source)
            curve_path.with_name("lookup_return.bpl").write_text(LOOKUP_RETURN_BPL)
            insert_specs(curve_path, "// === Imports ===", LOOKUP_TOTAL_SPECS + LOOKUP_RETURN_SPECS)
            filters = [arg for name in sorted(lookup_total_specs if not args.functions else lookup_total_specs & names)
                       for arg in ("--functions", f"curve::{name}")]
            result = subprocess.run(command + filters, cwd=work, env=env, check=False)
            status = status or result.returncode
        if not args.functions or progress_spec in names:
            pool_path.write_text(instrument_swap_progress(pool_source))
            curve_path.write_text(curve_source)
            insert_specs(pool_path, "// === Test-Only Functions ===", PROGRESS_SPEC)
            insert_specs(curve_path, "// === Imports ===",
                         CURSOR_ACCESSOR + CURVE_SPECS + LOOKUP_FOR_PROGRESS + CURVE_SWAP_SUMMARIES)
            result = subprocess.run(command + ["--functions", f"pool::{progress_spec}"], cwd=work, env=env, check=False)
            status = status or result.returncode
        if not args.functions or funding_spec in names:
            pool_path.write_text(instrument_swap_fee_funding(pool_source))
            curve_path.write_text(curve_source)
            insert_specs(pool_path, "// === Test-Only Functions ===", FEE_FUNDING_SPECS)
            insert_specs(curve_path, "// === Imports ===", CURVE_SPECS + LOOKUP_FOR_BUDGET + CURVE_SWAP_SUMMARIES)
            result = subprocess.run(command + ["--functions", f"pool::{funding_spec}"], cwd=work, env=env, check=False)
            status = status or result.returncode
        if not args.functions or (custody_specs | execution_specs) & names:
            pool_path.write_text(instrument_liquidity_execution(pool_source))
            curve_path.write_text(curve_source)
            insert_specs(pool_path, "// === Test-Only Functions ===", CUSTODY_SPECS + liquidity_execution_specs())
            insert_specs(curve_path, "// === Imports ===", CURVE_SPECS + CURVE_CUSTODY_SUMMARIES)
            insert_specs(dex / "sources/lib/blast_events.move", "// === Imports ===", CUSTODY_EVENTS)
            targets = custody_specs | execution_specs
            filters = [arg for name in sorted(targets if not args.functions else targets & names)
                       for arg in ("--functions", f"pool::{name}")]
            result = subprocess.run(command + filters, cwd=work, env=env, check=False)
            status = status or result.returncode
        if not args.functions or owned_specs.keys() & names:
            pool_path.write_text(pool_source)
            curve_path.write_text(curve_source)
            insert_specs(pool_path, "// === Test-Only Functions ===", OWNED_POSITION_SPECS + SWAP_BOUNDARY_SPECS)
            insert_specs(curve_path, "// === Imports ===", EMPTY_FEES_SPEC + CREDIT_TOTAL_SPEC)
            insert_specs(fee_path.with_name("price_reference.move"), "// === Imports ===", REFERENCE_TOTAL_SPECS)
            filters = [arg for name, module in owned_specs.items() if not args.functions or name in names
                       for arg in ("--functions", f"{module}::{name}")]
            result = subprocess.run(command + filters, cwd=work, env=env, check=False)
            status = status or result.returncode
        if not args.functions or frame_specs & names:
            pool_path.write_text(pool_source)
            curve_path.write_text(curve_source)
            insert_specs(curve_path, "// === Imports ===", TICK_FRAMES)
            filters = [arg for name in sorted(frame_specs if not args.functions else frame_specs & names)
                       for arg in ("--functions", f"curve::{name}")]
            result = subprocess.run(command + filters, cwd=work, env=env, check=False)
            status = status or result.returncode
        if not args.functions or total_settlement in names:
            pool_path.write_text(pool_source)
            insert_specs(pool_path, "// === Test-Only Functions ===", SWAP_SETTLEMENT_TOTAL)
            event_path = dex / "sources/lib/blast_events.move"
            events_before = event_path.read_text()
            insert_specs(event_path, "// === Imports ===", TOTAL_SETTLEMENT_EVENT)
            result = subprocess.run(command + ["--functions", f"pool::{total_settlement}"],
                                    cwd=work, env=env, check=False)
            status = status or result.returncode
            event_path.write_text(events_before)
        if not args.functions or cursor_specs.keys() & names:
            pool_path.write_text(pool_source)
            curve_path.write_text(curve_source)
            tick_path = curve_path.with_name("tick_math.move")
            tick_path.write_text(observe_floor_ceiling(tick_path.read_text()))
            with tick_path.open("a") as out:
                out.write("\n" + TICK_GRID_SPECS)
            if not args.functions or "swap_grid_spec" in names:
                fee_path.write_text(fee_source)
                insert_specs(fee_path, "// === Test-Only Types ===", SWAP_GRID_STEP_SPEC)
                insert_specs(pool_path, "// === Test-Only Functions ===", SWAP_GRID_SPEC)
                insert_specs(curve_path, "// === Imports ===", CURVE_TRANSITION_SPECS + SWAP_GRID_CURVE_SPECS)
            curve_path.with_name("grid_price.bpl").write_text(GRID_BPL)
            insert_specs(curve_path, "// === Imports ===", CURSOR_GRID_SPEC)
            filters = [arg for name, module in cursor_specs.items() if not args.functions or name in names
                       for arg in ("--functions", f"{module}::{name}")]
            result = subprocess.run(command + filters, cwd=work, env=env, check=False)
            status = status or result.returncode
        if not args.functions or (principal_specs | {pricing_spec} | step_principal_specs) & names:
            pool_path.write_text(pool_source)
            price_path = curve_path.with_name("sqrt_price_math.move")
            price_source = price_path.read_text()
            curve_path.with_name("principal_round.bpl").write_text(ROUND_BPL + SWAP_PRINCIPAL_BPL)
            for specs, targets in principal_runs:
                selected = targets & names if args.functions else targets
                if not selected:
                    continue
                price_path.write_text(price_source + "\n" + PRINCIPAL_SPECS + SWAP_PRINCIPAL_MATH + specs)
                filters = [arg for name in sorted(selected) for arg in ("--functions", f"sqrt_price_math::{name}")]
                result = subprocess.run(command + filters, cwd=work, env=env, check=False)
                status = status or result.returncode
            if not args.functions or pricing_spec in names:
                curve_path.write_text(curve_source)
                tick_path = curve_path.with_name("tick_math.move")
                grid_summary = TICK_GRID_SPECS.split("#[mode(spec), ext(spec_only(loop_inv", 1)[0]
                grid_summary = grid_summary.replace("fun tick_price_on_grid", "public(package) fun tick_price_on_grid")
                tick_path.write_text((SOURCE / "curve/tick_math.move").read_text() + "\n" + grid_summary)
                price_path.write_text(price_source + "\n" + PRINCIPAL_SPECS + SWAP_PRINCIPAL_MATH + PRINCIPAL_WRAPPER_SPECS)
                curve_path.with_name("position_principal.bpl").write_text(GRID_BPL + ROUND_BPL + SWAP_PRINCIPAL_BPL)
                insert_specs(curve_path, "// === Imports ===", POSITION_PRICING_SPECS)
                result = subprocess.run(command + ["--functions", f"curve::{pricing_spec}"],
                                        cwd=work, env=env, check=False)
                status = status or result.returncode
            if not args.functions or step_principal_specs & names:
                curve_path.write_text(curve_source)
                price_path.write_text(price_source + "\n" + SWAP_PRINCIPAL_MATH + SWAP_PRINCIPAL_SUMMARIES)
                fee_path.write_text(fee_source)
                fee_path.with_name("swap_principal.bpl").write_text(ROUND_BPL + SWAP_PRINCIPAL_WIRING_BPL)
                insert_specs(fee_path, "// === Test-Only Types ===", SWAP_PRINCIPAL_FEE)
                filters = [arg for name in sorted(step_principal_specs if not args.functions else step_principal_specs & names)
                           for arg in ("--functions", f"continuous_fee::{name}")]
                result = subprocess.run(command + filters, cwd=work, env=env, check=False)
                status = status or result.returncode
        raise SystemExit(status)


if __name__ == "__main__":
    main()
