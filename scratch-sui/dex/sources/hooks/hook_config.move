// The abort lint sees the shared error macros as numeric literals after expansion.
#[allow(lint(abort_without_constant))]
/// One shared configuration object per hook, at an address anyone can derive.
///
/// `HookConfig<Witness>` is derived from the singleton `HookNamespace` with the
/// witness's defining-ID type name as key, so routers compute its ID offline and
/// pass it to every hook call without an indexer. The hook keeps its cross-pool
/// state as dynamic fields on it and gates every function on `version`, because
/// old package versions remain callable after an upgrade.
module blast_fun_dex::hook_config;

// === Public Types ===

/// Singleton derivation parent for every hook configuration.
public struct HookNamespace has key {
    id: UID,
}

/// The hook's shared configuration. Only the witness's own package can mutate it.
/// Swaps borrow it immutably, so pools sharing one hook do not contend on it.
public struct HookConfig<phantom Witness> has key {
    id: UID,
    version: u64,
}

/// Derivation key: the witness's defining-ID type name.
public struct HookConfigKey(TypeName) has copy, drop, store;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(HookNamespace { id: object::new(ctx) });
}

// === Public Functions ===

/// Creates the hook's only configuration. A second call for the same witness
/// aborts in the framework because the derived address is already claimed.
/// The witness proves the caller is the hook package.
public fun new<Witness: drop>(
    namespace: &mut HookNamespace,
    _witness: Witness,
    version: u64,
): HookConfig<Witness> {
    let hook = type_name::with_defining_ids<Witness>();
    assert!(!hook.is_primitive(), blast_fun_dex::errors::primitive_witness!());

    HookConfig { id: derived_object::claim(&mut namespace.id, HookConfigKey(hook)), version }
}

/// Defining-module sink for a new configuration.
public fun share<Witness>(self: HookConfig<Witness>) {
    transfer::share_object(self);
}

/// The hook version this configuration accepts. Hooks abort unless it equals
/// the version compiled into the running package.
public fun version<Witness>(self: &HookConfig<Witness>): u64 {
    self.version
}

/// Advances the accepted version after a hook upgrade. A strictly increasing
/// version stops older package versions from restoring themselves.
public fun set_version<Witness: drop>(
    self: &mut HookConfig<Witness>,
    _witness: Witness,
    version: u64,
) {
    assert!(version > self.version, blast_fun_dex::errors::version_not_increasing!());

    self.version = version;
}

/// Read access for the hook's dynamic fields.
public fun uid<Witness>(self: &HookConfig<Witness>): &UID {
    &self.id
}

/// Write access for the hook's dynamic fields.
public fun uid_mut<Witness: drop>(self: &mut HookConfig<Witness>, _witness: &Witness): &mut UID {
    &mut self.id
}

// === Test-Only Functions ===

#[test_only]
public fun new_namespace_for_testing(ctx: &mut TxContext): HookNamespace {
    HookNamespace { id: object::new(ctx) }
}

#[test_only]
public fun key_for_testing(hook: TypeName): HookConfigKey {
    HookConfigKey(hook)
}

// === Imports ===

use std::type_name::{Self, TypeName};
use sui::derived_object;
