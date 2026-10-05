// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::creation_policy_tests;

// === Constants ===

const PUBLISHER: address = @0xB1A57;

/// Where the test partner is paid, and its share of Blast's fee: 40%.
const PARTNER: address = @0x9A27;
const PARTNER_SHARE_BPS: u64 = 4_000;

/// When the administrator removes a partner in the removal tests.
const REMOVED_AT_MS: u64 = 1_000;

// === Test-Only Types ===

public struct QUOTE() has drop;

public struct OTHER_QUOTE() has drop;

public struct MIGRATOR() has drop;

// === Tests ===

#[test]
#[expected_failure(
    abort_code = creation_policy::EQuoteNotAllowed,
    location = blast_presale::creation_policy,
)]
/// Publication shares one policy that allows no Quote type and no migrator.
fun publication_shares_a_policy_that_allows_nothing() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    creation_policy::init_for_testing(scenario.ctx());

    scenario.next_tx(PUBLISHER);
    let policy = scenario.take_shared<CreationPolicy>();

    policy.assert_allowed<QUOTE, MIGRATOR>();
    abort
}

#[test]
/// The administrator allows a Quote type and a migrator, and each change emits its type.
fun the_admin_allows_a_quote_and_a_migrator() {
    let mut policy = allowing_nothing();
    let (admin_registry, admin_cap) = admin();

    policy.set_quote_allowed<QUOTE>(&admin_registry, &admin_cap, true);
    policy.set_migration_witness_allowed<MIGRATOR>(&admin_registry, &admin_cap, true);

    policy.assert_allowed<QUOTE, MIGRATOR>();
    let (quote, allowed) = last_event<QuoteSet>().quote_set_fields();
    assert_eq!(quote, type_name<QUOTE>());
    assert_eq!(allowed, true);
    let (migration_witness, allowed) = last_event<MigrationWitnessSet>()
        .migration_witness_set_fields();
    assert_eq!(migration_witness, type_name<MIGRATOR>());
    assert_eq!(allowed, true);

    policy.destroy_for_testing();
    admin_registry.destroy_for_testing(admin_cap);
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EQuoteNotAllowed,
    location = blast_presale::creation_policy,
)]
/// Allowing one Quote type allows no other.
fun allowing_one_quote_allows_no_other() {
    let policy = allowing<QUOTE, MIGRATOR>();

    policy.assert_allowed<OTHER_QUOTE, MIGRATOR>();
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EMigrationWitnessNotAllowed,
    location = blast_presale::creation_policy,
)]
/// An allowed Quote type is not enough without an allowed migrator.
fun an_allowed_quote_still_needs_an_allowed_migrator() {
    let mut policy = allowing_nothing();
    let (admin_registry, admin_cap) = admin();
    policy.set_quote_allowed<QUOTE>(&admin_registry, &admin_cap, true);

    policy.assert_allowed<QUOTE, MIGRATOR>();
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EQuoteNotAllowed,
    location = blast_presale::creation_policy,
)]
/// Disallowing a Quote type emits it and stops later creations from raising it.
fun disallowing_a_quote_stops_later_creations() {
    let mut policy = allowing<QUOTE, MIGRATOR>();
    let (admin_registry, admin_cap) = admin();

    policy.set_quote_allowed<QUOTE>(&admin_registry, &admin_cap, false);

    let (quote, allowed) = last_event<QuoteSet>().quote_set_fields();
    assert_eq!(quote, type_name<QUOTE>());
    assert_eq!(allowed, false);
    policy.assert_allowed<QUOTE, MIGRATOR>();
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EMigrationWitnessNotAllowed,
    location = blast_presale::creation_policy,
)]
/// Disallowing a migrator emits it and stops later creations through it.
fun disallowing_a_migrator_stops_later_creations() {
    let mut policy = allowing<QUOTE, MIGRATOR>();
    let (admin_registry, admin_cap) = admin();

    policy.set_migration_witness_allowed<MIGRATOR>(&admin_registry, &admin_cap, false);

    let (migration_witness, allowed) = last_event<MigrationWitnessSet>()
        .migration_witness_set_fields();
    assert_eq!(migration_witness, type_name<MIGRATOR>());
    assert_eq!(allowed, false);
    policy.assert_allowed<QUOTE, MIGRATOR>();
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EAllowanceUnchanged,
    location = blast_presale::creation_policy,
)]
fun an_allowed_quote_cannot_be_allowed_again() {
    let mut policy = allowing<QUOTE, MIGRATOR>();
    let (admin_registry, admin_cap) = admin();

    policy.set_quote_allowed<QUOTE>(&admin_registry, &admin_cap, true);
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EAllowanceUnchanged,
    location = blast_presale::creation_policy,
)]
fun an_unlisted_quote_cannot_be_disallowed() {
    let mut policy = allowing<QUOTE, MIGRATOR>();
    let (admin_registry, admin_cap) = admin();

    policy.set_quote_allowed<OTHER_QUOTE>(&admin_registry, &admin_cap, false);
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EAllowanceUnchanged,
    location = blast_presale::creation_policy,
)]
fun an_allowed_migrator_cannot_be_allowed_again() {
    let mut policy = allowing<QUOTE, MIGRATOR>();
    let (admin_registry, admin_cap) = admin();

    policy.set_migration_witness_allowed<MIGRATOR>(&admin_registry, &admin_cap, true);
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EAllowanceUnchanged,
    location = blast_presale::creation_policy,
)]
fun an_unlisted_migrator_cannot_be_disallowed() {
    let mut policy = allowing_nothing();
    let (admin_registry, admin_cap) = admin();

    policy.set_migration_witness_allowed<MIGRATOR>(&admin_registry, &admin_cap, false);
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EInvalidMigrationWitness,
    location = blast_presale::creation_policy,
)]
/// Any caller can make a primitive, so allowing one would let anyone create and migrate sales.
fun a_primitive_cannot_be_allowed_as_a_migrator() {
    let mut policy = allowing_nothing();
    let (admin_registry, admin_cap) = admin();

    policy.set_migration_witness_allowed<u64>(&admin_registry, &admin_cap, true);
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EInvalidMigrationWitness,
    location = blast_presale::creation_policy,
)]
/// Any caller can make a vector of droppable values, so it is rejected like a primitive.
fun a_vector_cannot_be_allowed_as_a_migrator() {
    let mut policy = allowing_nothing();
    let (admin_registry, admin_cap) = admin();

    policy.set_migration_witness_allowed<vector<MIGRATOR>>(&admin_registry, &admin_cap, true);
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EAllowanceUnchanged,
    location = blast_presale::creation_policy,
)]
/// Disallowing never needs the struct check: a primitive can never have been allowed.
fun disallowing_a_primitive_is_an_unchanged_allowance() {
    let mut policy = allowing_nothing();
    let (admin_registry, admin_cap) = admin();

    policy.set_migration_witness_allowed<u64>(&admin_registry, &admin_cap, false);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale_admin::EInvalidAdminCap,
    location = blast_presale::blast_presale_admin,
)]
/// The AdminCap is checked before the witness type.
fun a_foreign_admin_cap_is_rejected_before_the_witness_type() {
    let mut ctx = tx_context::dummy();
    let mut policy = creation_policy::new_for_testing(&mut ctx);
    let (admin_registry, admin_cap) = blast_presale_admin::new_for_testing(&mut ctx);
    let (other_registry, other_cap) = blast_presale_admin::new_for_testing(&mut ctx);

    policy.set_migration_witness_allowed<u64>(&admin_registry, &other_cap, true);

    policy.destroy_for_testing();
    admin_registry.destroy_for_testing(admin_cap);
    other_registry.destroy_for_testing(other_cap);
}

// --- Partners ---

#[test]
/// The administrator lets new presales name a partner at once, and the change emits it.
fun an_added_partner_is_accepted_at_once() {
    let mut ctx = tx_context::dummy();
    let (mut policy, admin_registry, admin_cap) = admin_with_policy(&mut ctx);
    let partner = partner(&mut ctx);

    policy.add_partner(&admin_registry, &admin_cap, &partner);

    policy.assert_partner(object::id(&partner), 0);
    assert_eq!(last_event<PartnerAdded>().partner_added_fields(), object::id(&partner));
    destroy(partner);
    policy.destroy_for_testing();
    admin_registry.destroy_for_testing(admin_cap);
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EPartnerNotAccepted,
    location = blast_presale::creation_policy,
)]
/// A partner the administrator never added cannot be named.
fun an_unlisted_partner_is_not_accepted() {
    let mut ctx = tx_context::dummy();
    let policy = creation_policy::new_for_testing(&mut ctx);
    let partner = partner(&mut ctx);

    policy.assert_partner(object::id(&partner), 0);
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EPartnerNotAccepted,
    location = blast_presale::creation_policy,
)]
/// A removed partner stays accepted until one millisecond before Blast's partner notice ends, and
/// is refused from then on.
fun a_removed_partner_is_accepted_until_its_notice_ends() {
    let mut ctx = tx_context::dummy();
    let (policy, partner_id) = removed_partner(&mut ctx);
    let accepted_until_ms = REMOVED_AT_MS + partners::delay_ms();

    let (removed_id, removed_until_ms) = last_event<PartnerRemoved>().partner_removed_fields();
    assert_eq!(removed_id, partner_id);
    assert_eq!(removed_until_ms, accepted_until_ms);
    policy.assert_partner(partner_id, accepted_until_ms - 1);

    policy.assert_partner(partner_id, accepted_until_ms);
    abort
}

#[test]
/// Adding a partner whose removal is pending cancels the removal.
fun re_adding_a_partner_cancels_its_removal() {
    let mut ctx = tx_context::dummy();
    let (mut policy, admin_registry, admin_cap) = admin_with_policy(&mut ctx);
    let partner = partner(&mut ctx);
    let clock = clock_at(REMOVED_AT_MS, &mut ctx);
    policy.add_partner(&admin_registry, &admin_cap, &partner);
    policy.remove_partner(&admin_registry, &admin_cap, &partner, &clock);

    policy.add_partner(&admin_registry, &admin_cap, &partner);

    policy.assert_partner(object::id(&partner), std::u64::max_value!() - 1);
    destroy(partner);
    clock.destroy_for_testing();
    policy.destroy_for_testing();
    admin_registry.destroy_for_testing(admin_cap);
}

#[test]
/// Adding a partner whose notice has ended accepts it again.
fun re_adding_a_removed_partner_accepts_it_again() {
    let mut ctx = tx_context::dummy();
    let (mut policy, admin_registry, admin_cap) = admin_with_policy(&mut ctx);
    let partner = partner(&mut ctx);
    let mut clock = clock_at(REMOVED_AT_MS, &mut ctx);
    policy.add_partner(&admin_registry, &admin_cap, &partner);
    policy.remove_partner(&admin_registry, &admin_cap, &partner, &clock);
    clock.set_for_testing(REMOVED_AT_MS + partners::delay_ms());

    policy.add_partner(&admin_registry, &admin_cap, &partner);

    policy.assert_partner(object::id(&partner), clock.timestamp_ms());
    destroy(partner);
    clock.destroy_for_testing();
    policy.destroy_for_testing();
    admin_registry.destroy_for_testing(admin_cap);
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EAllowanceUnchanged,
    location = blast_presale::creation_policy,
)]
fun an_accepted_partner_cannot_be_added_again() {
    let mut ctx = tx_context::dummy();
    let (mut policy, admin_registry, admin_cap) = admin_with_policy(&mut ctx);
    let partner = partner(&mut ctx);
    policy.add_partner(&admin_registry, &admin_cap, &partner);

    policy.add_partner(&admin_registry, &admin_cap, &partner);
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EAllowanceUnchanged,
    location = blast_presale::creation_policy,
)]
/// A pending removal cannot be restarted to push its notice back.
fun a_removed_partner_cannot_be_removed_again() {
    let mut ctx = tx_context::dummy();
    let (mut policy, admin_registry, admin_cap) = admin_with_policy(&mut ctx);
    let partner = partner(&mut ctx);
    let clock = clock_at(REMOVED_AT_MS, &mut ctx);
    policy.add_partner(&admin_registry, &admin_cap, &partner);
    policy.remove_partner(&admin_registry, &admin_cap, &partner, &clock);

    policy.remove_partner(&admin_registry, &admin_cap, &partner, &clock);
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EPartnerNotAccepted,
    location = blast_presale::creation_policy,
)]
fun an_unlisted_partner_cannot_be_removed() {
    let mut ctx = tx_context::dummy();
    let (mut policy, admin_registry, admin_cap) = admin_with_policy(&mut ctx);
    let partner = partner(&mut ctx);
    let clock = clock_at(REMOVED_AT_MS, &mut ctx);

    policy.remove_partner(&admin_registry, &admin_cap, &partner, &clock);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale_admin::EInvalidAdminCap,
    location = blast_presale::blast_presale_admin,
)]
/// Only the accepted AdminCap changes which partners new presales may name.
fun a_foreign_admin_cap_cannot_add_a_partner() {
    let mut ctx = tx_context::dummy();
    let (mut policy, admin_registry, _admin_cap) = admin_with_policy(&mut ctx);
    let (_other_registry, other_cap) = blast_presale_admin::new_for_testing(&mut ctx);
    let partner = partner(&mut ctx);

    policy.add_partner(&admin_registry, &other_cap, &partner);
    abort
}

// === Test Helpers ===

fun allowing_nothing(): CreationPolicy {
    let mut ctx = tx_context::dummy();

    creation_policy::new_for_testing(&mut ctx)
}

fun allowing<Quote, MigrationWitness>(): CreationPolicy {
    let mut ctx = tx_context::dummy();

    creation_policy::allowing_for_testing<Quote, MigrationWitness>(&mut ctx)
}

fun admin(): (AdminRegistry, AdminCap) {
    blast_presale_admin::new_for_testing(&mut tx_context::dummy())
}

/// An empty policy and its administrator, from `ctx` so later objects get distinct IDs.
fun admin_with_policy(ctx: &mut TxContext): (CreationPolicy, AdminRegistry, AdminCap) {
    let policy = creation_policy::new_for_testing(ctx);
    let (admin_registry, admin_cap) = blast_presale_admin::new_for_testing(ctx);

    (policy, admin_registry, admin_cap)
}

/// A registered Blast partner whose share is in force.
fun partner(ctx: &mut TxContext): Partner {
    partners::new_for_testing(PARTNER, PARTNER_SHARE_BPS, ctx)
}

fun clock_at(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(timestamp_ms);

    clock
}

/// A policy whose administrator added a partner and removed it at `REMOVED_AT_MS`, and the
/// partner's ID.
fun removed_partner(ctx: &mut TxContext): (CreationPolicy, ID) {
    let (mut policy, admin_registry, admin_cap) = admin_with_policy(ctx);
    let partner = partner(ctx);
    let clock = clock_at(REMOVED_AT_MS, ctx);
    let partner_id = object::id(&partner);
    policy.add_partner(&admin_registry, &admin_cap, &partner);

    policy.remove_partner(&admin_registry, &admin_cap, &partner, &clock);

    destroy(partner);
    clock.destroy_for_testing();
    admin_registry.destroy_for_testing(admin_cap);
    (policy, partner_id)
}

fun type_name<T>(): TypeName {
    type_name::with_original_ids<T>()
}

fun last_event<Event: copy + drop>(): Event {
    let mut events = event::events_by_type<Event>();
    events.pop_back()
}

// === Imports ===

use blast_partners::blast_partners::{Self as partners, Partner};

use blast_presale::{
    blast_presale_admin::{Self, AdminCap, AdminRegistry},
    creation_policy::{
        Self,
        CreationPolicy,
        MigrationWitnessSet,
        PartnerAdded,
        PartnerRemoved,
        QuoteSet,
    },
};

use std::{type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::{clock::{Self, Clock}, event, test_scenario};
