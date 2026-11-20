// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

module blast_boosts_aftermath::blast_boosts_aftermath;

// === Constants ===

const PACKAGE_VERSION: u64 = 1;

// === Public Types ===

public struct BLAST_BOOSTS_AFTERMATH() has drop;

public struct PackageWitness() has drop;

/// The serving generation advances only when the successor activates (ADR 0123).
public struct Protocol has key {
    id: UID,
    generation: u64,
    partners: PartnerList,
}

public struct GenerationActivated has copy, drop {
    protocol: ID,
    previous: u64,
    current: u64,
}

// === Private Initialization ===

fun init(otw: BLAST_BOOSTS_AFTERMATH, ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
    package_version::new_publication<_, PackageWitness>(otw, deposits!(), ctx).keep(ctx);
}

// === Package Functions ===

/// Pauses issuance and minting without interrupting existing holders' exits.
macro public(package) fun deposits(): u8 { 1 }

public(package) fun package_witness(): PackageWitness { PackageWitness() }

public(package) fun assert_current(self: &Protocol) {
    assert!(self.generation == PACKAGE_VERSION, EGenerationMismatch);
}

public(package) fun activate(self: &mut Protocol) {
    assert!(self.generation < std::u64::max_value!(), EGenerationOverflow);
    let previous = self.generation;
    assert!(previous + 1 == PACKAGE_VERSION, EGenerationMismatch);
    self.generation = PACKAGE_VERSION;
    blast_boosts_aftermath::blast_events::emit_event(GenerationActivated { protocol: self.id.to_inner(), previous, current: PACKAGE_VERSION });
}

public(package) fun partners(self: &Protocol): &PartnerList { &self.partners }

public(package) fun partners_mut(self: &mut Protocol): &mut PartnerList { &mut self.partners }

// === Private Functions ===

fun new(ctx: &mut TxContext): Protocol {
    let id = object::new(ctx);
    let partners = partner_list::new(&id, ctx);
    Protocol { id, generation: 1, partners }
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(BLAST_BOOSTS_AFTERMATH(), ctx) }

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): Protocol { new(ctx) }

#[test_only]
public fun version_for_testing(self: &Protocol): u64 { self.generation }

#[test_only]
public fun set_version_for_testing(self: &mut Protocol, version: u64) { self.generation = version }

#[test_only]
public fun assert_current_for_testing(self: &Protocol) { self.assert_current() }

#[test_only]
public fun assert_partner_for_testing(self: &Protocol, id: ID, clock: &sui::clock::Clock) {
    self.partners.assert_accepted(id, clock);
}

#[test_only]
public fun active_version_for_testing(ctx: &mut TxContext): PackageVersion<BLAST_BOOSTS_AFTERMATH> {
    package_version::new_for_testing<_, PackageWitness>(deposits!(), ctx)
}

#[test_only]
public fun fields_for_testing(self: &GenerationActivated): (ID, u64, u64) {
    (self.protocol, self.previous, self.current)
}

// === Errors ===

const EGenerationMismatch: u64 = 0;
const EGenerationOverflow: u64 = 1;

// === Imports ===

use blast_admin::package_version;

#[test_only]
use blast_admin::package_version::PackageVersion;

use blast_partners::partner_list::{Self, PartnerList};
