// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Write-once custody for the venue capabilities and pool tiers migrators reserve before a presale
/// opens.
module blast_presale::venue_config;

// === Public Types ===

public struct VenueConfig has key {
    id: UID,
}

/// Key for the pool tier a sale token's venue reserved. Each sale token has one sale.
public struct PoolTierKey<phantom Meme>() has copy, drop, store;

/// A concentrated-liquidity pool tier, in the venue's own units.
public struct PoolTier has copy, drop, store {
    tick_spacing: u32,
    pool_fee_rate: u64,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(VenueConfig { id: object::new(ctx) });
}

// === Package Functions ===

public(package) fun add_object<Key: copy + drop + store, Object: key + store>(
    self: &mut VenueConfig,
    key: Key,
    object: Object,
) {
    self.id.add_dynamic_object_field(key, object);
}

public(package) fun object<Key: copy + drop + store, Object: key + store>(
    self: &VenueConfig,
    key: Key,
): &Object {
    self.id.dynamic_object_field(key)
}

/// Records the tier of the `<Meme, Quote>` sale's pool at the venue `Venue` marks, which only that
/// venue's module constructs, and emits it for indexers.
public(package) fun add_pool_tier<Meme, Quote, Venue>(
    self: &mut VenueConfig,
    _: &Venue,
    tick_spacing: u32,
    pool_fee_rate: u64,
) {
    self.id.add_dynamic_field(PoolTierKey<Meme>(), PoolTier { tick_spacing, pool_fee_rate });

    event::emit(PoolTierReserved<Meme, Quote, Venue> { tick_spacing, pool_fee_rate });
}

/// The tick spacing and fee rate recorded for the sale token's pool.
public(package) fun pool_tier<Meme>(self: &VenueConfig): (u32, u64) {
    let PoolTier { tick_spacing, pool_fee_rate } = *self.id.dynamic_field(PoolTierKey<Meme>());

    (tick_spacing, pool_fee_rate)
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): VenueConfig {
    VenueConfig { id: object::new(ctx) }
}

#[test_only]
public fun pool_tier_reserved_fields<Meme, Quote, Venue>(
    event: &PoolTierReserved<Meme, Quote, Venue>,
): (u32, u64) {
    (event.tick_spacing, event.pool_fee_rate)
}

// === Events ===

/// A venue reserved the `<Meme, Quote>` sale's pool at this tier, which its migration creates.
/// `Venue` is the venue's marker, such as `cetus::Venue`.
public struct PoolTierReserved<phantom Meme, phantom Quote, phantom Venue> has copy, drop {
    tick_spacing: u32,
    pool_fee_rate: u64,
}

// === Imports ===

use sui::{dynamic_field, dynamic_object_field, event};

use fun dynamic_field::add as UID.add_dynamic_field;
use fun dynamic_field::borrow as UID.dynamic_field;
use fun dynamic_object_field::add as UID.add_dynamic_object_field;
use fun dynamic_object_field::borrow as UID.dynamic_object_field;
