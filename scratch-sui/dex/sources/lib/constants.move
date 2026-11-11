// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// DEX protocol parameters, hook flags, package version and pause domains.
module blast_fun_dex::constants;

// === Package Constants ===

// Hook slot flags for `pool::register_hook`. Combine with `|`.

macro public fun before_add_liquidity_flag(): u8 { 0x80 }
macro public fun after_add_liquidity_flag(): u8 { 0x40 }
macro public fun before_remove_liquidity_flag(): u8 { 0x20 }
macro public fun after_remove_liquidity_flag(): u8 { 0x10 }
macro public fun before_swap_flag(): u8 { 0x08 }
macro public fun after_swap_flag(): u8 { 0x04 }
macro public fun before_donate_flag(): u8 { 0x02 }
macro public fun after_donate_flag(): u8 { 0x01 }
macro public fun all_hook_flags(): u8 { 0xff }

/// The package version this bytecode serves.
macro public(package) fun version(): u64 { 1 }

/// Stops pool creation, hook registration on new pools, finalization and sharing.
macro public(package) fun create_pause_bit(): u8 { 1 }

/// Stops both directions of swapping.
macro public(package) fun swap_pause_bit(): u8 { 2 }

/// Stops adding liquidity and donating to existing pools.
macro public(package) fun liquidity_in_pause_bit(): u8 { 4 }

/// All supported DEX pause flags. Removing liquidity never requires unpausing.
macro public(package) fun valid_pause_bits(): u8 {
    blast_fun_dex::constants::create_pause_bit!()
        | blast_fun_dex::constants::swap_pause_bit!()
        | blast_fun_dex::constants::liquidity_in_pause_bit!()
}

/// Initial fixed and dynamic base fee tiers: 0.1%, 0.3%, 1% and 2%.
macro public(package) fun default_fee_tiers_ppm(): vector<u32> {
    vector[1_000, 3_000, 10_000, 20_000]
}

/// Delay before a proposed LP fee tier can be registered: 48 hours.
macro public(package) fun fee_tier_delay_ms(): u64 {
    48 * 60 * 60 * 1_000
}

/// Maximum pending tier additions stored inline in the registry.
macro public(package) fun max_pending_fee_tiers(): u64 {
    32
}

/// Upper bound for a registered tier and a dynamic maximum: 10%.
macro public(package) fun max_lp_fee_ppm(): u32 {
    100_000
}

/// Lowest sensitivity, in ppm of fee per unit of squared price gap.
macro public(package) fun min_sensitivity_ppm(): u32 {
    100_000
}

/// Highest sensitivity, in ppm of fee per unit of squared price gap.
macro public(package) fun max_sensitivity_ppm(): u32 {
    100_000_000
}

/// Time window used by the pool-local price reference: 10 minutes.
macro public(package) fun reference_window_ms(): u64 {
    600_000
}

/// Largest supported tick spacing.
macro public(package) fun max_tick_spacing(): u32 {
    32_767
}

/// Largest tick magnitude, as in Uniswap v4.
macro public(package) fun max_tick(): u32 {
    887_272
}

/// Inclusive minimum square-root price in Q64.96, as in Uniswap v4.
macro public(package) fun min_sqrt_price_x96(): u256 {
    4_295_128_739
}

/// Exclusive maximum square-root price in Q64.96, as in Uniswap v4.
macro public(package) fun max_sqrt_price_x96(): u256 {
    1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342
}

/// Bound range traversal per swap. Any remaining input is refunded.
macro public(package) fun max_swap_steps(): u64 { 128 }
