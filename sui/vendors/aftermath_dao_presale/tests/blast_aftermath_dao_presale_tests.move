// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_aftermath_dao_presale::blast_aftermath_dao_presale_tests;

// === Constants ===

/// The package's compiled treasury, which receives every pool's DAO fees, owner cap, and locked LP.
const TREASURY: address = @0x37cf46b499f740e653644bd2f7a8ed97f248e8b3c69d5d12c97d7845a54c0cd8;
const CREATOR: address = @0xC0FFEE;

const TOKEN_SUPPLY: u64 = 1_000_000_000;
const RAISE_TARGET: u64 = 1_000_000;
const DURATION_MS: u64 = 100;
const LIQUIDITY_WINDOW_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

public struct BLAST_AFTERMATH_DAO_PRESALE_TESTS() has drop;

public struct QUOTE() has drop;

public struct OTHER_MIGRATOR() has drop;

public struct A() has drop;

public struct AB() has drop;

// === Tests ===

#[test]
/// A sale created here names this migrator and pays its whole LP-fee split to the treasury.
fun new_creates_a_sale_whose_lp_fees_pay_the_treasury() {
    let mut scenario = test_scenario::begin(CREATOR);

    create_sale(
        creation_policy::allowing_for_testing<QUOTE, Witness>(scenario.ctx()),
        scenario.ctx(),
    );

    let (
        witness,
        tick_spacing,
        pool_fee_rate,
        fee_recipients,
        fee_recipient_bps,
        holder_rewards_bps,
    ) = last_event<PresaleCreated<BLAST_AFTERMATH_DAO_PRESALE_TESTS, QUOTE>>()
        .created_migration_fields();
    assert_eq!(witness, type_name::with_original_ids<Witness>());
    assert_eq!(tick_spacing, 0);
    assert_eq!(pool_fee_rate, 0);
    assert_eq!(fee_recipients, vector[TREASURY]);
    assert_eq!(fee_recipient_bps, vector[10_000]);
    assert_eq!(holder_rewards_bps, 0);

    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EMigrationWitnessNotAllowed,
    location = blast_presale::creation_policy,
)]
/// Blast must allow this migrator's witness before it can create a sale.
fun new_needs_blast_to_allow_the_witness() {
    let mut scenario = test_scenario::begin(CREATOR);

    create_sale(
        creation_policy::allowing_for_testing<QUOTE, OTHER_MIGRATOR>(scenario.ctx()),
        scenario.ctx(),
    );
    abort
}

#[test]
/// Coin order is the byte order of defining-ID type names, a strict prefix first.
fun coin_order_is_the_byte_order_of_type_names() {
    // This test package sits at 0x0, so its types sort before the framework's 0x2.
    assert!(sorts_before_for_testing<QUOTE, SUI>());
    assert!(!sorts_before_for_testing<SUI, QUOTE>());
    assert!(sorts_before_for_testing<A, AB>());
    assert!(!sorts_before_for_testing<AB, A>());
    assert!(sorts_before_for_testing<AB, QUOTE>());
    assert!(!sorts_before_for_testing<A, A>());
}

// === Test Helpers ===

/// Creates a sale through this migrator under `creation_policy` and shares it.
fun create_sale(creation_policy: CreationPolicy, ctx: &mut TxContext) {
    let fee_policy = fee_policy::new_for_testing(ctx);
    let clock = clock::create_for_testing(ctx);
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<BLAST_AFTERMATH_DAO_PRESALE_TESTS>(),
        9,
        b"SALE".to_string(),
        b"Sale Token".to_string(),
        b"Presale test token".to_string(),
        b"".to_string(),
        ctx,
    );
    let mut currency = coin_registry::unwrap_for_testing(initializer);

    let (sale, cap) = migrator::new<_, QUOTE>(
        treasury_cap,
        &mut currency,
        TOKEN_SUPPLY,
        bps::new(5_000),
        option::none(),
        bps::new(5_000),
        vector[],
        false,
        RAISE_TARGET,
        vector[],
        DURATION_MS,
        LIQUIDITY_WINDOW_MS,
        presale::open_eligibility(RAISE_TARGET, 1, RAISE_TARGET),
        option::none(),
        &creation_policy,
        &fee_policy,
        ctx,
    );

    sale.share(0, &clock);
    transfer::public_transfer(cap, CREATOR);
    destroy(currency);
    destroy(clock);
    destroy(fee_policy);
    destroy(creation_policy);
}

fun last_event<Event: copy + drop>(): Event {
    let mut events = event::events_by_type<Event>();
    events.pop_back()
}

// === Imports ===

use blast_aftermath_dao_presale::blast_aftermath_dao_presale::{
    Self as migrator,
    Witness,
    sorts_before_for_testing,
};

use blast_presale::{
    blast_presale::{Self as presale, PresaleCreated},
    bps,
    creation_policy::{Self, CreationPolicy},
    fee_policy,
};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{clock, coin_registry, event, sui::SUI, test_scenario, test_utils};
