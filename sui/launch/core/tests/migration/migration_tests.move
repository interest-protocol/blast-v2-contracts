// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_core::migration_tests;

// === Test-Only Types ===

public struct MEME() has drop;

public struct QUOTE() has drop;

public struct VenueWitness() has drop;

public struct OtherVenueWitness() has drop;

public struct TestPackageWitness() has drop;

public struct OtherPackageWitness() has drop;

// === Tests ===

#[test]
fun a_ticket_names_its_venue() {
    let venue = migration::issue_ticket<MEME, QUOTE, _>(VenueWitness()).redeem_ticket();

    assert_eq!(venue, type_name::with_original_ids<VenueWitness>());
}

#[test]
/// Reading a ticket's venue leaves `redeem_ticket` its one consuming path.
fun a_ticket_reads_its_venue_before_redemption() {
    let ticket = migration::issue_ticket<MEME, QUOTE, _>(VenueWitness());

    assert_eq!(ticket.venue(), type_name::with_original_ids<VenueWitness>());
    assert_eq!(ticket.redeem_ticket(), type_name::with_original_ids<VenueWitness>());
}

#[test]
/// A migration's readers return its venue, amounts, and terms; only `redeem` releases the
/// balances.
fun a_migration_reads_its_venue_amounts_and_terms_before_redemption() {
    let migration = new_migration(type_name::with_original_ids<VenueWitness>());

    assert_eq!(migration.venue(), type_name::with_original_ids<VenueWitness>());
    let (meme_amount, quote_amount) = migration.balances();
    assert_eq!(vector[meme_amount, quote_amount], vector[100, 200]);
    assert_eq!(*migration.terms(), sale_terms());

    let (meme, quote, terms) = migration.redeem(VenueWitness());
    assert_eq!(terms, sale_terms());
    destroy(meme);
    destroy(quote);
}

#[test]
fun terms_read_their_residual_policy() {
    let to_protocol = sale_terms().residuals();
    let to_owner = migration::residuals_to_owner();

    assert_eq!(to_protocol, migration::residuals_to_protocol());
    assert!(to_protocol.is_protocol() && !to_protocol.is_owner());
    assert!(to_owner.is_owner() && !to_owner.is_protocol());
}

#[test]
fun the_stored_venue_redeems_the_balances_and_terms() {
    let migration = new_migration(type_name::with_original_ids<VenueWitness>());
    let (meme, quote, terms) = migration.redeem(VenueWitness());

    assert_eq!(meme.value(), 100);
    assert_eq!(quote.value(), 200);
    assert_eq!(terms.origin(), sale_id());
    assert_eq!(terms.package_witness(), type_name::with_original_ids<TestPackageWitness>());
    let (meme_share, quote_share) = terms.protocol_bps();
    assert_eq!(vector[meme_share, quote_share], vector[bps::new(1_500), bps::new(1_000)]);
    assert_eq!(terms.partner_id(), option::none());
    assert!(terms.residuals().is_protocol());
    assert!(terms.fee_split().routes()[0].destination().is_owner());

    destroy(meme);
    destroy(quote);
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EWrongVenue, location = blast_core::migration)]
fun another_venue_cannot_redeem_the_migration() {
    let migration = new_migration(type_name::with_original_ids<VenueWitness>());
    let (meme, quote, _) = migration.redeem(OtherVenueWitness());

    destroy(meme);
    destroy(quote);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EWrongPackageWitness,
    location = blast_core::migration,
)]
fun a_package_cannot_migrate_with_another_packages_terms() {
    let migration = migration::new(
        OtherPackageWitness(),
        balance::create_for_testing<MEME>(1),
        balance::create_for_testing<QUOTE>(1),
        type_name::with_original_ids<VenueWitness>(),
        sale_terms(),
    );

    destroy(migration);
}

#[test]
/// A standalone issuer seals terms without a hand-off and issues the owner proofs for them.
fun standalone_terms_verify_owner_proofs_from_their_issuer() {
    let origin = sale_uid();
    let terms = migration::vault_terms(
        OtherPackageWitness(),
        &origin,
        owner_split(),
        bps::new(0),
        bps::new(0),
        option::none(),
        migration::residuals_to_owner(),
    );
    origin.delete();
    assert!(terms.residuals().is_owner());

    sale_proof(OtherPackageWitness()).assert_terms(&terms);
}

#[test]
fun an_owner_proof_reads_its_package_witness_and_sale() {
    let proof = sale_proof(TestPackageWitness());

    assert_eq!(proof.package_witness(), type_name::with_original_ids<TestPackageWitness>());
    assert_eq!(proof.origin(), sale_id());
    proof.assert_terms(&sale_terms());
}

#[test]
fun the_sale_owner_proof_verifies_against_its_vault_terms() {
    let terms = sale_terms();

    sale_proof(TestPackageWitness()).assert_terms(&terms);
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EWrongOwner,
    location = blast_core::owner_proof,
)]
fun another_package_cannot_prove_ownership() {
    sale_proof(OtherPackageWitness()).assert_terms(&sale_terms());
}

#[test]
#[expected_failure(
    abort_code = blast_core::errors::EWrongOwner,
    location = blast_core::owner_proof,
)]
fun another_sale_cannot_prove_ownership() {
    let mut ctx = sui::tx_context::dummy();
    let sale = object::new(&mut ctx);
    let other_sale = object::new(&mut ctx);
    sale.delete();
    let proof = owner_proof::new(TestPackageWitness(), &other_sale);
    other_sale.delete();
    proof.assert_terms(&sale_terms());
}

#[test]
fun terms_at_the_lp_fee_maximum_are_sealed() {
    let origin = sale_uid();
    let terms = migration::vault_terms(
        TestPackageWitness(),
        &origin,
        owner_split(),
        bps::new(constants::max_lp_fee_bps!()),
        bps::new(constants::max_lp_fee_bps!()),
        option::none(),
        migration::residuals_to_owner(),
    );
    origin.delete();
    let (meme_share, quote_share) = terms.protocol_bps();

    assert_eq!(vector[meme_share.value(), quote_share.value()], vector[3_000, 3_000]);
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidLpFeeBps, location = blast_core::migration)]
fun terms_reject_a_meme_share_above_the_lp_fee_maximum() {
    let origin = sale_uid();
    let terms = migration::vault_terms(
        TestPackageWitness(),
        &origin,
        owner_split(),
        bps::new(3_001),
        bps::new(0),
        option::none(),
        migration::residuals_to_owner(),
    );
    origin.delete();
    destroy(terms);
}

#[test]
#[expected_failure(abort_code = blast_core::errors::EInvalidLpFeeBps, location = blast_core::migration)]
fun terms_reject_a_quote_share_above_the_lp_fee_maximum() {
    let origin = sale_uid();
    let terms = migration::vault_terms(
        TestPackageWitness(),
        &origin,
        owner_split(),
        bps::new(0),
        bps::new(3_001),
        option::none(),
        migration::residuals_to_owner(),
    );
    origin.delete();
    destroy(terms);
}

#[test]
/// The product-free seams: `TestIssuer` seals terms and owner proofs, and `TestVenue` redeems.
fun the_test_issuer_hands_off_to_the_test_venue() {
    let origin = sale_uid();
    let terms = migration::vault_terms(
        migration::test_issuer(),
        &origin,
        owner_split(),
        bps::new(1_500),
        bps::new(1_500),
        option::none(),
        migration::residuals_to_owner(),
    );
    origin.delete();
    sale_proof(migration::test_issuer()).assert_terms(&terms);
    let ticket = migration::issue_ticket<MEME, QUOTE, _>(migration::test_venue());
    assert_eq!(ticket.redeem_ticket(), type_name::with_original_ids<TestVenue>());

    let migration = migration::new(
        migration::test_issuer(),
        balance::create_for_testing<MEME>(7),
        balance::create_for_testing<QUOTE>(9),
        type_name::with_original_ids<TestVenue>(),
        terms,
    );
    let (meme, quote, redeemed) = migration.redeem(migration::test_venue());

    assert_eq!(vector[meme.value(), quote.value()], vector[7, 9]);
    assert_eq!(redeemed.package_witness(), type_name::with_original_ids<TestIssuer>());
    destroy(meme);
    destroy(quote);
}

// Pool price

#[test]
fun equal_atomic_amounts_price_at_one_in_both_coin_orders() {
    let one_x64 = 1u128 << 64;

    assert_eq!(migration::sqrt_price_x64(1, 1, true), one_x64);
    assert_eq!(migration::sqrt_price_x64(1, 1, false), one_x64);
    let max = std::u64::max_value!();
    assert_eq!(migration::sqrt_price_x64(max, max, true), one_x64);
    assert_eq!(migration::sqrt_price_x64(max, max, false), one_x64);
}

#[test]
/// The atomic-unit vectors of `docs/vectors/quote-decimals.json`, in both coin orders.
fun the_seed_price_matches_the_quote_decimal_vectors() {
    let meme = 200_000_000_000_000_001;
    assert_eq!(migration::sqrt_price_x64(meme, 2_970_000_000_000, true), 71_085_815_383_773_548);
    assert_eq!(
        migration::sqrt_price_x64(meme, 2_970_000_000_000, false),
        4_786_923_594_866_905_679_395,
    );
    assert_eq!(migration::sqrt_price_x64(meme, 2_970_000_000, true), 2_247_930_859_429_608);
    assert_eq!(
        migration::sqrt_price_x64(meme, 2_970_000_000, false),
        151_375_815_449_805_255_005_138,
    );
    assert_eq!(migration::sqrt_price_x64(meme, 297_000_000_000, true), 22_479_308_594_296_080);
    assert_eq!(
        migration::sqrt_price_x64(meme, 297_000_000_000, false),
        15_137_581_544_980_525_500_513,
    );
    assert_eq!(
        migration::sqrt_price_x64(200_000_000_000_000, 2_970_000_000_000, true),
        2_247_930_859_429_608_031,
    );
    assert_eq!(
        migration::sqrt_price_x64(200_000_000_000_000, 2_970_000_000_000, false),
        151_375_815_449_805_254_626,
    );
}

#[test]
fun the_seed_price_rounds_the_square_root_down_in_both_coin_orders() {
    vector[true, false].do!(|meme_is_coin_a| {
        let sqrt_price = migration::sqrt_price_x64(3, 2, meme_is_coin_a);
        let ratio_q128 = if (meme_is_coin_a) (2u256 << 128) / 3 else (3u256 << 128) / 2;

        assert!((sqrt_price as u256) * (sqrt_price as u256) <= ratio_q128);
        assert!(((sqrt_price + 1) as u256) * ((sqrt_price + 1) as u256) > ratio_q128);
    });
}

#[test]
fun the_extreme_amounts_price_at_the_q64_range_ends() {
    let max = std::u64::max_value!();

    // 2^64 * sqrt(1 / max) floors to 2^32, and 2^64 * sqrt(max) to just below 2^96; neither
    // can seed a pool.
    assert_eq!(migration::sqrt_price_x64(max, 1, true), 1 << 32);
    assert_eq!(migration::sqrt_price_x64(1, max, true), 79_228_162_514_264_337_591_396_466_687);
    assert!(!migration::is_seedable_price(1 << 32));
    assert!(!migration::is_seedable_price(79_228_162_514_264_337_591_396_466_687));
    assert_eq!(migration::sqrt_price_x64(0, 1, false), 0);
}

#[test]
#[expected_failure(arithmetic_error, location = blast_core::migration)]
fun the_seed_price_rejects_zero_meme_as_coin_a() {
    migration::sqrt_price_x64(0, 1, true);
}

#[test]
#[expected_failure(arithmetic_error, location = blast_core::migration)]
fun the_seed_price_rejects_zero_quote_as_coin_a() {
    migration::sqrt_price_x64(1, 0, false);
}

#[test]
fun a_price_is_seedable_exactly_inside_the_halved_tick_range() {
    let min = 4_295_048_016;
    let min_seed = min * 2;
    let max_seed = ((1u256 << 128) / ((min_seed + 1) as u256)) as u128;

    assert!(!migration::is_seedable_price(min_seed));
    assert!(migration::is_seedable_price(min_seed + 1));
    assert!(!migration::is_seedable_price(min_seed - 1));
    assert!(migration::is_seedable_price(max_seed));
    assert!(!migration::is_seedable_price(max_seed + 1));
    assert!(migration::is_seedable_price(1 << 64));
    assert!(!migration::is_seedable_price(0));
}

#[test]
fun seedability_agrees_for_both_coin_orders() {
    vector[
        vector[1, 1],
        vector[1, 1_000_000_000],
        vector[1, 4_611_512_677_774_425_882],
        vector[4_611_512_677_774_425_882, 1],
        vector[1, 4_611_512_677_360_306_403],
        vector[4_611_512_677_360_306_403, 1],
        vector[1, 4_611_512_678_433_987_689],
        vector[4_611_512_678_433_987_689, 1],
        vector[200_000_000_000_000_001, 2_970_000_000],
        vector[std::u64::max_value!(), 1],
        vector[1, std::u64::max_value!()],
    ].do!(|amounts| {
        assert_eq!(
            migration::is_seedable_price(migration::sqrt_price_x64(amounts[0], amounts[1], true)),
            migration::is_seedable_price(migration::sqrt_price_x64(amounts[0], amounts[1], false)),
        );
    });
}

// === Test Helpers ===

fun sale_id(): ID {
    let origin = sale_uid();
    let id = origin.to_inner();
    origin.delete();
    id
}

/// A dummy context derives the same first sale ID for terms and proofs.
fun sale_uid(): UID { object::new(&mut sui::tx_context::dummy()) }

fun sale_proof<PackageWitness: drop>(witness: PackageWitness): OwnerProof {
    let origin = sale_uid();
    let proof = owner_proof::new(witness, &origin);
    origin.delete();
    proof
}

fun owner_split(): FeeSplit {
    fee_split::new(vector[fee_split::route(fee_split::owner_destination(), bps::new(10_000))])
}

fun sale_terms(): VaultTerms {
    let origin = sale_uid();
    let terms = migration::vault_terms(
        TestPackageWitness(),
        &origin,
        owner_split(),
        bps::new(1_500),
        bps::new(1_000),
        option::none(),
        migration::residuals_to_protocol(),
    );
    origin.delete();
    terms
}

fun new_migration(venue: TypeName): Migration<MEME, QUOTE> {
    migration::new(
        TestPackageWitness(),
        balance::create_for_testing<MEME>(100),
        balance::create_for_testing<QUOTE>(200),
        venue,
        sale_terms(),
    )
}

// === Imports ===

use blast_core::{
    bps,
    constants,
    fee_split::{Self, FeeSplit},
    migration::{Self, Migration, TestIssuer, TestVenue, VaultTerms},
    owner_proof::{Self, OwnerProof}
};

use std::{type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::balance;
