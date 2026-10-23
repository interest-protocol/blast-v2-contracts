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
const TREASURY: address = @0x7EA5;
const NEW_TREASURY: address = @0x7EA6;
const ADMIN: address = @0xAD;

/// Scheduled sales are created and shared here, ahead of `COMMITMENT_STARTS_AT_MS`.
const SCHEDULED_AT_MS: u64 = 400;
const COMMITMENT_STARTS_AT_MS: u64 = 1_000;
const COMMITMENT_DURATION_MS: u64 = 100;
const COMMITMENT_ENDS_AT_MS: u64 = COMMITMENT_STARTS_AT_MS + COMMITMENT_DURATION_MS;
/// The shortest window `new` accepts, so every fixture also pins the seven-day floor.
const LIQUIDITY_WINDOW_DURATION_MS: u64 = 7 * 24 * 60 * 60 * 1_000;
const LIQUIDITY_DEADLINE_AT_MS: u64 = COMMITMENT_ENDS_AT_MS + LIQUIDITY_WINDOW_DURATION_MS;
const UNCAPPED_DELAY_MS: u64 = 50;
const UNCAPPED_STARTS_AT_MS: u64 = COMMITMENT_STARTS_AT_MS + UNCAPPED_DELAY_MS;
const CAROL: address = @0xCA201;
const RAISE_RECIPIENT: address = @0x5A1E;

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
const POOL_FEE_RATE: u64 = 1_000;
const CREATOR_FEE_BPS: u64 = 5_000;
const FEE_PARTNER_BPS: u64 = 2_000;
const HOLDER_REWARDS_BPS: u64 = 3_000;
const PROTOCOL_RAISE_BPS: u64 = 333;
const PROTOCOL_TOKEN_BPS: u64 = 500;
const PROTOCOL_TOKENS: u64 = 1_000;
/// Recipient B's share when Blast takes `PROTOCOL_TOKEN_BPS` of the supply.
const FEE_PAYING_RECIPIENT_B_BPS: u64 = 1_000;
const FEE_PAYING_RECIPIENT_B_TOKENS: u64 = 2_000;
/// Team vesting: half at the cliff, the rest over the following two steps.
const VESTING_CLIFF_DELAY_MS: u64 = 100;
const VESTING_PERIOD_DURATION_MS: u64 = 50;
const VESTING_PERIODS: u64 = 4;
const VESTING_DURATION_MS: u64 = VESTING_PERIOD_DURATION_MS * VESTING_PERIODS;
const MAX_VESTING_DURATION_MS: u64 = 1 << 63;

/// Where the Blast partner is paid, and its cut of Blast's raise fee: 40%.
const PARTNER_RECIPIENT: address = @0x9A27;
const PARTNER_CUT_BPS: u64 = 4_000;

// === Test-Only Types ===

public struct BLAST_PRESALE_TESTS() has drop;
public struct QUOTE() has drop;
public struct TEST_MIGRATOR() has drop;
public struct OTHER_MIGRATOR() has drop;

public struct Fixture {
    scenario: Scenario,
    clock: Clock,
    fee_policy: FeePolicy,
    presale_id: ID,
}

/// The creator-chosen terms the initializer's setters take, named so a test can change one field of
/// `valid_sale_terms` and show exactly which input a creation guard rejects.
public struct SaleTerms has drop {
    token_supply: u64,
    token_allocation_bps: u64,
    participant_vesting: Option<VestingTerms>,
    liquidity_token_allocation_bps: u64,
    recipient_allocations: vector<RecipientShare>,
    burnable: bool,
    raise_target: u64,
    raise_allocations: vector<RecipientShare>,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    hard_cap: Option<HardCapTerms>,
    fee_recipients: vector<RecipientShare>,
    holder_rewards_bps: u64,
}

/// The arguments of `set_hard_cap`.
public struct HardCapTerms has copy, drop {
    starts_after_ms: u64,
    closes_when_filled: bool,
}

// === Tests ===

#[test]
/// Every wallet gets the same fill rate regardless of commitment size or claim order.
fun oversubscription_uses_one_fill_rate_and_refunds_the_rest() {
    let mut fixture = start_sale(presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2));

    assert_eq!(fixture.commit_open(ALICE, 1_000), vector[1_000, 1_000, 1]);
    assert_eq!(fixture.commit_open(BOB, 3_000), vector[3_000, 4_000, 2]);

    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);

    let (presale_id, commitments, accepted, refundable, tokens) = only_event<
        PresaleFunded<BLAST_PRESALE_TESTS, QUOTE>,
    >().funded_fields();
    assert_eq!(presale_id, fixture.presale_id);
    assert_eq!(
        vector[commitments, accepted, refundable, tokens],
        vector[4_000, 1_000, 3_000, TOKEN_ALLOCATION],
    );
    assert_eq!(fixture.funded_deadlines(), vector[COMMITMENT_ENDS_AT_MS, LIQUIDITY_DEADLINE_AT_MS]);
    assert!(fixture.is_funded());

    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, RAISE_TARGET]);

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

    assert_eq!(fixture.claim(KEEPER, ALICE), vector[1_000, 2_500, 750, 1]);
    fixture.take_payout(ALICE, 2_500, 750);
    assert_eq!(fixture.claim(KEEPER, BOB), vector[3_000, 7_501, 2_250, 0]);
    fixture.take_payout(BOB, 7_501, 2_250);
    assert_eq!(fixture.custody(), vector[4_000, 0, 0, 0, 0, 0, 0]);

    fixture.destroy_migrated_cap();
    fixture.end();
}

#[test]
/// The claim that empties the sale takes the integer remainder, whichever wallet makes it.
fun claim_order_changes_only_who_takes_the_remainder() {
    let mut fixture = start_sale(presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2));
    fixture.commit_open(ALICE, 1_000);
    fixture.commit_open(BOB, 3_000);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);
    fixture.migrate();
    fixture.take_recipient_allocations();

    // Bob's 10,001 * 3,000 / 4,000 = 7,500.75 rounds down; Alice's last claim takes the rest.
    assert_eq!(fixture.claim(KEEPER, BOB), vector[3_000, 7_500, 2_250, 1]);
    fixture.take_payout(BOB, 7_500, 2_250);
    assert_eq!(fixture.claim(KEEPER, ALICE), vector[1_000, 2_501, 750, 0]);
    fixture.take_payout(ALICE, 2_501, 750);
    assert_eq!(fixture.custody(), vector[4_000, 0, 0, 0, 0, 0, 0]);

    fixture.destroy_migrated_cap();
    fixture.end();
}

#[test]
/// A commitment is backed one-for-one by Quote held in the presale object.
fun commitments_lock_quote_in_presale_custody() {
    let mut fixture = start_sale(presale::open_eligibility(WALLET_CAP, 1_000, 1));

    fixture.commit_open(ALICE, 400);
    assert_eq!(
        fixture.custody(),
        vector[400, 1, 400, TOKEN_ALLOCATION, LIQUIDITY_TOKENS, RECIPIENT_TOKENS, 0],
    );

    fixture.commit_open(ALICE, 100);
    assert_eq!(
        fixture.custody(),
        vector[500, 1, 500, TOKEN_ALLOCATION, LIQUIDITY_TOKENS, RECIPIENT_TOKENS, 0],
    );

    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);
    fixture.claim(KEEPER, ALICE);
    fixture.take_quote(ALICE, 500);

    fixture.destroy_cancelled_cap();
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidLifecycle,
    location = blast_presale::blast_presale,
)]
fun participants_cannot_withdraw_open_commitments() {
    let mut fixture = start_sale(presale::open_eligibility(WALLET_CAP, 1_000, 1));
    fixture.commit_open(ALICE, 500);

    fixture.claim(ALICE, ALICE);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidLifecycle,
    location = blast_presale::blast_presale,
)]
fun participants_cannot_withdraw_funded_commitments() {
    let mut fixture = start_funded_sale();

    fixture.claim(ALICE, ALICE);

    fixture.end();
}

#[test]
/// An underfunded sale releases no Quote and every wallet can recover its full commitment.
fun underfunded_sale_refunds_quote_and_locks_minted_supply_forever() {
    let mut fixture = start_sale(presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2));
    fixture.commit_open(ALICE, 500);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);

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
        vector[500, 0, 0, TOKEN_ALLOCATION, LIQUIDITY_TOKENS, RECIPIENT_TOKENS, 0],
    );

    fixture.destroy_cancelled_cap();
    fixture.end();
}

#[test]
/// A funded sale cannot lock participants forever when its creator never adds LP.
fun missed_liquidity_deadline_turns_a_funded_sale_into_full_refunds() {
    let mut fixture = start_funded_sale();
    fixture.set_time(LIQUIDITY_DEADLINE_AT_MS);

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
    let mut fixture = start_sale(presale::allowlisted_eligibility(root, 2));

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

    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);
    fixture.claim(KEEPER, ALICE);
    fixture.take_quote(ALICE, 500);
    fixture.claim(KEEPER, BOB);
    fixture.take_quote(BOB, 100);

    fixture.destroy_cancelled_cap();
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidEligibilityProof,
    location = blast_presale::blast_presale,
)]
fun an_allowlist_proof_cannot_change_its_wallet_cap() {
    let alice_leaf = presale::allowlist_leaf_for_testing(0, ALICE, 500);
    let mut fixture = start_sale(presale::allowlisted_eligibility(alice_leaf, 1));

    fixture.commit_allowlisted(ALICE, 500, 0, 501, vector[]);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EWalletCapExceeded,
    location = blast_presale::blast_presale,
)]
fun cumulative_commitments_cannot_exceed_the_wallet_cap() {
    let mut fixture = start_sale(presale::open_eligibility(500, 4, RAISE_TARGET / 4));
    fixture.commit_open(ALICE, 400);

    fixture.commit_open(ALICE, 101);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EParticipantCapacityReached,
    location = blast_presale::blast_presale,
)]
fun open_sales_bound_their_dynamic_commitment_records() {
    let mut fixture = start_sale(single_wallet_eligibility());
    fixture.commit_open(ALICE, RAISE_TARGET);

    fixture.commit_open(BOB, RAISE_TARGET);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EBelowMinimumCommitment,
    location = blast_presale::blast_presale,
)]
/// A dust commitment is rejected before it can occupy one of the sale's participant slots.
fun a_commitment_below_the_minimum_is_rejected_before_taking_a_slot() {
    let mut fixture = start_sale(presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2));

    fixture.commit_open(ALICE, RAISE_TARGET / 2 - 1);

    fixture.end();
}

#[test]
/// Once a wallet meets the minimum, it may top up by any positive amount.
fun a_wallet_above_the_minimum_may_top_up_by_any_amount() {
    let mut fixture = start_sale(presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2));
    fixture.commit_open(ALICE, RAISE_TARGET / 2);

    assert_eq!(
        fixture.commit_open(ALICE, 1),
        vector[RAISE_TARGET / 2 + 1, RAISE_TARGET / 2 + 1, 1],
    );

    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);
    fixture.claim(KEEPER, ALICE);
    fixture.take_quote(ALICE, RAISE_TARGET / 2 + 1);

    fixture.destroy_cancelled_cap();
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EUnreachableRaise,
    location = blast_presale::blast_presale,
)]
/// Filling every open slot at the minimum must fund the raise, or dust could block the sale.
fun an_open_sale_whose_slots_cannot_reach_the_raise_is_rejected() {
    start_sale(presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2 - 1)).end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidEligibilityPolicy,
    location = blast_presale::blast_presale,
)]
fun the_minimum_commitment_cannot_exceed_the_wallet_cap() {
    presale::open_eligibility(100, 20, 101);
}

#[test]
#[expected_failure(
    abort_code = presale::EWalletCapExceeded,
    location = blast_presale::blast_presale,
)]
/// Before the uncapped phase starts, wallet caps still apply.
fun wallet_caps_hold_until_the_uncapped_phase_starts() {
    let mut fixture = start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_eligible(UNCAPPED_DELAY_MS),
    );
    fixture.set_time(UNCAPPED_STARTS_AT_MS - 1);

    fixture.commit_open(ALICE, 501);

    fixture.end();
}

#[test]
/// Without a hard cap, the uncapped phase lifts caps and the sale still overflows pro-rata.
fun an_uncapped_phase_without_a_hard_cap_lifts_caps_and_overflows() {
    let mut fixture = start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_eligible(UNCAPPED_DELAY_MS),
    );
    fixture.commit_open(ALICE, 500);
    fixture.set_time(UNCAPPED_STARTS_AT_MS);

    assert_eq!(fixture.commit_open(BOB, 3_000), vector[3_000, 3_500, 2]);

    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);
    assert!(fixture.is_funded());

    fixture.end();
}

#[test]
/// A hard cap from the uncapped phase takes only what is left of the raise and returns the rest.
fun a_hard_capped_uncapped_phase_fills_the_raise_and_returns_the_excess() {
    let mut fixture = start_with_hard_cap(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        option::some(presale::uncapped_for_eligible(UNCAPPED_DELAY_MS)),
        hard_cap_at(UNCAPPED_DELAY_MS, false),
    );
    fixture.commit_open(ALICE, 400);
    fixture.set_time(UNCAPPED_STARTS_AT_MS);

    assert_eq!(fixture.commit_open_for_change(BOB, 2_000), vector[600, 1_400]);
    assert_eq!(fixture.commitment(BOB), 600);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EPresaleFilled, location = blast_presale::blast_presale)]
fun a_full_hard_capped_sale_accepts_no_more_quote() {
    let mut fixture = start_with_hard_cap(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        option::some(presale::uncapped_for_eligible(UNCAPPED_DELAY_MS)),
        hard_cap_at(UNCAPPED_DELAY_MS, false),
    );
    fixture.set_time(UNCAPPED_STARTS_AT_MS);
    fixture.commit_open_for_change(ALICE, RAISE_TARGET);

    fixture.commit_open_for_change(BOB, RAISE_TARGET / 4);

    fixture.end();
}

#[test]
/// The commitment that exactly fills a hard cap may fall below the per-wallet minimum.
fun the_commitment_that_fills_a_hard_cap_may_be_below_the_minimum() {
    let mut fixture = start_with_hard_cap(
        presale::open_eligibility(1_000, 4, RAISE_TARGET / 4),
        option::some(presale::uncapped_for_eligible(UNCAPPED_DELAY_MS)),
        hard_cap_at(UNCAPPED_DELAY_MS, false),
    );
    fixture.set_time(UNCAPPED_STARTS_AT_MS);
    fixture.commit_open_for_change(ALICE, 900);

    assert_eq!(fixture.commit_open_for_change(BOB, 500), vector[100, 400]);

    fixture.end();
}

#[test]
/// A hard cap from the start keeps wallet caps: wallets fill the raise first come, first served
/// within their caps, and the last commitment takes only what is left.
fun a_hard_cap_from_the_start_fills_first_come_within_wallet_caps() {
    let mut fixture = start_with_hard_cap(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        option::none(),
        hard_cap_at(0, false),
    );

    assert_eq!(fixture.commit_open_for_change(ALICE, 400), vector[400, 0]);
    assert_eq!(fixture.commit_open_for_change(BOB, 500), vector[500, 0]);
    assert_eq!(fixture.commit_open_for_change(CAROL, 500), vector[100, 400]);
    assert_eq!(fixture.commitment(CAROL), 100);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EWalletCapExceeded,
    location = blast_presale::blast_presale,
)]
/// A hard cap does not lift wallet caps; only an uncapped phase does.
fun a_hard_cap_keeps_wallet_caps() {
    let mut fixture = start_with_hard_cap(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        option::none(),
        hard_cap_at(0, false),
    );

    fixture.commit_open_for_change(ALICE, 501);

    fixture.end();
}

#[test]
/// A sale whose hard cap closes it when filled settles as soon as its raise is full, ending its
/// window then: its LP deadline counts from the close, and it migrates at once.
fun a_sale_that_closes_when_filled_settles_once_its_raise_is_full() {
    let closed_at_ms = COMMITMENT_STARTS_AT_MS + 10;
    let mut fixture = start_with_hard_cap(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        option::none(),
        hard_cap_at(0, true),
    );
    fixture.set_time(closed_at_ms);
    fixture.commit_open(ALICE, 500);
    fixture.commit_open(BOB, 500);

    fixture.settle(KEEPER);

    let (presale_id, commitments, accepted, refundable, tokens) = only_event<
        PresaleFunded<BLAST_PRESALE_TESTS, QUOTE>,
    >().funded_fields();
    assert_eq!(presale_id, fixture.presale_id);
    assert_eq!(
        vector[commitments, accepted, refundable, tokens],
        vector[RAISE_TARGET, RAISE_TARGET, 0, TOKEN_ALLOCATION],
    );
    assert_eq!(
        fixture.funded_deadlines(),
        vector[closed_at_ms, closed_at_ms + LIQUIDITY_WINDOW_DURATION_MS],
    );
    assert!(fixture.is_funded());
    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, RAISE_TARGET]);

    fixture.end();
}

#[test]
/// A sale filled at its very start under a hard cap from the start closes with a zero-length
/// window: it ends at its start, and its LP deadline is one LP window later.
fun a_sale_filled_at_its_start_closes_with_a_zero_length_window() {
    let mut fixture = start_with_hard_cap(
        single_wallet_eligibility(),
        option::none(),
        hard_cap_at(0, true),
    );
    fixture.commit_open(ALICE, RAISE_TARGET);

    fixture.settle(KEEPER);

    assert_eq!(fixture.funded_deadlines(), vector[COMMITMENT_STARTS_AT_MS, COMMITMENT_STARTS_AT_MS + LIQUIDITY_WINDOW_DURATION_MS]);
    assert!(fixture.is_funded());
    fixture.end();
}

#[test]
/// An early close brings the refund exit forward: a sale nobody migrates within the LP window
/// after its close can be cancelled before its original deadline.
fun an_early_closed_sale_can_be_cancelled_one_lp_window_after_its_close() {
    let closed_at_ms = COMMITMENT_STARTS_AT_MS + 10;
    let mut fixture = start_with_hard_cap(
        single_wallet_eligibility(),
        option::none(),
        hard_cap_at(0, true),
    );
    fixture.set_time(closed_at_ms);
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.settle(KEEPER);
    fixture.set_time(closed_at_ms + LIQUIDITY_WINDOW_DURATION_MS);

    fixture.cancel_unlaunched(KEEPER);

    assert!(fixture.is_cancelled());
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::ELiquidityDeadlineNotReached,
    location = blast_presale::blast_presale,
)]
fun an_early_closed_sale_cannot_be_cancelled_inside_its_lp_window() {
    let closed_at_ms = COMMITMENT_STARTS_AT_MS + 10;
    let mut fixture = start_with_hard_cap(
        single_wallet_eligibility(),
        option::none(),
        hard_cap_at(0, true),
    );
    fixture.set_time(closed_at_ms);
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.settle(KEEPER);
    fixture.set_time(closed_at_ms + LIQUIDITY_WINDOW_DURATION_MS - 1);

    fixture.cancel_unlaunched(KEEPER);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EPresaleNotEnded, location = blast_presale::blast_presale)]
/// A full sale whose hard cap does not close it when filled runs to its end.
fun a_full_sale_that_does_not_close_when_filled_waits_for_its_end() {
    let mut fixture = start_with_hard_cap(
        single_wallet_eligibility(),
        option::none(),
        hard_cap_at(0, false),
    );
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(COMMITMENT_ENDS_AT_MS - 1);

    fixture.settle(KEEPER);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EPresaleNotEnded, location = blast_presale::blast_presale)]
/// A hard-capped sale whose raise is not full yet can still take Quote, so it cannot close.
fun a_hard_capped_sale_short_of_its_raise_cannot_close_early() {
    let mut fixture = start_with_hard_cap(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        option::none(),
        hard_cap_at(0, true),
    );
    fixture.commit_open(ALICE, 500);
    fixture.commit_open(BOB, 499);

    fixture.settle(KEEPER);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EPresaleNotEnded, location = blast_presale::blast_presale)]
/// A sale without a hard cap overflows for its whole window, so reaching the raise never closes
/// it: later wallets may still join at the common fill rate.
fun an_overflowing_sale_cannot_close_early() {
    let mut fixture = start_sale(presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2));
    fixture.commit_open(ALICE, 3_000);

    fixture.settle(KEEPER);

    fixture.end();
}

#[test]
/// Commitments overfilling the raise before the hard cap starts keep their overflow, and the
/// sale may close once the hard cap starts, since it can take no more Quote.
fun a_sale_overfilled_before_its_hard_cap_closes_when_the_hard_cap_starts() {
    let mut fixture = start_with_hard_cap(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        option::some(presale::uncapped_for_eligible(UNCAPPED_DELAY_MS)),
        hard_cap_at(UNCAPPED_DELAY_MS, true),
    );
    fixture.commit_open(ALICE, 500);
    fixture.commit_open(BOB, 500);
    fixture.commit_open(CAROL, 500);
    fixture.set_time(UNCAPPED_STARTS_AT_MS);

    fixture.settle(KEEPER);

    let (_, commitments, accepted, refundable, _) = only_event<
        PresaleFunded<BLAST_PRESALE_TESTS, QUOTE>,
    >().funded_fields();
    assert_eq!(vector[commitments, accepted, refundable], vector[1_500, RAISE_TARGET, 500]);
    assert_eq!(
        fixture.funded_deadlines(),
        vector[UNCAPPED_STARTS_AT_MS, UNCAPPED_STARTS_AT_MS + LIQUIDITY_WINDOW_DURATION_MS],
    );

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EPresaleNotEnded, location = blast_presale::blast_presale)]
/// Before its hard cap starts, an overfilled sale still overflows, so it cannot close.
fun a_sale_overfilled_before_its_hard_cap_cannot_close_before_the_hard_cap_starts() {
    let mut fixture = start_with_hard_cap(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        option::some(presale::uncapped_for_eligible(UNCAPPED_DELAY_MS)),
        hard_cap_at(UNCAPPED_DELAY_MS, true),
    );
    fixture.commit_open(ALICE, 500);
    fixture.commit_open(BOB, 500);
    fixture.commit_open(CAROL, 500);
    fixture.set_time(UNCAPPED_STARTS_AT_MS - 1);

    fixture.settle(KEEPER);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidLifecycle,
    location = blast_presale::blast_presale,
)]
/// An early close ends commitments.
fun a_sale_closed_early_takes_no_more_commitments() {
    let mut fixture = start_with_hard_cap(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        option::none(),
        hard_cap_at(0, true),
    );
    fixture.commit_open(ALICE, 500);
    fixture.commit_open(BOB, 500);
    fixture.settle(KEEPER);

    fixture.commit_open(CAROL, 500);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidHardCap, location = blast_presale::blast_presale)]
fun a_hard_cap_must_start_inside_the_window() {
    start_with_hard_cap(
        single_wallet_eligibility(),
        option::none(),
        hard_cap_at(COMMITMENT_DURATION_MS, true),
    ).end();
}

#[test]
#[expected_failure(abort_code = presale::EMissingSetting, location = blast_presale::blast_presale)]
fun a_sale_cannot_be_finalized_without_an_eligibility_policy() {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::new_for_testing(&mut ctx);
    let (treasury_cap, mut currency) = new_currency(&mut ctx);
    let fee_policy = fee_policy::new_for_testing(&mut ctx);
    let creation_policy = creation_policy::allowing_for_testing<QUOTE, TEST_MIGRATOR>(&mut ctx);
    let mut initializer = bare_initializer(
        &package_version,
        treasury_cap,
        &creation_policy,
        &fee_policy,
    );
    initializer.set_fee_split(
        &package_version,
        presale::fee_split(fee_recipients(), bps::new(HOLDER_REWARDS_BPS)),
    );

    let (_sale, _cap) = initializer.finalize(&package_version, &mut currency, &mut ctx);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(abort_code = presale::EMissingSetting, location = blast_presale::blast_presale)]
fun a_sale_cannot_be_finalized_without_an_lp_fee_split() {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::new_for_testing(&mut ctx);
    let (treasury_cap, mut currency) = new_currency(&mut ctx);
    let fee_policy = fee_policy::new_for_testing(&mut ctx);
    let creation_policy = creation_policy::allowing_for_testing<QUOTE, TEST_MIGRATOR>(&mut ctx);
    let mut initializer = bare_initializer(
        &package_version,
        treasury_cap,
        &creation_policy,
        &fee_policy,
    );
    initializer.set_eligibility(&package_version, single_wallet_eligibility());

    let (_sale, _cap) = initializer.finalize(&package_version, &mut currency, &mut ctx);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidRaiseTarget,
    location = blast_presale::blast_presale,
)]
/// A sale whose raise was never set has a zero raise target.
fun a_sale_cannot_be_finalized_without_a_raise() {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::new_for_testing(&mut ctx);
    let (treasury_cap, mut currency) = new_currency(&mut ctx);
    let fee_policy = fee_policy::new_for_testing(&mut ctx);
    let creation_policy = creation_policy::allowing_for_testing<QUOTE, TEST_MIGRATOR>(&mut ctx);
    let mut initializer = bare_initializer(
        &package_version,
        treasury_cap,
        &creation_policy,
        &fee_policy,
    );
    initializer.set_eligibility(&package_version, single_wallet_eligibility());
    initializer.set_fee_split(
        &package_version,
        presale::fee_split(fee_recipients(), bps::new(HOLDER_REWARDS_BPS)),
    );

    let (_sale, _cap) = initializer.finalize(&package_version, &mut currency, &mut ctx);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
/// An uncapped phase open to anyone admits wallets outside the allowlist. Its four slots beyond
/// the one leaf reach the raise at the minimum.
fun an_uncapped_phase_open_to_anyone_admits_wallets_outside_the_allowlist() {
    let alice_leaf = presale::allowlist_leaf_for_testing(0, ALICE, 500);
    let mut fixture = start_with_uncapped_phase(
        presale::allowlisted_eligibility(alice_leaf, 1),
        presale::uncapped_for_anyone(UNCAPPED_DELAY_MS, 5, RAISE_TARGET / 4),
    );
    fixture.commit_allowlisted(ALICE, 500, 0, 500, vector[]);
    fixture.set_time(UNCAPPED_STARTS_AT_MS);

    assert_eq!(fixture.commit_uncapped(CAROL, 2_000), vector[2_000, 0]);
    assert_eq!(fixture.commitment(CAROL), 2_000);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EUncappedPhaseNotOpen,
    location = blast_presale::blast_presale,
)]
fun the_open_uncapped_route_waits_for_its_phase() {
    let mut fixture = start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_anyone(UNCAPPED_DELAY_MS, 4, RAISE_TARGET / 4),
    );
    fixture.set_time(UNCAPPED_STARTS_AT_MS - 1);

    fixture.commit_uncapped(CAROL, 500);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EUncappedPhaseNotOpen,
    location = blast_presale::blast_presale,
)]
/// A phase limited to eligible wallets never opens the anyone route.
fun an_eligible_only_phase_rejects_the_open_uncapped_route() {
    let mut fixture = start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_eligible(UNCAPPED_DELAY_MS),
    );
    fixture.set_time(UNCAPPED_STARTS_AT_MS);

    fixture.commit_uncapped(CAROL, 500);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidUncappedPhase,
    location = blast_presale::blast_presale,
)]
fun an_uncapped_phase_must_start_inside_the_window() {
    start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_eligible(COMMITMENT_DURATION_MS),
    ).end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidUncappedPhase,
    location = blast_presale::blast_presale,
)]
/// Opening to anyone cannot shrink the participant bound eligible wallets already have.
fun an_open_uncapped_phase_cannot_admit_fewer_wallets_than_the_policy() {
    start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_anyone(UNCAPPED_DELAY_MS, 3, RAISE_TARGET),
    ).end();
}

#[test]
#[expected_failure(
    abort_code = presale::EUnreachableRaise,
    location = blast_presale::blast_presale,
)]
/// Anyone-access slots must also fund the raise when filled at their minimum.
fun an_open_uncapped_phase_whose_slots_cannot_reach_the_raise_is_rejected() {
    start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_anyone(UNCAPPED_DELAY_MS, 4, RAISE_TARGET / 4 - 1),
    ).end();
}

#[test]
#[expected_failure(
    abort_code = presale::EUnreachableRaise,
    location = blast_presale::blast_presale,
)]
/// Allowlisted wallets may commit any positive amount, so only the phase slots beyond the
/// allowlist count toward reaching the raise: three slots at a quarter of it do not.
fun an_open_uncapped_phase_counts_only_the_slots_beyond_the_allowlist() {
    let alice_leaf = presale::allowlist_leaf_for_testing(0, ALICE, 500);

    start_with_uncapped_phase(
        presale::allowlisted_eligibility(alice_leaf, 1),
        presale::uncapped_for_anyone(UNCAPPED_DELAY_MS, 4, RAISE_TARGET / 4),
    ).end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidWindow, location = blast_presale::blast_presale)]
fun a_zero_commitment_window_is_rejected() {
    create_with_windows(0, LIQUIDITY_WINDOW_DURATION_MS);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidWindow, location = blast_presale::blast_presale)]
/// A shorter LP window would let one transaction settle and cancel a sale nobody settled in time.
fun a_liquidity_window_below_seven_days_is_rejected() {
    create_with_windows(COMMITMENT_DURATION_MS, LIQUIDITY_WINDOW_DURATION_MS - 1);
}

#[test]
/// A raise allocation is paid in Quote at migration and the LP takes the rest.
fun raise_allocations_are_paid_at_migration_and_the_lp_takes_the_rest() {
    let mut fixture = start_with_raise_allocations(vector[
        presale::recipient_share(RAISE_RECIPIENT, bps::new(2_000)),
    ]);
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);

    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, 800]);

    let (_, recipient, quote) = only_event<
        RaiseAllocated<BLAST_PRESALE_TESTS, QUOTE>,
    >().raise_allocated_fields();
    assert_eq!(recipient, RAISE_RECIPIENT);
    assert_eq!(quote, 200);
    fixture.take_recipient_allocations();
    fixture.take_quote(RAISE_RECIPIENT, 200);

    fixture.destroy_migrated_cap();
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidRaiseAllocation,
    location = blast_presale::blast_presale,
)]
/// The LP must always keep part of the raise.
fun raise_allocations_must_leave_the_lp_a_share() {
    start_with_raise_allocations(vector[
        presale::recipient_share(RAISE_RECIPIENT, bps::new(6_000)),
        presale::recipient_share(CAROL, bps::new(4_000)),
    ]).end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidRaiseAllocation,
    location = blast_presale::blast_presale,
)]
/// A zero share is a raise-allocation error, not a token-allocation one.
fun a_raise_allocation_must_take_a_positive_share() {
    start_with_raise_allocations(vector[
        presale::recipient_share(RAISE_RECIPIENT, bps::new(0)),
    ]).end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidRaiseAllocation,
    location = blast_presale::blast_presale,
)]
fun raise_allocation_recipients_must_be_distinct() {
    start_with_raise_allocations(vector[
        presale::recipient_share(RAISE_RECIPIENT, bps::new(1_000)),
        presale::recipient_share(RAISE_RECIPIENT, bps::new(1_000)),
    ]).end();
}

#[test]
#[expected_failure(abort_code = presale::EPresaleEnded, location = blast_presale::blast_presale)]
fun commitments_at_the_exact_end_are_rejected_before_amount_checks() {
    let mut fixture = start_sale(single_wallet_eligibility());
    fixture.set_time(COMMITMENT_ENDS_AT_MS);

    fixture.commit_open(ALICE, 0);

    fixture.end();
}

#[test]
/// The LP deadline only opens refunds; anyone may still migrate until someone cancels.
fun a_late_settled_sale_can_still_migrate_after_the_liquidity_deadline() {
    let mut fixture = start_sale(single_wallet_eligibility());
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(LIQUIDITY_DEADLINE_AT_MS);
    fixture.settle(KEEPER);
    assert!(fixture.is_funded());

    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, RAISE_TARGET]);
    fixture.take_recipient_allocations();

    fixture.destroy_migrated_cap();
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidLifecycle,
    location = blast_presale::blast_presale,
)]
fun a_cancelled_unlaunched_sale_cannot_migrate() {
    let mut fixture = start_funded_sale();
    fixture.set_time(LIQUIDITY_DEADLINE_AT_MS);
    fixture.cancel_unlaunched(KEEPER);

    fixture.migrate();

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::ELiquidityDeadlineNotReached,
    location = blast_presale::blast_presale,
)]
fun a_funded_sale_cannot_be_cancelled_before_the_liquidity_deadline() {
    let mut fixture = start_funded_sale();
    fixture.set_time(LIQUIDITY_DEADLINE_AT_MS - 1);

    fixture.cancel_unlaunched(KEEPER);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EWrongMigrationWitness,
    location = blast_presale::blast_presale,
)]
fun another_migrator_cannot_release_escrow() {
    let mut fixture = start_funded_sale();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());

    fixture.next_tx!(KEEPER, |fixture| {
        let mut sale = fixture.take_presale();
        let (liquidity_tokens, quote) = sale.migrate(
            &package_version,
            &fixture.fee_policy,
            OTHER_MIGRATOR(),
            &fixture.clock,
            fixture.scenario.ctx(),
        );
        liquidity_tokens.destroy_zero();
        quote.destroy_zero();
        fixture.return_presale(sale);
    });

    fixture.end();

    std::unit_test::destroy(package_version);
}

#[test]
#[expected_failure(
    abort_code = presale::EWrongEligibilityPolicy,
    location = blast_presale::blast_presale,
)]
fun the_open_commit_function_rejects_an_allowlist_policy() {
    let alice_leaf = presale::allowlist_leaf_for_testing(0, ALICE, 500);
    let mut fixture = start_sale(presale::allowlisted_eligibility(alice_leaf, 1));

    fixture.commit_open(ALICE, 1);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidAssetPair,
    location = blast_presale::blast_presale,
)]
/// The asset pair is checked before the raise and windows, so their one-unit values never matter.
fun sale_token_and_quote_types_must_differ() {
    let mut terms = valid_sale_terms();
    terms.raise_target = 1;
    terms.duration_ms = 1;
    terms.liquidity_window_ms = 1;
    terms.eligibility = presale::open_eligibility(1, 1, 1);

    create_sale<BLAST_PRESALE_TESTS>(terms);
}

#[test]
#[expected_failure(
    abort_code = presale::EInitialSupplyNotZero,
    location = blast_presale::blast_presale,
)]
fun treasury_cap_must_start_with_zero_supply() {
    let mut ctx = tx_context::dummy();
    let (mut treasury_cap, currency) = new_currency(&mut ctx);
    let existing_supply = treasury_cap.mint(1, &mut ctx);

    create_sale_with_treasury<QUOTE>(treasury_cap, currency, valid_sale_terms(), &mut ctx);

    existing_supply.burn_for_testing();
    destroy(ctx);
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidTokenAllocation,
    location = blast_presale::blast_presale,
)]
fun configured_allocation_bps_cannot_exceed_full_supply() {
    let mut terms = valid_sale_terms();
    terms.token_allocation_bps = 10_000;
    terms.liquidity_token_allocation_bps = 1;

    create_sale<QUOTE>(terms);
}

#[test]
#[expected_failure(
    abort_code = presale::ESaleTokenNotUnregulated,
    location = blast_presale::blast_presale,
)]
fun regulated_sale_currency_without_global_pause_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (treasury_cap, currency) = new_regulated_currency(false, &mut ctx);

    create_sale_with_treasury<QUOTE>(treasury_cap, currency, valid_sale_terms(), &mut ctx);
}

#[test]
#[expected_failure(
    abort_code = presale::ESaleTokenNotUnregulated,
    location = blast_presale::blast_presale,
)]
fun regulated_burnable_sale_currency_with_global_pause_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (treasury_cap, currency) = new_regulated_currency(true, &mut ctx);
    let mut terms = valid_sale_terms();
    terms.burnable = true;

    create_sale_with_treasury<QUOTE>(treasury_cap, currency, terms, &mut ctx);
}

#[test]
#[expected_failure(
    abort_code = presale::ESaleTokenNotUnregulated,
    location = blast_presale::blast_presale,
)]
fun regulated_sale_currency_is_rejected_before_missing_settings() {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::new_for_testing(&mut ctx);
    let (treasury_cap, mut currency) = new_regulated_currency(false, &mut ctx);
    let fee_policy = fee_policy::new_for_testing(&mut ctx);
    let creation_policy = creation_policy::allowing_for_testing<QUOTE, TEST_MIGRATOR>(&mut ctx);
    let initializer = bare_initializer(
        &package_version,
        treasury_cap,
        &creation_policy,
        &fee_policy,
    );

    let (sale, cap) = initializer.finalize(&package_version, &mut currency, &mut ctx);

    destroy(sale);
    destroy(cap);
    destroy(currency);
    destroy(fee_policy);
    destroy(creation_policy);

    std::unit_test::destroy(package_version);
}

#[test]
#[expected_failure(
    abort_code = presale::ESaleTokenNotUnregulated,
    location = blast_presale::blast_presale,
)]
fun legacy_regulated_sale_currency_with_unknown_status_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (treasury_cap, currency) = legacy_regulated_currency(false, &mut ctx);
    // This is the bypass a guard using only !is_regulated() would admit.
    assert!(!currency.is_regulated());

    create_sale_with_treasury<QUOTE>(treasury_cap, currency, valid_sale_terms(), &mut ctx);
}

#[test]
#[expected_failure(
    abort_code = presale::ESaleTokenNotUnregulated,
    location = blast_presale::blast_presale,
)]
fun legacy_regulated_sale_currency_with_migrated_status_is_rejected() {
    let mut ctx = tx_context::dummy();
    let (treasury_cap, currency) = legacy_regulated_currency(true, &mut ctx);
    assert!(currency.is_regulated());

    create_sale_with_treasury<QUOTE>(treasury_cap, currency, valid_sale_terms(), &mut ctx);
}

#[test]
fun unregulated_sale_currency_with_long_metadata_is_accepted() {
    let mut ctx = tx_context::dummy();
    let (treasury_cap, currency) = new_currency_with_symbol(
        vector::tabulate!(130, |_| 65),
        &mut ctx,
    );

    create_sale_with_treasury<QUOTE>(treasury_cap, currency, valid_sale_terms(), &mut ctx);
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidTokenAllocation,
    location = blast_presale::blast_presale,
)]
fun configured_allocation_bps_must_produce_positive_atomic_amounts() {
    let mut terms = valid_sale_terms();
    terms.token_supply = 1;

    create_sale<QUOTE>(terms);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidFeeSplit, location = blast_presale::blast_presale)]
fun fee_recipient_and_holder_shares_must_total_full_bps() {
    create_with_fee_split(fee_recipients(), HOLDER_REWARDS_BPS - 1);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidFeeSplit, location = blast_presale::blast_presale)]
fun fee_recipients_must_be_distinct() {
    create_with_fee_split(
        vector[
            presale::recipient_share(CREATOR, bps::new(CREATOR_FEE_BPS)),
            presale::recipient_share(CREATOR, bps::new(FEE_PARTNER_BPS)),
        ],
        HOLDER_REWARDS_BPS,
    );
}

#[test]
/// With no fee recipients every collected fee funds holder rewards.
fun holders_may_receive_every_fee() {
    create_with_fee_split(vector[], 10_000);
}

#[test]
#[expected_failure(abort_code = bps::EInvalidBps, location = blast_presale::bps)]
/// An out-of-range LP share cannot be constructed, so the BPS sum cannot overflow.
fun an_overflowing_liquidity_share_cannot_be_constructed() {
    let mut terms = valid_sale_terms();
    terms.liquidity_token_allocation_bps = std::u64::max_value!();

    create_sale<QUOTE>(terms);
}

#[test]
#[expected_failure(abort_code = bps::EInvalidBps, location = blast_presale::bps)]
/// An out-of-range holder share cannot be constructed, so the BPS sum cannot overflow.
fun an_overflowing_holder_share_cannot_be_constructed() {
    create_with_fee_split(fee_recipients(), std::u64::max_value!());
}

#[test]
/// Sixteen distinct fee recipients fit one collection's transfer bound.
fun sixteen_fee_recipients_are_accepted() {
    create_with_fee_split(distinct_fee_recipients(16), 10_000 - 16 * 100);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidFeeSplit, location = blast_presale::blast_presale)]
fun a_seventeenth_fee_recipient_is_rejected() {
    create_with_fee_split(distinct_fee_recipients(17), 10_000 - 17 * 100);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidFeeSplit, location = blast_presale::blast_presale)]
fun a_fee_recipient_cannot_be_the_zero_address() {
    create_with_fee_split(
        vector[presale::recipient_share(@0x0, bps::new(CREATOR_FEE_BPS + FEE_PARTNER_BPS))],
        HOLDER_REWARDS_BPS,
    );
}

#[test]
/// Bluefin accepts a Meme symbol at the 32-byte bound.
fun bluefin_accepts_a_thirty_two_byte_meme_symbol() {
    create_bluefin_sale<QUOTE, bluefin::Witness>(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ012345");
}

#[test]
#[expected_failure(abort_code = bluefin::ESymbolTooLong, location = blast_presale::bluefin)]
/// A longer symbol would grow every Bluefin position past Sui's object size limit.
fun bluefin_rejects_a_thirty_three_byte_meme_symbol() {
    create_bluefin_sale<QUOTE, bluefin::Witness>(b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456");
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EQuoteNotAllowed,
    location = blast_presale::creation_policy,
)]
/// A venue cannot create a sale raising a Quote type Blast has not allowed.
fun a_sale_cannot_raise_a_quote_blast_has_not_allowed() {
    create_bluefin_sale<BLAST_PRESALE_TESTS, bluefin::Witness>(b"SALE");
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EMigrationWitnessNotAllowed,
    location = blast_presale::creation_policy,
)]
/// A venue cannot create a sale while Blast has not allowed its migration witness.
fun a_sale_cannot_use_a_migrator_blast_has_not_allowed() {
    create_bluefin_sale<QUOTE, cetus::Witness>(b"SALE");
}

#[test]
/// The seed price must sit at least a factor of two inside both venues' sqrt-price bounds.
fun seed_prices_must_sit_inside_the_venue_bounds() {
    assert!(migration_math::is_seedable(4295048016 * 2));
    assert!(!migration_math::is_seedable(4295048016 * 2 - 1));
    assert!(migration_math::is_seedable(79226673515401279992447579055 / 2));
    assert!(!migration_math::is_seedable(79226673515401279992447579055 / 2 + 1));
    assert!(migration_math::is_seedable(1 << 64));
}

#[test]
#[expected_failure(abort_code = presale::EUnseedablePrice, location = blast_presale::blast_presale)]
/// A raise that dwarfs a one-token LP allocation would seed a price no venue can pool.
fun a_sale_whose_seed_price_no_venue_can_pool_is_rejected() {
    let raise_target = std::u64::max_value!();
    let mut terms = valid_sale_terms();
    terms.token_supply = 10;
    terms.token_allocation_bps = 9_000;
    terms.liquidity_token_allocation_bps = 1_000;
    terms.recipient_allocations = vector[];
    terms.raise_target = raise_target;
    terms.eligibility = presale::open_eligibility(raise_target, 1, raise_target);

    create_sale<QUOTE>(terms);
}

#[test]
fun burnable_supply_is_locked_to_burn_only_at_creation() {
    let mut fixture = start_burnable_sale(single_wallet_eligibility());

    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);

    fixture.destroy_cancelled_cap();
    fixture.end();
}

#[test]
/// Migration pays Blast the shares snapshotted at creation, even after the rates change, at the
/// policy's current destination. Blast's raise share is apportioned with the raise recipients'
/// and the LP keeps the rest; participants' fills and refunds are unchanged.
fun migration_pays_blast_its_snapshotted_shares_at_the_current_destination() {
    let mut fixture = start_with_protocol_fees(
        vector[presale::recipient_share(RAISE_RECIPIENT, bps::new(2_000))],
        presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2),
        PROTOCOL_RAISE_BPS,
        PROTOCOL_TOKEN_BPS,
        FEE_PAYING_RECIPIENT_B_BPS,
    );
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    let (protocol_bps, protocol_quote, protocol_tokens) = only_event<
        PresaleCreated<BLAST_PRESALE_TESTS, QUOTE>,
    >().created_protocol_fields();
    assert_eq!(protocol_bps, vector[PROTOCOL_RAISE_BPS, PROTOCOL_TOKEN_BPS, 0, 0]);
    // 1,000 * [2,000, 333, 7,667] / 10,000 = [200, 33.3, 766.7]: the LP takes the leftover unit.
    assert_eq!(vector[protocol_quote, protocol_tokens], vector[33, PROTOCOL_TOKENS]);

    fixture.commit_open(ALICE, 1_000);
    fixture.commit_open(BOB, 3_000);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);

    fixture
        .fee_policy
        .set_fees(
            &package_version,
            &fee_admin(),
            bps::new(0),
            bps::new(0),
            bps::new(0),
            bps::new(0),
        );
    fixture.fee_policy.set_destination(&package_version, &treasury_admin(), NEW_TREASURY);

    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, 767]);

    let paid = only_event<ProtocolFeesPaid<BLAST_PRESALE_TESTS, QUOTE>>();
    let (presale_id, destination, paid_quote, paid_tokens) = paid.protocol_fees_paid_fields();
    assert_eq!(presale_id, fixture.presale_id);
    assert_eq!(destination, NEW_TREASURY);
    assert_eq!(vector[paid_quote, paid_tokens], vector[33, PROTOCOL_TOKENS]);
    assert_eq!(paid.protocol_fees_paid_partner_quote(), 0);

    let (_, _, lp_quote, liquidity_tokens, recipient_tokens) = only_event<
        PresaleMigrated<BLAST_PRESALE_TESTS, QUOTE>,
    >().migrated_fields();
    assert_eq!(
        vector[lp_quote, liquidity_tokens, recipient_tokens],
        vector[767, LIQUIDITY_TOKENS, RECIPIENT_A_TOKENS + FEE_PAYING_RECIPIENT_B_TOKENS],
    );
    assert_eq!(fixture.unpaid_protocol_quote(), option::none());
    fixture.take_payout(NEW_TREASURY, PROTOCOL_TOKENS, 33);
    fixture.take_quote(RAISE_RECIPIENT, 200);

    assert_eq!(fixture.claim(KEEPER, ALICE), vector[1_000, 2_500, 750, 1]);
    assert_eq!(fixture.claim(KEEPER, BOB), vector[3_000, 7_501, 2_250, 0]);
    assert_eq!(fixture.custody(), vector[4_000, 0, 0, 0, 0, 0, 0]);

    fixture.destroy_migrated_cap();
    fixture.end();

    std::unit_test::destroy(package_version);
}

#[test]
/// A sale shared ahead of its start fixes its windows from that start and opens then.
fun a_scheduled_sale_opens_at_its_start() {
    let mut fixture = schedule_with_protocol_fees(vector[], 0, 0, RECIPIENT_B_BPS);
    fixture.set_time(COMMITMENT_STARTS_AT_MS);

    assert_eq!(
        fixture.commit_open(ALICE, RAISE_TARGET / 2),
        vector[RAISE_TARGET / 2, RAISE_TARGET / 2, 1],
    );

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EPresaleNotStarted,
    location = blast_presale::blast_presale,
)]
fun commitments_before_the_start_are_rejected_before_amount_checks() {
    let mut fixture = schedule_with_protocol_fees(vector[], 0, 0, RECIPIENT_B_BPS);
    fixture.set_time(COMMITMENT_STARTS_AT_MS - 1);

    fixture.commit_open(ALICE, 0);

    fixture.end();
}

#[test]
/// A start that has passed by the time the share executes opens the window at the share.
fun a_start_that_has_passed_opens_the_window_at_the_share() {
    assert_opened_event(share_new_sale(COMMITMENT_STARTS_AT_MS - 1, COMMITMENT_STARTS_AT_MS), COMMITMENT_ENDS_AT_MS, option::none());
}

#[test]
#[expected_failure(abort_code = presale::EInvalidWindow, location = blast_presale::blast_presale)]
fun a_start_whose_windows_end_past_u64_milliseconds_is_rejected() {
    share_new_sale(std::u64::max_value!() - COMMITMENT_DURATION_MS, COMMITMENT_STARTS_AT_MS);
}

#[test]
/// Before the window starts, the AdminCap can replace one sale's rates. Blast's token share moves
/// to or from the buyers' sale allocation and its raise share to or from the LP's Quote, each
/// rounded down; the recipients keep their amounts, and migration and claims use the new terms.
fun the_admin_can_replace_a_sales_rates_before_it_starts() {
    let mut fixture = schedule_with_protocol_fees(
        vector[presale::recipient_share(RAISE_RECIPIENT, bps::new(2_000))],
        PROTOCOL_RAISE_BPS,
        PROTOCOL_TOKEN_BPS,
        FEE_PAYING_RECIPIENT_B_BPS,
    );

    fixture.set_protocol_fees(vector[1_000, 250, 100, 200]);

    let (presale_id, rates, protocol_quote, protocol_tokens, token_allocation) = only_event<
        ProtocolFeesChanged<BLAST_PRESALE_TESTS, QUOTE>,
    >().protocol_fees_changed_fields();
    assert_eq!(presale_id, fixture.presale_id);
    assert_eq!(rates, vector[1_000, 250, 100, 200]);
    // 1,000 * 1,000 / 10,000 = 100 Quote and 20,001 * 250 / 10,000 = 500.025 tokens, rounded
    // down; the 500 tokens Blast gives up join the sale allocation of 10,001.
    assert_eq!(vector[protocol_quote, protocol_tokens, token_allocation], vector[100, 500, 10_501]);
    assert_eq!(fixture.protocol_rates(), vector[1_000, 250, 100, 200]);
    assert_eq!(fixture.vault_partner_id(), option::none());

    fixture.set_time(COMMITMENT_STARTS_AT_MS);
    fixture.commit_open(ALICE, 1_000);
    fixture.commit_open(BOB, 3_000);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);

    // The LP keeps the raise after the recipient's 200 and Blast's 100.
    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, 700]);
    fixture.take_payout(TREASURY, 500, 100);
    fixture.take_quote(RAISE_RECIPIENT, 200);

    // Alice gets 10,501 * 1,000 / 4,000 = 2,625.25, rounded down; Bob's last claim takes the rest.
    assert_eq!(fixture.claim(KEEPER, ALICE), vector[1_000, 2_625, 750, 1]);
    assert_eq!(fixture.claim(KEEPER, BOB), vector[3_000, 7_876, 2_250, 0]);
    assert_eq!(fixture.custody(), vector[4_000, 0, 0, 0, 0, 0, 0]);

    fixture.destroy_migrated_cap();
    fixture.end();
}

#[test]
/// Raising Blast's rates before the start takes its extra tokens from the sale allocation and its
/// extra Quote from the LP.
fun a_rate_increase_before_the_start_takes_from_the_sale_allocation_and_the_lp() {
    let mut fixture = schedule_with_protocol_fees(
        vector[],
        PROTOCOL_RAISE_BPS,
        PROTOCOL_TOKEN_BPS,
        FEE_PAYING_RECIPIENT_B_BPS,
    );

    fixture.set_protocol_fees(vector[1_000, 1_000, 0, 0]);

    // 20,001 * 1,000 / 10,000 = 2,000.1 tokens: Blast's extra 1,000 leave the sale allocation.
    assert_eq!(
        fixture.custody(),
        vector[
            0,
            0,
            0,
            TOKEN_ALLOCATION - 1_000,
            LIQUIDITY_TOKENS,
            RECIPIENT_A_TOKENS + FEE_PAYING_RECIPIENT_B_TOKENS,
            2_000,
        ],
    );

    fixture.set_time(COMMITMENT_STARTS_AT_MS);
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);

    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, 900]);
    fixture.take_payout(TREASURY, 2_000, 100);
    assert_eq!(fixture.claim(KEEPER, ALICE), vector[RAISE_TARGET, TOKEN_ALLOCATION - 1_000, 0, 0]);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EPresaleStarted, location = blast_presale::blast_presale)]
fun a_sales_rates_cannot_change_once_its_window_starts() {
    let mut fixture = schedule_with_protocol_fees(vector[], 0, 0, RECIPIENT_B_BPS);
    fixture.set_time(COMMITMENT_STARTS_AT_MS);

    fixture.set_protocol_fees(vector[1_000, 0, 0, 0]);

    fixture.end();
}

#[test]
/// In a sale's creation transaction, the AdminCap can replace its rates before `share`, which
/// then opens the sale on the new amounts.
fun an_unshared_sales_rates_can_change_before_its_share() {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::new_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let (treasury_cap, mut currency) = new_currency(&mut ctx);
    let fee_policy = fee_policy::new_for_testing(&mut ctx);
    let creation_policy = creation_policy::allowing_for_testing<QUOTE, TEST_MIGRATOR>(&mut ctx);
    let (mut sale, cap) = new_presale<QUOTE>(
        treasury_cap,
        &mut currency,
        valid_sale_terms(),
        &creation_policy,
        &fee_policy,
        &mut ctx,
    );
    let presale_id = object::id(&sale);

    sale.set_protocol_fees(
        &package_version,
        &fee_admin(),
        bps::new(1_000),
        bps::new(500),
        bps::new(100),
        bps::new(200),
        &clock,
    );

    let (changed_presale_id, rates, protocol_quote, protocol_tokens, token_allocation) = only_event<
        ProtocolFeesChanged<BLAST_PRESALE_TESTS, QUOTE>,
    >().protocol_fees_changed_fields();
    assert_eq!(changed_presale_id, presale_id);
    assert_eq!(rates, vector[1_000, 500, 100, 200]);
    // 1,000 * 1,000 / 10,000 = 100 Quote and 20,001 * 500 / 10,000 = 1,000.05 tokens, rounded
    // down; Blast's 1,000 tokens leave the sale allocation of 10,001.
    assert_eq!(
        vector[protocol_quote, protocol_tokens, token_allocation],
        vector[100, 1_000, 9_001],
    );
    let (
        _,
        _,
        _,
        sale_tokens,
        liquidity_tokens,
        recipient_tokens,
        escrowed_protocol_tokens,
    ) = sale.custody_for_testing();
    assert_eq!(
        vector[sale_tokens, liquidity_tokens, recipient_tokens, escrowed_protocol_tokens],
        vector[9_001, LIQUIDITY_TOKENS, RECIPIENT_TOKENS, 1_000],
    );

    sale.share(&package_version, COMMITMENT_STARTS_AT_MS, &clock);
    assert_opened_event(presale_id, COMMITMENT_ENDS_AT_MS, option::none());

    destroy(cap);
    destroy(currency);
    destroy(fee_policy);
    destroy(creation_policy);
    clock.destroy_for_testing();

    std::unit_test::destroy(package_version);
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidLifecycle,
    location = blast_presale::blast_presale,
)]
/// Past `Open`, the lifecycle alone fixes a sale's rates: a funded sale cannot be repriced.
fun a_funded_sales_rates_cannot_change() {
    let mut fixture = start_funded_sale();

    fixture.set_protocol_fees(vector[1_000, 0, 0, 0]);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EProtocolFeesUnchanged,
    location = blast_presale::blast_presale,
)]
fun a_sale_fee_update_must_change_its_rates() {
    let mut fixture = schedule_with_protocol_fees(
        vector[],
        PROTOCOL_RAISE_BPS,
        PROTOCOL_TOKEN_BPS,
        FEE_PAYING_RECIPIENT_B_BPS,
    );

    fixture.set_protocol_fees(vector[PROTOCOL_RAISE_BPS, PROTOCOL_TOKEN_BPS, 0, 0]);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = fee_policy::EInvalidFees, location = blast_presale::fee_policy)]
/// A sale's rates keep the policy's bounds: Blast's raise share stays below 10,000 BPS.
fun a_sale_fee_update_keeps_the_policy_bounds() {
    let mut fixture = schedule_with_protocol_fees(vector[], 0, 0, RECIPIENT_B_BPS);

    fixture.set_protocol_fees(vector[10_000, 0, 0, 0]);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidRaiseAllocation,
    location = blast_presale::blast_presale,
)]
/// Blast's new raise share must still leave the LP Quote after the raise recipients'.
fun a_raise_share_that_leaves_the_lp_nothing_is_rejected() {
    let mut fixture = schedule_with_protocol_fees(
        vector[presale::recipient_share(RAISE_RECIPIENT, bps::new(2_000))],
        0,
        0,
        RECIPIENT_B_BPS,
    );

    fixture.set_protocol_fees(vector[8_000, 0, 0, 0]);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidTokenAllocation,
    location = blast_presale::blast_presale,
)]
/// Blast's new token share must leave buyers a token: 20,001 * 5,501 / 10,000 rounds down to
/// 11,002, more than the 10,001 sale tokens and Blast's 1,000 together.
fun a_token_share_that_leaves_buyers_nothing_is_rejected() {
    let mut fixture = schedule_with_protocol_fees(
        vector[],
        0,
        PROTOCOL_TOKEN_BPS,
        FEE_PAYING_RECIPIENT_B_BPS,
    );

    fixture.set_protocol_fees(vector[0, 5_501, 0, 0]);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EUnseedablePrice, location = blast_presale::blast_presale)]
/// Cutting Blast's raise share hands the LP more Quote, which must still seed a poolable price.
fun a_raise_share_cut_that_seeds_an_unpoolable_price_is_rejected() {
    let raise_target = 1 << 63;
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(SCHEDULED_AT_MS);
    // With one LP token, 40% of 2^63 Quote seeds a poolable price and all of it does not.
    let fee_policy = treasury_fee_policy(6_000, 0, scenario.ctx());
    let creation_policy = creation_policy::allowing_for_testing<
        QUOTE,
        TEST_MIGRATOR,
    >(scenario.ctx());
    let mut terms = valid_sale_terms();
    terms.token_supply = 10;
    terms.token_allocation_bps = 9_000;
    terms.liquidity_token_allocation_bps = 1_000;
    terms.recipient_allocations = vector[];
    terms.raise_target = raise_target;
    terms.eligibility = presale::open_eligibility(raise_target, 1, raise_target);
    let (treasury_cap, mut currency) = new_currency(scenario.ctx());
    let (presale, cap) = new_presale<QUOTE>(
        treasury_cap,
        &mut currency,
        terms,
        &creation_policy,
        &fee_policy,
        scenario.ctx(),
    );
    let presale_id = object::id(&presale);
    presale.share(&package_version, COMMITMENT_STARTS_AT_MS, &clock);
    destroy(cap);
    destroy(currency);
    destroy(creation_policy);
    let mut fixture = Fixture { scenario, clock, fee_policy, presale_id };

    fixture.set_protocol_fees(vector[0, 0, 0, 0]);

    fixture.end();

    std::unit_test::destroy(package_version);
}

#[test]
/// With zero rates, migration pays Blast nothing and the whole raise reaches the LP.
fun a_zero_rate_sale_pays_blast_nothing() {
    let mut fixture = start_funded_sale();

    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, RAISE_TARGET]);

    let (_, destination, paid_quote, paid_tokens) = only_event<
        ProtocolFeesPaid<BLAST_PRESALE_TESTS, QUOTE>,
    >().protocol_fees_paid_fields();
    assert_eq!(destination, TREASURY);
    assert_eq!(vector[paid_quote, paid_tokens], vector[0, 0]);
    fixture.assert_treasury_received_nothing();

    fixture.end();
}

#[test]
/// An unsuccessful sale pays Blast nothing: every commitment is refunded in full and Blast's
/// token share stays locked with the rest of the supply.
fun a_cancelled_sale_pays_blast_nothing() {
    let mut fixture = start_with_protocol_fees(
        vector[],
        presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2),
        PROTOCOL_RAISE_BPS,
        PROTOCOL_TOKEN_BPS,
        FEE_PAYING_RECIPIENT_B_BPS,
    );
    fixture.commit_open(ALICE, 500);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);

    fixture.settle(KEEPER);

    assert_eq!(fixture.claim(KEEPER, ALICE), vector[500, 0, 500, 0]);
    fixture.take_quote(ALICE, 500);
    assert_eq!(
        fixture.custody(),
        vector[
            500,
            0,
            0,
            TOKEN_ALLOCATION,
            LIQUIDITY_TOKENS,
            RECIPIENT_A_TOKENS + FEE_PAYING_RECIPIENT_B_TOKENS,
            PROTOCOL_TOKENS,
        ],
    );
    fixture.assert_treasury_received_nothing();

    fixture.destroy_cancelled_cap();
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidTokenAllocation,
    location = blast_presale::blast_presale,
)]
/// The creator's allocations must total 10,000 BPS together with Blast's token share.
fun allocations_must_leave_room_for_blasts_token_share() {
    start_with_protocol_fees(
        vector[],
        single_wallet_eligibility(),
        0,
        PROTOCOL_TOKEN_BPS,
        RECIPIENT_B_BPS,
    ).end();
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidRaiseAllocation,
    location = blast_presale::blast_presale,
)]
/// Blast's raise share and the raise recipients' together must leave the LP a share.
fun raise_allocations_must_leave_the_lp_a_share_after_blasts() {
    start_with_protocol_fees(
        vector[presale::recipient_share(RAISE_RECIPIENT, bps::new(10_000 - PROTOCOL_RAISE_BPS))],
        single_wallet_eligibility(),
        PROTOCOL_RAISE_BPS,
        0,
        RECIPIENT_B_BPS,
    ).end();
}

#[test]
/// One migration locks each vesting token and raise share in its own shared irrevocable schedule
/// for its recipient from the migration time, and pays every unvested share at once.
fun migration_locks_each_vesting_share_in_its_own_schedule() {
    let mut fixture = start_with_team_vesting(vector[
        presale::vested_recipient_share(RAISE_RECIPIENT, bps::new(2_000), team_vesting_terms()),
        presale::recipient_share(CAROL, bps::new(1_000)),
    ]);
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);

    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, 700]);

    let schedules = event::events_by_type<VestingCreated>();
    assert_eq!(schedules.length(), 2);
    let raise_vesting_id = schedules[0].team_schedule_id<QUOTE>(RAISE_RECIPIENT, 200, COMMITMENT_ENDS_AT_MS);
    let token_vesting_id = schedules[1].team_schedule_id<BLAST_PRESALE_TESTS>(
        RECIPIENT_A,
        RECIPIENT_A_TOKENS,
        COMMITMENT_ENDS_AT_MS,
    );
    assert_eq!(
        event::events_by_type<RaiseAllocated<BLAST_PRESALE_TESTS, QUOTE>>().map_ref!(
            |allocated| allocated.raise_allocated_vesting_id(),
        ),
        vector[option::some(raise_vesting_id), option::none()],
    );
    assert_eq!(
        event::events_by_type<RecipientAllocated<BLAST_PRESALE_TESTS, QUOTE>>().map_ref!(
            |allocated| allocated.recipient_allocated_vesting_id(),
        ),
        vector[option::some(token_vesting_id), option::none()],
    );

    fixture.take_quote(CAROL, 100);
    fixture.next_tx!(
        RECIPIENT_B,
        |fixture| assert_eq!(
            fixture.scenario.take_from_sender<Coin<BLAST_PRESALE_TESTS>>().burn_for_testing(),
            RECIPIENT_B_TOKENS,
        ),
    );
    assert!(!test_scenario::has_most_recent_for_address<Coin<BLAST_PRESALE_TESTS>>(RECIPIENT_A));
    assert!(!test_scenario::has_most_recent_for_address<Coin<QUOTE>>(RAISE_RECIPIENT));

    fixture.destroy_migrated_cap();
    fixture.end();
}

#[test]
/// A vesting token recipient gets an irrevocable schedule that starts at migration, while the
/// other recipient is paid at once.
fun vested_recipient_tokens_lock_in_a_schedule_from_migration() {
    let mut fixture = start_with_team_vesting(vector[]);
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);

    fixture.migrate();

    let allocations = event::events_by_type<RecipientAllocated<BLAST_PRESALE_TESTS, QUOTE>>();
    let (_, vested_recipient, vested_tokens) = allocations[0].recipient_allocated_fields();
    let (_, paid_recipient, paid_tokens) = allocations[1].recipient_allocated_fields();
    assert_eq!(vector[vested_recipient, paid_recipient], vector[RECIPIENT_A, RECIPIENT_B]);
    assert_eq!(vector[vested_tokens, paid_tokens], vector[RECIPIENT_A_TOKENS, RECIPIENT_B_TOKENS]);
    assert!(allocations[1].recipient_allocated_vesting_id().is_none());
    fixture.next_tx!(
        RECIPIENT_B,
        |fixture| assert_eq!(
            fixture.scenario.take_from_sender<Coin<BLAST_PRESALE_TESTS>>().burn_for_testing(),
            RECIPIENT_B_TOKENS,
        ),
    );
    assert!(!test_scenario::has_most_recent_for_address<Coin<BLAST_PRESALE_TESTS>>(RECIPIENT_A));

    let vesting_id = allocations[0].recipient_allocated_vesting_id().destroy_some();
    fixture.claim_vesting<BLAST_PRESALE_TESTS>(vesting_id, COMMITMENT_ENDS_AT_MS + VESTING_CLIFF_DELAY_MS);
    fixture.take_tokens(RECIPIENT_A, RECIPIENT_A_TOKENS / 2);
    fixture.claim_vesting<BLAST_PRESALE_TESTS>(vesting_id, COMMITMENT_ENDS_AT_MS + VESTING_DURATION_MS);
    fixture.take_tokens(RECIPIENT_A, RECIPIENT_A_TOKENS / 2);

    fixture.destroy_migrated_cap();
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::ENothingClaimable,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
/// Nothing vests before the cliff, counted from migration rather than from creation.
fun vested_recipient_tokens_wait_for_the_cliff_after_migration() {
    let mut fixture = start_with_team_vesting(vector[]);
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);
    fixture.migrate();

    fixture.claim_vesting<BLAST_PRESALE_TESTS>(
        event::events_by_type<RecipientAllocated<BLAST_PRESALE_TESTS, QUOTE>>()[0]
            .recipient_allocated_vesting_id()
            .destroy_some(),
        COMMITMENT_ENDS_AT_MS + VESTING_CLIFF_DELAY_MS - 1,
    );

    fixture.end();
}

#[test]
/// A vesting raise recipient's Quote is locked in a schedule from migration; the LP still takes
/// the rest of the raise.
fun vested_raise_allocations_lock_quote_in_a_schedule_from_migration() {
    let mut fixture = start_with_raise_allocations(vector[
        presale::vested_recipient_share(RAISE_RECIPIENT, bps::new(2_000), team_vesting_terms()),
    ]);
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);

    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, 800]);

    let allocated = only_event<RaiseAllocated<BLAST_PRESALE_TESTS, QUOTE>>();
    let (_, recipient, quote) = allocated.raise_allocated_fields();
    assert_eq!(recipient, RAISE_RECIPIENT);
    assert_eq!(quote, 200);
    fixture.take_recipient_allocations();
    assert!(!test_scenario::has_most_recent_for_address<Coin<QUOTE>>(RAISE_RECIPIENT));

    fixture.claim_vesting<QUOTE>(
        allocated.raise_allocated_vesting_id().destroy_some(),
        COMMITMENT_ENDS_AT_MS + VESTING_DURATION_MS,
    );
    fixture.take_quote(RAISE_RECIPIENT, 200);

    fixture.destroy_migrated_cap();
    fixture.end();
}

#[test]
/// Under participant vesting each claim locks the wallet's tokens in its own irrevocable schedule
/// starting at that claim and pays its Quote refund at once; the last claim still takes the
/// token remainder.
fun claims_lock_participant_tokens_in_a_schedule_from_each_claim() {
    let mut fixture = start_with_participant_vesting(
        presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2),
    );
    fixture.commit_open(ALICE, 1_000);
    fixture.commit_open(BOB, 3_000);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);
    fixture.migrate();
    fixture.take_recipient_allocations();

    let alice_claimed_at_ms = COMMITMENT_ENDS_AT_MS + 10;
    fixture.set_time(alice_claimed_at_ms);
    let (claimed, alice_vesting_id) = fixture.claim_with_vesting(KEEPER, ALICE);
    assert_eq!(claimed, vector[1_000, 2_500, 750, 1]);
    let alice_vesting_id = alice_vesting_id.destroy_some();
    assert_eq!(
        only_event<VestingCreated>().team_schedule_id<BLAST_PRESALE_TESTS>(
            ALICE,
            2_500,
            alice_claimed_at_ms,
        ),
        alice_vesting_id,
    );
    fixture.take_quote(ALICE, 750);
    assert!(!test_scenario::has_most_recent_for_address<Coin<BLAST_PRESALE_TESTS>>(ALICE));

    let bob_claimed_at_ms = COMMITMENT_ENDS_AT_MS + 30;
    fixture.set_time(bob_claimed_at_ms);
    let (claimed, bob_vesting_id) = fixture.claim_with_vesting(KEEPER, BOB);
    assert_eq!(claimed, vector[3_000, 7_501, 2_250, 0]);
    let bob_vesting_id = bob_vesting_id.destroy_some();
    assert_eq!(
        only_event<VestingCreated>().team_schedule_id<BLAST_PRESALE_TESTS>(
            BOB,
            7_501,
            bob_claimed_at_ms,
        ),
        bob_vesting_id,
    );
    fixture.take_quote(BOB, 2_250);
    assert_eq!(fixture.custody(), vector[4_000, 0, 0, 0, 0, 0, 0]);

    fixture.claim_vesting<BLAST_PRESALE_TESTS>(
        alice_vesting_id,
        alice_claimed_at_ms + VESTING_CLIFF_DELAY_MS,
    );
    fixture.take_tokens(ALICE, 1_250);
    fixture.claim_vesting<BLAST_PRESALE_TESTS>(
        alice_vesting_id,
        alice_claimed_at_ms + VESTING_DURATION_MS,
    );
    fixture.take_tokens(ALICE, 1_250);
    fixture.claim_vesting<BLAST_PRESALE_TESTS>(
        bob_vesting_id,
        bob_claimed_at_ms + VESTING_DURATION_MS,
    );
    fixture.take_tokens(BOB, 7_501);

    fixture.destroy_migrated_cap();
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun_vesting::blast_fun_linear_vesting::ENothingClaimable,
    location = blast_fun_vesting::blast_fun_linear_vesting,
)]
/// A participant's cliff counts from its claim, not from migration.
fun participant_tokens_wait_for_the_cliff_after_the_claim() {
    let mut fixture = start_with_participant_vesting(single_wallet_eligibility());
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);
    fixture.migrate();
    let claimed_at_ms = COMMITMENT_ENDS_AT_MS + VESTING_CLIFF_DELAY_MS;
    fixture.set_time(claimed_at_ms);
    let (_, vesting_id) = fixture.claim_with_vesting(KEEPER, ALICE);

    fixture.claim_vesting<BLAST_PRESALE_TESTS>(
        vesting_id.destroy_some(),
        claimed_at_ms + VESTING_CLIFF_DELAY_MS - 1,
    );

    fixture.end();
}

#[test]
/// A schedule cannot hold nothing, so a claim whose pro-rata tokens round to zero creates none,
/// while the last claim still locks the remainder.
fun a_participant_claim_without_tokens_creates_no_schedule() {
    let mut fixture = start_with_participant_vesting(
        presale::open_eligibility(20_000, 1_000, 1),
    );
    fixture.commit_open(ALICE, 1);
    fixture.commit_open(BOB, 20_000);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);
    fixture.migrate();

    assert_eq!(fixture.claim(KEEPER, ALICE), vector[1, 0, 0, 1]);
    assert!(event::events_by_type<VestingCreated>().is_empty());

    let (claimed, vesting_id) = fixture.claim_with_vesting(KEEPER, BOB);
    assert_eq!(claimed, vector[20_000, TOKEN_ALLOCATION, 19_001, 0]);
    assert!(vesting_id.is_some());

    fixture.end();
}

#[test]
/// Cancellation pays no tokens, so participant vesting refunds every commitment without a
/// schedule.
fun a_cancelled_vesting_sale_refunds_without_a_schedule() {
    let mut fixture = start_with_participant_vesting(
        presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2),
    );
    fixture.commit_open(ALICE, 500);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);

    assert_eq!(fixture.claim(KEEPER, ALICE), vector[500, 0, 500, 0]);
    assert!(event::events_by_type<VestingCreated>().is_empty());
    fixture.take_quote(ALICE, 500);

    fixture.destroy_cancelled_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidFeeSplit, location = blast_presale::blast_presale)]
/// LP fees are paid as they are collected, so a fee share cannot vest.
fun fee_recipients_cannot_vest() {
    create_with_fee_split(
        vector[
            presale::vested_recipient_share(
                CREATOR,
                bps::new(CREATOR_FEE_BPS),
                team_vesting_terms(),
            ),
            presale::recipient_share(FEE_PARTNER, bps::new(FEE_PARTNER_BPS)),
        ],
        HOLDER_REWARDS_BPS,
    );
}

#[test]
/// The longest schedule is the technical bound, with the cliff at most its whole duration.
fun vesting_terms_accept_the_technical_bound_with_a_full_cliff() {
    presale::vesting_terms(MAX_VESTING_DURATION_MS, MAX_VESTING_DURATION_MS, 1);
    presale::vesting_terms(0, 1, MAX_VESTING_DURATION_MS);
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidVestingTerms,
    location = blast_presale::blast_presale,
)]
fun vesting_terms_need_a_positive_period() {
    presale::vesting_terms(0, 0, 1);
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidVestingTerms,
    location = blast_presale::blast_presale,
)]
fun vesting_terms_need_a_positive_period_count() {
    presale::vesting_terms(0, 1, 0);
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidVestingTerms,
    location = blast_presale::blast_presale,
)]
fun vesting_terms_keep_the_cliff_within_the_duration() {
    presale::vesting_terms(VESTING_DURATION_MS + 1, VESTING_PERIOD_DURATION_MS, VESTING_PERIODS);
}

#[test]
#[expected_failure(
    abort_code = presale::EInvalidVestingTerms,
    location = blast_presale::blast_presale,
)]
fun vesting_terms_stay_within_the_technical_bound() {
    presale::vesting_terms(0, MAX_VESTING_DURATION_MS / 2 + 1, 2);
}

#[test]
/// A sale naming a Blast partner releases the same raise and LP as any sale, but its migration
/// holds Blast's fees. `pay_protocol_fees_with_partner` then pays the partner its cut of Blast's
/// raise fee only, and Blast the rest of it and its whole token fee; claims are unchanged.
fun a_partnered_sale_pays_its_partner_a_cut_of_blasts_raise_fee_only() {
    let mut ctx = tx_context::dummy();
    let partner = new_partner(PARTNER_CUT_BPS, &mut ctx);
    let mut fixture = partner.start_partnered_sale();

    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, 767]);
    assert!(event::events_by_type<ProtocolFeesPaid<BLAST_PRESALE_TESTS, QUOTE>>().is_empty());
    assert_eq!(fixture.vault_partner_id(), option::some(object::id(&partner)));
    assert_eq!(fixture.unpaid_protocol_quote(), option::some(33));
    fixture.take_quote(RAISE_RECIPIENT, 200);
    fixture.assert_treasury_received_nothing();

    fixture.pay_protocol_fees_with_partner(KEEPER, &partner);

    // 40% of Blast's 33 Quote is 13.2: the partner takes 13 and Blast keeps 20 and every token.
    let paid = only_event<ProtocolFeesPaid<BLAST_PRESALE_TESTS, QUOTE>>();
    let (presale_id, destination, paid_quote, paid_tokens) = paid.protocol_fees_paid_fields();
    assert_eq!(presale_id, fixture.presale_id);
    assert_eq!(destination, TREASURY);
    assert_eq!(vector[paid_quote, paid_tokens], vector[20, PROTOCOL_TOKENS]);
    assert_eq!(paid.protocol_fees_paid_partner_quote(), 13);
    let (partner_id, partner_quote) = only_event<PartnerPaid<QUOTE>>().partner_paid_fields();
    assert_eq!(partner_id, object::id(&partner));
    assert_eq!(partner_quote, 13);
    assert!(event::events_by_type<PartnerPaid<BLAST_PRESALE_TESTS>>().is_empty());
    fixture.take_payout(TREASURY, PROTOCOL_TOKENS, 20);
    assert_eq!(fixture.unpaid_protocol_quote(), option::none());

    assert_eq!(fixture.claim(KEEPER, ALICE), vector[1_000, 2_500, 750, 1]);
    assert_eq!(fixture.claim(KEEPER, BOB), vector[3_000, 7_501, 2_250, 0]);
    assert_eq!(fixture.custody(), vector[4_000, 0, 0, 0, 0, 0, 0]);

    destroy(partner);
    fixture.destroy_migrated_cap();
    fixture.end();
}

#[test]
/// The partner is paid the cut in force when `pay_protocol_fees_with_partner` runs, not the one at
/// creation.
fun the_partner_is_paid_its_cut_in_force_at_payment() {
    let mut ctx = tx_context::dummy();
    let partner = partners::new_scheduled_for_testing(
        PARTNER_RECIPIENT,
        PARTNER_CUT_BPS,
        8_000,
        LIQUIDITY_DEADLINE_AT_MS,
        &mut ctx,
    );
    let mut fixture = partner.start_partnered_sale();
    fixture.migrate();
    fixture.set_time(LIQUIDITY_DEADLINE_AT_MS);

    fixture.pay_protocol_fees_with_partner(KEEPER, &partner);

    // 80% of 33 is 26.4: the partner takes 26 and Blast keeps 7.
    let paid = only_event<ProtocolFeesPaid<BLAST_PRESALE_TESTS, QUOTE>>();
    let (_, _, paid_quote, _) = paid.protocol_fees_paid_fields();
    assert_eq!(vector[paid_quote, paid.protocol_fees_paid_partner_quote()], vector[7, 26]);

    destroy(partner);
    fixture.end();
}

#[test]
/// A partner whose cut is zero is paid nothing and emits no `PartnerPaid`; Blast keeps its whole
/// raise fee.
fun a_zero_cut_partner_is_paid_nothing() {
    let mut ctx = tx_context::dummy();
    let partner = new_partner(0, &mut ctx);
    let mut fixture = partner.start_partnered_sale();
    fixture.migrate();

    fixture.pay_protocol_fees_with_partner(KEEPER, &partner);

    let paid = only_event<ProtocolFeesPaid<BLAST_PRESALE_TESTS, QUOTE>>();
    let (_, _, paid_quote, paid_tokens) = paid.protocol_fees_paid_fields();
    assert_eq!(vector[paid_quote, paid_tokens], vector[33, PROTOCOL_TOKENS]);
    assert_eq!(paid.protocol_fees_paid_partner_quote(), 0);
    assert!(event::events_by_type<PartnerPaid<QUOTE>>().is_empty());

    destroy(partner);
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EPartnerNotAccepted,
    location = blast_presale::creation_policy,
)]
/// A sale may name only a partner Blast accepts for new presales.
fun a_sale_cannot_name_a_partner_blast_has_not_accepted() {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::new_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let partner = new_partner(PARTNER_CUT_BPS, &mut ctx);
    let fee_policy = fee_policy::new_for_testing(&mut ctx);
    let creation_policy = creation_policy::allowing_for_testing<QUOTE, TEST_MIGRATOR>(&mut ctx);
    let (treasury_cap, _currency) = new_currency(&mut ctx);
    let mut initializer = new_initializer<QUOTE>(
        &package_version,
        treasury_cap,
        valid_sale_terms(),
        &creation_policy,
        &fee_policy,
    );

    initializer.set_partner(&package_version, &creation_policy, &partner, &clock);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(abort_code = presale::ENoPartnerPayout, location = blast_presale::blast_presale)]
/// A funded sale that has not migrated owes its partner nothing: it may still be refunded.
fun a_partner_cannot_be_paid_before_migration() {
    let mut ctx = tx_context::dummy();
    let partner = new_partner(PARTNER_CUT_BPS, &mut ctx);
    let mut fixture = partner.start_partnered_sale();

    fixture.pay_protocol_fees_with_partner(KEEPER, &partner);
    abort
}

#[test]
#[expected_failure(abort_code = presale::ENoPartnerPayout, location = blast_presale::blast_presale)]
/// A partnered sale pays Blast and its partner once.
fun a_partner_is_paid_once() {
    let mut ctx = tx_context::dummy();
    let partner = new_partner(PARTNER_CUT_BPS, &mut ctx);
    let mut fixture = partner.start_partnered_sale();
    fixture.migrate();
    fixture.pay_protocol_fees_with_partner(KEEPER, &partner);

    fixture.pay_protocol_fees_with_partner(KEEPER, &partner);
    abort
}

#[test]
#[expected_failure(abort_code = presale::EWrongPartner, location = blast_presale::blast_presale)]
/// Only the partner the sale named is paid, checked before anything is owed.
fun another_partner_cannot_be_paid() {
    let mut ctx = tx_context::dummy();
    let partner = new_partner(PARTNER_CUT_BPS, &mut ctx);
    let other_partner = new_partner(PARTNER_CUT_BPS, &mut ctx);
    let mut fixture = partner.start_partnered_sale();

    fixture.pay_protocol_fees_with_partner(KEEPER, &other_partner);
    abort
}

#[test]
#[expected_failure(abort_code = presale::EWrongPartner, location = blast_presale::blast_presale)]
/// A sale without a partner pays Blast at migration and never pays a partner.
fun an_unpartnered_sale_pays_no_partner() {
    let mut ctx = tx_context::dummy();
    let partner = new_partner(PARTNER_CUT_BPS, &mut ctx);
    let mut fixture = start_funded_sale();
    fixture.migrate();

    fixture.pay_protocol_fees_with_partner(KEEPER, &partner);
    abort
}

#[test]
#[expected_failure(abort_code = presale::ENoPartnerPayout, location = blast_presale::blast_presale)]
/// A partnered sale cancelled at its LP deadline holds nothing for its partner: the raise is
/// refundable and Blast's tokens stay locked with the rest of the supply.
fun a_cancelled_partnered_sale_pays_no_partner() {
    let mut ctx = tx_context::dummy();
    let partner = new_partner(PARTNER_CUT_BPS, &mut ctx);
    let mut fixture = partner.start_partnered_sale();
    fixture.set_time(LIQUIDITY_DEADLINE_AT_MS);
    fixture.cancel_unlaunched(KEEPER);
    assert_eq!(fixture.unpaid_protocol_quote(), option::none());
    assert_eq!(fixture.custody()[6], PROTOCOL_TOKENS);

    fixture.pay_protocol_fees_with_partner(KEEPER, &partner);
    abort
}

#[test]
/// Under a zero raise rate the partner has nothing to take, but the payout still releases Blast's
/// tokens, which the partnered migration held.
fun a_zero_raise_rate_partnered_sale_pays_blast_its_tokens() {
    let mut ctx = tx_context::dummy();
    let partner = new_partner(PARTNER_CUT_BPS, &mut ctx);
    let mut fixture = partner.share_partnered_sale(COMMITMENT_STARTS_AT_MS, 0);
    fixture.fund_partnered_sale();

    // The LP takes the raise after the recipient's 200.
    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, 800]);
    assert_eq!(fixture.unpaid_protocol_quote(), option::some(0));

    fixture.pay_protocol_fees_with_partner(KEEPER, &partner);

    let paid = only_event<ProtocolFeesPaid<BLAST_PRESALE_TESTS, QUOTE>>();
    let (_, _, paid_quote, paid_tokens) = paid.protocol_fees_paid_fields();
    assert_eq!(vector[paid_quote, paid_tokens], vector[0, PROTOCOL_TOKENS]);
    assert_eq!(paid.protocol_fees_paid_partner_quote(), 0);
    assert!(event::events_by_type<PartnerPaid<QUOTE>>().is_empty());
    fixture.take_tokens(TREASURY, PROTOCOL_TOKENS);

    destroy(partner);
    fixture.end();
}

#[test]
/// A rate the AdminCap sets before the start is the one a partnered migration holds: the partner
/// is paid its cut of Blast's new raise fee.
fun a_partnered_sale_holds_the_rates_set_before_its_start() {
    let mut ctx = tx_context::dummy();
    let partner = new_partner(PARTNER_CUT_BPS, &mut ctx);
    let mut fixture = partner.share_partnered_sale(SCHEDULED_AT_MS, PROTOCOL_RAISE_BPS);
    fixture.set_protocol_fees(vector[1_000, 250, 0, 0]);
    fixture.fund_partnered_sale();

    // 1,000 * 1,000 / 10,000 = 100 Quote for Blast: the LP keeps 1,000 - 200 - 100.
    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, 700]);
    assert_eq!(fixture.unpaid_protocol_quote(), option::some(100));

    fixture.pay_protocol_fees_with_partner(KEEPER, &partner);

    // 40% of 100 is 40; Blast keeps 60 and its 500 tokens.
    let paid = only_event<ProtocolFeesPaid<BLAST_PRESALE_TESTS, QUOTE>>();
    let (_, _, paid_quote, paid_tokens) = paid.protocol_fees_paid_fields();
    assert_eq!(vector[paid_quote, paid_tokens], vector[60, 500]);
    assert_eq!(paid.protocol_fees_paid_partner_quote(), 40);
    fixture.take_payout(TREASURY, 500, 60);

    destroy(partner);
    fixture.end();
}

#[test]
/// A rate update that leaves Blast's raise and token rates as they are keeps the amounts creation
/// apportioned for them, even where creation's largest remainder gave Blast the extra unit.
fun an_lp_rate_change_keeps_blasts_raise_and_token_amounts() {
    let mut fixture = schedule_with_protocol_fees(
        vector[],
        335,
        PROTOCOL_TOKEN_BPS,
        FEE_PAYING_RECIPIENT_B_BPS,
    );
    // 1,000 * [335, 9,665] / 10,000 = [33.5, 966.5]: the tie gives Blast, the earlier rate, 34.
    let (_, created_quote, created_tokens) = only_event<
        PresaleCreated<BLAST_PRESALE_TESTS, QUOTE>,
    >().created_protocol_fields();
    assert_eq!(vector[created_quote, created_tokens], vector[34, PROTOCOL_TOKENS]);

    fixture.set_protocol_fees(vector[335, PROTOCOL_TOKEN_BPS, 100, 0]);

    let (_, rates, protocol_quote, protocol_tokens, token_allocation) = only_event<
        ProtocolFeesChanged<BLAST_PRESALE_TESTS, QUOTE>,
    >().protocol_fees_changed_fields();
    assert_eq!(rates, vector[335, PROTOCOL_TOKEN_BPS, 100, 0]);
    assert_eq!(
        vector[protocol_quote, protocol_tokens, token_allocation],
        vector[34, PROTOCOL_TOKENS, TOKEN_ALLOCATION],
    );

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_precedes_partner_admission() {
    let mut ctx = tx_context::dummy();
    let mut package_version = blast_presale::blast_presale_package::new_for_testing(&mut ctx);
    let clock = clock::create_for_testing(&mut ctx);
    let partner = new_partner(PARTNER_CUT_BPS, &mut ctx);
    let fee_policy = fee_policy::new_for_testing(&mut ctx);
    let creation_policy = creation_policy::allowing_for_testing<QUOTE, TEST_MIGRATOR>(&mut ctx);
    let (treasury_cap, _currency) = new_currency(&mut ctx);
    let mut initializer = new_initializer<QUOTE>(
        &package_version,
        treasury_cap,
        valid_sale_terms(),
        &creation_policy,
        &fee_policy,
    );

    package_version.set_for_testing(2);
    initializer.set_partner(&package_version, &creation_policy, &partner, &clock);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun future_version_cannot_finalize() {
    let mut ctx = tx_context::dummy();
    let mut package_version = blast_presale::blast_presale_package::new_for_testing(&mut ctx);
    let (treasury_cap, mut currency) = new_currency(&mut ctx);
    let fee_policy = fee_policy::new_for_testing(&mut ctx);
    let creation_policy = creation_policy::allowing_for_testing<QUOTE, TEST_MIGRATOR>(&mut ctx);
    let mut initializer = bare_initializer(
        &package_version,
        treasury_cap,
        &creation_policy,
        &fee_policy,
    );
    initializer.set_fee_split(
        &package_version,
        presale::fee_split(fee_recipients(), bps::new(HOLDER_REWARDS_BPS)),
    );

    package_version.set_for_testing(3);
    let (_sale, _cap) = initializer.finalize(&package_version, &mut currency, &mut ctx);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_rejects_commit_before_lifecycle_or_amount_checks() {
    let mut fixture = start_sale(single_wallet_eligibility());
    fixture.next_tx!(ALICE, |fixture| {
        let mut package_version = blast_presale::blast_presale_package::new_for_testing(fixture
            .scenario
            .ctx());
        package_version.set_for_testing(2);
        let mut sale = fixture.take_presale();
        let coin = coin::zero<QUOTE>(fixture.scenario.ctx());
        let change = sale.commit_open(
            &package_version,
            coin,
            &fixture.clock,
            fixture.scenario.ctx(),
        );
        destroy(change);
        destroy(sale);
        destroy(package_version);
    });
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_rejects_settle_before_lifecycle_or_amount_checks() {
    let mut fixture = start_sale(single_wallet_eligibility());
    fixture.next_tx!(ALICE, |fixture| {
        let mut package_version = blast_presale::blast_presale_package::new_for_testing(fixture
            .scenario
            .ctx());
        package_version.set_for_testing(2);
        let mut sale = fixture.take_presale();
        sale.settle(&package_version, &fixture.clock);
        destroy(sale);
        destroy(package_version);
    });
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_rejects_cancel_before_lifecycle_or_amount_checks() {
    let mut fixture = start_sale(single_wallet_eligibility());
    fixture.next_tx!(ALICE, |fixture| {
        let mut package_version = blast_presale::blast_presale_package::new_for_testing(fixture
            .scenario
            .ctx());
        package_version.set_for_testing(2);
        let mut sale = fixture.take_presale();
        sale.cancel_unlaunched(&package_version, &fixture.clock);
        destroy(sale);
        destroy(package_version);
    });
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_rejects_claim_before_lifecycle_or_amount_checks() {
    let mut fixture = start_sale(single_wallet_eligibility());
    fixture.next_tx!(ALICE, |fixture| {
        let mut package_version = blast_presale::blast_presale_package::new_for_testing(fixture
            .scenario
            .ctx());
        package_version.set_for_testing(2);
        let mut sale = fixture.take_presale();
        sale.claim(&package_version, ALICE, &fixture.clock, fixture.scenario.ctx());
        destroy(sale);
        destroy(package_version);
    });
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_rejects_migrate_before_lifecycle_or_amount_checks() {
    let mut fixture = start_sale(single_wallet_eligibility());
    fixture.next_tx!(ALICE, |fixture| {
        let mut package_version = blast_presale::blast_presale_package::new_for_testing(fixture
            .scenario
            .ctx());
        package_version.set_for_testing(2);
        let mut sale = fixture.take_presale();
        let (meme, quote) = sale.migrate(
            &package_version,
            &fixture.fee_policy,
            TEST_MIGRATOR(),
            &fixture.clock,
            fixture.scenario.ctx(),
        );
        destroy(meme);
        destroy(quote);
        destroy(sale);
        destroy(package_version);
    });
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_prevents_initializer_creation() {
    let mut ctx = tx_context::dummy();
    let mut package_version = blast_presale::blast_presale_package::new_for_testing(&mut ctx);
    let (treasury_cap, mut currency) = new_currency(&mut ctx);
    let fee_policy = fee_policy::new_for_testing(&mut ctx);
    let creation_policy = creation_policy::allowing_for_testing<QUOTE, TEST_MIGRATOR>(&mut ctx);
    package_version.set_for_testing(2);
    let mut initializer = bare_initializer(
        &package_version,
        treasury_cap,
        &creation_policy,
        &fee_policy,
    );
    initializer.set_fee_split(
        &package_version,
        presale::fee_split(fee_recipients(), bps::new(HOLDER_REWARDS_BPS)),
    );

    let (_sale, _cap) = initializer.finalize(&package_version, &mut currency, &mut ctx);
    std::unit_test::destroy(package_version);
    abort
}

// === Test Helpers ===

/// Starts a fee-free sale under `eligibility` with no raise allocations or uncapped phase.
fun start_sale(eligibility: EligibilityPolicy): Fixture {
    start_configured(
        COMMITMENT_STARTS_AT_MS,
        vector[],
        eligibility,
        option::none(),
        option::none(),
        false,
        0,
        0,
        RECIPIENT_B_BPS,
        option::none(),
        option::none(),
    )
}

/// Starts the same sale as `start_sale`, but with its supply locked to burn-only.
fun start_burnable_sale(eligibility: EligibilityPolicy): Fixture {
    start_configured(
        COMMITMENT_STARTS_AT_MS,
        vector[],
        eligibility,
        option::none(),
        option::none(),
        true,
        0,
        0,
        RECIPIENT_B_BPS,
        option::none(),
        option::none(),
    )
}

/// Starts a fee-free sale under `eligibility` whose window ends in `phase`.
fun start_with_uncapped_phase(eligibility: EligibilityPolicy, phase: UncappedPhase): Fixture {
    start_configured(
        COMMITMENT_STARTS_AT_MS,
        vector[],
        eligibility,
        option::some(phase),
        option::none(),
        false,
        0,
        0,
        RECIPIENT_B_BPS,
        option::none(),
        option::none(),
    )
}

/// Starts a fee-free sale under `eligibility`, with `uncapped` if any, held to its raise by
/// `hard_cap`.
fun start_with_hard_cap(
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    hard_cap: HardCapTerms,
): Fixture {
    start_configured(
        COMMITMENT_STARTS_AT_MS,
        vector[],
        eligibility,
        uncapped,
        option::some(hard_cap),
        false,
        0,
        0,
        RECIPIENT_B_BPS,
        option::none(),
        option::none(),
    )
}

/// Starts a fee-free single-wallet sale that pays `raise_allocations` out of the raise.
fun start_with_raise_allocations(raise_allocations: vector<RecipientShare>): Fixture {
    start_configured(
        COMMITMENT_STARTS_AT_MS,
        raise_allocations,
        single_wallet_eligibility(),
        option::none(),
        option::none(),
        false,
        0,
        0,
        RECIPIENT_B_BPS,
        option::none(),
        option::none(),
    )
}

/// Starts the same sale as `start_with_raise_allocations`, but with recipient A's tokens vesting
/// under `team_vesting_terms`.
fun start_with_team_vesting(raise_allocations: vector<RecipientShare>): Fixture {
    start_configured(
        COMMITMENT_STARTS_AT_MS,
        raise_allocations,
        single_wallet_eligibility(),
        option::none(),
        option::none(),
        false,
        0,
        0,
        RECIPIENT_B_BPS,
        option::some(team_vesting_terms()),
        option::none(),
    )
}

/// Starts a fee-free sale under `eligibility` whose participants' tokens vest under
/// `team_vesting_terms`.
fun start_with_participant_vesting(eligibility: EligibilityPolicy): Fixture {
    start_configured(
        COMMITMENT_STARTS_AT_MS,
        vector[],
        eligibility,
        option::none(),
        option::none(),
        false,
        0,
        0,
        RECIPIENT_B_BPS,
        option::none(),
        option::some(team_vesting_terms()),
    )
}

/// Starts a sale created under Blast's raise and token rates, paying `TREASURY`, with recipient
/// B's share sized to leave room for Blast's.
fun start_with_protocol_fees(
    raise_allocations: vector<RecipientShare>,
    eligibility: EligibilityPolicy,
    protocol_raise_bps: u64,
    protocol_token_bps: u64,
    recipient_b_bps: u64,
): Fixture {
    start_configured(
        COMMITMENT_STARTS_AT_MS,
        raise_allocations,
        eligibility,
        option::none(),
        option::none(),
        false,
        protocol_raise_bps,
        protocol_token_bps,
        recipient_b_bps,
        option::none(),
        option::none(),
    )
}

/// Creates the same sale as `start_with_protocol_fees`, open to two wallets, at `SCHEDULED_AT_MS`
/// and shares it to open at `COMMITMENT_STARTS_AT_MS`, leaving the clock before the start.
fun schedule_with_protocol_fees(
    raise_allocations: vector<RecipientShare>,
    protocol_raise_bps: u64,
    protocol_token_bps: u64,
    recipient_b_bps: u64,
): Fixture {
    start_configured(
        SCHEDULED_AT_MS,
        raise_allocations,
        presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2),
        option::none(),
        option::none(),
        false,
        protocol_raise_bps,
        protocol_token_bps,
        recipient_b_bps,
        option::none(),
        option::none(),
    )
}

/// Creates a fee-free sale at `now_at_ms`, shares it to start at `commitment_starts_at_ms`, and returns its ID.
fun share_new_sale(commitment_starts_at_ms: u64, now_at_ms: u64): ID {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::new_for_testing(&mut ctx);
    let result = {
        let mut clock = clock::create_for_testing(&mut ctx);
        clock.set_for_testing(now_at_ms);
        let (treasury_cap, mut currency) = new_currency(&mut ctx);
        let fee_policy = fee_policy::new_for_testing(&mut ctx);
        let creation_policy = creation_policy::allowing_for_testing<QUOTE, TEST_MIGRATOR>(&mut ctx);
        let (sale, cap) = new_presale<QUOTE>(
            treasury_cap,
            &mut currency,
            valid_sale_terms(),
            &creation_policy,
            &fee_policy,
            &mut ctx,
        );
        let presale_id = object::id(&sale);

        sale.share(&package_version, commitment_starts_at_ms, &clock);

        destroy(cap);
        destroy(currency);
        destroy(fee_policy);
        destroy(creation_policy);
        clock.destroy_for_testing();
        destroy(ctx);
        presale_id
    };
    std::unit_test::destroy(package_version);
    result
}

/// Starts a single-wallet sale that Alice fills exactly and a keeper settles as funded at the
/// end of the window.
fun start_funded_sale(): Fixture {
    let mut fixture = start_sale(single_wallet_eligibility());
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(COMMITMENT_ENDS_AT_MS);
    fixture.settle(KEEPER);

    fixture
}

/// Creates a `RAISE_TARGET` sale at `created_at_ms` and shares it to open at `COMMITMENT_STARTS_AT_MS`, asserting
/// its creation and opening events, and hands the creator its cap. Recipient A's tokens vest
/// under `recipient_a_vesting` and every participant's under `participant_vesting`.
fun start_configured(
    created_at_ms: u64,
    raise_allocations: vector<RecipientShare>,
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    hard_cap: Option<HardCapTerms>,
    burnable: bool,
    protocol_raise_bps: u64,
    protocol_token_bps: u64,
    recipient_b_bps: u64,
    recipient_a_vesting: Option<VestingTerms>,
    participant_vesting: Option<VestingTerms>,
): Fixture {
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let result = {
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(created_at_ms);
        let fee_policy = treasury_fee_policy(
            protocol_raise_bps,
            protocol_token_bps,
            scenario.ctx(),
        );
        let creation_policy = creation_policy::allowing_for_testing<
            QUOTE,
            TEST_MIGRATOR,
        >(scenario.ctx());

        let raise_vesting = raise_allocations.map_ref!(|share| share.vesting_terms_for_testing());

        let mut terms = valid_sale_terms();
        terms.recipient_allocations = vector[
            recipient_a_share(recipient_a_vesting),
            presale::recipient_share(RECIPIENT_B, bps::new(recipient_b_bps)),
        ];
        terms.burnable = burnable;
        terms.raise_allocations = raise_allocations;
        terms.eligibility = eligibility;
        terms.uncapped = uncapped;
        terms.hard_cap = hard_cap;
        terms.participant_vesting = participant_vesting;

        let (treasury_cap, mut currency) = new_currency(scenario.ctx());
        let treasury_cap_id = object::id(&treasury_cap);
        let (presale, cap) = new_presale<QUOTE>(
            treasury_cap,
            &mut currency,
            terms,
            &creation_policy,
            &fee_policy,
            scenario.ctx(),
        );
        creation_policy.destroy_for_testing();

        let presale_id = object::id(&presale);
        assert_created_event(
            presale_id,
            object::id(&cap),
            treasury_cap_id,
            eligibility,
            burnable,
            recipient_b_bps,
            participant_vesting,
            vector[recipient_a_vesting, option::none()],
            raise_vesting,
            hard_cap,
        );
        assert_eq!(currency.is_supply_fixed(), !burnable);
        assert_eq!(currency.is_supply_burn_only(), burnable);
        assert_eq!(currency.total_supply().destroy_some(), TOKEN_SUPPLY);
        destroy(currency);

        presale.share(&package_version, COMMITMENT_STARTS_AT_MS, &clock);
        assert_opened_event(
            presale_id,
            if (uncapped.is_some()) UNCAPPED_STARTS_AT_MS else COMMITMENT_ENDS_AT_MS,
            hard_cap.map!(|cap| COMMITMENT_STARTS_AT_MS + cap.starts_after_ms),
        );
        transfer::public_transfer(cap, CREATOR);

        Fixture { scenario, clock, fee_policy, presale_id }
    };
    std::unit_test::destroy(package_version);
    result
}

/// Creates the sale `migration_pays_blast_its_snapshotted_shares_at_the_current_destination`
/// creates, names `partner` before sharing it, then lets Alice and Bob overfill it and a keeper
/// settle it as funded.
fun start_partnered_sale(partner: &Partner): Fixture {
    let mut fixture = partner.share_partnered_sale(COMMITMENT_STARTS_AT_MS, PROTOCOL_RAISE_BPS);
    fixture.fund_partnered_sale();

    fixture
}

/// Creates that sale at `created_at_ms` under Blast's `protocol_raise_bps`, names `partner`, and
/// shares it to open at `COMMITMENT_STARTS_AT_MS`.
fun share_partnered_sale(partner: &Partner, created_at_ms: u64, protocol_raise_bps: u64): Fixture {
    let mut scenario = test_scenario::begin(CREATOR);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let result = {
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(created_at_ms);
        let fee_policy = treasury_fee_policy(
            protocol_raise_bps,
            PROTOCOL_TOKEN_BPS,
            scenario.ctx(),
        );
        let creation_policy = partner.accepting_partner(scenario.ctx());
        let mut terms = valid_sale_terms();
        terms.recipient_allocations = vector[
            recipient_a_share(option::none()),
            presale::recipient_share(RECIPIENT_B, bps::new(FEE_PAYING_RECIPIENT_B_BPS)),
        ];
        terms.raise_allocations = vector[
            presale::recipient_share(RAISE_RECIPIENT, bps::new(2_000)),
        ];
        terms.eligibility = presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2);
        let (treasury_cap, mut currency) = new_currency(scenario.ctx());
        let mut initializer = new_initializer<QUOTE>(
            &package_version,
            treasury_cap,
            terms,
            &creation_policy,
            &fee_policy,
        );

        initializer.set_partner(&package_version, &creation_policy, partner, &clock);
        let (sale, cap) = initializer.finalize(&package_version, &mut currency, scenario.ctx());
        let presale_id = object::id(&sale);
        sale.share(&package_version, COMMITMENT_STARTS_AT_MS, &clock);

        let opened = only_event<PresaleOpened<BLAST_PRESALE_TESTS, QUOTE>>();
        assert_eq!(opened.opened_partner_id(), option::some(object::id(partner)));
        transfer::public_transfer(cap, CREATOR);
        destroy(currency);
        creation_policy.destroy_for_testing();
        Fixture { scenario, clock, fee_policy, presale_id }
    };
    std::unit_test::destroy(package_version);
    result
}

/// Alice and Bob overfill an open partnered sale at its start, and a keeper settles it as funded.
fun fund_partnered_sale(self: &mut Fixture) {
    self.set_time(COMMITMENT_STARTS_AT_MS);
    self.commit_open(ALICE, 1_000);
    self.commit_open(BOB, 3_000);
    self.set_time(COMMITMENT_ENDS_AT_MS);
    self.settle(KEEPER);
}

/// A creation policy allowing the fixture's Quote and migrator that also accepts `partner`.
fun accepting_partner(partner: &Partner, ctx: &mut TxContext): CreationPolicy {
    let package_version = blast_presale::blast_presale_package::new_for_testing(ctx);
    let result = {
        let mut creation_policy = creation_policy::allowing_for_testing<QUOTE, TEST_MIGRATOR>(ctx);
        creation_policy.add_partner(&package_version, &fee_admin(), partner);

        creation_policy
    };
    std::unit_test::destroy(package_version);
    result
}

/// A Blast partner paid at `PARTNER_RECIPIENT` whose cut, `cut_bps` of Blast's fee, is in force.
fun new_partner(cut_bps: u64, ctx: &mut TxContext): Partner {
    partners::new_for_testing(PARTNER_RECIPIENT, cut_bps, ctx)
}

/// A fee policy paying `TREASURY`, charging the given raise and token rates and no LP-fee share.
fun treasury_fee_policy(
    protocol_raise_bps: u64,
    protocol_token_bps: u64,
    ctx: &mut TxContext,
): FeePolicy {
    let package_version = blast_presale::blast_presale_package::new_for_testing(ctx);
    let result = {
        let mut fee_policy = fee_policy::new_for_testing(ctx);
        fee_policy.set_destination(&package_version, &treasury_admin(), TREASURY);
        if (protocol_raise_bps > 0 || protocol_token_bps > 0)
            fee_policy.set_fees(
                &package_version,
                &fee_admin(),
                bps::new(protocol_raise_bps),
                bps::new(protocol_token_bps),
                bps::new(0),
                bps::new(0),
            );

        fee_policy
    };
    std::unit_test::destroy(package_version);
    result
}

/// Asserts the single `PresaleCreated` event records the fixture's objects and terms.
fun assert_created_event(
    presale_id: ID,
    cap_id: ID,
    treasury_cap_id: ID,
    eligibility: EligibilityPolicy,
    burnable: bool,
    recipient_b_bps: u64,
    participant_vesting: Option<VestingTerms>,
    recipient_vesting: vector<Option<VestingTerms>>,
    raise_vesting: vector<Option<VestingTerms>>,
    hard_cap: Option<HardCapTerms>,
) {
    let created = only_event<PresaleCreated<BLAST_PRESALE_TESTS, QUOTE>>();

    let (
        created_presale_id,
        created_cap_id,
        created_treasury_cap_id,
        token_supply,
        token_allocation_bps,
        liquidity_token_allocation_bps,
        raise_target,
        commitment_duration_ms,
        liquidity_window_duration_ms,
        created_eligibility,
    ) = created.created_fields();
    assert_eq!(created_presale_id, presale_id);
    assert_eq!(created_cap_id, cap_id);
    assert_eq!(created_treasury_cap_id, treasury_cap_id);
    assert_eq!(
        vector[
            token_supply,
            token_allocation_bps,
            liquidity_token_allocation_bps,
            raise_target,
            commitment_duration_ms,
            liquidity_window_duration_ms,
        ],
        vector[
            TOKEN_SUPPLY,
            TOKEN_ALLOCATION_BPS,
            LIQUIDITY_TOKEN_ALLOCATION_BPS,
            RAISE_TARGET,
            COMMITMENT_DURATION_MS,
            LIQUIDITY_WINDOW_DURATION_MS,
        ],
    );
    assert_eq!(created_eligibility, eligibility);

    let (
        migration_witness,
        fee_recipients,
        fee_recipient_bps,
        holder_rewards_bps,
    ) = created.created_migration_fields();
    assert_eq!(migration_witness, type_name::with_original_ids<TEST_MIGRATOR>());
    assert_eq!(fee_recipients, vector[CREATOR, FEE_PARTNER]);
    assert_eq!(fee_recipient_bps, vector[CREATOR_FEE_BPS, FEE_PARTNER_BPS]);
    assert_eq!(holder_rewards_bps, HOLDER_REWARDS_BPS);

    let (recipients, recipient_bps, created_burnable) = created.created_supply_fields();
    assert_eq!(recipients, vector[RECIPIENT_A, RECIPIENT_B]);
    assert_eq!(recipient_bps, vector[RECIPIENT_A_BPS, recipient_b_bps]);
    assert_eq!(created_burnable, burnable);

    let (
        created_participant_vesting,
        created_recipient_vesting,
        created_raise_vesting,
    ) = created.created_vesting_fields();
    assert_eq!(created_participant_vesting, participant_vesting);
    assert_eq!(created_recipient_vesting, recipient_vesting);
    assert_eq!(created_raise_vesting, raise_vesting);
    assert_eq!(
        created.created_hard_cap(),
        hard_cap.map!(
            |cap| presale::hard_cap_for_testing(cap.starts_after_ms, cap.closes_when_filled),
        ),
    );
}

/// Asserts one `VestingCreated` event is an irrevocable `T` schedule paying `beneficiary`
/// `total_amount` under `team_vesting_terms` from `vesting_starts_at_ms`, and returns its ID.
fun team_schedule_id<T>(
    created: &VestingCreated,
    beneficiary: address,
    total_amount: u64,
    vesting_starts_at_ms: u64,
): ID {
    let (
        vesting_id,
        coin_type,
        created_beneficiary,
        refund_recipient,
        cancel_cap_id,
        created_total_amount,
        created_vesting_starts_at_ms,
        vesting_cliff_delay_ms,
        vesting_period_duration_ms,
        periods,
    ) = created.vesting_created_fields();
    assert_eq!(coin_type, type_name::with_original_ids<T>());
    assert_eq!(created_beneficiary, beneficiary);
    assert!(refund_recipient.is_none());
    assert!(cancel_cap_id.is_none());
    assert_eq!(
        vector[created_total_amount, created_vesting_starts_at_ms, vesting_cliff_delay_ms, vesting_period_duration_ms, periods],
        vector[total_amount, vesting_starts_at_ms, VESTING_CLIFF_DELAY_MS, VESTING_PERIOD_DURATION_MS, VESTING_PERIODS],
    );

    vesting_id
}

/// Asserts the single `PresaleOpened` event fixes the fixture's window and its uncapped and
/// hard-cap starts.
fun assert_opened_event(presale_id: ID, uncapped_starts_at_ms: u64, hard_cap_starts_at_ms: Option<u64>) {
    let (opened_presale_id, commitment_starts_at_ms, commitment_ends_at_ms, deadline_at_ms, opened_uncapped_starts_at_ms) = only_event<
        PresaleOpened<BLAST_PRESALE_TESTS, QUOTE>,
    >().opened_fields();
    assert_eq!(opened_presale_id, presale_id);
    assert_eq!(
        vector[commitment_starts_at_ms, commitment_ends_at_ms, deadline_at_ms, opened_uncapped_starts_at_ms],
        vector[COMMITMENT_STARTS_AT_MS, COMMITMENT_ENDS_AT_MS, LIQUIDITY_DEADLINE_AT_MS, uncapped_starts_at_ms],
    );
    assert_eq!(
        only_event<PresaleOpened<BLAST_PRESALE_TESTS, QUOTE>>().opened_hard_cap_from_ms(),
        hard_cap_starts_at_ms,
    );
    assert_eq!(
        only_event<PresaleOpened<BLAST_PRESALE_TESTS, QUOTE>>().opened_partner_id(),
        option::none(),
    );
}

fun end(self: Fixture) {
    let Fixture { scenario, clock, fee_policy, presale_id: _ } = self;
    clock.destroy_for_testing();
    fee_policy.destroy_for_testing();
    scenario.end();
}

/// Terms every creation guard accepts: the fixture's supply split, a single-wallet raise, the
/// seven-day LP window, and the standard fee split.
fun valid_sale_terms(): SaleTerms {
    SaleTerms {
        token_supply: TOKEN_SUPPLY,
        token_allocation_bps: TOKEN_ALLOCATION_BPS,
        participant_vesting: option::none(),
        liquidity_token_allocation_bps: LIQUIDITY_TOKEN_ALLOCATION_BPS,
        recipient_allocations: recipient_allocations(),
        burnable: false,
        raise_target: RAISE_TARGET,
        raise_allocations: vector[],
        duration_ms: COMMITMENT_DURATION_MS,
        liquidity_window_ms: LIQUIDITY_WINDOW_DURATION_MS,
        eligibility: single_wallet_eligibility(),
        uncapped: option::none(),
        hard_cap: option::none(),
        fee_recipients: fee_recipients(),
        holder_rewards_bps: HOLDER_REWARDS_BPS,
    }
}

/// A hard cap from `start_delay_ms` into the window.
fun hard_cap_at(start_delay_ms: u64, closes_when_filled: bool): HardCapTerms {
    HardCapTerms { starts_after_ms: start_delay_ms, closes_when_filled }
}

/// A sale started for the fixture's migrator with nothing set.
fun bare_initializer(
    package_version: &blast_presale::blast_presale_package::PackageVersion,
    treasury_cap: TreasuryCap<BLAST_PRESALE_TESTS>,
    creation_policy: &CreationPolicy,
    fee_policy: &FeePolicy,
): PresaleInitializer<BLAST_PRESALE_TESTS, QUOTE> {
    presale::new<BLAST_PRESALE_TESTS, QUOTE, TEST_MIGRATOR>(
        treasury_cap,
        package_version,
        TEST_MIGRATOR(),
        creation_policy,
        fee_policy,
    )
}

/// One wallet slot whose minimum is the whole raise, so a single commitment funds the sale.
fun single_wallet_eligibility(): EligibilityPolicy {
    presale::open_eligibility(WALLET_CAP, 1, RAISE_TARGET)
}

/// Finalizes `new_initializer`'s sale.
fun new_presale<Quote>(
    treasury_cap: TreasuryCap<BLAST_PRESALE_TESTS>,
    currency: &mut Currency<BLAST_PRESALE_TESTS>,
    terms: SaleTerms,
    creation_policy: &CreationPolicy,
    fee_policy: &FeePolicy,
    ctx: &mut TxContext,
): (Presale<BLAST_PRESALE_TESTS, Quote>, PresaleCap) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(ctx);
    let (result_0, result_1) = {
        new_initializer<Quote>(
            &package_version,
            treasury_cap,
            terms,
            creation_policy,
            fee_policy,
        ).finalize(&package_version, currency, ctx)
    };
    std::unit_test::destroy(package_version);
    (result_0, result_1)
}

/// Starts a sale with the fixture's migrator and sets every one of `terms`.
fun new_initializer<Quote>(
    package_version: &blast_presale::blast_presale_package::PackageVersion,
    treasury_cap: TreasuryCap<BLAST_PRESALE_TESTS>,
    terms: SaleTerms,
    creation_policy: &CreationPolicy,
    fee_policy: &FeePolicy,
): PresaleInitializer<BLAST_PRESALE_TESTS, Quote> {
    let SaleTerms {
        token_supply,
        token_allocation_bps,
        participant_vesting,
        liquidity_token_allocation_bps,
        recipient_allocations,
        burnable,
        raise_target,
        raise_allocations,
        duration_ms: commitment_duration_ms,
        liquidity_window_ms: liquidity_window_duration_ms,
        eligibility,
        uncapped,
        hard_cap,
        fee_recipients,
        holder_rewards_bps,
    } = terms;
    let mut initializer = presale::new<BLAST_PRESALE_TESTS, Quote, TEST_MIGRATOR>(
        treasury_cap,
        package_version,
        TEST_MIGRATOR(),
        creation_policy,
        fee_policy,
    );

    initializer.set_supply(package_version, token_supply, burnable);
    initializer.set_token_allocations(
        package_version,
        bps::new(token_allocation_bps),
        bps::new(liquidity_token_allocation_bps),
        recipient_allocations,
    );
    participant_vesting.do!(
        |vesting| initializer.set_participant_vesting(package_version, vesting),
    );
    initializer.set_raise(package_version, raise_target, raise_allocations);
    initializer.set_windows(package_version, commitment_duration_ms, liquidity_window_duration_ms);
    initializer.set_eligibility(package_version, eligibility);
    uncapped.do!(|phase| initializer.set_uncapped_phase(package_version, phase));
    hard_cap.do!(
        |cap| initializer.set_hard_cap(
            package_version,
            cap.starts_after_ms,
            cap.closes_when_filled,
        ),
    );
    initializer.set_fee_split(
        package_version,
        presale::fee_split(fee_recipients, bps::new(holder_rewards_bps)),
    );

    initializer
}

/// Creates a sale raising `Quote` under `terms` with a fresh treasury, then discards it.
fun create_sale<Quote>(terms: SaleTerms) {
    let mut ctx = tx_context::dummy();
    let (treasury_cap, currency) = new_currency(&mut ctx);

    create_sale_with_treasury<Quote>(treasury_cap, currency, terms, &mut ctx);

    destroy(ctx);
}

/// Creates a sale raising `Quote` under `terms` from `treasury_cap`, then discards it.
fun create_sale_with_treasury<Quote>(
    treasury_cap: TreasuryCap<BLAST_PRESALE_TESTS>,
    mut currency: Currency<BLAST_PRESALE_TESTS>,
    terms: SaleTerms,
    ctx: &mut TxContext,
) {
    let fee_policy = fee_policy::new_for_testing(ctx);
    let creation_policy = creation_policy::allowing_for_testing<Quote, TEST_MIGRATOR>(ctx);

    let (sale, cap) = new_presale<Quote>(
        treasury_cap,
        &mut currency,
        terms,
        &creation_policy,
        &fee_policy,
        ctx,
    );

    destroy(sale);
    destroy(cap);
    destroy(currency);
    destroy(fee_policy);
    destroy(creation_policy);
}

fun create_with_fee_split(fee_recipients: vector<RecipientShare>, holder_rewards_bps: u64) {
    let mut terms = valid_sale_terms();
    terms.fee_recipients = fee_recipients;
    terms.holder_rewards_bps = holder_rewards_bps;

    create_sale<QUOTE>(terms);
}

fun create_with_windows(commitment_duration_ms: u64, liquidity_window_duration_ms: u64) {
    let mut terms = valid_sale_terms();
    terms.duration_ms = commitment_duration_ms;
    terms.liquidity_window_ms = liquidity_window_duration_ms;

    create_sale<QUOTE>(terms);
}

/// Creates a Bluefin sale under a creation policy that allows only `AllowedQuote` and
/// `AllowedWitness`, and checks the pool tier it reserved.
fun create_bluefin_sale<AllowedQuote, AllowedWitness>(symbol: vector<u8>) {
    let mut ctx = tx_context::dummy();
    let package_version = blast_presale::blast_presale_package::new_for_testing(&mut ctx);
    let (treasury_cap, mut currency) = new_currency_with_symbol(symbol, &mut ctx);
    let fee_policy = fee_policy::new_for_testing(&mut ctx);
    let creation_policy = creation_policy::allowing_for_testing<AllowedQuote, AllowedWitness>(
        &mut ctx,
    );
    let mut venue_config = venue_config::new_for_testing(&mut ctx);

    let mut initializer = bluefin::new<BLAST_PRESALE_TESTS, QUOTE>(
        treasury_cap,
        &package_version,
        &currency,
        &creation_policy,
        &fee_policy,
        &mut venue_config,
        TICK_SPACING,
        POOL_FEE_RATE,
    );
    let (reserved_tick_spacing, reserved_fee_rate) = only_event<
        PoolTierReserved<BLAST_PRESALE_TESTS, QUOTE, bluefin::Venue>,
    >().pool_tier_reserved_fields();
    assert_eq!(reserved_tick_spacing, TICK_SPACING);
    assert_eq!(reserved_fee_rate, POOL_FEE_RATE);
    let (stored_tick_spacing, stored_fee_rate) = venue_config.pool_tier<BLAST_PRESALE_TESTS>();
    assert_eq!(stored_tick_spacing, TICK_SPACING);
    assert_eq!(stored_fee_rate, POOL_FEE_RATE);
    initializer.set_supply(&package_version, TOKEN_SUPPLY, false);
    initializer.set_token_allocations(
        &package_version,
        bps::new(TOKEN_ALLOCATION_BPS),
        bps::new(LIQUIDITY_TOKEN_ALLOCATION_BPS),
        recipient_allocations(),
    );
    initializer.set_raise(&package_version, RAISE_TARGET, vector[]);
    initializer.set_windows(&package_version, COMMITMENT_DURATION_MS, LIQUIDITY_WINDOW_DURATION_MS);
    initializer.set_eligibility(&package_version, single_wallet_eligibility());
    initializer.set_fee_split(
        &package_version,
        presale::fee_split(fee_recipients(), bps::new(HOLDER_REWARDS_BPS)),
    );
    let (sale, cap) = initializer.finalize(&package_version, &mut currency, &mut ctx);

    destroy(sale);
    destroy(cap);
    destroy(currency);
    destroy(fee_policy);
    destroy(creation_policy);
    destroy(venue_config);
    destroy(ctx);

    std::unit_test::destroy(package_version);
}

fun new_currency(
    ctx: &mut TxContext,
): (TreasuryCap<BLAST_PRESALE_TESTS>, Currency<BLAST_PRESALE_TESTS>) {
    new_currency_with_symbol(b"SALE", ctx)
}

fun new_regulated_currency(
    allow_global_pause: bool,
    ctx: &mut TxContext,
): (TreasuryCap<BLAST_PRESALE_TESTS>, Currency<BLAST_PRESALE_TESTS>) {
    let (mut initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<BLAST_PRESALE_TESTS>(),
        9,
        b"SALE".to_string(),
        b"Sale Token".to_string(),
        b"Regulated presale test token".to_string(),
        b"".to_string(),
        ctx,
    );
    let deny_cap = initializer.make_regulated(allow_global_pause, ctx);
    destroy(deny_cap);

    (treasury_cap, coin_registry::unwrap_for_testing(initializer))
}

// Legacy constructors are required to reproduce a deny cap hidden behind Unknown status.
#[allow(deprecated_usage)]
fun legacy_regulated_currency(
    migrate_status: bool,
    ctx: &mut TxContext,
): (TreasuryCap<BLAST_PRESALE_TESTS>, Currency<BLAST_PRESALE_TESTS>) {
    let (treasury_cap, deny_cap, metadata) = coin::create_regulated_currency_v2(
        test_utils::create_one_time_witness<BLAST_PRESALE_TESTS>(),
        9,
        b"SALE",
        b"Sale Token",
        b"Legacy regulated presale test token",
        option::none(),
        true,
        ctx,
    );
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let mut currency = coin_registry::migrate_legacy_metadata_for_testing(
        &mut registry,
        &metadata,
        ctx,
    );
    if (migrate_status) currency.migrate_regulated_state_by_cap(&deny_cap);
    destroy(deny_cap);
    destroy(metadata);
    destroy(registry);

    (treasury_cap, currency)
}

fun new_currency_with_symbol(
    symbol: vector<u8>,
    ctx: &mut TxContext,
): (TreasuryCap<BLAST_PRESALE_TESTS>, Currency<BLAST_PRESALE_TESTS>) {
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<BLAST_PRESALE_TESTS>(),
        9,
        symbol.to_string(),
        b"Sale Token".to_string(),
        b"Presale test token".to_string(),
        b"".to_string(),
        ctx,
    );

    (treasury_cap, coin_registry::unwrap_for_testing(initializer))
}

/// `count` distinct non-zero fee recipients taking 100 BPS each.
fun distinct_fee_recipients(count: u64): vector<RecipientShare> {
    vector::tabulate!(count, |i| {
        presale::recipient_share(sui::address::from_u256((i as u256) + 1), bps::new(100))
    })
}

fun fee_recipients(): vector<RecipientShare> {
    vector[
        presale::recipient_share(CREATOR, bps::new(CREATOR_FEE_BPS)),
        presale::recipient_share(FEE_PARTNER, bps::new(FEE_PARTNER_BPS)),
    ]
}

/// Recipient A's token share, vesting under `vesting` when it has terms.
fun recipient_a_share(vesting: Option<VestingTerms>): RecipientShare {
    vesting
        .map!(|terms| {
            presale::vested_recipient_share(RECIPIENT_A, bps::new(RECIPIENT_A_BPS), terms)
        })
        .destroy_or!(presale::recipient_share(RECIPIENT_A, bps::new(RECIPIENT_A_BPS)))
}

fun team_vesting_terms(): VestingTerms {
    presale::vesting_terms(VESTING_CLIFF_DELAY_MS, VESTING_PERIOD_DURATION_MS, VESTING_PERIODS)
}

fun recipient_allocations(): vector<RecipientShare> {
    vector[
        presale::recipient_share(RECIPIENT_A, bps::new(RECIPIENT_A_BPS)),
        presale::recipient_share(RECIPIENT_B, bps::new(RECIPIENT_B_BPS)),
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

/// Commits `amount` under the open policy and returns
/// `[wallet_commitment, total_commitments, participants]`.
fun commit_open(self: &mut Fixture, sender: address, amount: u64): vector<u64> {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let result = {
        self.next_tx!(sender, |fixture| {
            let mut sale = fixture.take_presale();
            sale
                .commit_open(
                    &package_version,
                    coin::mint_for_testing(amount, fixture.ctx!()),
                    &fixture.clock,
                    fixture.scenario.ctx(),
                )
                .destroy_zero();
            fixture.return_presale(sale);
        });

        self.committed_totals(amount)
    };
    std::unit_test::destroy(package_version);
    result
}

/// Commits `amount` with an allowlist proof and returns
/// `[wallet_commitment, total_commitments, participants]`.
fun commit_allowlisted(
    self: &mut Fixture,
    sender: address,
    amount: u64,
    index: u64,
    wallet_cap: u64,
    proof: vector<vector<u8>>,
): vector<u64> {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let result = {
        self.next_tx!(sender, |fixture| {
            let mut sale = fixture.take_presale();
            sale
                .commit_allowlisted(
                    &package_version,
                    coin::mint_for_testing(amount, fixture.ctx!()),
                    index,
                    wallet_cap,
                    proof,
                    &fixture.clock,
                    fixture.scenario.ctx(),
                )
                .destroy_zero();
            fixture.return_presale(sale);
        });

        self.committed_totals(amount)
    };
    std::unit_test::destroy(package_version);
    result
}

/// Asserts the single `Committed` event took all of `amount` for this sale and returns
/// `[wallet_commitment, total_commitments, participants]`.
fun committed_totals(self: &Fixture, amount: u64): vector<u64> {
    let (presale_id, quote, wallet_commitment, total_commitments, participants) = only_event<
        Committed<BLAST_PRESALE_TESTS, QUOTE>,
    >().committed_fields();
    assert_eq!(presale_id, self.presale_id);
    assert_eq!(quote, amount);

    vector[wallet_commitment, total_commitments, participants]
}

/// Commits under the open policy and returns `[accepted, change]`.
fun commit_open_for_change(self: &mut Fixture, sender: address, amount: u64): vector<u64> {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let result = {
        let mut change = vector[];
        self.next_tx!(sender, |fixture| {
            let mut sale = fixture.take_presale();
            change.push_back(
                sale
                .commit_open(
                    &package_version,
                    coin::mint_for_testing(amount, fixture.ctx!()),
                    &fixture.clock,
                    fixture.scenario.ctx(),
                )
                .burn_for_testing());
            fixture.return_presale(sale);
        });
        let (_, accepted, _, _, _) = only_event<
            Committed<BLAST_PRESALE_TESTS, QUOTE>,
        >().committed_fields();

        vector[accepted, change[0]]
    };
    std::unit_test::destroy(package_version);
    result
}

/// Commits through the open-to-anyone uncapped route and returns `[accepted, change]`.
fun commit_uncapped(self: &mut Fixture, sender: address, amount: u64): vector<u64> {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let result = {
        let mut change = vector[];
        self.next_tx!(sender, |fixture| {
            let mut sale = fixture.take_presale();
            change.push_back(
                sale
                .commit_uncapped(
                    &package_version,
                    coin::mint_for_testing(amount, fixture.ctx!()),
                    &fixture.clock,
                    fixture.scenario.ctx(),
                )
                .burn_for_testing());
            fixture.return_presale(sale);
        });
        let (_, accepted, _, _, _) = only_event<
            Committed<BLAST_PRESALE_TESTS, QUOTE>,
        >().committed_fields();

        vector[accepted, change[0]]
    };
    std::unit_test::destroy(package_version);
    result
}

/// Has the AdminCap replace the sale's `[raise, token, LP-fee meme, LP-fee quote]` BPS rates.
fun set_protocol_fees(self: &mut Fixture, rates: vector<u64>) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    self.next_tx!(ADMIN, |fixture| {
        let mut sale = fixture.take_presale();
        sale.set_protocol_fees(
            &package_version,
            &fee_admin(),
            bps::new(rates[0]),
            bps::new(rates[1]),
            bps::new(rates[2]),
            bps::new(rates[3]),
            &fixture.clock,
        );
        fixture.return_presale(sale);
    });

    std::unit_test::destroy(package_version);
}

/// Returns the sale's `[raise, token, LP-fee meme, LP-fee quote]` BPS rates its vault inherits.
fun protocol_rates(self: &mut Fixture): vector<u64> {
    let mut rates = vector[];
    self.next_tx!(KEEPER, |fixture| {
        let sale = fixture.take_presale();
        let (_, _, _, protocol_fees, _) = sale.vault_config();
        rates.append(
            vector[
            protocol_fees.raise_bps().value(),
            protocol_fees.token_bps().value(),
            protocol_fees.lp_fee_meme_bps().value(),
            protocol_fees.lp_fee_quote_bps().value(),
        ]);
        fixture.return_presale(sale);
    });

    rates
}

/// Returns the partner the sale's vault inherits, which it pays a cut of Blast's LP fees.
fun vault_partner_id(self: &mut Fixture): Option<ID> {
    let mut partner_id = option::none();
    self.next_tx!(KEEPER, |fixture| {
        let sale = fixture.take_presale();
        let (_, _, _, _, vault_partner_id) = sale.vault_config();
        partner_id = vault_partner_id;
        fixture.return_presale(sale);
    });

    partner_id
}

/// The window end and LP deadline the sale's `PresaleFunded` event records.
fun funded_deadlines(_self: &Fixture): vector<u64> {
    let (commitment_ends_at_ms, liquidity_deadline_at_ms) = only_event<
        PresaleFunded<BLAST_PRESALE_TESTS, QUOTE>,
    >().funded_deadlines();

    vector[commitment_ends_at_ms, liquidity_deadline_at_ms]
}

fun settle(self: &mut Fixture, sender: address) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    self.next_tx!(sender, |fixture| {
        let mut sale = fixture.take_presale();
        sale.settle(&package_version, &fixture.clock);
        fixture.return_presale(sale);
    });

    std::unit_test::destroy(package_version);
}

/// Migrates with the allowed witness and returns the released `[liquidity_tokens, quote]`.
fun migrate(self: &mut Fixture): vector<u64> {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let result = {
        let mut released = vector[];
        self.next_tx!(KEEPER, |fixture| {
            let mut sale = fixture.take_presale();
            let (liquidity_tokens, quote) = sale.migrate(
                &package_version,
                &fixture.fee_policy,
                TEST_MIGRATOR(),
                &fixture.clock,
                fixture.scenario.ctx(),
            );
            released.push_back(liquidity_tokens.into_coin(fixture.ctx!()).burn_for_testing());
            released.push_back(quote.into_coin(fixture.ctx!()).burn_for_testing());
            assert!(sale.is_migrated_for_testing());
            fixture.return_presale(sale);
        });

        released
    };
    std::unit_test::destroy(package_version);
    result
}

/// Has `sender` pay the sale's partner and Blast the fees its migration held.
fun pay_protocol_fees_with_partner(self: &mut Fixture, sender: address, partner: &Partner) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    self.next_tx!(sender, |fixture| {
        let mut sale = fixture.take_presale();
        sale.pay_protocol_fees_with_partner(
            &package_version,
            &fixture.fee_policy,
            partner,
            &fixture.clock,
            fixture.ctx!(),
        );
        fixture.return_presale(sale);
    });

    std::unit_test::destroy(package_version);
}

/// Blast's raise fee the sale holds for `pay_protocol_fees_with_partner`, if it still does.
fun unpaid_protocol_quote(self: &mut Fixture): Option<u64> {
    let mut unpaid = vector[];
    self.next_tx!(KEEPER, |fixture| {
        let sale = fixture.take_presale();
        unpaid.push_back(sale.unpaid_protocol_quote_for_testing());
        fixture.return_presale(sale);
    });

    unpaid.pop_back()
}

fun take_recipient_allocations(self: &mut Fixture) {
    self.next_tx!(
        RECIPIENT_A,
        |fixture| assert_eq!(
            fixture.scenario.take_from_sender<Coin<BLAST_PRESALE_TESTS>>().burn_for_testing(),
            RECIPIENT_A_TOKENS,
        ),
    );
    self.next_tx!(
        RECIPIENT_B,
        |fixture| assert_eq!(
            fixture.scenario.take_from_sender<Coin<BLAST_PRESALE_TESTS>>().burn_for_testing(),
            RECIPIENT_B_TOKENS,
        ),
    );
}

fun destroy_migrated_cap(self: &mut Fixture) {
    self.next_tx!(CREATOR, |fixture| destroy(fixture.scenario.take_from_sender<PresaleCap>()));
}

fun cancel_unlaunched(self: &mut Fixture, sender: address) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    self.next_tx!(sender, |fixture| {
        let mut sale = fixture.take_presale();
        sale.cancel_unlaunched(&package_version, &fixture.clock);
        fixture.return_presale(sale);
    });

    std::unit_test::destroy(package_version);
}

/// Claims for `participant` from a sale without participant vesting and returns
/// `[commitment, tokens, quote_refund, remaining_participants]`.
fun claim(self: &mut Fixture, sender: address, participant: address): vector<u64> {
    let (claimed, vesting_id) = self.claim_with_vesting(sender, participant);
    assert!(vesting_id.is_none());

    claimed
}

/// Claims for `participant` and returns `[commitment, tokens, quote_refund,
/// remaining_participants]` with the vesting schedule the claim created, if any.
fun claim_with_vesting(
    self: &mut Fixture,
    sender: address,
    participant: address,
): (vector<u64>, Option<ID>) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let (result_0, result_1) = {
        self.next_tx!(sender, |fixture| {
            let mut sale = fixture.take_presale();
            sale.claim(&package_version, participant, &fixture.clock, fixture.ctx!());
            fixture.return_presale(sale);
        });

        let claimed = only_event<Claimed<BLAST_PRESALE_TESTS, QUOTE>>();
        let (
            presale_id,
            delivered_to,
            commitment,
            tokens,
            quote_refund,
            remaining,
        ) = claimed.claim_fields();
        assert_eq!(presale_id, self.presale_id);
        assert_eq!(delivered_to, participant);

        (vector[commitment, tokens, quote_refund, remaining], claimed.claimed_vesting_id())
    };
    std::unit_test::destroy(package_version);
    (result_0, result_1)
}

fun take_payout(self: &mut Fixture, participant: address, tokens: u64, quote: u64) {
    self.next_tx!(participant, |fixture| {
        assert_eq!(
            fixture.scenario.take_from_sender<Coin<BLAST_PRESALE_TESTS>>().burn_for_testing(),
            tokens,
        );
        assert_eq!(fixture.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), quote);
    });
}

fun take_tokens(self: &mut Fixture, participant: address, tokens: u64) {
    self.next_tx!(participant, |fixture| {
        assert_eq!(
            fixture.scenario.take_from_sender<Coin<BLAST_PRESALE_TESTS>>().burn_for_testing(),
            tokens,
        );
    });
}

fun take_quote(self: &mut Fixture, participant: address, quote: u64) {
    self.next_tx!(participant, |fixture| {
        assert_eq!(fixture.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), quote);
    });
}

fun assert_treasury_received_nothing(self: &mut Fixture) {
    self.next_tx!(TREASURY, |fixture| {
        assert!(!fixture.scenario.has_most_recent_for_sender<Coin<QUOTE>>());
        assert!(!fixture.scenario.has_most_recent_for_sender<Coin<BLAST_PRESALE_TESTS>>());
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

/// Returns `[total_commitments, participants, quote, sale_tokens, liquidity_tokens,
/// recipient_tokens, protocol_tokens]`, where `participants` are the wallets still to claim.
fun custody(self: &mut Fixture): vector<u64> {
    let mut balances = vector[];
    self.next_tx!(KEEPER, |fixture| {
        let sale = fixture.take_presale();
        let (
            total_commitments,
            participants,
            quote,
            sale_tokens,
            liquidity_tokens,
            recipient_tokens,
            protocol_tokens,
        ) = sale.custody_for_testing();
        balances.append(
            vector[
            total_commitments,
            participants,
            quote,
            sale_tokens,
            liquidity_tokens,
            recipient_tokens,
            protocol_tokens,
        ]);
        fixture.return_presale(sale);
    });

    balances
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

/// Lets a keeper claim a presale-created vesting schedule at `timestamp_ms`; the vesting package
/// pays its beneficiary.
fun claim_vesting<T>(self: &mut Fixture, vesting_id: ID, timestamp_ms: u64) {
    self.set_time(timestamp_ms);
    self.next_tx!(KEEPER, |fixture| {
        let mut vesting = fixture.scenario.take_shared_by_id<Vesting<T>>(vesting_id);
        vesting.claim(&fixture.clock, fixture.ctx!());
        test_scenario::return_shared(vesting);
    });
}

fun only_event<Event: copy + drop>(): Event {
    let mut events = event::events_by_type<Event>();
    assert_eq!(events.length(), 1);
    events.pop_back()
}

fun fee_admin(): AdminWitness<FeeAdmin> {
    blast_acl::witness_for_testing()
}

fun treasury_admin(): AdminWitness<TreasuryAdmin> {
    blast_acl::witness_for_testing()
}

// === Imports ===

use blast_admin::blast_acl::{Self, AdminWitness};

use blast_fun_vesting::blast_fun_linear_vesting::{Vesting, VestingCreated};

use blast_partners::blast_partners::{Self as partners, Partner, PartnerPaid};

use blast_presale::{
    blast_presale::{
        Self as presale,
        Claimed,
        Committed,
        EligibilityPolicy,
        RaiseAllocated,
        RecipientAllocated,
        Presale,
        PresaleCancelled,
        PresaleCap,
        PresaleInitializer,
        PresaleCreated,
        PresaleFunded,
        PresaleMigrated,
        PresaleOpened,
        ProtocolFeesChanged,
        RecipientShare,
        UncappedPhase,
        VestingTerms,
        ProtocolFeesPaid,
    },
    blast_presale_domain::{FeeAdmin, TreasuryAdmin},
    bluefin,
    bps,
    cetus,
    creation_policy::{Self, CreationPolicy},
    fee_policy::{Self, FeePolicy},
    migration_math,
    venue_config::{Self, PoolTierReserved}
};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin, TreasuryCap},
    coin_registry::{Self, Currency},
    event,
    test_scenario::{Self, Scenario},
    test_utils
};

use fun accepting_partner as Partner.accepting_partner;

use fun share_partnered_sale as Partner.share_partnered_sale;

use fun start_partnered_sale as Partner.start_partnered_sale;

use fun team_schedule_id as VestingCreated.team_schedule_id;
