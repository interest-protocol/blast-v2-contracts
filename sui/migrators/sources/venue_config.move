// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Shared venue state: admin-pinned tiers and write-once venue-owned entries.
///
/// Migration is deliberately permissionless, so no migration caller may choose the economic
/// policy of the pool that custodies the launch principal. Two kinds of entry live here, each
/// under a dynamic-field key that only its venue module can construct:
///
/// - one `(tick_spacing, fee_rate)` tier per venue, pinned through that venue module's
///   admin-gated `set_tier`; and
/// - write-once entries a venue module adds while binding launch tickets: plain values (Cetus
///   pair reservations) as dynamic fields, and authority-bearing objects (the Meme type's Cetus
///   `PoolCreationCap`) as dynamic object fields, so each object keeps its ID and stays readable
///   by it.
///
/// No entry is ever removed, replaced, or borrowed mutably except a tier pin. New venue modules
/// add entries without changing this object's layout.
module blast_fun_migrators::venue_config;

// === Errors ===

#[error(code = 0)]
const EInvalidTickSpacing: vector<u8> = b"Venue tick spacing must be greater than zero.";

#[error(code = 1)]
const EInvalidFeeRate: vector<u8> = b"Venue fee rate must be greater than zero.";

#[error(code = 2)]
const EUnchangedTier: vector<u8> = b"Venue tier must differ from its current pinned values.";

#[error(code = 3)]
const EVenueTierUnset: vector<u8> = b"Venue tier must be pinned before an override-only read.";

// === Public Types ===

/// A sealed field name that binds one venue's tier entry to its witness type.
public struct TierKey<phantom Venue>() has copy, drop, store;

/// One pinned `(tick_spacing, fee_rate)` pair in venue-native units.
public struct Tier has copy, drop, store {
    tick_spacing: u32,
    fee_rate: u64,
}

/// Shared singleton holding the venue tiers and venue-owned entries.
public struct VenueConfig has key {
    id: UID,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(VenueConfig { id: object::new(ctx) });
}

// === Package Functions ===

/// Pins or replaces one venue's tier; only the venue module holds the witness.
///
/// Zero old values in the emitted fact mean the venue had no earlier pin.
public(package) fun set_tier<Venue: drop>(
    self: &mut VenueConfig,
    _venue: Venue,
    tick_spacing: u32,
    fee_rate: u64,
) {
    assert!(tick_spacing > 0, EInvalidTickSpacing);
    assert!(fee_rate > 0, EInvalidFeeRate);

    let (old_tick_spacing, old_fee_rate) = if (self.has_tier<Venue>()) {
        let tier_mut = self.id.dynamic_field_mut<_, Tier>(TierKey<Venue>());
        let old_tick_spacing = tier_mut.tick_spacing;
        let old_fee_rate = tier_mut.fee_rate;
        assert!(
            old_tick_spacing != tick_spacing || old_fee_rate != fee_rate,
            EUnchangedTier,
        );
        *tier_mut = Tier { tick_spacing, fee_rate };
        (old_tick_spacing, old_fee_rate)
    } else {
        self.id.add_dynamic_field(
            TierKey<Venue>(),
            Tier { tick_spacing, fee_rate },
        );
        (0, 0)
    };

    blast_events::venue_tier_updated<Venue>(
        old_tick_spacing,
        tick_spacing,
        old_fee_rate,
        fee_rate,
    );
}

/// Reports whether the venue has a stored tier.
public(package) fun has_tier<Venue>(self: &VenueConfig): bool {
    self.id.has_dynamic_field(TierKey<Venue>())
}

/// Returns the pinned `(tick_spacing, fee_rate)`; aborts while no pin exists.
public(package) fun tier<Venue>(self: &VenueConfig): (u32, u64) {
    assert!(self.has_tier<Venue>(), EVenueTierUnset);

    let tier = self.id.dynamic_field<_, Tier>(TierKey<Venue>());

    (tier.tick_spacing, tier.fee_rate)
}

/// Adds a write-once value under a key only its venue module constructs.
public(package) fun add_policy<Key: copy + drop + store, Policy: store>(
    self: &mut VenueConfig,
    key: Key,
    policy: Policy,
) {
    self.id.add_dynamic_field(key, policy);
}

/// Reports whether the venue module has added a value under `key`.
public(package) fun has_policy<Key: copy + drop + store>(
    self: &VenueConfig,
    key: Key,
): bool {
    self.id.has_dynamic_field(key)
}

/// Borrows the value added under `key`.
public(package) fun policy<Key: copy + drop + store, Policy: store>(
    self: &VenueConfig,
    key: Key,
): &Policy {
    self.id.dynamic_field(key)
}

/// Adds a write-once authority-bearing object under a key only its venue module constructs.
public(package) fun add_object<Key: copy + drop + store, Object: key + store>(
    self: &mut VenueConfig,
    key: Key,
    object: Object,
) {
    self.id.add_dynamic_object_field(key, object);
}

/// Reports whether the venue module has added an object under `key`.
public(package) fun has_object<Key: copy + drop + store>(
    self: &VenueConfig,
    key: Key,
): bool {
    self.id.has_dynamic_object_field(key)
}

/// Borrows the object added under `key`.
public(package) fun object<Key: copy + drop + store, Object: key + store>(
    self: &VenueConfig,
    key: Key,
): &Object {
    self.id.dynamic_object_field(key)
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

// === Imports ===

use blast_fun_migrators::blast_events;

use sui::{dynamic_field, dynamic_object_field};

use fun dynamic_field::add as UID.add_dynamic_field;

use fun dynamic_field::borrow as UID.dynamic_field;

use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;

use fun dynamic_field::exists as UID.has_dynamic_field;

use fun dynamic_object_field::add as UID.add_dynamic_object_field;

use fun dynamic_object_field::borrow as UID.dynamic_object_field;

use fun dynamic_object_field::exists as UID.has_dynamic_object_field;
