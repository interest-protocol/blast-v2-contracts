// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

module blast_sui::constants;

// === Package Constants ===

/// Denominator for protocol rates expressed in basis points.
macro public(package) fun basis_points_denominator(): u64 {
    10_000
}

/// blastSUI redemption fee a new vault starts with.
macro public(package) fun default_redeem_fee_bps(): u64 {
    2
}

/// Immutable ceiling for the blastSUI redemption fee.
macro public(package) fun max_redeem_fee_bps(): u64 {
    100
}

/// Exact byte length of a Sui package digest.
macro public(package) fun package_digest_length(): u64 {
    32
}

/// Smallest SUI amount the native validator set accepts as one new stake request.
///
/// It is also the minimum protocol bootstrap deposit: a smaller bootstrap could
/// not be delegated and would leave blast custody idle.
macro public(package) fun native_min_stake_mist(): u64 {
    1_000_000_000
}

/// Most pending native receipts one custody ledger holds at once.
///
/// Same-epoch requests join the newest receipt, refresh drains every arrived
/// receipt at the first current-rate epoch, and delegation is gated by that
/// same current-rate proof, so at most two receipts — one buffer-deferred and
/// one current-epoch — can coexist. Three carries one slot of slack, and
/// `stake_idle` skips delegation instead of aborting when the ledger is full,
/// so an unexpected third receipt costs deferred yield, never a user abort.
macro public(package) fun max_pending_stakes(): u64 {
    3
}

/// Extra MIST requested from one native FungibleStakedSui redemption.
///
/// Native redemption floors the pool's total SUI value, then floors the
/// principal and reward portions separately, so redeeming `v` pool tokens
/// returns at least `floor(v * sui / tokens) - 3` MIST at the current rate.
/// Requesting ceil pool tokens for `amount + 3` therefore funds `amount`.
/// The constant carries ten times that proven bound: the vault calls the
/// live system package, and headroom keeps exact redemption alive if a
/// system upgrade drifts native rounding by a few MIST. Over-requested
/// residue stays liquid in custody. An unbounded rate decrease is not a
/// rounding drift and still fails closed.
macro public(package) fun native_redemption_rounding_margin(): u64 {
    30
}

/// Protocol-funded fun exit and rounding reserve, in MIST.
///
/// Native conversion floors pool tokens and a full active-position redemption
/// loses up to the redemption margin, so fun custody can fall a few MIST below
/// the funSUI supply between rewarded epochs. The reserve absorbs those losses
/// so exact 1:1 redemption never needs blast custody. One tenth of a SUI also
/// makes adversarial depletion through repeated native rounding impractical.
macro public(package) fun fun_rounding_reserve_mist(): u64 {
    100_000_000
}

/// Buffer at which active fun stake is unwound before another redemption can exhaust backing.
///
/// One redemption can lose at most the native margin. Keeping twice that
/// amount lets a partial redemption and the protective unwind each absorb it.
macro public(package) fun fun_exit_low_water_mist(): u64 {
    2 * native_redemption_rounding_margin!()
}
