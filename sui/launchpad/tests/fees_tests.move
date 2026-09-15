#[test_only]
module blast_fun::fees_tests;

use blast_admin::acl::{Authority, AdminCap, AdminWitness};
use blast_fun::{
    bps,
    creator_authority,
    domain_fixture,
    fees,
    launchpad_domain::LAUNCHPAD_DOMAIN,
    package_version,
    runtime_config,
};
use std::unit_test::{assert_eq, destroy};
use sui::{balance::{Self, Balance}, clock, coin::Coin, test_scenario::{Self, Scenario}};

use fun creator_ctx as CreatorFixture.ctx;
use fun creator_end as CreatorFixture.end;
use fun creator_next_tx as CreatorFixture.next_tx;
use fun fees_ctx as FeesFixture.ctx;
use fun fees_end as FeesFixture.end;
use fun fees_next_tx as FeesFixture.next_tx;

// === Constants ===

const CREATOR: address = @0xC0FFEE;
const BENEFICIARY: address = @0xB0B;
const PAYOUT_RECIPIENT: address = @0xCAFE;
const PROTOCOL_FEE_SHARE_BPS: u64 = 5_000;

// === Test-Only Types ===

public struct TEST_MEME() has drop;
public struct TEST_QUOTE() has drop;

/// Fee-claim authorities: the live protocol share plus one claimed creator cap.
public struct FeesFixture {
    scenario: Scenario,
    authority: Authority<LAUNCHPAD_DOMAIN>,
    admin_cap: AdminCap<LAUNCHPAD_DOMAIN>,
    package_version: package_version::PackageVersion,
    runtime_config: runtime_config::RuntimeConfig,
    creator_cap: Option<creator_authority::CurveFeeCap<TEST_MEME>>,
}

/// Creator-claim authority only: one claimed creator cap, no ACL or live settings.
public struct CreatorFixture {
    scenario: Scenario,
    creator_cap: creator_authority::CurveFeeCap<TEST_MEME>,
}

// === Tests ===

#[test]
fun dual_asset_accrual_splits_and_claims_exactly() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let admin_witness = f.sign_in();
        let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

        let (
            protocol_meme_delta,
            creator_meme_delta,
            protocol_quote_delta,
            creator_quote_delta,
        ) = accrue(&mut ledger,
            balance::create_for_testing<TEST_MEME>(9),
            balance::create_for_testing<TEST_QUOTE>(10),
            7_000,
        );

        assert_eq!(protocol_meme_delta, 7);
        assert_eq!(creator_meme_delta, 2);
        assert_eq!(protocol_quote_delta, 7);
        assert_eq!(creator_quote_delta, 3);
        let (creator_meme, creator_quote) = f.claim_creator_fees(&mut ledger);
        let (protocol_meme, protocol_quote) =
            ledger.claim_protocol_fees(&admin_witness, f.ctx!());

        assert_eq!(creator_meme.value(), 2);
        assert_eq!(creator_quote.value(), 3);
        assert_eq!(protocol_meme.value(), 7);
        assert_eq!(protocol_quote.value(), 7);

        destroy(creator_meme);
        destroy(creator_quote);
        destroy(protocol_meme);
        destroy(protocol_quote);
        destroy(ledger);
    });

    fixture.end();
}

#[test]
fun protocol_fee_share_boundaries_route_every_accrued_unit() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let admin_witness = f.sign_in();
        let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

        let (
            protocol_meme_delta,
            creator_meme_delta,
            protocol_quote_delta,
            creator_quote_delta,
        ) = accrue(&mut ledger,
            balance::create_for_testing<TEST_MEME>(9),
            balance::create_for_testing<TEST_QUOTE>(10),
            0,
        );

        assert_eq!(protocol_meme_delta, 0);
        assert_eq!(creator_meme_delta, 9);
        assert_eq!(protocol_quote_delta, 0);
        assert_eq!(creator_quote_delta, 10);
        let (
            protocol_meme_delta,
            creator_meme_delta,
            protocol_quote_delta,
            creator_quote_delta,
        ) = accrue(&mut ledger,
            balance::create_for_testing<TEST_MEME>(5),
            balance::create_for_testing<TEST_QUOTE>(6),
            10_000,
        );

        assert_eq!(protocol_meme_delta, 5);
        assert_eq!(creator_meme_delta, 0);
        assert_eq!(protocol_quote_delta, 6);
        assert_eq!(creator_quote_delta, 0);
        let (creator_meme, creator_quote) = f.claim_creator_fees(&mut ledger);
        let (protocol_meme, protocol_quote) =
            ledger.claim_protocol_fees(&admin_witness, f.ctx!());

        assert_eq!(creator_meme.value(), 9);
        assert_eq!(creator_quote.value(), 10);
        assert_eq!(protocol_meme.value(), 5);
        assert_eq!(protocol_quote.value(), 6);

        destroy(creator_meme);
        destroy(creator_quote);
        destroy(protocol_meme);
        destroy(protocol_quote);
        destroy(ledger);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ENothingAccrued,
    location = blast_fun::fees,
)]
fun protocol_cannot_claim_when_nothing_is_accrued() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let admin_witness = f.sign_in();
        let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();
        let (meme, quote) =
            ledger.claim_protocol_fees(&admin_witness, f.ctx!());

        destroy(meme);
        destroy(quote);
        destroy(ledger);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ENothingAccrued,
    location = blast_fun::fees,
)]
fun creator_cannot_claim_when_nothing_is_accrued() {
    let mut fixture = start_creator();

    fixture.next_tx!(CREATOR, |f| {
        let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();
        let (meme, quote) =
            ledger.claim_creator_fees(f.ctx!());

        destroy(meme);
        destroy(quote);
        destroy(ledger);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EZeroFeeAccrual,
    location = blast_fun::fees,
)]
fun accrual_rejects_two_zero_asset_balances() {
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

    accrue(&mut ledger,
        balance::create_for_testing<TEST_MEME>(0),
        balance::create_for_testing<TEST_QUOTE>(0),
        PROTOCOL_FEE_SHARE_BPS,
    );

    destroy(ledger);
}

#[test]
fun maximum_u64_fees_match_the_committed_split_vector() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let admin_witness = f.sign_in();
        let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

        accrue(&mut ledger,
            balance::create_for_testing<TEST_MEME>(std::u64::max_value!()),
            balance::create_for_testing<TEST_QUOTE>(std::u64::max_value!()),
            PROTOCOL_FEE_SHARE_BPS,
        );

        let (creator_meme, creator_quote) = f.claim_creator_fees(&mut ledger);
        let (protocol_meme, protocol_quote) =
            ledger.claim_protocol_fees(&admin_witness, f.ctx!());

        assert_eq!(creator_meme.value(), 9_223_372_036_854_775_807);
        assert_eq!(creator_quote.value(), 9_223_372_036_854_775_807);
        assert_eq!(protocol_meme.value(), 9_223_372_036_854_775_808);
        assert_eq!(protocol_quote.value(), 9_223_372_036_854_775_808);

        destroy(creator_meme);
        destroy(creator_quote);
        destroy(protocol_meme);
        destroy(protocol_quote);
        destroy(ledger);
    });

    fixture.end();
}

#[test]
fun changed_protocol_fee_share_applies_to_the_next_accrual() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let admin_witness = f.sign_in();
        let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

        f.runtime_config.set_protocol_fee_share(
            &f.package_version,
            &admin_witness,
            bps::new(PROTOCOL_FEE_SHARE_BPS),
        );
        ledger.accrue(
            balance::create_for_testing<TEST_MEME>(3),
            balance::create_for_testing<TEST_QUOTE>(4),
            f.runtime_config.protocol_fee_share(),
        );
        f.runtime_config.set_protocol_fee_share(
            &f.package_version,
            &admin_witness,
            bps::new(8_000),
        );
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
        let (protocol_meme, protocol_quote) =
            ledger.claim_protocol_fees(&admin_witness, f.ctx!());
        let (creator_meme, creator_quote) = f.claim_creator_fees(&mut ledger);

        assert_eq!(protocol_meme.value(), 6);
        assert_eq!(protocol_quote.value(), 7);
        assert_eq!(creator_meme.value(), 2);
        assert_eq!(creator_quote.value(), 3);

        destroy(protocol_meme);
        destroy(protocol_quote);
        destroy(creator_meme);
        destroy(creator_quote);
        destroy(ledger);
    });

    fixture.end();
}

#[test]
fun meme_only_accrual_returns_zero_quote_coins() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let admin_witness = f.sign_in();
        let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

        accrue(&mut ledger,
            balance::create_for_testing<TEST_MEME>(3),
            balance::create_for_testing<TEST_QUOTE>(0),
            PROTOCOL_FEE_SHARE_BPS,
        );

        let (creator_meme, creator_quote) = f.claim_creator_fees(&mut ledger);
        let (protocol_meme, protocol_quote) =
            ledger.claim_protocol_fees(&admin_witness, f.ctx!());

        assert_eq!(creator_meme.value(), 1);
        assert_eq!(creator_quote.value(), 0);
        assert_eq!(protocol_meme.value(), 2);
        assert_eq!(protocol_quote.value(), 0);

        destroy(creator_meme);
        destroy(creator_quote);
        destroy(protocol_meme);
        destroy(protocol_quote);
        destroy(ledger);
    });

    fixture.end();
}

#[test]
fun quote_only_accrual_returns_zero_meme_coins() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let admin_witness = f.sign_in();
        let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

        accrue(&mut ledger,
            balance::create_for_testing<TEST_MEME>(0),
            balance::create_for_testing<TEST_QUOTE>(4),
            PROTOCOL_FEE_SHARE_BPS,
        );

        let (creator_meme, creator_quote) = f.claim_creator_fees(&mut ledger);
        let (protocol_meme, protocol_quote) =
            ledger.claim_protocol_fees(&admin_witness, f.ctx!());

        assert_eq!(creator_meme.value(), 0);
        assert_eq!(creator_quote.value(), 2);
        assert_eq!(protocol_meme.value(), 0);
        assert_eq!(protocol_quote.value(), 2);

        destroy(creator_meme);
        destroy(creator_quote);
        destroy(protocol_meme);
        destroy(protocol_quote);
        destroy(ledger);
    });

    fixture.end();
}

#[test]
fun transferred_creator_cap_claims_and_routes_both_assets_composably() {
    let mut fixture = start();
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

    fixture.next_tx!(CREATOR, |f| {
        let admin_witness = f.sign_in();
        accrue(&mut ledger,
            balance::create_for_testing<TEST_MEME>(9),
            balance::create_for_testing<TEST_QUOTE>(10),
            PROTOCOL_FEE_SHARE_BPS,
        );

        let (protocol_meme, protocol_quote) =
            ledger.claim_protocol_fees(&admin_witness, f.ctx!());
        destroy(protocol_meme);
        destroy(protocol_quote);

        transfer::public_transfer(f.take_creator_cap(), BENEFICIARY);
    });

    fixture.next_tx!(BENEFICIARY, |f| {
        f.retake_creator_cap();

        let (creator_meme, creator_quote) = f.claim_creator_fees(&mut ledger);
        assert_eq!(creator_meme.value(), 4);
        assert_eq!(creator_quote.value(), 5);
        transfer::public_transfer(creator_meme, PAYOUT_RECIPIENT);
        transfer::public_transfer(creator_quote, PAYOUT_RECIPIENT);
    });

    fixture.next_tx!(PAYOUT_RECIPIENT, |f| {
        let creator_meme = f.take_coin<TEST_MEME>();
        let creator_quote = f.take_coin<TEST_QUOTE>();
        assert_eq!(creator_meme.value(), 4);
        assert_eq!(creator_quote.value(), 5);
        destroy(creator_meme);
        destroy(creator_quote);
    });

    destroy(ledger);
    fixture.end();
}

// === Private Test Helpers ===

fun accrue<Meme, Quote>(
    ledger: &mut fees::FeeLedger<Meme, Quote>,
    meme_fee: Balance<Meme>,
    quote_fee: Balance<Quote>,
    protocol_fee_share_bps: u64,
): (u64, u64, u64, u64) {
    ledger.accrue(
        meme_fee,
        quote_fee,
        bps::new(protocol_fee_share_bps),
    )
}

macro fun fees_next_tx(
    $fixture: &mut FeesFixture,
    $sender: address,
    $fn: |&mut FeesFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun creator_next_tx(
    $fixture: &mut CreatorFixture,
    $sender: address,
    $fn: |&mut CreatorFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun fees_ctx($fixture: &mut FeesFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

macro fun creator_ctx($fixture: &mut CreatorFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun start(): FeesFixture {
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(&super_admin_cap, 0, CREATOR, scenario.ctx());
    destroy(super_admin_cap);

    scenario.next_tx(CREATOR);
    let admin_cap = scenario.take_from_sender<AdminCap<LAUNCHPAD_DOMAIN>>();
    let runtime_config = runtime_config::new_disabled_for_testing(scenario.ctx());
    let creator_cap = new_creator_cap(&runtime_config, scenario.ctx());

    FeesFixture {
        scenario,
        authority,
        admin_cap,
        package_version,
        runtime_config,
        creator_cap: option::some(creator_cap),
    }
}

fun start_creator(): CreatorFixture {
    let mut scenario = test_scenario::begin(CREATOR);
    let runtime_config = runtime_config::new_disabled_for_testing(scenario.ctx());
    let creator_cap = new_creator_cap(&runtime_config, scenario.ctx());
    destroy(runtime_config);

    CreatorFixture { scenario, creator_cap }
}

fun new_creator_cap(
    runtime_config: &runtime_config::RuntimeConfig,
    ctx: &mut TxContext,
): creator_authority::CurveFeeCap<TEST_MEME> {
    let creator_authority = creator_authority::new_address(CREATOR)
        .into_authority<TEST_MEME>();
    let clock = clock::create_for_testing(ctx);
    let (creator_cap, metadata_cap) = creator_authority.claim_creator_caps(
        runtime_config,
        option::none(),
        &clock,
        ctx,
    );
    destroy(metadata_cap);
    destroy(clock);

    creator_cap
}

fun sign_in(self: &FeesFixture): AdminWitness<LAUNCHPAD_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun claim_creator_fees(
    self: &mut FeesFixture,
    ledger: &mut fees::FeeLedger<TEST_MEME, TEST_QUOTE>,
): (Coin<TEST_MEME>, Coin<TEST_QUOTE>) {
    ledger.claim_creator_fees(self.scenario.ctx())
}

fun take_creator_cap(self: &mut FeesFixture): creator_authority::CurveFeeCap<TEST_MEME> {
    self.creator_cap.extract()
}

fun retake_creator_cap(self: &mut FeesFixture) {
    let creator_cap = self.scenario.take_from_sender();
    self.creator_cap.fill(creator_cap);
}

fun take_coin<T>(self: &FeesFixture): Coin<T> {
    self.scenario.take_from_sender()
}

fun fees_end(self: FeesFixture) {
    destroy(self);
}

fun creator_end(self: CreatorFixture) {
    destroy(self);
}
