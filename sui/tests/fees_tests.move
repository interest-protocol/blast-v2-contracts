#[test_only]
module blast_fun::fees_tests;

use blast_fun::{acl, creator_authority, fees, runtime_config};
use std::unit_test::{assert_eq, destroy};
use sui::{
    balance,
    clock::{Self, Clock},
    coin::Coin,
    test_scenario::{Self, Scenario},
};

// === Constants ===

const CREATOR: address = @0xC0FFEE;
const BENEFICIARY: address = @0xB0B;
const PAYOUT_RECIPIENT: address = @0xCAFE;
const PROTOCOL_FEE_SHARE_BPS: u64 = 5_000;

// === Test-Only Types ===

public struct TEST_MEME() has drop;
public struct TEST_QUOTE() has drop;

public struct Fixture {
    scenario: Scenario,
    super_admin_cap: acl::SuperAdminCap,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
    runtime_config: runtime_config::RuntimeConfig,
    clock: Clock,
    creator_cap: creator_authority::CreatorCap<TEST_MEME>,
}

// === Tests ===

#[test]
fun dual_asset_accrual_splits_and_claims_exactly() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

    let (
        protocol_meme_delta,
        creator_meme_delta,
        protocol_quote_delta,
        creator_quote_delta,
        protocol_meme_total,
        creator_meme_total,
        protocol_quote_total,
        creator_quote_total,
    ) = ledger.accrue(
        balance::create_for_testing<TEST_MEME>(9),
        balance::create_for_testing<TEST_QUOTE>(10),
        7_000,
    );

    assert_eq!(protocol_meme_delta, 7);
    assert_eq!(creator_meme_delta, 2);
    assert_eq!(protocol_quote_delta, 7);
    assert_eq!(creator_quote_delta, 3);
    assert_eq!(protocol_meme_total, 7);
    assert_eq!(creator_meme_total, 2);
    assert_eq!(protocol_quote_total, 7);
    assert_eq!(creator_quote_total, 3);

    let (creator_meme, creator_quote) =
        ledger.claim_creator_fees(&fixture.creator_cap, fixture.scenario.ctx());
    let (protocol_meme, protocol_quote) =
        ledger.claim_protocol_fees(&admin_witness, fixture.scenario.ctx());

    assert_eq!(creator_meme.value(), 2);
    assert_eq!(creator_quote.value(), 3);
    assert_eq!(protocol_meme.value(), 7);
    assert_eq!(protocol_quote.value(), 7);

    destroy(creator_meme);
    destroy(creator_quote);
    destroy(protocol_meme);
    destroy(protocol_quote);
    destroy(ledger);
    fixture.end();
}

#[test]
fun protocol_fee_share_boundaries_route_every_accrued_unit() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

    let (
        protocol_meme_delta,
        creator_meme_delta,
        protocol_quote_delta,
        creator_quote_delta,
        protocol_meme_total,
        creator_meme_total,
        protocol_quote_total,
        creator_quote_total,
    ) = ledger.accrue(
        balance::create_for_testing<TEST_MEME>(9),
        balance::create_for_testing<TEST_QUOTE>(10),
        0,
    );

    assert_eq!(protocol_meme_delta, 0);
    assert_eq!(creator_meme_delta, 9);
    assert_eq!(protocol_quote_delta, 0);
    assert_eq!(creator_quote_delta, 10);
    assert_eq!(protocol_meme_total, 0);
    assert_eq!(creator_meme_total, 9);
    assert_eq!(protocol_quote_total, 0);
    assert_eq!(creator_quote_total, 10);

    let (
        protocol_meme_delta,
        creator_meme_delta,
        protocol_quote_delta,
        creator_quote_delta,
        protocol_meme_total,
        creator_meme_total,
        protocol_quote_total,
        creator_quote_total,
    ) = ledger.accrue(
        balance::create_for_testing<TEST_MEME>(5),
        balance::create_for_testing<TEST_QUOTE>(6),
        10_000,
    );

    assert_eq!(protocol_meme_delta, 5);
    assert_eq!(creator_meme_delta, 0);
    assert_eq!(protocol_quote_delta, 6);
    assert_eq!(creator_quote_delta, 0);
    assert_eq!(protocol_meme_total, 5);
    assert_eq!(creator_meme_total, 9);
    assert_eq!(protocol_quote_total, 6);
    assert_eq!(creator_quote_total, 10);

    let (creator_meme, creator_quote) =
        ledger.claim_creator_fees(&fixture.creator_cap, fixture.scenario.ctx());
    let (protocol_meme, protocol_quote) =
        ledger.claim_protocol_fees(&admin_witness, fixture.scenario.ctx());

    assert_eq!(creator_meme.value(), 9);
    assert_eq!(creator_quote.value(), 10);
    assert_eq!(protocol_meme.value(), 5);
    assert_eq!(protocol_quote.value(), 6);

    destroy(creator_meme);
    destroy(creator_quote);
    destroy(protocol_meme);
    destroy(protocol_quote);
    destroy(ledger);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = 38)]
fun protocol_cannot_claim_when_nothing_is_accrued() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();
    let (meme, quote) =
        ledger.claim_protocol_fees(&admin_witness, fixture.scenario.ctx());

    destroy(meme);
    destroy(quote);
    destroy(ledger);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = 38)]
fun creator_cannot_claim_when_nothing_is_accrued() {
    let mut fixture = start();
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();
    let (meme, quote) =
        ledger.claim_creator_fees(&fixture.creator_cap, fixture.scenario.ctx());

    destroy(meme);
    destroy(quote);
    destroy(ledger);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = 39)]
fun accrual_rejects_two_zero_asset_balances() {
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

    ledger.accrue(
        balance::create_for_testing<TEST_MEME>(0),
        balance::create_for_testing<TEST_QUOTE>(0),
        PROTOCOL_FEE_SHARE_BPS,
    );

    destroy(ledger);
}

#[test]
fun maximum_u64_fees_match_the_committed_split_vector() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

    ledger.accrue(
        balance::create_for_testing<TEST_MEME>(std::u64::max_value!()),
        balance::create_for_testing<TEST_QUOTE>(std::u64::max_value!()),
        PROTOCOL_FEE_SHARE_BPS,
    );

    let (creator_meme, creator_quote) =
        ledger.claim_creator_fees(&fixture.creator_cap, fixture.scenario.ctx());
    let (protocol_meme, protocol_quote) =
        ledger.claim_protocol_fees(&admin_witness, fixture.scenario.ctx());

    assert_eq!(creator_meme.value(), 9_223_372_036_854_775_807);
    assert_eq!(creator_quote.value(), 9_223_372_036_854_775_807);
    assert_eq!(protocol_meme.value(), 9_223_372_036_854_775_808);
    assert_eq!(protocol_quote.value(), 9_223_372_036_854_775_808);

    destroy(creator_meme);
    destroy(creator_quote);
    destroy(protocol_meme);
    destroy(protocol_quote);
    destroy(ledger);
    fixture.end();
}

#[test]
fun changed_protocol_fee_share_applies_to_the_next_accrual() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

    fixture.runtime_config.set_protocol_fee_share(&admin_witness, PROTOCOL_FEE_SHARE_BPS);
    ledger.accrue(
        balance::create_for_testing<TEST_MEME>(3),
        balance::create_for_testing<TEST_QUOTE>(4),
        fixture.runtime_config.protocol_fee_share_bps(),
    );
    fixture.runtime_config.set_protocol_fee_share(&admin_witness, 8_000);
    let (
        protocol_meme_delta,
        creator_meme_delta,
        protocol_quote_delta,
        creator_quote_delta,
        protocol_meme_total,
        creator_meme_total,
        protocol_quote_total,
        creator_quote_total,
    ) = ledger.accrue(
        balance::create_for_testing<TEST_MEME>(5),
        balance::create_for_testing<TEST_QUOTE>(6),
        fixture.runtime_config.protocol_fee_share_bps(),
    );

    assert_eq!(protocol_meme_delta, 4);
    assert_eq!(creator_meme_delta, 1);
    assert_eq!(protocol_quote_delta, 5);
    assert_eq!(creator_quote_delta, 1);
    assert_eq!(protocol_meme_total, 6);
    assert_eq!(creator_meme_total, 2);
    assert_eq!(protocol_quote_total, 7);
    assert_eq!(creator_quote_total, 3);

    let (protocol_meme, protocol_quote) =
        ledger.claim_protocol_fees(&admin_witness, fixture.scenario.ctx());
    let (creator_meme, creator_quote) =
        ledger.claim_creator_fees(&fixture.creator_cap, fixture.scenario.ctx());

    assert_eq!(protocol_meme.value(), 6);
    assert_eq!(protocol_quote.value(), 7);
    assert_eq!(creator_meme.value(), 2);
    assert_eq!(creator_quote.value(), 3);

    destroy(protocol_meme);
    destroy(protocol_quote);
    destroy(creator_meme);
    destroy(creator_quote);
    destroy(ledger);
    fixture.end();
}

#[test]
fun meme_only_accrual_returns_zero_quote_coins() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

    ledger.accrue(
        balance::create_for_testing<TEST_MEME>(3),
        balance::create_for_testing<TEST_QUOTE>(0),
        PROTOCOL_FEE_SHARE_BPS,
    );

    let (creator_meme, creator_quote) =
        ledger.claim_creator_fees(&fixture.creator_cap, fixture.scenario.ctx());
    let (protocol_meme, protocol_quote) =
        ledger.claim_protocol_fees(&admin_witness, fixture.scenario.ctx());

    assert_eq!(creator_meme.value(), 1);
    assert_eq!(creator_quote.value(), 0);
    assert_eq!(protocol_meme.value(), 2);
    assert_eq!(protocol_quote.value(), 0);

    destroy(creator_meme);
    destroy(creator_quote);
    destroy(protocol_meme);
    destroy(protocol_quote);
    destroy(ledger);
    fixture.end();
}

#[test]
fun quote_only_accrual_returns_zero_meme_coins() {
    let mut fixture = start();
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

    ledger.accrue(
        balance::create_for_testing<TEST_MEME>(0),
        balance::create_for_testing<TEST_QUOTE>(4),
        PROTOCOL_FEE_SHARE_BPS,
    );

    let (creator_meme, creator_quote) =
        ledger.claim_creator_fees(&fixture.creator_cap, fixture.scenario.ctx());
    let (protocol_meme, protocol_quote) =
        ledger.claim_protocol_fees(&admin_witness, fixture.scenario.ctx());

    assert_eq!(creator_meme.value(), 0);
    assert_eq!(creator_quote.value(), 2);
    assert_eq!(protocol_meme.value(), 0);
    assert_eq!(protocol_quote.value(), 2);

    destroy(creator_meme);
    destroy(creator_quote);
    destroy(protocol_meme);
    destroy(protocol_quote);
    destroy(ledger);
    fixture.end();
}

#[test]
fun transferred_creator_cap_claims_and_routes_both_assets_composably() {
    let Fixture {
        mut scenario,
        super_admin_cap,
        authority,
        admin_cap,
        runtime_config: fixture_runtime_config,
        clock: fixture_clock,
        creator_cap,
    } = start();
    let admin_witness = authority.sign_in(&admin_cap);
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();
    ledger.accrue(
        balance::create_for_testing<TEST_MEME>(9),
        balance::create_for_testing<TEST_QUOTE>(10),
        PROTOCOL_FEE_SHARE_BPS,
    );

    let (protocol_meme, protocol_quote) =
        ledger.claim_protocol_fees(&admin_witness, scenario.ctx());
    destroy(protocol_meme);
    destroy(protocol_quote);
    scenario.return_to_sender(admin_cap);
    transfer::public_transfer(creator_cap, BENEFICIARY);

    scenario.next_tx(BENEFICIARY);
    let creator_cap =
        scenario.take_from_sender<creator_authority::CreatorCap<TEST_MEME>>();
    let (creator_meme, creator_quote) =
        ledger.claim_creator_fees(&creator_cap, scenario.ctx());
    assert_eq!(creator_meme.value(), 4);
    assert_eq!(creator_quote.value(), 5);
    transfer::public_transfer(creator_meme, PAYOUT_RECIPIENT);
    transfer::public_transfer(creator_quote, PAYOUT_RECIPIENT);
    destroy(ledger);

    scenario.next_tx(PAYOUT_RECIPIENT);
    let creator_meme = scenario.take_from_sender<Coin<TEST_MEME>>();
    let creator_quote = scenario.take_from_sender<Coin<TEST_QUOTE>>();
    assert_eq!(creator_meme.value(), 4);
    assert_eq!(creator_quote.value(), 5);
    destroy(creator_meme);
    destroy(creator_quote);

    scenario.next_tx(CREATOR);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    Fixture {
        scenario,
        super_admin_cap,
        authority,
        admin_cap,
        runtime_config: fixture_runtime_config,
        clock: fixture_clock,
        creator_cap,
    }.end();
}

// === Private Functions ===

fun start(): Fixture {
    let mut scenario = test_scenario::begin(CREATOR);
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(CREATOR, scenario.ctx());
    authority.grant_admin(&super_admin_cap, CREATOR, scenario.ctx());
    scenario.next_tx(CREATOR);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let fixture_runtime_config = runtime_config::new_disabled_for_testing(scenario.ctx());
    let creator_authority = creator_authority::new_address<TEST_MEME>(CREATOR);
    let fixture_clock = clock::create_for_testing(scenario.ctx());
    let creator_cap = creator_authority.claim_creator_cap(
        &fixture_runtime_config,
        option::none(),
        &fixture_clock,
        scenario.ctx(),
    );

    Fixture {
        scenario,
        super_admin_cap,
        authority,
        admin_cap,
        runtime_config: fixture_runtime_config,
        clock: fixture_clock,
        creator_cap,
    }
}

fun end(self: Fixture) {
    destroy(self);
}
