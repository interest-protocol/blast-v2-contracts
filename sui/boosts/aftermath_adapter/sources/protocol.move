// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Aftermath adapter operational generation and the partners Boosts accepts.
///
/// The generation value, its checked arithmetic, and its replay event belong to
/// `blast_admin::operational_version`. This module owns the shared container,
/// the two compiled constants that identify this bytecode and the bytecode a
/// governed upgrade cuts over to, and the list of accepted Blast partners, one
/// dynamic field per partner so the container's layout never changes.
module blast_boosts_aftermath::protocol;

// === Constants ===

/// Current adapter generation accepted by every protected mutation.
const PACKAGE_VERSION: u64 = 1;

/// The generation this bytecode hands over to in a governed upgrade.
const NEXT_PACKAGE_VERSION: u64 = 2;

// === Public Types ===

/// Shared operational generation for the Aftermath adapter package.
public struct Protocol has key {
    id: UID,
    generation: OperationalVersion<BLAST_BOOSTS_AFTERMATH>,
}

/// Dynamic-field key of a Blast partner Boosts accepts. Its value is the time
/// the partner stops being accepted: `u64::MAX` until Blast removes it.
public struct PartnerKey(ID) has copy, drop, store;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Package Functions ===

/// Rejects bytecode that is not the active adapter generation.
public(package) fun assert_current(self: &Protocol) {
    self.generation.assert_current(PACKAGE_VERSION);
}

/// Proves the cutover target is exactly next before any upgrade finalizer effect.
public(package) fun assert_next(self: &Protocol) {
    self.generation.assert_next(NEXT_PACKAGE_VERSION);
}

/// Advances the generation to the exact bytecode this upgrade installs.
public(package) fun advance(self: &mut Protocol) {
    self.generation.advance(self.id.to_inner(), NEXT_PACKAGE_VERSION);
}

/// Accepts `partner_id` at once. Adding a partner whose removal is pending
/// cancels the removal; adding a removed partner accepts it again.
public(package) fun add_partner(self: &mut Protocol, partner_id: ID) {
    let key = PartnerKey(partner_id);

    if (self.id.exists_dynamic_field(key)) {
        let accepted_until_ms: &mut u64 = self.id.borrow_dynamic_field_mut(key);
        assert!(*accepted_until_ms != std::u64::max_value!(), errors::partner_unchanged!());
        *accepted_until_ms = std::u64::max_value!();
    } else {
        self.id.add_dynamic_field(key, std::u64::max_value!());
    }
}

/// Stops accepting `partner_id` from `accepted_until_ms`. The partner must be
/// accepted at `now_ms` with no removal pending.
public(package) fun remove_partner(
    self: &mut Protocol,
    partner_id: ID,
    now_ms: u64,
    accepted_until_ms: u64,
) {
    self.assert_partner(partner_id, now_ms);

    let current: &mut u64 = self.id.borrow_dynamic_field_mut(PartnerKey(partner_id));
    assert!(*current == std::u64::max_value!(), errors::partner_unchanged!());
    *current = accepted_until_ms;
}

/// Aborts unless Boosts accepts `partner_id` at `now_ms`.
public(package) fun assert_partner(self: &Protocol, partner_id: ID, now_ms: u64) {
    let key = PartnerKey(partner_id);

    assert!(self.id.exists_dynamic_field(key), errors::partner_not_accepted!());
    let accepted_until_ms: u64 = *self.id.borrow_dynamic_field(key);
    assert!(now_ms < accepted_until_ms, errors::partner_not_accepted!());
}

// === Private Functions ===

fun new(ctx: &mut TxContext): Protocol {
    Protocol { id: object::new(ctx), generation: operational_version::new() }
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): Protocol {
    let mut protocol = new(ctx);
    protocol.generation.set_generation_for_testing(PACKAGE_VERSION);
    protocol
}

#[test_only]
public fun id_for_testing(self: &Protocol): ID {
    self.id.to_inner()
}

#[test_only]
public fun version_for_testing(self: &Protocol): u64 {
    self.generation.generation_for_testing()
}

#[test_only]
public fun set_version_for_testing(self: &mut Protocol, version: u64) {
    self.generation.set_generation_for_testing(version);
}

#[test_only]
/// Exercises the compiled cutover target without a native upgrade fixture.
public fun advance_for_testing(self: &mut Protocol) {
    self.advance();
}

#[test_only]
/// Exercises the finalizer's pre-commit proof without a native upgrade fixture.
public fun assert_next_for_testing(self: &Protocol) {
    self.assert_next();
}

#[test_only]
/// Exercises the generation guard every protected mutation runs first.
public fun assert_current_for_testing(self: &Protocol) {
    self.assert_current();
}

#[test_only]
/// Exercises the guard every trade that names a partner runs first.
public fun assert_partner_for_testing(self: &Protocol, partner_id: ID, now_ms: u64) {
    self.assert_partner(partner_id, now_ms);
}

// === Imports ===

use blast_admin::operational_version::{Self, OperationalVersion};

use blast_boosts_aftermath::{blast_boosts_aftermath::BLAST_BOOSTS_AFTERMATH, errors};

use sui::dynamic_field;

use fun dynamic_field::add as UID.add_dynamic_field;
use fun dynamic_field::borrow as UID.borrow_dynamic_field;
use fun dynamic_field::borrow_mut as UID.borrow_dynamic_field_mut;
use fun dynamic_field::exists as UID.exists_dynamic_field;
