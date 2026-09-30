// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::blast_presale_tests;

// === Constants ===

const CREATOR: address = @0xC0FFEE;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const KEEPER: address = @0x4EE9;
const RECIPIENT_A: address = @0xA110C;
const RECIPIENT_B: address = @0xB110C;
const FEE_PARTNER: address = @0xFEE;

const START_MS: u64 = 1_000;
const DURATION_MS: u64 = 100;
const END_MS: u64 = START_MS + DURATION_MS;
const LIQUIDITY_WINDOW_MS: u64 = 50;
const LIQUIDITY_DEADLINE_MS: u64 = END_MS + LIQUIDITY_WINDOW_MS;

const RAISE_TARGET: u64 = 1_000;
const TOKEN_SUPPLY: u64 = 20_001;
const TOKEN_ALLOCATION_BPS: u64 = 5_000;
const LIQUIDITY_TOKEN_ALLOCATION_BPS: u64 = 1_000;
const RECIPIENT_A_BPS: u64 = 2_500;
const RECIPIENT_B_BPS: u64 = 1_500;
const TOKEN_ALLOCATION: u64 = 10_001;
const LIQUIDITY_TOKENS: u64 = 2_000;
const RECIPIENT_A_TOKENS: u64 = 5_000;
const RECIPIENT_B_TOKENS: u64 = 3_000;
const RECIPIENT_TOKENS: u64 = RECIPIENT_A_TOKENS + RECIPIENT_B_TOKENS;
const WALLET_CAP: u64 = 5_000;
const TICK_SPACING: u32 = 10;
const FEE_RATE: u64 = 1_000;
const CREATOR_FEE_BPS: u64 = 5_000;
const FEE_PARTNER_BPS: u64 = 2_000;
const REWARDS_FEE_BPS: u64 = 3_000;

// === Test-Only Types ===

public struct BLAST_PRESALE_TESTS() has drop;
public struct QUOTE() has drop;
public struct TEST_MIGRATOR() has drop;
public struct OTHER_MIGRATOR() has drop;

public struct Fixture {
    scenario: Scenario,
    clock: Clock,
    presale_id: ID,
}

// === Tests ===

#[test]
/// Every wallet gets the same fill rate regardless of commitment size or claim order.
fun oversubscription_uses_one_fill_rate_and_refunds_the_rest() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 2),
    );

    assert_eq!(fixture.commit_open(ALICE, 1_000), vector[1_000, 1_000, 1]);
    assert_eq!(fixture.commit_open(BOB, 3_000), vector[3_000, 4_000, 2]);
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);

    let (presale_id, commitments, accepted, refundable, tokens) = only_event<
        PresaleFunded<BLAST_PRESALE_TESTS, QUOTE>,
    >().funded_fields();
    assert_eq!(presale_id, fixture.presale_id);
    assert_eq!(
        vector[commitments, accepted, refundable, tokens],
        vector[4_000, 1_000, 3_000, TOKEN_ALLOCATION],
    );
    assert!(fixture.is_funded());

    assert_eq!(
        fixture.migrate(),
        vector[LIQUIDITY_TOKENS, RAISE_TARGET],
    );
    let (presale_id, migration_witness, quote, liquidity_tokens, recipient_tokens) = only_event<
        PresaleMigrated<BLAST_PRESALE_TESTS, QUOTE>,
    >().migrated_fields();
    assert_eq!(presale_id, fixture.presale_id);
    assert_eq!(migration_witness, type_name::with_original_ids<TEST_MIGRATOR>());
    assert_eq!(
        vector[quote, liquidity_tokens, recipient_tokens],
        vector[RAISE_TARGET, LIQUIDITY_TOKENS, RECIPIENT_TOKENS],
    );
    fixture.take_recipient_allocations();

    assert_eq!(fixture.claim(KEEPER, ALICE), vector[1_000, 2_500, 750, 3_000]);
    fixture.take_payout(ALICE, 2_500, 750);
    assert_eq!(fixture.claim(KEEPER, BOB), vector[3_000, 7_501, 2_250, 0]);
    fixture.take_payout(BOB, 7_501, 2_250);
    assert_eq!(fixture.custody(), vector[4_000, 0, 2, 0, 0, 0, 0]);

    fixture.destroy_migrated_cap();
    fixture.end();
}

#[test]
/// A commitment is backed one-for-one by Quote held in the presale object.
fun commitments_lock_quote_in_presale_custody() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 1),
    );

    fixture.commit_open(ALICE, 400);
    assert_eq!(
        fixture.custody(),
        vector[400, 400, 1, 400, TOKEN_ALLOCATION, LIQUIDITY_TOKENS, RECIPIENT_TOKENS],
    );
    fixture.commit_open(ALICE, 100);
    assert_eq!(
        fixture.custody(),
        vector[500, 500, 1, 500, TOKEN_ALLOCATION, LIQUIDITY_TOKENS, RECIPIENT_TOKENS],
    );

    fixture.set_time(END_MS);
    fixture.settle(KEEPER);
    fixture.claim(KEEPER, ALICE);
    fixture.take_quote(ALICE, 500);
    fixture.destroy_cancelled_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidLifecycle, location = blast_presale::blast_presale)]
fun participants_cannot_withdraw_open_commitments() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 1),
    );
    fixture.commit_open(ALICE, 500);

    fixture.claim(ALICE, ALICE);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidLifecycle, location = blast_presale::blast_presale)]
fun participants_cannot_withdraw_funded_commitments() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 1),
    );
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);

    fixture.claim(ALICE, ALICE);
    fixture.end();
}

#[test]
/// An underfunded sale releases no Quote and every wallet can recover its full commitment.
fun underfunded_sale_refunds_quote_and_locks_minted_supply_forever() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 2),
    );
    fixture.commit_open(ALICE, 500);
    fixture.set_time(END_MS);

    fixture.settle(KEEPER);

    let (presale_id, commitments, refundable) = only_event<
        PresaleCancelled<BLAST_PRESALE_TESTS, QUOTE>,
    >().cancelled_fields();
    assert_eq!(presale_id, fixture.presale_id);
    assert_eq!(vector[commitments, refundable], vector[500, 500]);
    assert!(fixture.is_cancelled());
    assert_eq!(fixture.claim(KEEPER, ALICE), vector[500, 0, 500, 0]);
    fixture.take_quote(ALICE, 500);
    assert_eq!(
        fixture.custody(),
        vector[500, 0, 1, 0, TOKEN_ALLOCATION, LIQUIDITY_TOKENS, RECIPIENT_TOKENS],
    );
    fixture.destroy_cancelled_cap();
    fixture.end();
}

#[test]
/// A funded sale cannot lock participants forever when its creator never adds LP.
fun missed_liquidity_deadline_turns_a_funded_sale_into_full_refunds() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 1),
    );
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);
    fixture.set_time(LIQUIDITY_DEADLINE_MS);

    fixture.cancel_unlaunched(KEEPER);

    assert!(fixture.is_cancelled());
    assert_eq!(fixture.claim(KEEPER, ALICE), vector[RAISE_TARGET, 0, RAISE_TARGET, 0]);
    fixture.take_quote(ALICE, RAISE_TARGET);
    fixture.destroy_cancelled_cap();
    fixture.end();
}

#[test]
/// Merkle leaves carry each wallet's cap, so one policy supports rank tiers.
fun allowlist_proofs_enforce_distinct_wallet_caps() {
    let alice_leaf = presale::allowlist_leaf_for_testing(0, ALICE, 500);
    let bob_leaf = presale::allowlist_leaf_for_testing(1, BOB, 100);
    let root = presale::merkle_node_for_testing(alice_leaf, bob_leaf);
    let mut fixture = start(
        RAISE_TARGET,
        presale::allowlisted_eligibility(root, 2),
    );

    assert_eq!(
        fixture.commit_allowlisted(ALICE, 500, 0, 500, vector[bob_leaf]),
        vector[500, 500, 1],
    );
    assert_eq!(
        fixture.commit_allowlisted(BOB, 100, 1, 100, vector[alice_leaf]),
        vector[100, 600, 2],
    );
    assert_eq!(fixture.commitment(ALICE), 500);
    assert_eq!(fixture.commitment(BOB), 100);
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);
    fixture.claim(KEEPER, ALICE);
    fixture.take_quote(ALICE, 500);
    fixture.claim(KEEPER, BOB);
    fixture.take_quote(BOB, 100);
    fixture.destroy_cancelled_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidEligibilityProof, location = blast_presale::blast_presale)]
fun an_allowlist_proof_cannot_change_its_wallet_cap() {
    let alice_leaf = presale::allowlist_leaf_for_testing(0, ALICE, 500);
    let mut fixture = start(
        RAISE_TARGET,
        presale::allowlisted_eligibility(alice_leaf, 1),
    );

    fixture.commit_allowlisted(ALICE, 500, 0, 501, vector[]);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EWalletCapExceeded, location = blast_presale::blast_presale)]
fun cumulative_commitments_cannot_exceed_the_wallet_cap() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(500, 2),
    );
    fixture.commit_open(ALICE, 400);

    fixture.commit_open(ALICE, 101);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EParticipantCapacityReached, location = blast_presale::blast_presale)]
fun open_sales_bound_their_dynamic_commitment_records() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 1),
    );
    fixture.commit_open(ALICE, 1);

    fixture.commit_open(BOB, 1);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EPresaleEnded, location = blast_presale::blast_presale)]
fun commitments_at_the_exact_end_are_rejected_before_amount_checks() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 1),
    );
    fixture.set_time(END_MS);

    fixture.commit_open(ALICE, 0);
    fixture.end();
}

#[test]
/// The LP deadline only opens refunds; anyone may still migrate until someone cancels.
fun a_late_settled_sale_can_still_migrate_after_the_liquidity_deadline() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 1),
    );
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(LIQUIDITY_DEADLINE_MS);
    fixture.settle(KEEPER);
    assert!(fixture.is_funded());

    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, RAISE_TARGET]);
    fixture.take_recipient_allocations();
    fixture.destroy_migrated_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidLifecycle, location = blast_presale::blast_presale)]
fun a_cancelled_unlaunched_sale_cannot_migrate() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 1),
    );
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);
    fixture.set_time(LIQUIDITY_DEADLINE_MS);
    fixture.cancel_unlaunched(KEEPER);

    fixture.migrate();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::ELiquidityDeadlineNotReached, location = blast_presale::blast_presale)]
fun a_funded_sale_cannot_be_cancelled_before_the_liquidity_deadline() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 1),
    );
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);
    fixture.set_time(LIQUIDITY_DEADLINE_MS - 1);

    fixture.cancel_unlaunched(KEEPER);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EWrongMigrationWitness, location = blast_presale::blast_presale)]
fun another_migrator_cannot_release_escrow() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 1),
    );
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);

    fixture.next_tx!(KEEPER, |fixture| {
        let mut sale = fixture.take_presale();
        let (liquidity_tokens, quote) = sale.migrate(
            OTHER_MIGRATOR(),
            fixture.ctx!(),
        );
        liquidity_tokens.destroy_zero();
        quote.destroy_zero();
        fixture.return_presale(sale);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EWrongEligibilityPolicy, location = blast_presale::blast_presale)]
fun the_open_commit_function_rejects_an_allowlist_policy() {
    let leaf = presale::allowlist_leaf_for_testing(0, ALICE, 500);
    let mut fixture = start(
        RAISE_TARGET,
        presale::allowlisted_eligibility(leaf, 1),
    );

    fixture.commit_open(ALICE, 1);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidAssetPair, location = blast_presale::blast_presale)]
fun sale_token_and_quote_types_must_differ() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let policy = presale::open_eligibility(1, 1);
    let (treasury_cap, mut currency) = new_currency(&mut ctx);

    let (sale, cap) = presale::new<BLAST_PRESALE_TESTS, BLAST_PRESALE_TESTS, TEST_MIGRATOR>(
        treasury_cap,
        &mut currency,
        TOKEN_SUPPLY,
        TOKEN_ALLOCATION_BPS,
        LIQUIDITY_TOKEN_ALLOCATION_BPS,
        recipient_allocations(),
        false,
        1,
        1,
        1,
        policy,
        TEST_MIGRATOR(),
        TICK_SPACING,
        FEE_RATE,
        fee_recipients(),
        REWARDS_FEE_BPS,
        &mut ctx,
    );
    sale.share(&clock);
    transfer::public_transfer(cap, CREATOR);
    destroy(currency);
    clock.destroy_for_testing();
    destroy(ctx);
}

#[test]
#[expected_failure(abort_code = presale::EInitialSupplyNotZero, location = blast_presale::blast_presale)]
fun treasury_cap_must_start_with_zero_supply() {
    let mut ctx = tx_context::dummy();
    let (mut treasury_cap, mut currency) = new_currency(&mut ctx);
    let existing_supply = treasury_cap.mint(1, &mut ctx);

    let (sale, cap) = presale::new<BLAST_PRESALE_TESTS, QUOTE, TEST_MIGRATOR>(
        treasury_cap,
        &mut currency,
        TOKEN_SUPPLY,
        TOKEN_ALLOCATION_BPS,
        LIQUIDITY_TOKEN_ALLOCATION_BPS,
        recipient_allocations(),
        false,
        RAISE_TARGET,
        DURATION_MS,
        LIQUIDITY_WINDOW_MS,
        presale::open_eligibility(WALLET_CAP, 1),
        TEST_MIGRATOR(),
        TICK_SPACING,
        FEE_RATE,
        fee_recipients(),
        REWARDS_FEE_BPS,
        &mut ctx,
    );
    existing_supply.burn_for_testing();
    let clock = clock::create_for_testing(&mut ctx);
    sale.share(&clock);
    transfer::public_transfer(cap, CREATOR);
    destroy(currency);
    clock.destroy_for_testing();
    destroy(ctx);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidTokenAllocation, location = blast_presale::blast_presale)]
fun configured_allocation_bps_cannot_exceed_full_supply() {
    let mut ctx = tx_context::dummy();
    let (treasury_cap, mut currency) = new_currency(&mut ctx);

    let (sale, cap) = presale::new<BLAST_PRESALE_TESTS, QUOTE, TEST_MIGRATOR>(
        treasury_cap,
        &mut currency,
        TOKEN_SUPPLY,
        10_000,
        1,
        recipient_allocations(),
        false,
        RAISE_TARGET,
        DURATION_MS,
        LIQUIDITY_WINDOW_MS,
        presale::open_eligibility(WALLET_CAP, 1),
        TEST_MIGRATOR(),
        TICK_SPACING,
        FEE_RATE,
        fee_recipients(),
        REWARDS_FEE_BPS,
        &mut ctx,
    );
    let clock = clock::create_for_testing(&mut ctx);
    sale.share(&clock);
    transfer::public_transfer(cap, CREATOR);
    destroy(currency);
    clock.destroy_for_testing();
    destroy(ctx);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidTokenAllocation, location = blast_presale::blast_presale)]
fun configured_allocation_bps_must_produce_positive_atomic_amounts() {
    let mut ctx = tx_context::dummy();
    let (treasury_cap, mut currency) = new_currency(&mut ctx);

    let (sale, cap) = presale::new<BLAST_PRESALE_TESTS, QUOTE, TEST_MIGRATOR>(
        treasury_cap,
        &mut currency,
        1,
        TOKEN_ALLOCATION_BPS,
        LIQUIDITY_TOKEN_ALLOCATION_BPS,
        recipient_allocations(),
        false,
        RAISE_TARGET,
        DURATION_MS,
        LIQUIDITY_WINDOW_MS,
        presale::open_eligibility(WALLET_CAP, 1),
        TEST_MIGRATOR(),
        TICK_SPACING,
        FEE_RATE,
        fee_recipients(),
        REWARDS_FEE_BPS,
        &mut ctx,
    );
    let clock = clock::create_for_testing(&mut ctx);
    sale.share(&clock);
    transfer::public_transfer(cap, CREATOR);
    destroy(currency);
    clock.destroy_for_testing();
    destroy(ctx);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidFeeSplit, location = blast_presale::blast_presale)]
fun fee_recipient_and_holder_shares_must_total_full_bps() {
    create_with_fee_split(fee_recipients(), REWARDS_FEE_BPS - 1);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidFeeSplit, location = blast_presale::blast_presale)]
fun fee_recipients_must_be_distinct() {
    create_with_fee_split(
        vector[
            presale::fee_recipient(CREATOR, CREATOR_FEE_BPS),
            presale::fee_recipient(CREATOR, FEE_PARTNER_BPS),
        ],
        REWARDS_FEE_BPS,
    );
}

#[test]
/// With no fee recipients every collected fee funds holder rewards.
fun holders_may_receive_every_fee() {
    create_with_fee_split(vector[], 10_000);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidTokenAllocation, location = blast_presale::blast_presale)]
/// An out-of-range LP share is rejected by its own error before the BPS sum can overflow.
fun an_overflowing_liquidity_share_is_rejected_before_summing() {
    let mut ctx = tx_context::dummy();
    let (treasury_cap, mut currency) = new_currency(&mut ctx);

    let (sale, cap) = presale::new<BLAST_PRESALE_TESTS, QUOTE, TEST_MIGRATOR>(
        treasury_cap,
        &mut currency,
        TOKEN_SUPPLY,
        TOKEN_ALLOCATION_BPS,
        std::u64::max_value!(),
        recipient_allocations(),
        false,
        RAISE_TARGET,
        DURATION_MS,
        LIQUIDITY_WINDOW_MS,
        presale::open_eligibility(WALLET_CAP, 1),
        TEST_MIGRATOR(),
        TICK_SPACING,
        FEE_RATE,
        fee_recipients(),
        REWARDS_FEE_BPS,
        &mut ctx,
    );
    destroy(sale);
    destroy(cap);
    destroy(currency);
    destroy(ctx);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidFeeSplit, location = blast_presale::blast_presale)]
/// An out-of-range holder share is rejected by its own error before the BPS sum can overflow.
fun an_overflowing_holder_share_is_rejected_before_summing() {
    create_with_fee_split(fee_recipients(), std::u64::max_value!());
}

#[test]
/// Sixteen distinct fee recipients fit one collection's transfer bound.
fun sixteen_fee_recipients_are_accepted() {
    create_with_fee_split(fee_recipient_set(16), 10_000 - 16 * 100);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidFeeSplit, location = blast_presale::blast_presale)]
fun a_seventeenth_fee_recipient_is_rejected() {
    create_with_fee_split(fee_recipient_set(17), 10_000 - 17 * 100);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidFeeSplit, location = blast_presale::blast_presale)]
fun a_fee_recipient_cannot_be_the_zero_address() {
    presale::fee_recipient(@0x0, 1);
}

#[test]
/// Bluefin accepts a Meme symbol at the 32-byte bound.
fun bluefin_accepts_a_thirty_two_byte_meme_symbol() {
    create_bluefin_sale(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ012345");
}

#[test]
#[expected_failure(abort_code = bluefin::ESymbolTooLong, location = blast_presale::bluefin)]
/// A longer symbol would grow every Bluefin position past Sui's object size limit.
fun bluefin_rejects_a_thirty_three_byte_meme_symbol() {
    create_bluefin_sale(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456");
}

#[test]
fun burnable_supply_is_locked_to_burn_only_at_creation() {
    let mut fixture = start_with_mode(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 1),
        true,
    );
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);
    fixture.destroy_cancelled_cap();
    fixture.end();
}

// === Test Helpers ===

fun start(raise_target: u64, eligibility: EligibilityPolicy): Fixture {
    start_with_mode(raise_target, eligibility, false)
}

fun start_with_mode(
    raise_target: u64,
    eligibility: EligibilityPolicy,
    burnable: bool,
): Fixture {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(START_MS);
    let (treasury_cap, mut currency) = new_currency(scenario.ctx());
    let treasury_cap_id = object::id(&treasury_cap);
    let (presale, cap) = presale::new<BLAST_PRESALE_TESTS, QUOTE, TEST_MIGRATOR>(
        treasury_cap,
        &mut currency,
        TOKEN_SUPPLY,
        TOKEN_ALLOCATION_BPS,
        LIQUIDITY_TOKEN_ALLOCATION_BPS,
        recipient_allocations(),
        burnable,
        raise_target,
        DURATION_MS,
        LIQUIDITY_WINDOW_MS,
        eligibility,
        TEST_MIGRATOR(),
        TICK_SPACING,
        FEE_RATE,
        fee_recipients(),
        REWARDS_FEE_BPS,
        scenario.ctx(),
    );
    let presale_id = object::id(&presale);
    let cap_id = object::id(&cap);
    let (
        created_id,
        created_presale_cap_id,
        created_treasury_cap_id,
        created_token_supply,
        created_token_allocation_bps,
        created_liquidity_token_allocation_bps,
        created_raise,
        created_duration,
        created_liquidity_window,
        created_eligibility,
    ) = only_event<PresaleCreated<BLAST_PRESALE_TESTS, QUOTE>>().created_fields();
    assert_eq!(created_id, presale_id);
    assert_eq!(created_presale_cap_id, cap_id);
    assert_eq!(created_treasury_cap_id, treasury_cap_id);
    assert_eq!(currency.is_supply_fixed(), !burnable);
    assert_eq!(currency.is_supply_burn_only(), burnable);
    assert_eq!(currency.total_supply().destroy_some(), TOKEN_SUPPLY);
    assert_eq!(
        vector[
            created_token_supply,
            created_token_allocation_bps,
            created_liquidity_token_allocation_bps,
            created_raise,
            created_duration,
            created_liquidity_window,
        ],
        vector[
            TOKEN_SUPPLY,
            TOKEN_ALLOCATION_BPS,
            LIQUIDITY_TOKEN_ALLOCATION_BPS,
            raise_target,
            DURATION_MS,
            LIQUIDITY_WINDOW_MS,
        ],
    );
    assert_eq!(created_eligibility, eligibility);
    let (
        migration_witness,
        tick_spacing,
        fee_rate,
        fee_recipients,
        fee_recipient_bps,
        rewards_fee_bps,
    ) = only_event<PresaleCreated<BLAST_PRESALE_TESTS, QUOTE>>().created_migration_fields();
    assert_eq!(migration_witness, type_name::with_original_ids<TEST_MIGRATOR>());
    assert_eq!(tick_spacing, TICK_SPACING);
    assert_eq!(fee_rate, FEE_RATE);
    assert_eq!(fee_recipients, vector[CREATOR, FEE_PARTNER]);
    assert_eq!(fee_recipient_bps, vector[CREATOR_FEE_BPS, FEE_PARTNER_BPS]);
    assert_eq!(rewards_fee_bps, REWARDS_FEE_BPS);
    let (recipient_count, created_burnable) = only_event<
        PresaleCreated<BLAST_PRESALE_TESTS, QUOTE>,
    >().created_supply_fields();
    assert_eq!(recipient_count, 2);
    assert_eq!(created_burnable, burnable);
    destroy(currency);
    presale.share(&clock);
    let (opened_id, start_ms, end_ms, deadline_ms) = only_event<
        PresaleOpened<BLAST_PRESALE_TESTS, QUOTE>,
    >().opened_fields();
    assert_eq!(opened_id, presale_id);
    assert_eq!(vector[start_ms, end_ms, deadline_ms], vector[START_MS, END_MS, LIQUIDITY_DEADLINE_MS]);
    transfer::public_transfer(cap, CREATOR);

    Fixture { scenario, clock, presale_id }
}

fun end(self: Fixture) {
    let Fixture { scenario, clock, presale_id: _ } = self;
    clock.destroy_for_testing();
    scenario.end();
}

fun new_currency(
    ctx: &mut TxContext,
): (TreasuryCap<BLAST_PRESALE_TESTS>, Currency<BLAST_PRESALE_TESTS>) {
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<BLAST_PRESALE_TESTS>(),
        9,
        b"SALE".to_string(),
        b"Sale Token".to_string(),
        b"Presale test token".to_string(),
        b"".to_string(),
        ctx,
    );

    (treasury_cap, coin_registry::unwrap_for_testing(initializer))
}

fun create_with_fee_split(fee_recipients: vector<FeeRecipient>, rewards_fee_bps: u64) {
    let mut ctx = tx_context::dummy();
    let (treasury_cap, mut currency) = new_currency(&mut ctx);

    let (sale, cap) = presale::new<BLAST_PRESALE_TESTS, QUOTE, TEST_MIGRATOR>(
        treasury_cap,
        &mut currency,
        TOKEN_SUPPLY,
        TOKEN_ALLOCATION_BPS,
        LIQUIDITY_TOKEN_ALLOCATION_BPS,
        recipient_allocations(),
        false,
        RAISE_TARGET,
        DURATION_MS,
        LIQUIDITY_WINDOW_MS,
        presale::open_eligibility(WALLET_CAP, 1),
        TEST_MIGRATOR(),
        TICK_SPACING,
        FEE_RATE,
        fee_recipients,
        rewards_fee_bps,
        &mut ctx,
    );
    destroy(sale);
    destroy(cap);
    destroy(currency);
    destroy(ctx);
}

fun fee_recipient_set(count: u64): vector<FeeRecipient> {
    vector::tabulate!(count, |i| presale::fee_recipient(sui::address::from_u256((i as u256) + 1), 100))
}

fun create_bluefin_sale(symbol: vector<u8>) {
    let mut ctx = tx_context::dummy();
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<BLAST_PRESALE_TESTS>(),
        9,
        symbol.to_string(),
        b"Sale Token".to_string(),
        b"Presale test token".to_string(),
        b"".to_string(),
        &mut ctx,
    );
    let mut currency = coin_registry::unwrap_for_testing(initializer);

    let (sale, cap) = bluefin::new<BLAST_PRESALE_TESTS, QUOTE>(
        treasury_cap,
        &mut currency,
        TOKEN_SUPPLY,
        TOKEN_ALLOCATION_BPS,
        LIQUIDITY_TOKEN_ALLOCATION_BPS,
        recipient_allocations(),
        false,
        RAISE_TARGET,
        DURATION_MS,
        LIQUIDITY_WINDOW_MS,
        presale::open_eligibility(WALLET_CAP, 1),
        fee_recipients(),
        REWARDS_FEE_BPS,
        TICK_SPACING,
        FEE_RATE,
        &mut ctx,
    );
    destroy(sale);
    destroy(cap);
    destroy(currency);
    destroy(ctx);
}

fun fee_recipients(): vector<FeeRecipient> {
    vector[
        presale::fee_recipient(CREATOR, CREATOR_FEE_BPS),
        presale::fee_recipient(FEE_PARTNER, FEE_PARTNER_BPS),
    ]
}

fun recipient_allocations(): vector<RecipientAllocation> {
    vector[
        presale::recipient_allocation(RECIPIENT_A, RECIPIENT_A_BPS),
        presale::recipient_allocation(RECIPIENT_B, RECIPIENT_B_BPS),
    ]
}

macro fun next_tx($self: &mut Fixture, $sender: address, $body: |&mut Fixture|) {
    let fixture = $self;
    fixture.scenario.next_tx($sender);
    $body(fixture);
}

macro fun ctx($self: &mut Fixture): &mut TxContext {
    let fixture = $self;
    fixture.scenario.ctx()
}

fun set_time(self: &mut Fixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
}

fun take_presale(self: &Fixture): Presale<BLAST_PRESALE_TESTS, QUOTE> {
    self.scenario.take_shared_by_id(self.presale_id)
}

fun return_presale(_self: &Fixture, presale: Presale<BLAST_PRESALE_TESTS, QUOTE>) {
    test_scenario::return_shared(presale);
}

fun commit_open(self: &mut Fixture, sender: address, amount: u64): vector<u64> {
    self.next_tx!(sender, |fixture| {
        let mut sale = fixture.take_presale();
        sale.commit_open(
            coin::mint_for_testing(amount, fixture.ctx!()),
            &fixture.clock,
            fixture.scenario.ctx(),
        );
        fixture.return_presale(sale);
    });
    let (presale_id, quote, wallet_commitment, total_commitments, participants) = only_event<
        Committed<BLAST_PRESALE_TESTS, QUOTE>,
    >().committed_fields();
    assert_eq!(presale_id, self.presale_id);
    assert_eq!(quote, amount);

    vector[wallet_commitment, total_commitments, participants]
}

fun commit_allowlisted(
    self: &mut Fixture,
    sender: address,
    amount: u64,
    index: u64,
    wallet_cap: u64,
    proof: vector<vector<u8>>,
): vector<u64> {
    self.next_tx!(sender, |fixture| {
        let mut sale = fixture.take_presale();
        sale.commit_allowlisted(
            coin::mint_for_testing(amount, fixture.ctx!()),
            index,
            wallet_cap,
            proof,
            &fixture.clock,
            fixture.scenario.ctx(),
        );
        fixture.return_presale(sale);
    });
    let (presale_id, quote, wallet_commitment, total_commitments, participants) = only_event<
        Committed<BLAST_PRESALE_TESTS, QUOTE>,
    >().committed_fields();
    assert_eq!(presale_id, self.presale_id);
    assert_eq!(quote, amount);

    vector[wallet_commitment, total_commitments, participants]
}

fun settle(self: &mut Fixture, sender: address) {
    self.next_tx!(sender, |fixture| {
        let mut sale = fixture.take_presale();
        sale.settle(&fixture.clock);
        fixture.return_presale(sale);
    });
}

fun migrate(self: &mut Fixture): vector<u64> {
    let mut amounts = vector[];
    self.next_tx!(KEEPER, |fixture| {
        let mut sale = fixture.take_presale();
        let (liquidity_tokens, quote) = sale.migrate(
            TEST_MIGRATOR(),
            fixture.ctx!(),
        );
        amounts.push_back(liquidity_tokens.into_coin(fixture.ctx!()).burn_for_testing());
        amounts.push_back(quote.into_coin(fixture.ctx!()).burn_for_testing());
        assert!(sale.is_migrated_for_testing());
        fixture.return_presale(sale);
    });
    amounts
}

fun take_recipient_allocations(self: &mut Fixture) {
    self.next_tx!(RECIPIENT_A, |fixture| assert_eq!(
        fixture.scenario.take_from_sender<Coin<BLAST_PRESALE_TESTS>>().burn_for_testing(),
        RECIPIENT_A_TOKENS,
    ));
    self.next_tx!(RECIPIENT_B, |fixture| assert_eq!(
        fixture.scenario.take_from_sender<Coin<BLAST_PRESALE_TESTS>>().burn_for_testing(),
        RECIPIENT_B_TOKENS,
    ));
}

fun destroy_migrated_cap(self: &mut Fixture) {
    self.next_tx!(CREATOR, |fixture| {
        let cap = fixture.scenario.take_from_sender<PresaleCap>();
        destroy(cap);
    });
}

fun cancel_unlaunched(self: &mut Fixture, sender: address) {
    self.next_tx!(sender, |fixture| {
        let mut sale = fixture.take_presale();
        sale.cancel_unlaunched(&fixture.clock);
        fixture.return_presale(sale);
    });
}

fun claim(self: &mut Fixture, sender: address, participant: address): vector<u64> {
    self.next_tx!(sender, |fixture| {
        let mut sale = fixture.take_presale();
        sale.claim(participant, fixture.ctx!());
        fixture.return_presale(sale);
    });
    let (presale_id, delivered_to, commitment, tokens, quote_refund, remaining) = only_event<
        Claimed<BLAST_PRESALE_TESTS, QUOTE>,
    >().claim_fields();
    assert_eq!(presale_id, self.presale_id);
    assert_eq!(delivered_to, participant);

    vector[commitment, tokens, quote_refund, remaining]
}

fun take_payout(self: &mut Fixture, participant: address, tokens: u64, quote: u64) {
    self.next_tx!(participant, |fixture| {
        assert_eq!(
            fixture.scenario.take_from_sender<Coin<BLAST_PRESALE_TESTS>>().burn_for_testing(),
            tokens,
        );
        assert_eq!(
            fixture.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(),
            quote,
        );
    });
}

fun take_quote(self: &mut Fixture, participant: address, quote: u64) {
    self.next_tx!(participant, |fixture| {
        assert_eq!(
            fixture.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(),
            quote,
        );
    });
}

fun destroy_cancelled_cap(self: &mut Fixture) {
    self.next_tx!(CREATOR, |fixture| {
        let cap = fixture.scenario.take_from_sender<PresaleCap>();
        let sale = fixture.take_presale();
        sale.destroy_cap(cap);
        fixture.return_presale(sale);
    });
}

fun is_funded(self: &mut Fixture): bool {
    let mut funded = vector[];
    self.next_tx!(KEEPER, |fixture| {
        let sale = fixture.take_presale();
        funded.push_back(sale.is_funded_for_testing());
        fixture.return_presale(sale);
    });
    funded.pop_back()
}

fun is_cancelled(self: &mut Fixture): bool {
    let mut cancelled = vector[];
    self.next_tx!(KEEPER, |fixture| {
        let sale = fixture.take_presale();
        cancelled.push_back(sale.is_cancelled_for_testing());
        fixture.return_presale(sale);
    });
    cancelled.pop_back()
}

fun custody(self: &mut Fixture): vector<u64> {
    let mut values = vector[];
    self.next_tx!(KEEPER, |fixture| {
        let sale = fixture.take_presale();
        let (
            total,
            remaining,
            participants,
            quote,
            sale_tokens,
            liquidity_tokens,
            recipient_tokens,
        ) = sale.custody_for_testing();
        values.append(vector[
            total,
            remaining,
            participants,
            quote,
            sale_tokens,
            liquidity_tokens,
            recipient_tokens,
        ]);
        fixture.return_presale(sale);
    });

    values
}

fun commitment(self: &mut Fixture, participant: address): u64 {
    let mut commitment = vector[];
    self.next_tx!(KEEPER, |fixture| {
        let sale = fixture.take_presale();
        commitment.push_back(sale.commitment_for_testing(participant));
        fixture.return_presale(sale);
    });
    commitment.pop_back()
}

fun only_event<Event: copy + drop>(): Event {
    let mut events = event::events_by_type<Event>();
    assert_eq!(events.length(), 1);
    events.pop_back()
}

// === Imports ===

use blast_presale::{bluefin, blast_presale::{
    Self as presale,
    Claimed,
    Committed,
    EligibilityPolicy,
    FeeRecipient,
    Presale,
    PresaleCancelled,
    PresaleCap,
    PresaleCreated,
    PresaleFunded,
    PresaleMigrated,
    PresaleOpened,
    RecipientAllocation,
}};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin, TreasuryCap},
    coin_registry::{Self, Currency},
    event,
    test_scenario::{Self, Scenario},
    test_utils,
};
