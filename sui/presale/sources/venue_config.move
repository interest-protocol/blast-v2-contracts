// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Write-once custody for venue capabilities reserved before a presale opens.
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

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

// === Imports ===

use sui::dynamic_object_field;

use fun dynamic_object_field::add as UID.add_dynamic_object_field;
use fun dynamic_object_field::borrow as UID.dynamic_object_field;
