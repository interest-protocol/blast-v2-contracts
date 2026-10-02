// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::fees_tests;

// === Constants ===

const PROTOCOL_ADMIN: address = @0xAD;

const PROTOCOL_FEE_SHARE_BPS: u64 = 5_000;

// === Test-Only Types ===

public struct TEST_MEME() has drop;

public struct TEST_QUOTE() has drop;

/// A live protocol fee share an administrator can change between accruals.
public struct FeesFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    runtime_config: RuntimeConfig,
}

// === Tests ===

#[test]
fun dual_asset_accrual_splits_and_claims_exactly() {
    let mut ctx = tx_context::dummy();
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>(balance::zero());

    let (
        protocol_meme_delta,
        creator_meme_delta,
        protocol_quote_delta,
        creator_quote_delta,
    ) = accrue(&mut ledger, 9, 10, 7_000);

    assert_eq!(protocol_meme_delta, 7);
    assert_eq!(creator_meme_delta, 2);
    assert_eq!(protocol_quote_delta, 7);
    assert_eq!(creator_quote_delta, 3);
    assert_eq!(totals(&ledger), vector[7, 2, 7, 3]);

    let (creator_meme, creator_quote) = ledger.claim_creator_fees(&mut ctx);
    let (protocol_meme, protocol_quote, protocol_sui) = ledger.claim_protocol_fees(&mut ctx);

    assert_eq!(creator_meme.value(), 2);
    assert_eq!(creator_quote.value(), 3);
    assert_eq!(protocol_meme.value(), 7);
    assert_eq!(protocol_quote.value(), 7);
    assert_eq!(totals(&ledger), vector[0, 0, 0, 0]);

    destroy(creator_meme);
    destroy(creator_quote);
    destroy(protocol_meme);
    destroy(protocol_quote);
    destroy(protocol_sui);
    destroy(ledger);
}

#[test]
fun protocol_fee_share_boundaries_route_every_accrued_unit() {
    let mut ctx = tx_context::dummy();
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>(balance::zero());

    let (
        protocol_meme_delta,
        creator_meme_delta,
        protocol_quote_delta,
        creator_quote_delta,
    ) = accrue(&mut ledger, 9, 10, 0);

    assert_eq!(protocol_meme_delta, 0);
    assert_eq!(creator_meme_delta, 9);
    assert_eq!(protocol_quote_delta, 0);
    assert_eq!(creator_quote_delta, 10);

    let (
        protocol_meme_delta,
        creator_meme_delta,
        protocol_quote_delta,
        creator_quote_delta,
    ) = accrue(&mut ledger, 5, 6, 10_000);

    assert_eq!(protocol_meme_delta, 5);
    assert_eq!(creator_meme_delta, 0);
    assert_eq!(protocol_quote_delta, 6);
    assert_eq!(creator_quote_delta, 0);

    let (creator_meme, creator_quote) = ledger.claim_creator_fees(&mut ctx);
    let (protocol_meme, protocol_quote, protocol_sui) = ledger.claim_protocol_fees(&mut ctx);

    assert_eq!(creator_meme.value(), 9);
    assert_eq!(creator_quote.value(), 10);
    assert_eq!(protocol_meme.value(), 5);
    assert_eq!(protocol_quote.value(), 6);

    destroy(creator_meme);
    destroy(creator_quote);
    destroy(protocol_meme);
    destroy(protocol_quote);
    destroy(protocol_sui);
    destroy(ledger);
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ENothingAccrued,
    location = blast_fun::fees,
)]
fun protocol_cannot_claim_when_nothing_is_accrued() {
    let mut ctx = tx_context::dummy();
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>(balance::zero());

    let (meme, quote, sui) = ledger.claim_protocol_fees(&mut ctx);

    destroy(meme);
    destroy(quote);
    destroy(sui);
    destroy(ledger);
}

#[test]
/// The creation fee alone is enough to claim: Blast takes it before any trade.
fun protocol_claims_the_creation_fee_before_any_trade() {
    let mut ctx = tx_context::dummy();
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>(balance::create_for_testing(1_001));

    let (meme, quote, sui) = ledger.claim_protocol_fees(&mut ctx);

    assert_eq!(meme.value(), 0);
    assert_eq!(quote.value(), 0);
    assert_eq!(sui.value(), 1_001);
    assert_eq!(ledger.protocol_sui_for_testing(), 0);

    destroy(meme);
    destroy(quote);
    destroy(sui);
    destroy(ledger);
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ENothingAccrued,
    location = blast_fun::fees,
)]
fun creator_cannot_claim_when_nothing_is_accrued() {
    let mut ctx = tx_context::dummy();
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>(balance::zero());

    let (meme, quote) = ledger.claim_creator_fees(&mut ctx);

    destroy(meme);
    destroy(quote);
    destroy(ledger);
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ENothingAccrued,
    location = blast_fun::fees,
)]
fun creator_cannot_claim_when_the_whole_fee_went_to_the_protocol() {
    let mut ctx = tx_context::dummy();
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>(balance::zero());

    accrue(&mut ledger, 5, 6, 10_000);
    let (meme, quote) = ledger.claim_creator_fees(&mut ctx);

    destroy(meme);
    destroy(quote);
    destroy(ledger);
}

#[test]
fun accrual_of_two_zero_balances_changes_nothing() {
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>(balance::zero());

    let (
        protocol_meme_delta,
        creator_meme_delta,
        protocol_quote_delta,
        creator_quote_delta,
    ) = accrue(&mut ledger, 0, 0, PROTOCOL_FEE_SHARE_BPS);

    assert_eq!(protocol_meme_delta, 0);
    assert_eq!(creator_meme_delta, 0);
    assert_eq!(protocol_quote_delta, 0);
    assert_eq!(creator_quote_delta, 0);
    assert_eq!(totals(&ledger), vector[0, 0, 0, 0]);

    destroy(ledger);
}

#[test]
fun maximum_u64_fees_match_the_committed_split_vector() {
    let mut ctx = tx_context::dummy();
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>(balance::zero());

    accrue(
        &mut ledger,
        std::u64::max_value!(),
        std::u64::max_value!(),
        PROTOCOL_FEE_SHARE_BPS,
    );

    let (creator_meme, creator_quote) = ledger.claim_creator_fees(&mut ctx);
    let (protocol_meme, protocol_quote, protocol_sui) = ledger.claim_protocol_fees(&mut ctx);

    assert_eq!(creator_meme.value(), 9_223_372_036_854_775_807);
    assert_eq!(creator_quote.value(), 9_223_372_036_854_775_807);
    assert_eq!(protocol_meme.value(), 9_223_372_036_854_775_808);
    assert_eq!(protocol_quote.value(), 9_223_372_036_854_775_808);

    destroy(creator_meme);
    destroy(creator_quote);
    destroy(protocol_meme);
    destroy(protocol_quote);
    destroy(protocol_sui);
    destroy(ledger);
}

#[test]
fun changed_protocol_fee_share_applies_to_the_next_accrual() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>(balance::zero());

        f.set_protocol_fee_share(PROTOCOL_FEE_SHARE_BPS);
        ledger.accrue(
            balance::create_for_testing<TEST_MEME>(3),
            balance::create_for_testing<TEST_QUOTE>(4),
            f.runtime_config.protocol_fee_share(),
        );
        f.set_protocol_fee_share(8_000);
        let (
            protocol_meme_delta,
            creator_meme_delta,
            protocol_quote_delta,
            creator_quote_delta,
        ) = ledger.accrue(
            balance::create_for_testing<TEST_MEME>(5),
            balance::create_for_testing<TEST_QUOTE>(6),
            f.runtime_config.protocol_fee_share(),
        );

        assert_eq!(protocol_meme_delta, 4);
        assert_eq!(creator_meme_delta, 1);
        assert_eq!(protocol_quote_delta, 5);
        assert_eq!(creator_quote_delta, 1);
        let (protocol_meme, protocol_quote, protocol_sui) = ledger.claim_protocol_fees(f.ctx!());
        let (creator_meme, creator_quote) = ledger.claim_creator_fees(f.ctx!());

        assert_eq!(protocol_meme.value(), 6);
        assert_eq!(protocol_quote.value(), 7);
        assert_eq!(creator_meme.value(), 2);
        assert_eq!(creator_quote.value(), 3);

        destroy(protocol_meme);
        destroy(protocol_quote);
        destroy(protocol_sui);
        destroy(creator_meme);
        destroy(creator_quote);
        destroy(ledger);
    });

    fixture.end();
}

#[test]
fun meme_only_accrual_returns_zero_quote_coins() {
    let mut ctx = tx_context::dummy();
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>(balance::zero());

    accrue(&mut ledger, 3, 0, PROTOCOL_FEE_SHARE_BPS);

    let (creator_meme, creator_quote) = ledger.claim_creator_fees(&mut ctx);
    let (protocol_meme, protocol_quote, protocol_sui) = ledger.claim_protocol_fees(&mut ctx);

    assert_eq!(creator_meme.value(), 1);
    assert_eq!(creator_quote.value(), 0);
    assert_eq!(protocol_meme.value(), 2);
    assert_eq!(protocol_quote.value(), 0);

    destroy(creator_meme);
    destroy(creator_quote);
    destroy(protocol_meme);
    destroy(protocol_quote);
    destroy(protocol_sui);
    destroy(ledger);
}

#[test]
fun quote_only_accrual_returns_zero_meme_coins() {
    let mut ctx = tx_context::dummy();
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>(balance::zero());

    accrue(&mut ledger, 0, 4, PROTOCOL_FEE_SHARE_BPS);

    let (creator_meme, creator_quote) = ledger.claim_creator_fees(&mut ctx);
    let (protocol_meme, protocol_quote, protocol_sui) = ledger.claim_protocol_fees(&mut ctx);

    assert_eq!(creator_meme.value(), 0);
    assert_eq!(creator_quote.value(), 2);
    assert_eq!(protocol_meme.value(), 0);
    assert_eq!(protocol_quote.value(), 2);

    destroy(creator_meme);
    destroy(creator_quote);
    destroy(protocol_meme);
    destroy(protocol_quote);
    destroy(protocol_sui);
    destroy(ledger);
}

// === Test Helpers ===

fun accrue(
    ledger: &mut FeeLedger<TEST_MEME, TEST_QUOTE>,
    meme_fee: u64,
    quote_fee: u64,
    protocol_fee_share_bps: u64,
): (u64, u64, u64, u64) {
    ledger.accrue(
        balance::create_for_testing(meme_fee),
        balance::create_for_testing(quote_fee),
        bps::new(protocol_fee_share_bps),
    )
}

/// The ledger's `[protocol_meme, creator_meme, protocol_quote, creator_quote]` balances.
fun totals(ledger: &FeeLedger<TEST_MEME, TEST_QUOTE>): vector<u64> {
    let (protocol_meme, creator_meme, protocol_quote, creator_quote) = ledger.totals_for_testing();

    vector[protocol_meme, creator_meme, protocol_quote, creator_quote]
}

macro fun next_tx($fixture: &mut FeesFixture, $sender: address, $fn: |&mut FeesFixture|) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun ctx($fixture: &mut FeesFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

/// A runtime configuration with no protocol share.
fun start(): FeesFixture {
    let mut scenario = test_scenario::begin(PROTOCOL_ADMIN);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let runtime_config = runtime_config::new_disabled_for_testing(scenario.ctx());

    FeesFixture { scenario, package_version, runtime_config }
}

fun set_protocol_fee_share(self: &mut FeesFixture, protocol_fee_share_bps: u64) {
    let admin_witness = blast_acl::witness_for_testing<FeeAdmin>();

    self
        .runtime_config
        .set_protocol_fee_share(
            &self.package_version,
            &admin_witness,
            bps::new(protocol_fee_share_bps),
        );
}

fun end(self: FeesFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::blast_acl;

use blast_fun::{
    blast_fun_domain::FeeAdmin,
    bps,
    fees::{Self, FeeLedger},
    blast_fun::{Self as package_version, PackageVersion},
    runtime_config::{Self, RuntimeConfig},
};

use std::unit_test::{assert_eq, destroy};

use sui::{balance, test_scenario::{Self, Scenario}};
