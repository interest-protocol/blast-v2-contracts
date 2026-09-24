// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Shared venue state: write-once objects only their venue module can key.
///
/// Venue modules add authority-bearing objects (the Meme type's Cetus `PoolCreationCap`) while
/// starting a launch, as dynamic object fields, so each object keeps its ID and stays readable by
/// it. No entry is ever removed, replaced, or borrowed mutably. New venue modules add entries
/// without changing this object's layout.
module blast_fun_migrators::venue_config;

// === Public Types ===

/// Shared singleton holding venue-owned entries.
public struct VenueConfig has key {
    id: UID,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(VenueConfig { id: object::new(ctx) });
}

// === Package Functions ===

/// Adds a write-once authority-bearing object under a key only its venue module constructs.
public(package) fun add_object<Key: copy + drop + store, Object: key + store>(
    self: &mut VenueConfig,
    key: Key,
    object: Object,
) {
    self.id.add_dynamic_object_field(key, object);
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

use sui::dynamic_object_field;

use fun dynamic_object_field::add as UID.add_dynamic_object_field;

use fun dynamic_object_field::borrow as UID.dynamic_object_field;
