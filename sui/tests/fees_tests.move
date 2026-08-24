#[test_only]
module blast_fun::fees_tests;

use blast_fun::{acl, creator_authority, fees, x_claim_config};
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

// === Tests ===

#[test]
fun dual_asset_accrual_splits_and_claims_exactly() {
    let mut scenario = test_scenario::begin(CREATOR);
    let (
        super_admin_cap,
        authority,
        admin_cap,
        x_config,
        test_clock,
        creator_cap,
    ) = new_claim_authorities(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
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

    std::unit_test::assert_eq!(protocol_meme_delta, 7);
    std::unit_test::assert_eq!(creator_meme_delta, 2);
    std::unit_test::assert_eq!(protocol_quote_delta, 7);
    std::unit_test::assert_eq!(creator_quote_delta, 3);
    std::unit_test::assert_eq!(protocol_meme_total, 7);
    std::unit_test::assert_eq!(creator_meme_total, 2);
    std::unit_test::assert_eq!(protocol_quote_total, 7);
    std::unit_test::assert_eq!(creator_quote_total, 3);

    let (creator_meme, creator_quote) =
        ledger.claim_creator_fees(&creator_cap, scenario.ctx());
    let (protocol_meme, protocol_quote) =
        ledger.claim_protocol_fees(&admin_witness, scenario.ctx());

    std::unit_test::assert_eq!(creator_meme.value(), 2);
    std::unit_test::assert_eq!(creator_quote.value(), 3);
    std::unit_test::assert_eq!(protocol_meme.value(), 7);
    std::unit_test::assert_eq!(protocol_quote.value(), 7);

    destroy_coin(creator_meme);
    destroy_coin(creator_quote);
    destroy_coin(protocol_meme);
    destroy_coin(protocol_quote);
    ledger.destroy_for_testing();
    destroy_claim_authorities(
        super_admin_cap,
        admin_cap,
        authority,
        x_config,
        test_clock,
        creator_cap,
        scenario,
    );
}

#[test]
fun protocol_fee_share_boundaries_route_every_accrued_unit() {
    let mut scenario = test_scenario::begin(CREATOR);
    let (
        super_admin_cap,
        authority,
        admin_cap,
        x_config,
        test_clock,
        creator_cap,
    ) = new_claim_authorities(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
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

    std::unit_test::assert_eq!(protocol_meme_delta, 0);
    std::unit_test::assert_eq!(creator_meme_delta, 9);
    std::unit_test::assert_eq!(protocol_quote_delta, 0);
    std::unit_test::assert_eq!(creator_quote_delta, 10);
    std::unit_test::assert_eq!(protocol_meme_total, 0);
    std::unit_test::assert_eq!(creator_meme_total, 9);
    std::unit_test::assert_eq!(protocol_quote_total, 0);
    std::unit_test::assert_eq!(creator_quote_total, 10);

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

    std::unit_test::assert_eq!(protocol_meme_delta, 5);
    std::unit_test::assert_eq!(creator_meme_delta, 0);
    std::unit_test::assert_eq!(protocol_quote_delta, 6);
    std::unit_test::assert_eq!(creator_quote_delta, 0);
    std::unit_test::assert_eq!(protocol_meme_total, 5);
    std::unit_test::assert_eq!(creator_meme_total, 9);
    std::unit_test::assert_eq!(protocol_quote_total, 6);
    std::unit_test::assert_eq!(creator_quote_total, 10);

    let (creator_meme, creator_quote) =
        ledger.claim_creator_fees(&creator_cap, scenario.ctx());
    let (protocol_meme, protocol_quote) =
        ledger.claim_protocol_fees(&admin_witness, scenario.ctx());

    std::unit_test::assert_eq!(creator_meme.value(), 9);
    std::unit_test::assert_eq!(creator_quote.value(), 10);
    std::unit_test::assert_eq!(protocol_meme.value(), 5);
    std::unit_test::assert_eq!(protocol_quote.value(), 6);

    destroy_coin(creator_meme);
    destroy_coin(creator_quote);
    destroy_coin(protocol_meme);
    destroy_coin(protocol_quote);
    ledger.destroy_for_testing();
    destroy_claim_authorities(
        super_admin_cap,
        admin_cap,
        authority,
        x_config,
        test_clock,
        creator_cap,
        scenario,
    );
}

#[test]
#[expected_failure(abort_code = 38)]
fun protocol_cannot_claim_when_nothing_is_accrued() {
    let mut scenario = test_scenario::begin(CREATOR);
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(CREATOR, scenario.ctx());
    authority.add_admin(&super_admin_cap, CREATOR, scenario.ctx());

    scenario.next_tx(CREATOR);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let admin_witness = authority.sign_in(&admin_cap);
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();
    let (meme, quote) = ledger.claim_protocol_fees(&admin_witness, scenario.ctx());

    destroy_coin(meme);
    destroy_coin(quote);
    ledger.destroy_for_testing();
    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 38)]
fun creator_cannot_claim_when_nothing_is_accrued() {
    let mut scenario = test_scenario::begin(CREATOR);
    let x_config = x_claim_config::new_disabled_for_testing(scenario.ctx());
    let creator_authority = creator_authority::new_address<TEST_MEME>(CREATOR);
    let test_clock = clock::create_for_testing(scenario.ctx());
    scenario.next_tx(CREATOR);
    let creator_cap = creator_authority.claim_creator_cap(
        &x_config,
        option::none(),
        &test_clock,
        scenario.ctx(),
    );
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();
    let (meme, quote) = ledger.claim_creator_fees(&creator_cap, scenario.ctx());

    destroy_coin(meme);
    destroy_coin(quote);
    ledger.destroy_for_testing();
    creator_cap.destroy_cap_for_testing();
    x_config.destroy_for_testing();
    test_clock.destroy_for_testing();
    scenario.end();
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

    ledger.destroy_for_testing();
}

#[test]
fun maximum_u64_fees_match_the_committed_split_vector() {
    let mut scenario = test_scenario::begin(CREATOR);
    let (
        super_admin_cap,
        authority,
        admin_cap,
        x_config,
        test_clock,
        creator_cap,
    ) = new_claim_authorities(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

    ledger.accrue(
        balance::create_for_testing<TEST_MEME>(std::u64::max_value!()),
        balance::create_for_testing<TEST_QUOTE>(std::u64::max_value!()),
        PROTOCOL_FEE_SHARE_BPS,
    );

    let (creator_meme, creator_quote) =
        ledger.claim_creator_fees(&creator_cap, scenario.ctx());
    let (protocol_meme, protocol_quote) =
        ledger.claim_protocol_fees(&admin_witness, scenario.ctx());

    std::unit_test::assert_eq!(creator_meme.value(), 9_223_372_036_854_775_807);
    std::unit_test::assert_eq!(creator_quote.value(), 9_223_372_036_854_775_807);
    std::unit_test::assert_eq!(protocol_meme.value(), 9_223_372_036_854_775_808);
    std::unit_test::assert_eq!(protocol_quote.value(), 9_223_372_036_854_775_808);

    destroy_coin(creator_meme);
    destroy_coin(creator_quote);
    destroy_coin(protocol_meme);
    destroy_coin(protocol_quote);
    ledger.destroy_for_testing();
    destroy_claim_authorities(
        super_admin_cap,
        admin_cap,
        authority,
        x_config,
        test_clock,
        creator_cap,
        scenario,
    );
}

#[test]
fun changed_protocol_fee_share_applies_to_the_next_accrual() {
    let mut scenario = test_scenario::begin(CREATOR);
    let (
        super_admin_cap,
        authority,
        admin_cap,
        x_config,
        test_clock,
        creator_cap,
    ) = new_claim_authorities(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

    ledger.accrue(
        balance::create_for_testing<TEST_MEME>(3),
        balance::create_for_testing<TEST_QUOTE>(4),
        PROTOCOL_FEE_SHARE_BPS,
    );
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
        8_000,
    );

    std::unit_test::assert_eq!(protocol_meme_delta, 4);
    std::unit_test::assert_eq!(creator_meme_delta, 1);
    std::unit_test::assert_eq!(protocol_quote_delta, 5);
    std::unit_test::assert_eq!(creator_quote_delta, 1);
    std::unit_test::assert_eq!(protocol_meme_total, 6);
    std::unit_test::assert_eq!(creator_meme_total, 2);
    std::unit_test::assert_eq!(protocol_quote_total, 7);
    std::unit_test::assert_eq!(creator_quote_total, 3);

    let (protocol_meme, protocol_quote) =
        ledger.claim_protocol_fees(&admin_witness, scenario.ctx());
    let (creator_meme, creator_quote) =
        ledger.claim_creator_fees(&creator_cap, scenario.ctx());

    std::unit_test::assert_eq!(protocol_meme.value(), 6);
    std::unit_test::assert_eq!(protocol_quote.value(), 7);
    std::unit_test::assert_eq!(creator_meme.value(), 2);
    std::unit_test::assert_eq!(creator_quote.value(), 3);

    destroy_coin(protocol_meme);
    destroy_coin(protocol_quote);
    destroy_coin(creator_meme);
    destroy_coin(creator_quote);
    ledger.destroy_for_testing();
    destroy_claim_authorities(
        super_admin_cap,
        admin_cap,
        authority,
        x_config,
        test_clock,
        creator_cap,
        scenario,
    );
}

#[test]
fun meme_only_accrual_returns_zero_quote_coins() {
    let mut scenario = test_scenario::begin(CREATOR);
    let (
        super_admin_cap,
        authority,
        admin_cap,
        x_config,
        test_clock,
        creator_cap,
    ) = new_claim_authorities(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

    ledger.accrue(
        balance::create_for_testing<TEST_MEME>(3),
        balance::create_for_testing<TEST_QUOTE>(0),
        PROTOCOL_FEE_SHARE_BPS,
    );

    let (creator_meme, creator_quote) =
        ledger.claim_creator_fees(&creator_cap, scenario.ctx());
    let (protocol_meme, protocol_quote) =
        ledger.claim_protocol_fees(&admin_witness, scenario.ctx());

    std::unit_test::assert_eq!(creator_meme.value(), 1);
    std::unit_test::assert_eq!(creator_quote.value(), 0);
    std::unit_test::assert_eq!(protocol_meme.value(), 2);
    std::unit_test::assert_eq!(protocol_quote.value(), 0);

    destroy_coin(creator_meme);
    destroy_coin(creator_quote);
    destroy_coin(protocol_meme);
    destroy_coin(protocol_quote);
    ledger.destroy_for_testing();
    destroy_claim_authorities(
        super_admin_cap,
        admin_cap,
        authority,
        x_config,
        test_clock,
        creator_cap,
        scenario,
    );
}

#[test]
fun quote_only_accrual_returns_zero_meme_coins() {
    let mut scenario = test_scenario::begin(CREATOR);
    let (
        super_admin_cap,
        authority,
        admin_cap,
        x_config,
        test_clock,
        creator_cap,
    ) = new_claim_authorities(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();

    ledger.accrue(
        balance::create_for_testing<TEST_MEME>(0),
        balance::create_for_testing<TEST_QUOTE>(4),
        PROTOCOL_FEE_SHARE_BPS,
    );

    let (creator_meme, creator_quote) =
        ledger.claim_creator_fees(&creator_cap, scenario.ctx());
    let (protocol_meme, protocol_quote) =
        ledger.claim_protocol_fees(&admin_witness, scenario.ctx());

    std::unit_test::assert_eq!(creator_meme.value(), 0);
    std::unit_test::assert_eq!(creator_quote.value(), 2);
    std::unit_test::assert_eq!(protocol_meme.value(), 0);
    std::unit_test::assert_eq!(protocol_quote.value(), 2);

    destroy_coin(creator_meme);
    destroy_coin(creator_quote);
    destroy_coin(protocol_meme);
    destroy_coin(protocol_quote);
    ledger.destroy_for_testing();
    destroy_claim_authorities(
        super_admin_cap,
        admin_cap,
        authority,
        x_config,
        test_clock,
        creator_cap,
        scenario,
    );
}

#[test]
fun transferred_creator_cap_claims_and_routes_both_assets_composably() {
    let mut scenario = test_scenario::begin(CREATOR);
    let (
        super_admin_cap,
        authority,
        admin_cap,
        x_config,
        test_clock,
        creator_cap,
    ) = new_claim_authorities(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);
    let mut ledger = fees::new<TEST_MEME, TEST_QUOTE>();
    ledger.accrue(
        balance::create_for_testing<TEST_MEME>(9),
        balance::create_for_testing<TEST_QUOTE>(10),
        PROTOCOL_FEE_SHARE_BPS,
    );

    let (protocol_meme, protocol_quote) =
        ledger.claim_protocol_fees(&admin_witness, scenario.ctx());
    destroy_coin(protocol_meme);
    destroy_coin(protocol_quote);
    scenario.return_to_sender(admin_cap);
    transfer::public_transfer(creator_cap, BENEFICIARY);

    scenario.next_tx(BENEFICIARY);
    let creator_cap =
        scenario.take_from_sender<creator_authority::CreatorCap<TEST_MEME>>();
    let (creator_meme, creator_quote) =
        ledger.claim_creator_fees(&creator_cap, scenario.ctx());
    std::unit_test::assert_eq!(creator_meme.value(), 4);
    std::unit_test::assert_eq!(creator_quote.value(), 5);
    transfer::public_transfer(creator_meme, PAYOUT_RECIPIENT);
    transfer::public_transfer(creator_quote, PAYOUT_RECIPIENT);
    creator_cap.destroy_cap_for_testing();
    ledger.destroy_for_testing();

    scenario.next_tx(PAYOUT_RECIPIENT);
    let creator_meme = scenario.take_from_sender<Coin<TEST_MEME>>();
    let creator_quote = scenario.take_from_sender<Coin<TEST_QUOTE>>();
    std::unit_test::assert_eq!(creator_meme.value(), 4);
    std::unit_test::assert_eq!(creator_quote.value(), 5);
    destroy_coin(creator_meme);
    destroy_coin(creator_quote);

    scenario.next_tx(CREATOR);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let mut authority = authority;
    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    x_config.destroy_for_testing();
    test_clock.destroy_for_testing();
    scenario.end();
}

// === Private Functions ===

fun new_claim_authorities(
    scenario: &mut Scenario,
): (
    acl::SuperAdminCap,
    acl::ProtocolAuthority,
    acl::AdminCap,
    x_claim_config::XClaimConfig,
    Clock,
    creator_authority::CreatorCap<TEST_MEME>,
) {
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(CREATOR, scenario.ctx());
    authority.add_admin(&super_admin_cap, CREATOR, scenario.ctx());
    scenario.next_tx(CREATOR);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let x_config = x_claim_config::new_disabled_for_testing(scenario.ctx());
    let creator_authority = creator_authority::new_address<TEST_MEME>(CREATOR);
    let test_clock = clock::create_for_testing(scenario.ctx());
    let creator_cap = creator_authority.claim_creator_cap(
        &x_config,
        option::none(),
        &test_clock,
        scenario.ctx(),
    );
    (
        super_admin_cap,
        authority,
        admin_cap,
        x_config,
        test_clock,
        creator_cap,
    )
}

fun destroy_claim_authorities(
    super_admin_cap: acl::SuperAdminCap,
    admin_cap: acl::AdminCap,
    mut authority: acl::ProtocolAuthority,
    x_config: x_claim_config::XClaimConfig,
    test_clock: Clock,
    creator_cap: creator_authority::CreatorCap<TEST_MEME>,
    scenario: Scenario,
) {
    creator_cap.destroy_cap_for_testing();
    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    x_config.destroy_for_testing();
    test_clock.destroy_for_testing();
    scenario.end();
}

fun destroy_coin<T>(coin: Coin<T>) {
    coin.into_balance().destroy_for_testing();
}
