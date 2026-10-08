// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Write-once custody for the venue capabilities and pool terms each migrator reserves before a
/// presale opens, keyed by the migrator's own types.
module blast_presale::venue_config;

// === Public Types ===

public struct VenueConfig has key {
    id: UID,
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

public(package) fun add_value<Key: copy + drop + store, Value: store>(
    self: &mut VenueConfig,
    key: Key,
    value: Value,
) {
    self.id.add_dynamic_field(key, value);
}

public(package) fun value<Key: copy + drop + store, Value: store>(
    self: &VenueConfig,
    key: Key,
): &Value {
    self.id.dynamic_field(key)
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

// === Imports ===

use sui::{dynamic_field, dynamic_object_field};

use fun dynamic_field::add as UID.add_dynamic_field;
use fun dynamic_field::borrow as UID.dynamic_field;
use fun dynamic_object_field::add as UID.add_dynamic_object_field;
use fun dynamic_object_field::borrow as UID.dynamic_object_field;
