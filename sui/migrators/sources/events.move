/// Typed replay facts for migrations, custody, tier policy, and fee flows.
module blast_fun_migrators::events;

use std::type_name::{Self, TypeName};

// === Public Structs ===

/// Records discovery of the one shared venue tier policy singleton.
public struct VenueConfigCreated has copy, drop {
    config_id: ID,
}

/// Records one pinned Bluefin tier replacing the previous values.
public struct BluefinTierUpdated has copy, drop {
    old_tick_spacing: u32,
    new_tick_spacing: u32,
    old_fee_rate: u64,
    new_fee_rate: u64,
}

/// Records one pinned Cetus tick spacing replacing the previous value.
public struct CetusTickSpacingUpdated has copy, drop {
    old_tick_spacing: u32,
    new_tick_spacing: u32,
}

/// Records one pinned Full Sail tick spacing replacing the previous value.
public struct FullSailTickSpacingUpdated has copy, drop {
    old_tick_spacing: u32,
    new_tick_spacing: u32,
}

/// Records one pinned MMT fee rate replacing the previous value.
public struct MmtFeeRateUpdated has copy, drop {
    old_fee_rate: u64,
    new_fee_rate: u64,
}

/// Records one pinned Turbos tier replacing the previous values.
public struct TurbosTierUpdated has copy, drop {
    old_tick_spacing: u32,
    new_tick_spacing: u32,
    old_fee_rate: u64,
    new_fee_rate: u64,
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

/// Records one complete venue migration and residual disposition.
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
    residual_treasury: address,
    sqrt_price_x64: u128,
    lower_tick_bits: u32,
    upper_tick_bits: u32,
    tick_spacing: u32,
    fee_rate: u64,
}

/// Records one venue fee collection, allocation, and final ledger snapshot.
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
    protocol_meme_fee_total: u64,
    creator_meme_fee_total: u64,
    protocol_quote_fee_total: u64,
    creator_quote_fee_total: u64,
    principal_liquidity_before: u128,
    principal_liquidity_after: u128,
}

/// Records a creator drain and the complete post-claim ledger snapshot.
public struct CreatorFeesClaimed has copy, drop {
    vault_id: ID,
    meme: TypeName,
    quote: TypeName,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
    protocol_meme_fee_total: u64,
    creator_meme_fee_total: u64,
    protocol_quote_fee_total: u64,
    creator_quote_fee_total: u64,
}

/// Records a protocol drain and the complete post-claim ledger snapshot.
public struct ProtocolFeesClaimed has copy, drop {
    vault_id: ID,
    meme: TypeName,
    quote: TypeName,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
    protocol_meme_fee_total: u64,
    creator_meme_fee_total: u64,
    protocol_quote_fee_total: u64,
    creator_quote_fee_total: u64,
}

// === Package Functions ===

public(package) fun venue_config_created(config_id: ID) {
    sui::event::emit(VenueConfigCreated { config_id });
}

public(package) fun bluefin_tier_updated(
    old_tick_spacing: u32,
    new_tick_spacing: u32,
    old_fee_rate: u64,
    new_fee_rate: u64,
) {
    sui::event::emit(BluefinTierUpdated {
        old_tick_spacing,
        new_tick_spacing,
        old_fee_rate,
        new_fee_rate,
    });
}

public(package) fun cetus_tick_spacing_updated(
    old_tick_spacing: u32,
    new_tick_spacing: u32,
) {
    sui::event::emit(CetusTickSpacingUpdated {
        old_tick_spacing,
        new_tick_spacing,
    });
}

public(package) fun fullsail_tick_spacing_updated(
    old_tick_spacing: u32,
    new_tick_spacing: u32,
) {
    sui::event::emit(FullSailTickSpacingUpdated {
        old_tick_spacing,
        new_tick_spacing,
    });
}

public(package) fun mmt_fee_rate_updated(
    old_fee_rate: u64,
    new_fee_rate: u64,
) {
    sui::event::emit(MmtFeeRateUpdated { old_fee_rate, new_fee_rate });
}

public(package) fun turbos_tier_updated(
    old_tick_spacing: u32,
    new_tick_spacing: u32,
    old_fee_rate: u64,
    new_fee_rate: u64,
) {
    sui::event::emit(TurbosTierUpdated {
        old_tick_spacing,
        new_tick_spacing,
        old_fee_rate,
        new_fee_rate,
    });
}

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
    residual_treasury: address,
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
        residual_treasury,
        sqrt_price_x64,
        lower_tick_bits,
        upper_tick_bits,
        tick_spacing,
        fee_rate,
    });
}

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
    protocol_meme_fee_total: u64,
    creator_meme_fee_total: u64,
    protocol_quote_fee_total: u64,
    creator_quote_fee_total: u64,
    principal_liquidity_before: u128,
    principal_liquidity_after: u128,
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
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
        principal_liquidity_before,
        principal_liquidity_after,
    });
}

public(package) fun creator_fees_claimed<Meme, Quote>(
    vault_id: ID,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
    protocol_meme_fee_total: u64,
    creator_meme_fee_total: u64,
    protocol_quote_fee_total: u64,
    creator_quote_fee_total: u64,
) {
    sui::event::emit(CreatorFeesClaimed {
        vault_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        claimant,
        meme_amount,
        quote_amount,
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
    });
}

public(package) fun protocol_fees_claimed<Meme, Quote>(
    vault_id: ID,
    claimant: address,
    meme_amount: u64,
    quote_amount: u64,
    protocol_meme_fee_total: u64,
    creator_meme_fee_total: u64,
    protocol_quote_fee_total: u64,
    creator_quote_fee_total: u64,
) {
    sui::event::emit(ProtocolFeesClaimed {
        vault_id,
        meme: type_name::with_original_ids<Meme>(),
        quote: type_name::with_original_ids<Quote>(),
        claimant,
        meme_amount,
        quote_amount,
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
    });
}
