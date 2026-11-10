#[test_only]
module blast_fun_dex::hook_config_tests;

// === Test-Only Types ===

public struct TestHook() has drop;

// === Tests ===

#[test]
fun new_derives_one_address_per_witness_from_the_namespace() {
    let mut ctx = tx_context::dummy();
    let mut namespace = hook_config::new_namespace_for_testing(&mut ctx);
    let namespace_id = object::id(&namespace);

    let config = hook_config::new(&mut namespace, TestHook(), 7);

    let expected = derived_object::derive_address(
        namespace_id,
        hook_config_key<TestHook>(),
    );
    assert_eq!(object::id(&config).to_address(), expected);
    assert_eq!(config.version(), 7);

    destroy(config);
    destroy(namespace);
}

#[test]
#[expected_failure(abort_code = derived_object::EObjectAlreadyExists, location = sui::derived_object)]
fun new_rejects_a_second_config_for_the_same_witness() {
    let mut ctx = tx_context::dummy();
    let mut namespace = hook_config::new_namespace_for_testing(&mut ctx);
    let first = hook_config::new(&mut namespace, TestHook(), 1);

    let second = hook_config::new(&mut namespace, TestHook(), 1);

    destroy(first);
    destroy(second);
    destroy(namespace);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::hook_config::EPrimitiveWitness, location = blast_fun_dex::hook_config)]
fun new_rejects_a_primitive_witness() {
    let mut ctx = tx_context::dummy();
    let mut namespace = hook_config::new_namespace_for_testing(&mut ctx);

    let config = hook_config::new(&mut namespace, 0u8, 1);

    destroy(config);
    destroy(namespace);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::hook_config::EPrimitiveWitness, location = blast_fun_dex::hook_config)]
fun new_rejects_a_vector_witness() {
    let mut ctx = tx_context::dummy();
    let mut namespace = hook_config::new_namespace_for_testing(&mut ctx);

    let config = hook_config::new(&mut namespace, vector<u8>[], 1);

    destroy(config);
    destroy(namespace);
}

#[test]
fun set_version_accepts_a_higher_version() {
    let mut ctx = tx_context::dummy();
    let mut namespace = hook_config::new_namespace_for_testing(&mut ctx);
    let mut config = hook_config::new(&mut namespace, TestHook(), 1);

    config.set_version(TestHook(), 2);

    assert_eq!(config.version(), 2);
    destroy(config);
    destroy(namespace);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::hook_config::EVersionNotIncreasing, location = blast_fun_dex::hook_config)]
fun set_version_rejects_the_current_version() {
    let mut ctx = tx_context::dummy();
    let mut namespace = hook_config::new_namespace_for_testing(&mut ctx);
    let mut config = hook_config::new(&mut namespace, TestHook(), 2);

    config.set_version(TestHook(), 2);

    destroy(config);
    destroy(namespace);
}

#[test]
#[expected_failure(abort_code = blast_fun_dex::hook_config::EVersionNotIncreasing, location = blast_fun_dex::hook_config)]
fun set_version_rejects_an_older_version() {
    let mut ctx = tx_context::dummy();
    let mut namespace = hook_config::new_namespace_for_testing(&mut ctx);
    let mut config = hook_config::new(&mut namespace, TestHook(), 2);

    config.set_version(TestHook(), 1);

    destroy(config);
    destroy(namespace);
}

// === Test Helpers ===

/// The key routers hash with the namespace ID to find a hook's configuration.
fun hook_config_key<Witness>(): HookConfigKey {
    hook_config::key_for_testing(type_name::with_defining_ids<Witness>())
}

// === Imports ===

use blast_fun_dex::hook_config::{Self, HookConfigKey};
use std::{type_name, unit_test::{assert_eq, destroy}};
use sui::derived_object;
