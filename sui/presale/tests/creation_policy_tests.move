// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::creation_policy_tests;

// === Constants ===

const PUBLISHER: address = @0xB1A57;

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
/// The fee administrator allows a Quote type and a migrator, and each change emits its type.
fun the_fee_admin_allows_a_quote_and_a_migrator() {
    let mut ctx = tx_context::dummy();
    let mut policy = creation_policy::new_for_testing(&mut ctx);

    policy.set_quote_allowed<QUOTE>(&fee_admin(), true);
    policy.set_migration_witness_allowed<MIGRATOR>(&fee_admin(), true);

    policy.assert_allowed<QUOTE, MIGRATOR>();
    let (quote, allowed) = last_event<QuoteSet>().quote_set_fields();
    assert_eq!(quote, type_name<QUOTE>());
    assert_eq!(allowed, true);
    let (migration_witness, allowed) = last_event<MigrationWitnessSet>()
        .migration_witness_set_fields();
    assert_eq!(migration_witness, type_name<MIGRATOR>());
    assert_eq!(allowed, true);
    policy.destroy_for_testing();
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
    let mut ctx = tx_context::dummy();
    let mut policy = creation_policy::new_for_testing(&mut ctx);
    policy.set_quote_allowed<QUOTE>(&fee_admin(), true);

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

    policy.set_quote_allowed<QUOTE>(&fee_admin(), false);

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

    policy.set_migration_witness_allowed<MIGRATOR>(&fee_admin(), false);

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

    policy.set_quote_allowed<QUOTE>(&fee_admin(), true);
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EAllowanceUnchanged,
    location = blast_presale::creation_policy,
)]
fun an_unlisted_quote_cannot_be_disallowed() {
    let mut policy = allowing<QUOTE, MIGRATOR>();

    policy.set_quote_allowed<OTHER_QUOTE>(&fee_admin(), false);
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EAllowanceUnchanged,
    location = blast_presale::creation_policy,
)]
fun an_allowed_migrator_cannot_be_allowed_again() {
    let mut policy = allowing<QUOTE, MIGRATOR>();

    policy.set_migration_witness_allowed<MIGRATOR>(&fee_admin(), true);
    abort
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EAllowanceUnchanged,
    location = blast_presale::creation_policy,
)]
fun an_unlisted_migrator_cannot_be_disallowed() {
    let mut ctx = tx_context::dummy();
    let mut policy = creation_policy::new_for_testing(&mut ctx);

    policy.set_migration_witness_allowed<MIGRATOR>(&fee_admin(), false);
    abort
}

// === Test Helpers ===

fun allowing<Quote, MigrationWitness>(): CreationPolicy {
    let mut ctx = tx_context::dummy();

    creation_policy::allowing_for_testing<Quote, MigrationWitness>(&mut ctx)
}

fun fee_admin(): AdminWitness<FeeAdmin> {
    blast_acl::witness_for_testing<FeeAdmin>()
}

fun type_name<T>(): TypeName {
    type_name::with_original_ids<T>()
}

fun last_event<Event: copy + drop>(): Event {
    let mut events = event::events_by_type<Event>();
    events.pop_back()
}

// === Imports ===

use blast_admin::blast_acl::{Self, AdminWitness};

use blast_presale::{
    blast_presale_domain::FeeAdmin,
    creation_policy::{Self, CreationPolicy, MigrationWitnessSet, QuoteSet},
};

use std::{type_name::{Self, TypeName}, unit_test::assert_eq};

use sui::{event, test_scenario};
