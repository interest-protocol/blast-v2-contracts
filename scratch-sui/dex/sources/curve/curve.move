// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Shared error macros expand to literals under the pinned abort lint.
#[allow(lint(abort_without_constant))]
/// Owns initialized ranges, active liquidity and fee growth. The pool owns
/// coin custody and calls this module while its operation is locked.
module blast_fun_dex::curve;

// === Constants ===

const Q128: u256 = 1 << 128;

// === Public Types ===

public struct Curve has store {
    // The cursor is one below the boundary after a downward crossing.
    index: u32,
    liquidity: u128,
    total_liquidity: u128,
    growth: Growth,
    ticks: Table<u32, Tick>,
    words: Table<u32, u256>,
    groups: Table<u32, u256>,
    group_index: u256,
}

public struct Tick has drop, store {
    sqrt_price_x96: u256,
    starts: u128,
    ends: u128,
    outside: Growth,
}

public struct Growth has copy, drop, store {
    asset: u256,
    quote: u256,
}

public struct PositionFees has drop, store {
    checkpoint: Growth,
    owed_x128: Growth,
}

// === Package Functions ===

public(package) fun new(price_x96: u256, ctx: &mut TxContext): Curve {
    Curve {
        index: tick_math::floor_index(price_x96, 0, 2 * constants::max_tick!()),
        liquidity: 0,
        total_liquidity: 0,
        growth: zero(),
        ticks: table::new(ctx),
        words: table::new(ctx),
        groups: table::new(ctx),
        group_index: 0,
    }
}

public(package) fun new_position_fees(): PositionFees {
    PositionFees { checkpoint: zero(), owed_x128: zero() }
}

public(package) fun liquidity(self: &Curve): u128 { self.liquidity }

/// Returns the principal obligations for a liquidity change in atomic units.
public(package) fun position_amounts(
    price_x96: u256,
    lower: u32,
    upper: u32,
    liquidity: u128,
    round_up: bool,
): (u256, u256) {
    let lower_price = tick_math::sqrt_price_x96(lower);
    let upper_price = tick_math::sqrt_price_x96(upper);
    let spot = price_x96.max(lower_price).min(upper_price);
    (
        sqrt_price_math::asset_delta(spot, upper_price, liquidity, round_up),
        sqrt_price_math::quote_delta(lower_price, spot, liquidity, round_up),
    )
}

/// Checkpoint the old stake before modifying ticks. Empty positions establish
/// a fresh checkpoint after their endpoints have been initialized.
public(package) fun change_liquidity(
    self: &mut Curve,
    fees: &mut PositionFees,
    lower: u32,
    upper: u32,
    old: u128,
    delta: u128,
    add: bool,
) {
    if (add) assert!(delta <= u128::max_value!() - self.total_liquidity, errors::liquidity_limit!());
    if (old > 0) {
        let inside = self.growth_inside(lower, upper);
        let accrued = subtract(inside, fees.checkpoint);
        fees.owed_x128.asset = fees.owed_x128.asset + accrued.asset * (old as u256);
        fees.owed_x128.quote = fees.owed_x128.quote + accrued.quote * (old as u256);
        fees.checkpoint = inside;
    };

    self.change_tick(lower, true, delta, add);
    self.change_tick(upper, false, delta, add);
    self.total_liquidity = change(self.total_liquidity, delta, add);
    if (lower <= self.index && self.index < upper) {
        self.liquidity = change(self.liquidity, delta, add);
    };
    if (old == 0) fees.checkpoint = self.growth_inside(lower, upper);
}

/// Pays whole atoms on removal. Fractions carry across partial withdrawals.
/// Full exit relinquishes any fraction below one atomic unit.
public(package) fun take_fees(self: &mut PositionFees, full_exit: bool): (u64, u64) {
    let asset = (self.owed_x128.asset >> 128) as u64;
    let quote = (self.owed_x128.quote >> 128) as u64;
    self.owed_x128 = if (full_exit) zero() else Growth {
        asset: self.owed_x128.asset % Q128,
        quote: self.owed_x128.quote % Q128,
    };
    (asset, quote)
}

/// Funded swap fees and donations accrue only to the currently active range.
public(package) fun credit(self: &mut Curve, asset: u64, quote: u64) {
    let liquidity = self.liquidity as u256;
    assert!(liquidity > 0, errors::insufficient_liquidity!());
    self.growth.asset = wrapping_add(self.growth.asset, ((asset as u256) << 128) / liquidity);
    self.growth.quote = wrapping_add(self.growth.quote, ((quote as u256) << 128) / liquidity);
}

/// Find the next initialized tick via a three-level bitmap over the bounded
/// tick index space. At most 28 groups cover all 1,774,545 tick indexes.
public(package) fun next_tick(self: &Curve, up: bool): Option<u32> {
    let start = self.index + if (up) 1 else 0;
    let word = start >> 8;
    let group = word >> 8;
    let bits = at_or_beyond(bitmap(&self.words, word), (start % 256) as u8, up);
    if (bits != 0) return option::some((word << 8) + bit_index(bits, up));

    let words = strictly_beyond(bitmap(&self.groups, group), (word % 256) as u8, up);
    if (words != 0) {
        let next_word = (group << 8) + bit_index(words, up);
        return option::some((next_word << 8) + bit_index(self.words[next_word], up))
    };

    let groups = strictly_beyond(self.group_index, group as u8, up);
    if (groups == 0) return option::none();
    let next_group = bit_index(groups, up);
    let next_word = (next_group << 8) + bit_index(self.groups[next_group], up);
    option::some((next_word << 8) + bit_index(self.words[next_word], up))
}

public(package) fun tick_price(self: &Curve, index: u32): u256 {
    self.ticks[index].sqrt_price_x96
}

/// Credit the old range before crossing. The outside checkpoint flips sides
/// and subsequent fees use the newly active liquidity.
public(package) fun cross(self: &mut Curve, index: u32, up: bool) {
    let tick = &mut self.ticks[index];
    tick.outside = subtract(self.growth, tick.outside);
    if (up) {
        self.liquidity = self.liquidity - tick.ends + tick.starts;
        self.index = index;
    } else {
        self.liquidity = self.liquidity - tick.starts + tick.ends;
        self.index = index - 1;
    };
}

public(package) fun move_inside(self: &mut Curve, price_x96: u256, neighbor: Option<u32>, up: bool) {
    let (lower, upper) = if (up) {
        (self.index, neighbor.destroy_or!(2 * constants::max_tick!()))
    } else {
        (neighbor.destroy_or!(0), self.index)
    };
    self.index = tick_math::floor_index(price_x96, lower, upper);
}

// === Private Functions ===

fun change_tick(self: &mut Curve, index: u32, start: bool, delta: u128, add: bool) {
    if (!self.ticks.contains(index)) {
        let outside = if (index <= self.index) self.growth else zero();
        self.ticks.add(index, Tick {
            sqrt_price_x96: tick_math::sqrt_price_x96(index),
            starts: 0,
            ends: 0,
            outside,
        });
        self.set_initialized(index, true);
    };

    let tick = &mut self.ticks[index];
    if (start) tick.starts = change(tick.starts, delta, add)
    else tick.ends = change(tick.ends, delta, add);
    if (tick.starts == 0 && tick.ends == 0) {
        self.ticks.remove(index);
        self.set_initialized(index, false);
    };
}

fun change(value: u128, delta: u128, add: bool): u128 {
    if (add) value + delta else value - delta
}

fun growth_inside(self: &Curve, lower: u32, upper: u32): Growth {
    let below = self.ticks[lower].outside;
    let above = self.ticks[upper].outside;
    if (self.index < lower) return subtract(below, above);
    if (self.index >= upper) return subtract(above, below);
    subtract(subtract(self.growth, below), above)
}

fun zero(): Growth { Growth { asset: 0, quote: 0 } }

/// Modulo growth preserves a position's earned delta across accumulator wraps.
/// A live position's unclaimed whole atoms fit its funded u64 fee vault.
fun wrapping_add(first: u256, second: u256): u256 {
    let headroom = u256::max_value!() - first;
    if (second <= headroom) first + second else second - headroom - 1
}

fun wrapping_sub(first: u256, second: u256): u256 {
    if (first >= second) first - second else u256::max_value!() - (second - first) + 1
}

fun subtract(first: Growth, second: Growth): Growth {
    Growth {
        asset: wrapping_sub(first.asset, second.asset),
        quote: wrapping_sub(first.quote, second.quote),
    }
}

fun bitmap(table: &Table<u32, u256>, key: u32): u256 {
    if (table.contains(key)) table[key] else 0
}

fun set_initialized(self: &mut Curve, index: u32, present: bool) {
    let word = index >> 8;
    let group = word >> 8;
    let word_live = change_bitmap(&mut self.words, word, (index % 256) as u8, present);
    let group_live = change_bitmap(&mut self.groups, group, (word % 256) as u8, word_live);
    let mask = 1u256 << (group as u8);
    self.group_index = if (group_live) self.group_index | mask else self.group_index & (u256::max_value!() ^ mask);
}

fun change_bitmap(table: &mut Table<u32, u256>, key: u32, bit: u8, present: bool): bool {
    let mask = 1u256 << bit;
    if (!table.contains(key)) {
        if (present) table.add(key, mask);
        return present
    };
    let bits = &mut table[key];
    *bits = if (present) *bits | mask else *bits & (u256::max_value!() ^ mask);
    if (*bits != 0) return true;
    table.remove(key);
    false
}

fun at_or_beyond(bits: u256, bit: u8, up: bool): u256 {
    let lower = (1u256 << bit) - 1;
    if (up) bits & (u256::max_value!() ^ lower)
    else bits & (lower | (1u256 << bit))
}

fun strictly_beyond(bits: u256, bit: u8, up: bool): u256 {
    at_or_beyond(bits, bit, up) & (u256::max_value!() ^ (1u256 << bit))
}

fun bit_index(mut bits: u256, up: bool): u32 {
    let mut index = 0;
    vector[128u8, 64, 32, 16, 8, 4, 2, 1].do!(|shift| {
        let high = bits >> shift;
        let low = bits & ((1u256 << shift) - 1);
        if (if (up) low == 0 else high > 0) {
            bits = high;
            index = index + (shift as u32);
        } else {
            bits = low;
        };
    });
    index
}

// === Imports ===

use blast_fun_dex::{constants, errors, sqrt_price_math, tick_math};
use std::{u128, u256};
use sui::table::{Self, Table};
