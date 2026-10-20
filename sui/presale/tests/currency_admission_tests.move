// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Exercises the production admission guard with framework-created Currency objects.
/// No test recreates the parser or manufactures a Currency byte layout.
module blast_presale::currency_admission_tests;

// === Test-Only Types ===

public struct CURRENCY_ADMISSION_TESTS has drop {}

public struct DynamicCoin has key { id: UID }

// === Tests ===

#[test]
fun unregulated_metadata_length_0_is_accepted() {
    // Vary every string independently; distinct neighbors expose field misalignment.
    4u64.do!(|field| {
        let mut ctx = tx_context::dummy();
        let mut metadata = default_metadata();
        let field_bytes = &mut metadata[field];
        *field_bytes = vector::tabulate!(0, |_| 65);
        let (treasury, currency) = currency_with_metadata((field * 85) as u8, metadata, option::none(), &mut ctx);
        presale::assert_unregulated_currency_for_testing(&currency);
        destroy(treasury);
        destroy(currency);
    });
}

#[test]
fun unregulated_metadata_length_1_is_accepted() {
    // Vary every string independently; distinct neighbors expose field misalignment.
    4u64.do!(|field| {
        let mut ctx = tx_context::dummy();
        let mut metadata = default_metadata();
        let field_bytes = &mut metadata[field];
        *field_bytes = vector::tabulate!(1, |_| 65);
        let (treasury, currency) = currency_with_metadata((field * 85) as u8, metadata, option::none(), &mut ctx);
        presale::assert_unregulated_currency_for_testing(&currency);
        destroy(treasury);
        destroy(currency);
    });
}

#[test]
fun unregulated_metadata_length_127_is_accepted() {
    // Vary every string independently; distinct neighbors expose field misalignment.
    4u64.do!(|field| {
        let mut ctx = tx_context::dummy();
        let mut metadata = default_metadata();
        let field_bytes = &mut metadata[field];
        *field_bytes = vector::tabulate!(127, |_| 65);
        let (treasury, currency) = currency_with_metadata((field * 85) as u8, metadata, option::none(), &mut ctx);
        presale::assert_unregulated_currency_for_testing(&currency);
        destroy(treasury);
        destroy(currency);
    });
}

#[test]
fun unregulated_metadata_length_128_is_accepted() {
    // Vary every string independently; distinct neighbors expose field misalignment.
    4u64.do!(|field| {
        let mut ctx = tx_context::dummy();
        let mut metadata = default_metadata();
        let field_bytes = &mut metadata[field];
        *field_bytes = vector::tabulate!(128, |_| 65);
        let (treasury, currency) = currency_with_metadata((field * 85) as u8, metadata, option::none(), &mut ctx);
        presale::assert_unregulated_currency_for_testing(&currency);
        destroy(treasury);
        destroy(currency);
    });
}

#[test]
fun unregulated_metadata_length_129_is_accepted() {
    // Vary every string independently; distinct neighbors expose field misalignment.
    4u64.do!(|field| {
        let mut ctx = tx_context::dummy();
        let mut metadata = default_metadata();
        let field_bytes = &mut metadata[field];
        *field_bytes = vector::tabulate!(129, |_| 65);
        let (treasury, currency) = currency_with_metadata((field * 85) as u8, metadata, option::none(), &mut ctx);
        presale::assert_unregulated_currency_for_testing(&currency);
        destroy(treasury);
        destroy(currency);
    });
}

#[test]
fun unregulated_metadata_length_16383_is_accepted() {
    // Vary every string independently; distinct neighbors expose field misalignment.
    4u64.do!(|field| {
        let mut ctx = tx_context::dummy();
        let mut metadata = default_metadata();
        let field_bytes = &mut metadata[field];
        *field_bytes = vector::tabulate!(16383, |_| 65);
        let (treasury, currency) = currency_with_metadata((field * 85) as u8, metadata, option::none(), &mut ctx);
        presale::assert_unregulated_currency_for_testing(&currency);
        destroy(treasury);
        destroy(currency);
    });
}

#[test]
fun unregulated_metadata_length_16384_is_accepted() {
    // Vary every string independently; distinct neighbors expose field misalignment.
    4u64.do!(|field| {
        let mut ctx = tx_context::dummy();
        let mut metadata = default_metadata();
        let field_bytes = &mut metadata[field];
        *field_bytes = vector::tabulate!(16384, |_| 65);
        let (treasury, currency) = currency_with_metadata((field * 85) as u8, metadata, option::none(), &mut ctx);
        presale::assert_unregulated_currency_for_testing(&currency);
        destroy(treasury);
        destroy(currency);
    });
}

#[test]
fun unregulated_metadata_length_16385_is_accepted() {
    // Vary every string independently; distinct neighbors expose field misalignment.
    4u64.do!(|field| {
        let mut ctx = tx_context::dummy();
        let mut metadata = default_metadata();
        let field_bytes = &mut metadata[field];
        *field_bytes = vector::tabulate!(16385, |_| 65);
        let (treasury, currency) = currency_with_metadata((field * 85) as u8, metadata, option::none(), &mut ctx);
        presale::assert_unregulated_currency_for_testing(&currency);
        destroy(treasury);
        destroy(currency);
    });
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun regulated_pause_false_long_metadata_field_0_is_rejected() {
    let mut ctx = tx_context::dummy();
    let mut metadata = default_metadata();
    let field_bytes = &mut metadata[0];
    *field_bytes = vector::tabulate!(16384, |_| 65);
    let (treasury, currency) = currency_with_metadata(255, metadata, option::some(false), &mut ctx);
    assert!(currency.is_regulated());
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(treasury);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun regulated_pause_false_long_metadata_field_1_is_rejected() {
    let mut ctx = tx_context::dummy();
    let mut metadata = default_metadata();
    let field_bytes = &mut metadata[1];
    *field_bytes = vector::tabulate!(16384, |_| 65);
    let (treasury, currency) = currency_with_metadata(255, metadata, option::some(false), &mut ctx);
    assert!(currency.is_regulated());
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(treasury);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun regulated_pause_false_long_metadata_field_2_is_rejected() {
    let mut ctx = tx_context::dummy();
    let mut metadata = default_metadata();
    let field_bytes = &mut metadata[2];
    *field_bytes = vector::tabulate!(16384, |_| 65);
    let (treasury, currency) = currency_with_metadata(255, metadata, option::some(false), &mut ctx);
    assert!(currency.is_regulated());
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(treasury);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun regulated_pause_false_long_metadata_field_3_is_rejected() {
    let mut ctx = tx_context::dummy();
    let mut metadata = default_metadata();
    let field_bytes = &mut metadata[3];
    *field_bytes = vector::tabulate!(16384, |_| 65);
    let (treasury, currency) = currency_with_metadata(255, metadata, option::some(false), &mut ctx);
    assert!(currency.is_regulated());
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(treasury);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun regulated_pause_true_long_metadata_field_0_is_rejected() {
    let mut ctx = tx_context::dummy();
    let mut metadata = default_metadata();
    let field_bytes = &mut metadata[0];
    *field_bytes = vector::tabulate!(16384, |_| 65);
    let (treasury, currency) = currency_with_metadata(255, metadata, option::some(true), &mut ctx);
    assert!(currency.is_regulated());
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(treasury);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun regulated_pause_true_long_metadata_field_1_is_rejected() {
    let mut ctx = tx_context::dummy();
    let mut metadata = default_metadata();
    let field_bytes = &mut metadata[1];
    *field_bytes = vector::tabulate!(16384, |_| 65);
    let (treasury, currency) = currency_with_metadata(255, metadata, option::some(true), &mut ctx);
    assert!(currency.is_regulated());
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(treasury);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun regulated_pause_true_long_metadata_field_2_is_rejected() {
    let mut ctx = tx_context::dummy();
    let mut metadata = default_metadata();
    let field_bytes = &mut metadata[2];
    *field_bytes = vector::tabulate!(16384, |_| 65);
    let (treasury, currency) = currency_with_metadata(255, metadata, option::some(true), &mut ctx);
    assert!(currency.is_regulated());
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(treasury);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun regulated_pause_true_long_metadata_field_3_is_rejected() {
    let mut ctx = tx_context::dummy();
    let mut metadata = default_metadata();
    let field_bytes = &mut metadata[3];
    *field_bytes = vector::tabulate!(16384, |_| 65);
    let (treasury, currency) = currency_with_metadata(255, metadata, option::some(true), &mut ctx);
    assert!(currency.is_regulated());
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(treasury);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun fixed_supply_0_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut treasury, mut currency) = currency_with_metadata(9, default_metadata(), option::none(), &mut ctx);
    let coins = treasury.mint(0, &mut ctx);
    currency.make_supply_fixed(treasury);
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(coins);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun fixed_supply_1_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut treasury, mut currency) = currency_with_metadata(9, default_metadata(), option::none(), &mut ctx);
    let coins = treasury.mint(1, &mut ctx);
    currency.make_supply_fixed(treasury);
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(coins);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun fixed_supply_257_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut treasury, mut currency) = currency_with_metadata(9, default_metadata(), option::none(), &mut ctx);
    let coins = treasury.mint(257, &mut ctx);
    currency.make_supply_fixed(treasury);
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(coins);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun fixed_supply_18446744073709551615_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut treasury, mut currency) = currency_with_metadata(9, default_metadata(), option::none(), &mut ctx);
    let coins = treasury.mint(18446744073709551615, &mut ctx);
    currency.make_supply_fixed(treasury);
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(coins);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun burn_only_supply_0_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut treasury, mut currency) = currency_with_metadata(9, default_metadata(), option::none(), &mut ctx);
    let coins = treasury.mint(0, &mut ctx);
    currency.make_supply_burn_only(treasury);
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(coins);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun burn_only_supply_1_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut treasury, mut currency) = currency_with_metadata(9, default_metadata(), option::none(), &mut ctx);
    let coins = treasury.mint(1, &mut ctx);
    currency.make_supply_burn_only(treasury);
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(coins);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun burn_only_supply_257_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut treasury, mut currency) = currency_with_metadata(9, default_metadata(), option::none(), &mut ctx);
    let coins = treasury.mint(257, &mut ctx);
    currency.make_supply_burn_only(treasury);
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(coins);
    destroy(currency);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun burn_only_supply_18446744073709551615_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (mut treasury, mut currency) = currency_with_metadata(9, default_metadata(), option::none(), &mut ctx);
    let coins = treasury.mint(18446744073709551615, &mut ctx);
    currency.make_supply_burn_only(treasury);
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(coins);
    destroy(currency);
}

#[test]
fun metadata_content_and_suffix_mutations_do_not_change_admission() {
    let mut ctx = tx_context::dummy();
    let (treasury, mut currency) = currency_with_metadata(255, default_metadata(), option::none(), &mut ctx);
    presale::assert_unregulated_currency_for_testing(&currency);
    let cap = currency.claim_metadata_cap(&treasury, &mut ctx);
    // Embedded tag-like bytes and multibyte UTF-8 must be skipped as string contents.
    currency.set_name(&cap, b"\x00\x01\x02\x7f\xc3\xa9".to_string());
    currency.set_description(&cap, vector::tabulate!(16384, |_| 1).to_string());
    currency.set_icon_url(&cap, b"\x02\x01\x00".to_string());
    presale::assert_unregulated_currency_for_testing(&currency);
    currency.delete_metadata_cap(cap);
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(treasury);
    destroy(currency);
}

#[test]
fun finalized_currency_with_registry_marker_is_accepted() {
    let mut ctx = tx_context::dummy();
    let (initializer, treasury) = initializer_with_metadata(9, default_metadata(), &mut ctx);
    let (mut currency, cap) = coin_registry::finalize_unwrap_for_testing(initializer, &mut ctx);
    presale::assert_unregulated_currency_for_testing(&currency);
    currency.delete_metadata_cap(cap);
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(treasury);
    destroy(currency);
}

#[test]
fun dynamic_currency_is_accepted() {
    let mut ctx = tx_context::dummy();
    let mut registry = coin_registry::create_coin_data_registry_for_testing(&mut ctx);
    let (initializer, treasury) = coin_registry::new_currency<DynamicCoin>(
        &mut registry, 0, b"DYN".to_string(), b"".to_string(), b"".to_string(), b"".to_string(), &mut ctx,
    );
    let currency = coin_registry::unwrap_for_testing(initializer);
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(treasury);
    destroy(currency);
    destroy(registry);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
fun dynamic_regulated_currency_is_rejected() {
    let mut ctx = tx_context::dummy();
    let mut registry = coin_registry::create_coin_data_registry_for_testing(&mut ctx);
    let (mut initializer, treasury) = coin_registry::new_currency<DynamicCoin>(
        &mut registry, 2, b"DYN".to_string(), b"".to_string(), b"".to_string(), b"".to_string(), &mut ctx,
    );
    let deny_cap = initializer.make_regulated(false, &mut ctx);
    let currency = coin_registry::unwrap_for_testing(initializer);
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(deny_cap);
    destroy(treasury);
    destroy(currency);
    destroy(registry);
}

#[test]
#[expected_failure(abort_code = presale::ESaleTokenNotUnregulated, location = blast_presale::blast_presale)]
#[allow(deprecated_usage)]
fun ordinary_legacy_unknown_currency_is_rejected_even_with_registered_treasury() {
    let mut ctx = tx_context::dummy();
    let (treasury, metadata) = coin::create_currency(
        test_utils::create_one_time_witness<CURRENCY_ADMISSION_TESTS>(),
        1, b"LEGACY", b"Legacy", b"", option::none(), &mut ctx,
    );
    let mut registry = coin_registry::create_coin_data_registry_for_testing(&mut ctx);
    let mut currency = coin_registry::migrate_legacy_metadata_for_testing(&mut registry, &metadata, &mut ctx);
    currency.set_treasury_cap_id(&treasury);
    assert!(!currency.is_regulated());
    presale::assert_unregulated_currency_for_testing(&currency);
    destroy(treasury);
    destroy(metadata);
    destroy(currency);
    destroy(registry);
}

// === Test Helpers ===

/// Metadata in Currency serialization order, with deliberately distinct lengths.
fun default_metadata(): vector<vector<u8>> {
    vector[b"Name", b"SYM", b"Description", b"https://example.com/icon"]
}

fun initializer_with_metadata(
    decimals: u8,
    metadata: vector<vector<u8>>,
    ctx: &mut TxContext,
): (CurrencyInitializer<CURRENCY_ADMISSION_TESTS>, TreasuryCap<CURRENCY_ADMISSION_TESTS>) {
    coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<CURRENCY_ADMISSION_TESTS>(),
        decimals, metadata[1].to_string(), metadata[0].to_string(), metadata[2].to_string(), metadata[3].to_string(), ctx,
    )
}

fun currency_with_metadata(
    decimals: u8,
    metadata: vector<vector<u8>>,
    regulation: Option<bool>,
    ctx: &mut TxContext,
): (TreasuryCap<CURRENCY_ADMISSION_TESTS>, Currency<CURRENCY_ADMISSION_TESTS>) {
    let (mut initializer, treasury) = initializer_with_metadata(decimals, metadata, ctx);
    regulation.do!(|pause| destroy(initializer.make_regulated(pause, ctx)));
    (treasury, coin_registry::unwrap_for_testing(initializer))
}

// === Imports ===

use blast_presale::blast_presale as presale;

use std::unit_test::destroy;

use sui::{coin::{Self, TreasuryCap}, coin_registry::{Self, Currency, CurrencyInitializer}, test_utils};
