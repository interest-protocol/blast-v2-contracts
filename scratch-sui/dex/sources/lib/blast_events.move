// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Events emitted by the scratch DEX.
module blast_fun_dex::blast_events;

// === Public Types ===

/// An additional LP fee rate became available to new pools.
public struct BlastDexFeeTierAdded has copy, drop {
    fee_ppm: u32,
}

/// The finalized pool's fee schedule and hook bindings are carried as values.
public struct PoolCreated<Fee: copy + drop, Bindings: copy + drop> has copy, drop {
    pool_id: ID,
    asset: TypeName,
    quote: TypeName,
    tick_spacing: u32,
    lp_fee: Fee,
    sqrt_price_x96: u256,
    hooks: Bindings,
}

public struct Swapped has copy, drop {
    pool_id: ID,
    sender: address,
    is_asset_input: bool,
    input_spent: u64,
    output_amount: u64,
    /// LP fee paid in atomic units of the input coin.
    lp_fee_amount: u64,
    sqrt_price_after_x96: u256,
}

public struct LiquidityAdded has copy, drop {
    pool_id: ID,
    position_id: ID,
    tick_lower: I32,
    tick_upper: I32,
    liquidity: u128,
    asset_amount: u64,
    quote_amount: u64,
}

public struct LiquidityRemoved has copy, drop {
    pool_id: ID,
    position_id: ID,
    tick_lower: I32,
    tick_upper: I32,
    liquidity: u128,
    asset_amount: u64,
    quote_amount: u64,
    asset_fee: u64,
    quote_fee: u64,
}

public struct Donated has copy, drop {
    pool_id: ID,
    asset_amount: u64,
    quote_amount: u64,
}

// === Package Functions ===

public(package) fun fee_tier_added(fee_ppm: u32) {
    event::emit(BlastDexFeeTierAdded { fee_ppm });
}

public(package) fun pool_created<Fee: copy + drop, Bindings: copy + drop>(
    pool_id: ID,
    asset: TypeName,
    quote: TypeName,
    tick_spacing: u32,
    lp_fee: Fee,
    sqrt_price_x96: u256,
    hooks: Bindings,
) {
    event::emit(PoolCreated { pool_id, asset, quote, tick_spacing, lp_fee, sqrt_price_x96, hooks });
}

public(package) fun swapped(
    pool_id: ID,
    sender: address,
    is_asset_input: bool,
    input_spent: u64,
    output_amount: u64,
    lp_fee_amount: u64,
    sqrt_price_after_x96: u256,
) {
    event::emit(Swapped {
        pool_id,
        sender,
        is_asset_input,
        input_spent,
        output_amount,
        lp_fee_amount,
        sqrt_price_after_x96,
    });
}

public(package) fun liquidity_added(
    pool_id: ID,
    position_id: ID,
    tick_lower: I32,
    tick_upper: I32,
    liquidity: u128,
    asset_amount: u64,
    quote_amount: u64,
) {
    event::emit(LiquidityAdded { pool_id, position_id, tick_lower, tick_upper, liquidity, asset_amount, quote_amount });
}

public(package) fun liquidity_removed(
    pool_id: ID,
    position_id: ID,
    tick_lower: I32,
    tick_upper: I32,
    liquidity: u128,
    asset_amount: u64,
    quote_amount: u64,
    asset_fee: u64,
    quote_fee: u64,
) {
    event::emit(LiquidityRemoved {
        pool_id, position_id, tick_lower, tick_upper, liquidity, asset_amount, quote_amount, asset_fee, quote_fee,
    });
}

public(package) fun donated(pool_id: ID, asset_amount: u64, quote_amount: u64) {
    event::emit(Donated { pool_id, asset_amount, quote_amount });
}

// === Test-Only Functions ===

#[test_only]
public fun added_fee_ppm_for_testing(self: &BlastDexFeeTierAdded): u32 {
    self.fee_ppm
}

#[test_only]
public fun pool_created_fields<Fee: copy + drop, Bindings: copy + drop>(
    self: &PoolCreated<Fee, Bindings>,
): (ID, TypeName, TypeName, u32, Fee, u256, Bindings) {
    (self.pool_id, self.asset, self.quote, self.tick_spacing, self.lp_fee, self.sqrt_price_x96, self.hooks)
}

#[test_only]
public fun swapped_fields(self: &Swapped): (ID, address, bool, u64, u64, u64, u256) {
    (
        self.pool_id,
        self.sender,
        self.is_asset_input,
        self.input_spent,
        self.output_amount,
        self.lp_fee_amount,
        self.sqrt_price_after_x96,
    )
}

#[test_only]
public fun liquidity_added_fields(self: &LiquidityAdded): (ID, ID, u128, u64, u64) {
    (self.pool_id, self.position_id, self.liquidity, self.asset_amount, self.quote_amount)
}

#[test_only]
public fun liquidity_removed_fields(self: &LiquidityRemoved): (ID, ID, u128, u64, u64) {
    (self.pool_id, self.position_id, self.liquidity, self.asset_amount, self.quote_amount)
}

#[test_only]
public fun donated_fields(self: &Donated): (ID, u64, u64) {
    (self.pool_id, self.asset_amount, self.quote_amount)
}

// === Imports ===

use blast_fun_dex::i32::I32;
use std::type_name::TypeName;
use sui::event;
