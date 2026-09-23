// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Typed replay facts for migrations, custody, tier policy, and fee flows.
module blast_fun_migrators::blast_events;

// === Public Structs ===

/// Records one pinned venue tier replacing the previous values.
///
/// Zero old values mean the venue module's compiled default was active before
/// this pin; consumers overlay the documented defaults when replaying.
public struct VenueTierUpdated has copy, drop {
    venue: TypeName,
    old_tick_spacing: u32,
    new_tick_spacing: u32,
    old_fee_rate: u64,
    new_fee_rate: u64,
}

/// Records one Aftermath policy replacing the previously effective policy.
public struct AftermathPolicyUpdated has copy, drop {
    old_meme_weight: u64,
    old_quote_weight: u64,
    old_dao_fee_bps: u16,
    new_meme_weight: u64,
    new_quote_weight: u64,
    new_dao_fee_bps: u16,
}

/// Records a reconciled Aftermath weighted-pool migration.
public struct AftermathMigrationCompleted has copy, drop {
    launch_id: ID,
    vault_id: ID,
    inner_pool_id: ID,
    dao_fee_pool_id: ID,
    venue: TypeName,
    lp: TypeName,
    meme: TypeName,
    quote: TypeName,
    meme_amount: u64,
    quote_amount: u64,
    locked_lp_amount: u64,
    meme_weight: u64,
    quote_weight: u64,
    flatness: u64,
    swap_in_fee: u64,
    dao_fee_bps: u16,
}

/// Records an admin-authorized DAO fee change for one migrated Aftermath pool.
public struct AftermathDaoFeeUpdated has copy, drop {
    vault_id: ID,
    dao_fee_pool_id: ID,
    old_dao_fee_bps: u16,
    new_dao_fee_bps: u16,
}

/// Records a replacement of the migrator-wide LP-fee protocol share.
public struct LpProtocolFeeShareChanged(u64) has copy, drop;

/// Records one project's newly pinned LP-fee protocol share.
public struct ProjectLpProtocolFeeShareSet has copy, drop {
    meme: TypeName,
    protocol_fee_share_bps: u64,
}

/// Records removal of one project's pinned LP-fee protocol share.
public struct ProjectLpProtocolFeeShareCleared(TypeName) has copy, drop;

/// Records the live curve-fee holder claiming a vault's migration-born LP-fee capability.
public struct LpFeeCapClaimed has copy, drop {
    vault_id: ID,
    meme: TypeName,
    quote: TypeName,
    lp_fee_cap_id: ID,
    claimant: address,
}

/// Records the LP-fee capability a vault honors after an administrative issue.
public struct LpFeeCapIssued has copy, drop {
    vault_id: ID,
    meme: TypeName,
    quote: TypeName,
    revoked_lp_fee_cap_id: Option<ID>,
    lp_fee_cap_id: ID,
    recipient: address,
}

/// Records creator LP fees bound to a custodian forever; `lp_fee_cap_id` is the destroyed
/// capability, or none when pending fees were bound without one.
public struct LpFeesLocked has copy, drop {
    vault_id: ID,
    meme: TypeName,
    quote: TypeName,
    lp_fee_cap_id: Option<ID>,
    custodian: TypeName,
}

/// Records discovery and typed position custody for one completed vault.
public struct VaultCreated has copy, drop {
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
    venue: TypeName,
    meme: TypeName,
    quote: TypeName,
}

/// Records one complete venue migration and residual custody.
///
/// `sqrt_price_x64` is the pool's Q64.64 square-root price at the moment the
/// principal was seeded: the balance-derived opening price on new-pool routes
/// and the adopted pool's live price on adoption routes. Both tick fields are
/// two's-complement `i32` bit patterns on every venue.
public struct MigrationCompleted has copy, drop {
    launch_id: ID,
    vault_id: ID,
    pool_id: ID,
    venue: TypeName,
    meme: TypeName,
    quote: TypeName,
    source_meme_amount: u64,
    source_quote_amount: u64,
    used_meme_amount: u64,
    used_quote_amount: u64,
    residual_meme_amount: u64,
    residual_quote_amount: u64,
    sqrt_price_x64: u128,
    lower_tick_bits: u32,
    upper_tick_bits: u32,
    tick_spacing: u32,
    fee_rate: u64,
}

/// Records one venue fee collection and allocation.
public struct LpFeesCollected has copy, drop {
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
    venue: TypeName,
    meme: TypeName,
    quote: TypeName,
    collector: address,
    gross_meme_fee: u64,
    gross_quote_fee: u64,
    protocol_fee_share_bps: u64,
    protocol_meme_fee_delta: u64,
    creator_meme_fee_delta: u64,
    protocol_quote_fee_delta: u64,
    creator_quote_fee_delta: u64,
    principal_liquidity: u128,
}

/// Records a creator fee claim.
public struct CreatorFeesClaimed has copy, drop {
    vault_id: ID,
    meme: TypeName,
    quote: TypeName,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
}

/// Records a protocol fee and residual claim.
public struct ProtocolFeesClaimed has copy, drop {
    vault_id: ID,
    meme: TypeName,
    quote: TypeName,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
}

// === Package Functions ===

/// Emits installation or replacement of one venue's effective tier override.
public(package) fun venue_tier_updated<Venue>(
    old_tick_spacing: u32,
    new_tick_spacing: u32,
    old_fee_rate: u64,
    new_fee_rate: u64,
) {
    sui::event::emit(VenueTierUpdated {
        venue: type_name::with_original_ids<Venue>(),
        old_tick_spacing,
        new_tick_spacing,
        old_fee_rate,
        new_fee_rate,
    });
}

/// Emits installation or replacement of the effective Aftermath policy.
public(package) fun aftermath_policy_updated(
    old_meme_weight: u64,
    old_quote_weight: u64,
    old_dao_fee_bps: u16,
    new_meme_weight: u64,
    new_quote_weight: u64,
    new_dao_fee_bps: u16,
) {
    sui::event::emit(AftermathPolicyUpdated {
        old_meme_weight,
        old_quote_weight,
        old_dao_fee_bps,
        new_meme_weight,
        new_quote_weight,
        new_dao_fee_bps,
    });
}

/// Emits one fully reconciled Aftermath weighted-pool migration.
public(package) fun aftermath_migration_completed<Lp, Meme, Quote, Venue>(
    launch_id: ID,
    vault_id: ID,
    inner_pool_id: ID,
    dao_fee_pool_id: ID,
    meme_amount: u64,
    quote_amount: u64,
    locked_lp_amount: u64,
    meme_weight: u64,
    quote_weight: u64,
    flatness: u64,
    swap_in_fee: u64,
    dao_fee_bps: u16,
) {
    sui::event::emit(AftermathMigrationCompleted {
        launch_id,
        vault_id,
        inner_pool_id,
        dao_fee_pool_id,
        venue: type_name::with_original_ids<Venue>(),
        lp: type_name::with_original_ids<Lp>(),
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        meme_amount,
        quote_amount,
        locked_lp_amount,
        meme_weight,
        quote_weight,
        flatness,
        swap_in_fee,
        dao_fee_bps,
    });
}

/// Emits one admin-authorized DAO fee update for an existing pool.
public(package) fun aftermath_dao_fee_updated(
    vault_id: ID,
    dao_fee_pool_id: ID,
    old_dao_fee_bps: u16,
    new_dao_fee_bps: u16,
) {
    sui::event::emit(AftermathDaoFeeUpdated {
        vault_id,
        dao_fee_pool_id,
        old_dao_fee_bps,
        new_dao_fee_bps,
    });
}

/// Emits creation of one venue-sealed LP vault and attached position.
public(package) fun vault_created<Meme, Quote, Venue>(
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
) {
    sui::event::emit(VaultCreated {
        vault_id,
        pool_id,
        position_id,
        venue: type_name::with_original_ids<Venue>(),
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
    });
}

/// Emits one completed launch migration with source, usage, residual, and tier facts.
public(package) fun migration_completed<Meme, Quote, Venue>(
    launch_id: ID,
    vault_id: ID,
    pool_id: ID,
    source_meme_amount: u64,
    source_quote_amount: u64,
    used_meme_amount: u64,
    used_quote_amount: u64,
    residual_meme_amount: u64,
    residual_quote_amount: u64,
    sqrt_price_x64: u128,
    lower_tick_bits: u32,
    upper_tick_bits: u32,
    tick_spacing: u32,
    fee_rate: u64,
) {
    sui::event::emit(MigrationCompleted {
        launch_id,
        vault_id,
        pool_id,
        venue: type_name::with_original_ids<Venue>(),
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        source_meme_amount,
        source_quote_amount,
        used_meme_amount,
        used_quote_amount,
        residual_meme_amount,
        residual_quote_amount,
        sqrt_price_x64,
        lower_tick_bits,
        upper_tick_bits,
        tick_spacing,
        fee_rate,
    });
}

/// Emits one LP-fee collection and allocation.
public(package) fun lp_fees_collected<Meme, Quote, Venue>(
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
    collector: address,
    gross_meme_fee: u64,
    gross_quote_fee: u64,
    protocol_fee_share_bps: u64,
    protocol_meme_fee_delta: u64,
    creator_meme_fee_delta: u64,
    protocol_quote_fee_delta: u64,
    creator_quote_fee_delta: u64,
    principal_liquidity: u128,
) {
    sui::event::emit(LpFeesCollected {
        vault_id,
        pool_id,
        position_id,
        venue: type_name::with_original_ids<Venue>(),
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        collector,
        gross_meme_fee,
        gross_quote_fee,
        protocol_fee_share_bps,
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
        principal_liquidity,
    });
}

/// Emits replacement of the migrator-wide LP-fee protocol share.
public(package) fun lp_protocol_fee_share_changed(protocol_fee_share_bps: u64) {
    sui::event::emit(LpProtocolFeeShareChanged(protocol_fee_share_bps));
}

/// Emits one project's newly pinned LP-fee protocol share.
public(package) fun project_lp_protocol_fee_share_set<Meme>(protocol_fee_share_bps: u64) {
    sui::event::emit(ProjectLpProtocolFeeShareSet {
        meme: type_name::with_original_ids<Meme>(),
        protocol_fee_share_bps,
    });
}

/// Emits removal of one project's pinned LP-fee protocol share.
public(package) fun project_lp_protocol_fee_share_cleared<Meme>() {
    sui::event::emit(ProjectLpProtocolFeeShareCleared(type_name::with_original_ids<Meme>()));
}

/// Emits the one-time claim of a migration-born LP-fee capability.
public(package) fun lp_fee_cap_claimed<Meme, Quote>(
    vault_id: ID,
    lp_fee_cap_id: ID,
    claimant: address,
) {
    sui::event::emit(LpFeeCapClaimed {
        vault_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        lp_fee_cap_id,
        claimant,
    });
}

/// Emits an administrative LP-fee capability issue and any retired predecessor.
public(package) fun lp_fee_cap_issued<Meme, Quote>(
    vault_id: ID,
    revoked_lp_fee_cap_id: Option<ID>,
    lp_fee_cap_id: ID,
    recipient: address,
) {
    sui::event::emit(LpFeeCapIssued {
        vault_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        revoked_lp_fee_cap_id,
        lp_fee_cap_id,
        recipient,
    });
}

/// Emits the permanent binding of creator LP fees to a custodian object.
public(package) fun lp_fees_locked<Meme, Quote>(
    vault_id: ID,
    lp_fee_cap_id: Option<ID>,
    custodian: TypeName,
) {
    sui::event::emit(LpFeesLocked {
        vault_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        lp_fee_cap_id,
        custodian,
    });
}

/// Emits a creator-owned LP-fee withdrawal.
public(package) fun creator_fees_claimed<Meme, Quote>(
    vault_id: ID,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
) {
    sui::event::emit(CreatorFeesClaimed {
        vault_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        claimant,
        meme_amount,
        quote_amount,
    });
}

/// Emits a protocol-owned residual and LP-fee withdrawal.
public(package) fun protocol_fees_claimed<Meme, Quote>(
    vault_id: ID,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
) {
    sui::event::emit(ProtocolFeesClaimed {
        vault_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        claimant,
        meme_amount,
        quote_amount,
    });
}

// === Test-Only Functions ===

#[test_only]
public fun lp_protocol_fee_share_changed_fields(self: &LpProtocolFeeShareChanged): u64 {
    self.0
}

#[test_only]
public fun project_lp_protocol_fee_share_set_fields(
    self: &ProjectLpProtocolFeeShareSet,
): (TypeName, u64) {
    (self.meme, self.protocol_fee_share_bps)
}

#[test_only]
public fun project_lp_protocol_fee_share_cleared_fields(
    self: &ProjectLpProtocolFeeShareCleared,
): TypeName {
    self.0
}

// === Imports ===

use std::type_name::{Self, TypeName};
