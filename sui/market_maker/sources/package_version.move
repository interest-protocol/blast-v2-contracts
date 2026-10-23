// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Local operational generation. No usable version exists before native custody is sealed.
module blast_market_maker::package_version;

// === Public Types ===

/// Unique publication resource, consumed together with the native UpgradeCap.
public struct BlastMarketMakerBootstrap has key {
    id: UID,
    publisher: Publisher,
    treasury_id: ID,
    policy_id: ID,
    initial_generation: InitialGeneration,
}

/// Non-copyable publication seed. Only an authentic one-time witness can create it.
public struct InitialGeneration has store { generation: u64 }

/// Canonical local identities and current operational generation.
public struct BlastMarketMakerVersion has key {
    id: UID,
    generation: u64,
    treasury_id: ID,
    policy_id: ID,
    package_admin_id: ID,
}

// === Package Functions ===

public(package) fun new_bootstrap(
    publisher: Publisher,
    initial_generation: InitialGeneration,
    treasury_id: ID,
    policy_id: ID,
    ctx: &mut TxContext,
) {
    transfer::transfer(
        BlastMarketMakerBootstrap {
            id: object::new(ctx),
            publisher,
            treasury_id,
            policy_id,
            initial_generation,
        },
        ctx.sender(),
    );
}

public(package) fun destroy_bootstrap(
    self: BlastMarketMakerBootstrap,
): (Publisher, InitialGeneration, ID, ID) {
    let BlastMarketMakerBootstrap { id, publisher, treasury_id, policy_id, initial_generation } =
        self;
    id.delete();

    (publisher, initial_generation, treasury_id, policy_id)
}

public(package) fun initial_generation<Marker: drop>(otw: &Marker): InitialGeneration {
    assert!(sui::types::is_one_time_witness(otw), ENotOneTimeWitness);

    InitialGeneration { generation: PACKAGE_VERSION }
}

public(package) fun activate(
    initial_generation: InitialGeneration,
    treasury_id: ID,
    policy_id: ID,
    package_admin_id: ID,
    ctx: &mut TxContext,
) {
    let InitialGeneration { generation } = initial_generation;
    transfer::share_object(BlastMarketMakerVersion {
        id: object::new(ctx),
        generation,
        treasury_id,
        policy_id,
        package_admin_id,
    });
}

public(package) fun assert_current(self: &BlastMarketMakerVersion) {
    assert!(self.generation == PACKAGE_VERSION, EVersionMismatch);
}

public(package) fun assert_package_admin(self: &BlastMarketMakerVersion, package_admin_id: ID) {
    self.assert_current();
    self.assert_activation_custody(package_admin_id);
}

public(package) fun assert_treasury(self: &BlastMarketMakerVersion, treasury_id: ID) {
    self.assert_current();
    assert!(self.treasury_id == treasury_id, ECanonicalObjectMismatch);
}

public(package) fun assert_policy(self: &BlastMarketMakerVersion, policy_id: ID) {
    self.assert_current();
    assert!(self.policy_id == policy_id, ECanonicalObjectMismatch);
}

/// Only newly installed bytecode may activate its own next operational generation.
public(package) fun activate_generation(self: &mut BlastMarketMakerVersion) {
    self.activate_compiled_generation(PACKAGE_VERSION);
}

/// Identity check reserved for the new-bytecode activation authority path.
public(package) fun assert_activation_custody(
    self: &BlastMarketMakerVersion,
    package_admin_id: ID,
) {
    assert!(self.package_admin_id == package_admin_id, ECanonicalObjectMismatch);
}

// === Private Functions ===

fun activate_compiled_generation(self: &mut BlastMarketMakerVersion, compiled_generation: u64) {
    assert!(self.generation.checked_add(1).contains(&compiled_generation), EVersionMismatch);
    self.generation = compiled_generation;
    sui::event::emit(BlastGenerationAdvanced { generation: compiled_generation });
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(
    treasury_id: ID,
    policy_id: ID,
    ctx: &mut TxContext,
): BlastMarketMakerVersion {
    new_for_custody_testing(treasury_id, policy_id, object::id_from_address(@0x0), ctx)
}

#[test_only]
public fun new_for_custody_testing(
    treasury_id: ID,
    policy_id: ID,
    package_admin_id: ID,
    ctx: &mut TxContext,
): BlastMarketMakerVersion {
    BlastMarketMakerVersion {
        id: object::new(ctx),
        generation: PACKAGE_VERSION,
        treasury_id,
        policy_id,
        package_admin_id,
    }
}

#[test_only]
public fun set_generation_for_testing(self: &mut BlastMarketMakerVersion, generation: u64) {
    self.generation = generation;
}

#[test_only]
public fun activate_generation_for_testing(
    self: &mut BlastMarketMakerVersion,
    compiled_generation: u64,
) {
    self.activate_compiled_generation(compiled_generation);
}

// === Events ===

public struct BlastGenerationAdvanced has copy, drop { generation: u64 }

// === Constants ===

const PACKAGE_VERSION: u64 = 1;

// === Errors ===

#[error(code = 0)]
const EVersionMismatch: vector<u8> = b"The calling bytecode is not the active protocol generation.";
#[error(code = 1)]
const ECanonicalObjectMismatch: vector<u8> = b"The object is not the protocol's canonical object.";

#[error(code = 2)]
const ENotOneTimeWitness: vector<u8> =
    b"Only the publication one-time witness may seed the operational generation.";

// === Imports ===

use sui::package::Publisher;
