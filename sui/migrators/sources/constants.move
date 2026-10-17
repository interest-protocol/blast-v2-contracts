// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Package-wide migrator constants exposed as zero-cost macros.
module blast_fun_migrators::constants;

// === Package Constants ===

/// Bluefin pool creation's own tick-spacing bound (`pool` aborts 1026 above it).
macro public(package) fun bluefin_max_tick_spacing(): u32 {
    400
}

/// Bluefin pool creation's own fee-rate bound (`pool` aborts 1027 above it).
macro public(package) fun bluefin_max_fee_rate(): u64 {
    20_000
}

/// Aftermath's own bound on a DAO fee, the whole amount; the creator picks the launch's fee
/// within it, and Aftermath sends that share of every swap, deposit, and withdrawal to the vault.
macro public(package) fun aftermath_max_dao_fee_bps(): u16 {
    10_000
}

/// Each coin's weight in an Aftermath launch pool: half of Aftermath's `1e18` fixed-point one.
macro public(package) fun aftermath_half_weight(): u64 {
    500_000_000_000_000_000
}

/// Selects Aftermath's uncorrelated weighted-product curve.
macro public(package) fun aftermath_flatness(): u64 {
    0
}

/// Aftermath's minimum base swap-in fee, 0.01% in its `1e18` unit; it rejects zero. This part
/// compounds into the locked LP.
macro public(package) fun aftermath_base_swap_fee(): u64 {
    100_000_000_000_000
}

/// The name every Aftermath launch pool is created with.
macro public(package) fun aftermath_pool_name(): vector<u8> {
    b"Blast Launch Pool"
}

/// Lowest sqrt price a Cetus or Bluefin swap accepts as its limit; buybacks selling Quote as coin A
/// run to it and rely on the caller's minimum Meme out instead.
macro public(package) fun min_swap_sqrt_price(): u128 {
    4_295_048_017
}

/// Highest sqrt price a Cetus or Bluefin swap accepts as its limit, for buybacks selling Quote as
/// coin B.
macro public(package) fun max_swap_sqrt_price(): u128 {
    79_226_673_515_401_279_992_447_579_054
}

/// Fractional bits of a Q64.64 sqrt price.
macro public(package) fun q64_shift(): u8 {
    64
}

/// Fractional bits of the Q128 price ratio the seed sqrt price is taken from.
macro public(package) fun q128_shift(): u8 {
    128
}

/// Exponent of the integer square-root search's upper bound: a positive u64/u64 Q128 ratio is
/// below 2^192, so its root is below 2^96.
macro public(package) fun sqrt_upper_bound_shift(): u8 {
    96
}

/// Atoms of the other asset kept in reserve beyond the estimate, covering the venue's own
/// rounding of the liquidity it derives from the fixed amount.
macro public(package) fun auto_lp_margin(): u256 {
    2
}

/// Maximum leaves in one holder-rewards round.
macro public(package) fun max_reward_leaves(): u64 {
    65_536
}

/// Byte length of a Blake2b-256 digest: Merkle roots, nodes, and manifest digests.
macro public(package) fun digest_length(): u64 {
    32
}
