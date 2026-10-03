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

const START_MS: u64 = 1_000;
const DURATION_MS: u64 = 100;
const END_MS: u64 = START_MS + DURATION_MS;
/// The shortest window `new` accepts, so every fixture also pins the seven-day floor.
const LIQUIDITY_WINDOW_MS: u64 = 7 * 24 * 60 * 60 * 1_000;
const LIQUIDITY_DEADLINE_MS: u64 = END_MS + LIQUIDITY_WINDOW_MS;
const UNCAPPED_AFTER_MS: u64 = 50;
const UNCAPPED_FROM_MS: u64 = START_MS + UNCAPPED_AFTER_MS;
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
const VESTING_CLIFF_MS: u64 = 100;
const VESTING_PERIOD_MS: u64 = 50;
const VESTING_PERIODS: u64 = 4;
const VESTING_DURATION_MS: u64 = VESTING_PERIOD_MS * VESTING_PERIODS;
const MAX_VESTING_DURATION_MS: u64 = 1 << 63;

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

/// The creator-chosen terms `presale::new` takes, named so a test can change one field of
/// `valid_sale_terms` and show exactly which input a creation guard rejects.
public struct SaleTerms has drop {
    token_supply: u64,
    token_allocation_bps: u64,
    liquidity_token_allocation_bps: u64,
    recipient_allocations: vector<RecipientShare>,
    burnable: bool,
    raise_target: u64,
    raise_allocations: vector<RecipientShare>,
    duration_ms: u64,
    liquidity_window_ms: u64,
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    fee_recipients: vector<RecipientShare>,
    holder_rewards_bps: u64,
}

// === Tests ===

#[test]
/// Every wallet gets the same fill rate regardless of commitment size or claim order.
fun oversubscription_uses_one_fill_rate_and_refunds_the_rest() {
    let mut fixture = start_sale(presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2));

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

    assert_eq!(fixture.claim(KEEPER, ALICE), vector[1_000, 2_500, 750, 3_000]);
    fixture.take_payout(ALICE, 2_500, 750);
    assert_eq!(fixture.claim(KEEPER, BOB), vector[3_000, 7_501, 2_250, 0]);
    fixture.take_payout(BOB, 7_501, 2_250);
    assert_eq!(fixture.custody(), vector[4_000, 0, 2, 0, 0, 0, 0, 0]);

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
        vector[400, 400, 1, 400, TOKEN_ALLOCATION, LIQUIDITY_TOKENS, RECIPIENT_TOKENS, 0],
    );

    fixture.commit_open(ALICE, 100);
    assert_eq!(
        fixture.custody(),
        vector[500, 500, 1, 500, TOKEN_ALLOCATION, LIQUIDITY_TOKENS, RECIPIENT_TOKENS, 0],
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
    let mut fixture = start_sale(presale::open_eligibility(WALLET_CAP, 1_000, 1));
    fixture.commit_open(ALICE, 500);

    fixture.claim(ALICE, ALICE);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidLifecycle, location = blast_presale::blast_presale)]
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
        vector[500, 0, 1, 0, TOKEN_ALLOCATION, LIQUIDITY_TOKENS, RECIPIENT_TOKENS, 0],
    );

    fixture.destroy_cancelled_cap();
    fixture.end();
}

#[test]
/// A funded sale cannot lock participants forever when its creator never adds LP.
fun missed_liquidity_deadline_turns_a_funded_sale_into_full_refunds() {
    let mut fixture = start_funded_sale();
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
    let mut fixture = start_sale(presale::allowlisted_eligibility(alice_leaf, 1));

    fixture.commit_allowlisted(ALICE, 500, 0, 501, vector[]);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EWalletCapExceeded, location = blast_presale::blast_presale)]
fun cumulative_commitments_cannot_exceed_the_wallet_cap() {
    let mut fixture = start_sale(presale::open_eligibility(500, 4, RAISE_TARGET / 4));
    fixture.commit_open(ALICE, 400);

    fixture.commit_open(ALICE, 101);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EParticipantCapacityReached, location = blast_presale::blast_presale)]
fun open_sales_bound_their_dynamic_commitment_records() {
    let mut fixture = start_sale(single_wallet_eligibility());
    fixture.commit_open(ALICE, RAISE_TARGET);

    fixture.commit_open(BOB, RAISE_TARGET);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EBelowMinimumCommitment, location = blast_presale::blast_presale)]
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

    fixture.set_time(END_MS);
    fixture.settle(KEEPER);
    fixture.claim(KEEPER, ALICE);
    fixture.take_quote(ALICE, RAISE_TARGET / 2 + 1);

    fixture.destroy_cancelled_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EUnreachableRaise, location = blast_presale::blast_presale)]
/// Filling every open slot at the minimum must fund the raise, or dust could block the sale.
fun an_open_sale_whose_slots_cannot_reach_the_raise_is_rejected() {
    start_sale(presale::open_eligibility(WALLET_CAP, 2, RAISE_TARGET / 2 - 1)).end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidEligibilityPolicy, location = blast_presale::blast_presale)]
fun the_minimum_commitment_cannot_exceed_the_wallet_cap() {
    presale::open_eligibility(100, 20, 101);
}

#[test]
#[expected_failure(abort_code = presale::EWalletCapExceeded, location = blast_presale::blast_presale)]
/// Before the uncapped phase starts, wallet caps still apply.
fun wallet_caps_hold_until_the_uncapped_phase_starts() {
    let mut fixture = start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_eligible(UNCAPPED_AFTER_MS, false),
    );
    fixture.set_time(UNCAPPED_FROM_MS - 1);

    fixture.commit_open(ALICE, 501);

    fixture.end();
}

#[test]
/// Without a hard cap, the uncapped phase lifts caps and the sale still overflows pro-rata.
fun an_uncapped_phase_without_a_hard_cap_lifts_caps_and_overflows() {
    let mut fixture = start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_eligible(UNCAPPED_AFTER_MS, false),
    );
    fixture.commit_open(ALICE, 500);
    fixture.set_time(UNCAPPED_FROM_MS);

    assert_eq!(fixture.commit_open(BOB, 3_000), vector[3_000, 3_500, 2]);

    fixture.set_time(END_MS);
    fixture.settle(KEEPER);
    assert!(fixture.is_funded());

    fixture.end();
}

#[test]
/// A hard-capped uncapped phase takes only what is left of the raise and returns the rest.
fun a_hard_capped_uncapped_phase_fills_the_raise_and_returns_the_excess() {
    let mut fixture = start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_eligible(UNCAPPED_AFTER_MS, true),
    );
    fixture.commit_open(ALICE, 400);
    fixture.set_time(UNCAPPED_FROM_MS);

    assert_eq!(fixture.commit_open_for_change(BOB, 2_000), vector[600, 1_400]);
    assert_eq!(fixture.commitment(BOB), 600);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EPresaleFilled, location = blast_presale::blast_presale)]
fun a_full_hard_capped_sale_accepts_no_more_quote() {
    let mut fixture = start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_eligible(UNCAPPED_AFTER_MS, true),
    );
    fixture.set_time(UNCAPPED_FROM_MS);
    fixture.commit_open_for_change(ALICE, RAISE_TARGET);

    fixture.commit_open_for_change(BOB, RAISE_TARGET / 4);

    fixture.end();
}

#[test]
/// The commitment that exactly fills a hard cap may fall below the per-wallet minimum.
fun the_commitment_that_fills_a_hard_cap_may_be_below_the_minimum() {
    let mut fixture = start_with_uncapped_phase(
        presale::open_eligibility(1_000, 4, RAISE_TARGET / 4),
        presale::uncapped_for_eligible(UNCAPPED_AFTER_MS, true),
    );
    fixture.set_time(UNCAPPED_FROM_MS);
    fixture.commit_open_for_change(ALICE, 900);

    assert_eq!(fixture.commit_open_for_change(BOB, 500), vector[100, 400]);

    fixture.end();
}

#[test]
/// An uncapped phase open to anyone admits wallets outside the allowlist. Its four slots beyond
/// the one leaf reach the raise at the minimum.
fun an_uncapped_phase_open_to_anyone_admits_wallets_outside_the_allowlist() {
    let alice_leaf = presale::allowlist_leaf_for_testing(0, ALICE, 500);
    let mut fixture = start_with_uncapped_phase(
        presale::allowlisted_eligibility(alice_leaf, 1),
        presale::uncapped_for_anyone(UNCAPPED_AFTER_MS, 5, RAISE_TARGET / 4, false),
    );
    fixture.commit_allowlisted(ALICE, 500, 0, 500, vector[]);
    fixture.set_time(UNCAPPED_FROM_MS);

    assert_eq!(fixture.commit_uncapped(CAROL, 2_000), vector[2_000, 0]);
    assert_eq!(fixture.commitment(CAROL), 2_000);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EUncappedPhaseNotOpen, location = blast_presale::blast_presale)]
fun the_open_uncapped_route_waits_for_its_phase() {
    let mut fixture = start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_anyone(UNCAPPED_AFTER_MS, 4, RAISE_TARGET / 4, false),
    );
    fixture.set_time(UNCAPPED_FROM_MS - 1);

    fixture.commit_uncapped(CAROL, 500);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EUncappedPhaseNotOpen, location = blast_presale::blast_presale)]
/// A phase limited to eligible wallets never opens the anyone route.
fun an_eligible_only_phase_rejects_the_open_uncapped_route() {
    let mut fixture = start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_eligible(UNCAPPED_AFTER_MS, false),
    );
    fixture.set_time(UNCAPPED_FROM_MS);

    fixture.commit_uncapped(CAROL, 500);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidUncappedPhase, location = blast_presale::blast_presale)]
fun an_uncapped_phase_must_start_inside_the_window() {
    start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_eligible(DURATION_MS, false),
    ).end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidUncappedPhase, location = blast_presale::blast_presale)]
/// Opening to anyone cannot shrink the participant bound eligible wallets already have.
fun an_open_uncapped_phase_cannot_admit_fewer_wallets_than_the_policy() {
    start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_anyone(UNCAPPED_AFTER_MS, 3, RAISE_TARGET, false),
    ).end();
}

#[test]
#[expected_failure(abort_code = presale::EUnreachableRaise, location = blast_presale::blast_presale)]
/// Anyone-access slots must also fund the raise when filled at their minimum.
fun an_open_uncapped_phase_whose_slots_cannot_reach_the_raise_is_rejected() {
    start_with_uncapped_phase(
        presale::open_eligibility(500, 4, RAISE_TARGET / 4),
        presale::uncapped_for_anyone(UNCAPPED_AFTER_MS, 4, RAISE_TARGET / 4 - 1, false),
    ).end();
}

#[test]
#[expected_failure(abort_code = presale::EUnreachableRaise, location = blast_presale::blast_presale)]
/// Allowlisted wallets may commit any positive amount, so only the phase slots beyond the
/// allowlist count toward reaching the raise: three slots at a quarter of it do not.
fun an_open_uncapped_phase_counts_only_the_slots_beyond_the_allowlist() {
    let alice_leaf = presale::allowlist_leaf_for_testing(0, ALICE, 500);

    start_with_uncapped_phase(
        presale::allowlisted_eligibility(alice_leaf, 1),
        presale::uncapped_for_anyone(UNCAPPED_AFTER_MS, 4, RAISE_TARGET / 4, false),
    ).end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidWindow, location = blast_presale::blast_presale)]
fun a_zero_commitment_window_is_rejected() {
    create_with_windows(0, LIQUIDITY_WINDOW_MS);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidWindow, location = blast_presale::blast_presale)]
/// A shorter LP window would let one transaction settle and cancel a sale nobody settled in time.
fun a_liquidity_window_below_seven_days_is_rejected() {
    create_with_windows(DURATION_MS, LIQUIDITY_WINDOW_MS - 1);
}

#[test]
/// A raise allocation is paid in Quote at migration and the LP takes the rest.
fun raise_allocations_are_paid_at_migration_and_the_lp_takes_the_rest() {
    let mut fixture = start_with_raise_allocations(
        vector[presale::recipient_share(RAISE_RECIPIENT, bps::new(2_000))],
    );
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);

    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, 800]);

    let (_, recipient, quote) = only_event<RaiseAllocated<BLAST_PRESALE_TESTS, QUOTE>>()
        .raise_allocated_fields();
    assert_eq!(recipient, RAISE_RECIPIENT);
    assert_eq!(quote, 200);
    fixture.take_recipient_allocations();
    fixture.take_quote(RAISE_RECIPIENT, 200);

    fixture.destroy_migrated_cap();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidRaiseAllocation, location = blast_presale::blast_presale)]
/// The LP must always keep part of the raise.
fun raise_allocations_must_leave_the_lp_a_share() {
    start_with_raise_allocations(vector[
        presale::recipient_share(RAISE_RECIPIENT, bps::new(6_000)),
        presale::recipient_share(CAROL, bps::new(4_000)),
    ]).end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidRaiseAllocation, location = blast_presale::blast_presale)]
/// A zero share is a raise-allocation error, not a token-allocation one.
fun a_raise_allocation_must_take_a_positive_share() {
    start_with_raise_allocations(
        vector[presale::recipient_share(RAISE_RECIPIENT, bps::new(0))],
    ).end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidRaiseAllocation, location = blast_presale::blast_presale)]
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
    fixture.set_time(END_MS);

    fixture.commit_open(ALICE, 0);

    fixture.end();
}

#[test]
/// The LP deadline only opens refunds; anyone may still migrate until someone cancels.
fun a_late_settled_sale_can_still_migrate_after_the_liquidity_deadline() {
    let mut fixture = start_sale(single_wallet_eligibility());
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
    let mut fixture = start_funded_sale();
    fixture.set_time(LIQUIDITY_DEADLINE_MS);
    fixture.cancel_unlaunched(KEEPER);

    fixture.migrate();

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::ELiquidityDeadlineNotReached, location = blast_presale::blast_presale)]
fun a_funded_sale_cannot_be_cancelled_before_the_liquidity_deadline() {
    let mut fixture = start_funded_sale();
    fixture.set_time(LIQUIDITY_DEADLINE_MS - 1);

    fixture.cancel_unlaunched(KEEPER);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EWrongMigrationWitness, location = blast_presale::blast_presale)]
fun another_migrator_cannot_release_escrow() {
    let mut fixture = start_funded_sale();

    fixture.next_tx!(KEEPER, |fixture| {
        let mut sale = fixture.take_presale();
        let (liquidity_tokens, quote) = sale.migrate(
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
}

#[test]
#[expected_failure(abort_code = presale::EWrongEligibilityPolicy, location = blast_presale::blast_presale)]
fun the_open_commit_function_rejects_an_allowlist_policy() {
    let alice_leaf = presale::allowlist_leaf_for_testing(0, ALICE, 500);
    let mut fixture = start_sale(presale::allowlisted_eligibility(alice_leaf, 1));

    fixture.commit_open(ALICE, 1);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EInvalidAssetPair, location = blast_presale::blast_presale)]
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
#[expected_failure(abort_code = presale::EInitialSupplyNotZero, location = blast_presale::blast_presale)]
fun treasury_cap_must_start_with_zero_supply() {
    let mut ctx = tx_context::dummy();
    let (mut treasury_cap, currency) = new_currency(&mut ctx);
    let existing_supply = treasury_cap.mint(1, &mut ctx);

    create_sale_with_treasury<QUOTE>(treasury_cap, currency, valid_sale_terms(), &mut ctx);

    existing_supply.burn_for_testing();
    destroy(ctx);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidTokenAllocation, location = blast_presale::blast_presale)]
fun configured_allocation_bps_cannot_exceed_full_supply() {
    let mut terms = valid_sale_terms();
    terms.token_allocation_bps = 10_000;
    terms.liquidity_token_allocation_bps = 1;

    create_sale<QUOTE>(terms);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidTokenAllocation, location = blast_presale::blast_presale)]
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

    fixture.set_time(END_MS);
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
    let (protocol_bps, protocol_quote, protocol_tokens) = only_event<
        PresaleCreated<BLAST_PRESALE_TESTS, QUOTE>,
    >().created_protocol_fields();
    assert_eq!(protocol_bps, vector[PROTOCOL_RAISE_BPS, PROTOCOL_TOKEN_BPS, 0, 0]);
    // 1,000 * [2,000, 333, 7,667] / 10,000 = [200, 33.3, 766.7]: the LP takes the leftover unit.
    assert_eq!(vector[protocol_quote, protocol_tokens], vector[33, PROTOCOL_TOKENS]);

    fixture.commit_open(ALICE, 1_000);
    fixture.commit_open(BOB, 3_000);
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);

    fixture
        .fee_policy
        .set_fees(
            &blast_acl::witness_for_testing<FeeAdmin>(),
            bps::new(0),
            bps::new(0),
            bps::new(0),
            bps::new(0),
        );
    fixture.fee_policy.set_destination(
        &blast_acl::witness_for_testing<TreasuryAdmin>(),
        NEW_TREASURY,
    );

    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, 767]);

    let (presale_id, destination, paid_quote, paid_tokens) = only_event<
        ProtocolFeesPaid<BLAST_PRESALE_TESTS, QUOTE>,
    >().protocol_fees_paid_fields();
    assert_eq!(presale_id, fixture.presale_id);
    assert_eq!(destination, NEW_TREASURY);
    assert_eq!(vector[paid_quote, paid_tokens], vector[33, PROTOCOL_TOKENS]);

    let (_, _, lp_quote, liquidity_tokens, recipient_tokens) = only_event<
        PresaleMigrated<BLAST_PRESALE_TESTS, QUOTE>,
    >().migrated_fields();
    assert_eq!(
        vector[lp_quote, liquidity_tokens, recipient_tokens],
        vector[767, LIQUIDITY_TOKENS, RECIPIENT_A_TOKENS + FEE_PAYING_RECIPIENT_B_TOKENS],
    );
    fixture.take_payout(NEW_TREASURY, PROTOCOL_TOKENS, 33);
    fixture.take_quote(RAISE_RECIPIENT, 200);

    assert_eq!(fixture.claim(KEEPER, ALICE), vector[1_000, 2_500, 750, 3_000]);
    assert_eq!(fixture.claim(KEEPER, BOB), vector[3_000, 7_501, 2_250, 0]);
    assert_eq!(fixture.custody(), vector[4_000, 0, 2, 0, 0, 0, 0, 0]);

    fixture.destroy_migrated_cap();
    fixture.end();
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
    fixture.set_time(END_MS);

    fixture.settle(KEEPER);

    assert_eq!(fixture.claim(KEEPER, ALICE), vector[500, 0, 500, 0]);
    fixture.take_quote(ALICE, 500);
    assert_eq!(
        fixture.custody(),
        vector[
            500,
            0,
            1,
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
#[expected_failure(abort_code = presale::EInvalidTokenAllocation, location = blast_presale::blast_presale)]
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
#[expected_failure(abort_code = presale::EInvalidRaiseAllocation, location = blast_presale::blast_presale)]
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
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);

    assert_eq!(fixture.migrate(), vector[LIQUIDITY_TOKENS, 700]);

    let schedules = event::events_by_type<VestingCreated>();
    assert_eq!(schedules.length(), 2);
    let raise_vesting_id = team_schedule_id<QUOTE>(&schedules[0], RAISE_RECIPIENT, 200);
    let token_vesting_id = team_schedule_id<BLAST_PRESALE_TESTS>(
        &schedules[1],
        RECIPIENT_A,
        RECIPIENT_A_TOKENS,
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
    fixture.next_tx!(RECIPIENT_B, |fixture| assert_eq!(
        fixture.scenario.take_from_sender<Coin<BLAST_PRESALE_TESTS>>().burn_for_testing(),
        RECIPIENT_B_TOKENS,
    ));
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
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);

    fixture.migrate();

    let allocations = event::events_by_type<RecipientAllocated<BLAST_PRESALE_TESTS, QUOTE>>();
    let (_, vested_recipient, vested_tokens) = allocations[0].recipient_allocated_fields();
    let (_, paid_recipient, paid_tokens) = allocations[1].recipient_allocated_fields();
    assert_eq!(vector[vested_recipient, paid_recipient], vector[RECIPIENT_A, RECIPIENT_B]);
    assert_eq!(vector[vested_tokens, paid_tokens], vector[RECIPIENT_A_TOKENS, RECIPIENT_B_TOKENS]);
    assert!(allocations[1].recipient_allocated_vesting_id().is_none());
    fixture.next_tx!(RECIPIENT_B, |fixture| assert_eq!(
        fixture.scenario.take_from_sender<Coin<BLAST_PRESALE_TESTS>>().burn_for_testing(),
        RECIPIENT_B_TOKENS,
    ));
    assert!(!test_scenario::has_most_recent_for_address<Coin<BLAST_PRESALE_TESTS>>(RECIPIENT_A));

    let vesting_id = allocations[0].recipient_allocated_vesting_id().destroy_some();
    fixture.claim_vesting<BLAST_PRESALE_TESTS>(vesting_id, END_MS + VESTING_CLIFF_MS);
    fixture.take_tokens(RECIPIENT_A, RECIPIENT_A_TOKENS / 2);
    fixture.claim_vesting<BLAST_PRESALE_TESTS>(vesting_id, END_MS + VESTING_DURATION_MS);
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
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);
    fixture.migrate();

    fixture.claim_vesting<BLAST_PRESALE_TESTS>(
        event::events_by_type<RecipientAllocated<BLAST_PRESALE_TESTS, QUOTE>>()[0]
            .recipient_allocated_vesting_id()
            .destroy_some(),
        END_MS + VESTING_CLIFF_MS - 1,
    );

    fixture.end();
}

#[test]
/// A vesting raise recipient's Quote is locked in a schedule from migration; the LP still takes
/// the rest of the raise.
fun vested_raise_allocations_lock_quote_in_a_schedule_from_migration() {
    let mut fixture = start_with_raise_allocations(
        vector[
            presale::vested_recipient_share(RAISE_RECIPIENT, bps::new(2_000), team_vesting_terms()),
        ],
    );
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(END_MS);
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
        END_MS + VESTING_DURATION_MS,
    );
    fixture.take_quote(RAISE_RECIPIENT, 200);

    fixture.destroy_migrated_cap();
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
#[expected_failure(abort_code = presale::EInvalidVestingTerms, location = blast_presale::blast_presale)]
fun vesting_terms_need_a_positive_period() {
    presale::vesting_terms(0, 0, 1);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidVestingTerms, location = blast_presale::blast_presale)]
fun vesting_terms_need_a_positive_period_count() {
    presale::vesting_terms(0, 1, 0);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidVestingTerms, location = blast_presale::blast_presale)]
fun vesting_terms_keep_the_cliff_within_the_duration() {
    presale::vesting_terms(VESTING_DURATION_MS + 1, VESTING_PERIOD_MS, VESTING_PERIODS);
}

#[test]
#[expected_failure(abort_code = presale::EInvalidVestingTerms, location = blast_presale::blast_presale)]
fun vesting_terms_stay_within_the_technical_bound() {
    presale::vesting_terms(0, MAX_VESTING_DURATION_MS / 2 + 1, 2);
}

// === Test Helpers ===

/// Starts a fee-free sale under `eligibility` with no raise allocations or uncapped phase.
fun start_sale(eligibility: EligibilityPolicy): Fixture {
    start_configured(
        vector[],
        eligibility,
        option::none(),
        false,
        0,
        0,
        RECIPIENT_B_BPS,
        option::none(),
    )
}

/// Starts the same sale as `start_sale`, but with its supply locked to burn-only.
fun start_burnable_sale(eligibility: EligibilityPolicy): Fixture {
    start_configured(
        vector[],
        eligibility,
        option::none(),
        true,
        0,
        0,
        RECIPIENT_B_BPS,
        option::none(),
    )
}

/// Starts a fee-free sale under `eligibility` whose window ends in `phase`.
fun start_with_uncapped_phase(eligibility: EligibilityPolicy, phase: UncappedPhase): Fixture {
    start_configured(
        vector[],
        eligibility,
        option::some(phase),
        false,
        0,
        0,
        RECIPIENT_B_BPS,
        option::none(),
    )
}

/// Starts a fee-free single-wallet sale that pays `raise_allocations` out of the raise.
fun start_with_raise_allocations(raise_allocations: vector<RecipientShare>): Fixture {
    start_configured(
        raise_allocations,
        single_wallet_eligibility(),
        option::none(),
        false,
        0,
        0,
        RECIPIENT_B_BPS,
        option::none(),
    )
}

/// Starts the same sale as `start_with_raise_allocations`, but with recipient A's tokens vesting
/// under `team_vesting_terms`.
fun start_with_team_vesting(raise_allocations: vector<RecipientShare>): Fixture {
    start_configured(
        raise_allocations,
        single_wallet_eligibility(),
        option::none(),
        false,
        0,
        0,
        RECIPIENT_B_BPS,
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
        raise_allocations,
        eligibility,
        option::none(),
        false,
        protocol_raise_bps,
        protocol_token_bps,
        recipient_b_bps,
        option::none(),
    )
}

/// Starts a single-wallet sale that Alice fills exactly and a keeper settles as funded at the
/// end of the window.
fun start_funded_sale(): Fixture {
    let mut fixture = start_sale(single_wallet_eligibility());
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);

    fixture
}

/// Creates and opens a `RAISE_TARGET` sale at `START_MS`, asserting its creation and opening
/// events, and hands the creator its cap. Recipient A's tokens vest under `recipient_a_vesting`.
fun start_configured(
    raise_allocations: vector<RecipientShare>,
    eligibility: EligibilityPolicy,
    uncapped: Option<UncappedPhase>,
    burnable: bool,
    protocol_raise_bps: u64,
    protocol_token_bps: u64,
    recipient_b_bps: u64,
    recipient_a_vesting: Option<VestingTerms>,
): Fixture {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(START_MS);
    let fee_policy = treasury_fee_policy(protocol_raise_bps, protocol_token_bps, scenario.ctx());
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
        vector[recipient_a_vesting, option::none()],
        raise_vesting,
    );
    assert_eq!(currency.is_supply_fixed(), !burnable);
    assert_eq!(currency.is_supply_burn_only(), burnable);
    assert_eq!(currency.total_supply().destroy_some(), TOKEN_SUPPLY);
    destroy(currency);

    presale.share(&clock);
    assert_opened_event(presale_id, if (uncapped.is_some()) UNCAPPED_FROM_MS else END_MS);
    transfer::public_transfer(cap, CREATOR);

    Fixture { scenario, clock, fee_policy, presale_id }
}

/// A fee policy paying `TREASURY`, charging the given raise and token rates and no LP-fee share.
fun treasury_fee_policy(
    protocol_raise_bps: u64,
    protocol_token_bps: u64,
    ctx: &mut TxContext,
): FeePolicy {
    let mut fee_policy = fee_policy::new_for_testing(ctx);
    fee_policy.set_destination(&blast_acl::witness_for_testing<TreasuryAdmin>(), TREASURY);
    if (protocol_raise_bps > 0 || protocol_token_bps > 0) fee_policy.set_fees(
        &blast_acl::witness_for_testing<FeeAdmin>(),
        bps::new(protocol_raise_bps),
        bps::new(protocol_token_bps),
        bps::new(0),
        bps::new(0),
    );

    fee_policy
}

/// Asserts the single `PresaleCreated` event records the fixture's objects and terms.
fun assert_created_event(
    presale_id: ID,
    cap_id: ID,
    treasury_cap_id: ID,
    eligibility: EligibilityPolicy,
    burnable: bool,
    recipient_b_bps: u64,
    recipient_vesting: vector<Option<VestingTerms>>,
    raise_vesting: vector<Option<VestingTerms>>,
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
        duration_ms,
        liquidity_window_ms,
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
            duration_ms,
            liquidity_window_ms,
        ],
        vector[
            TOKEN_SUPPLY,
            TOKEN_ALLOCATION_BPS,
            LIQUIDITY_TOKEN_ALLOCATION_BPS,
            RAISE_TARGET,
            DURATION_MS,
            LIQUIDITY_WINDOW_MS,
        ],
    );
    assert_eq!(created_eligibility, eligibility);

    let (
        migration_witness,
        tick_spacing,
        pool_fee_rate,
        fee_recipients,
        fee_recipient_bps,
        holder_rewards_bps,
    ) = created.created_migration_fields();
    assert_eq!(migration_witness, type_name::with_original_ids<TEST_MIGRATOR>());
    assert_eq!(tick_spacing, TICK_SPACING);
    assert_eq!(pool_fee_rate, POOL_FEE_RATE);
    assert_eq!(fee_recipients, vector[CREATOR, FEE_PARTNER]);
    assert_eq!(fee_recipient_bps, vector[CREATOR_FEE_BPS, FEE_PARTNER_BPS]);
    assert_eq!(holder_rewards_bps, HOLDER_REWARDS_BPS);

    let (recipients, recipient_bps, created_burnable) = created.created_supply_fields();
    assert_eq!(recipients, vector[RECIPIENT_A, RECIPIENT_B]);
    assert_eq!(recipient_bps, vector[RECIPIENT_A_BPS, recipient_b_bps]);
    assert_eq!(created_burnable, burnable);

    let (created_recipient_vesting, created_raise_vesting) = created.created_vesting_fields();
    assert_eq!(created_recipient_vesting, recipient_vesting);
    assert_eq!(created_raise_vesting, raise_vesting);
}

/// Asserts one `VestingCreated` event is an irrevocable `T` schedule paying `beneficiary`
/// `total_amount` under `team_vesting_terms` from the migration time, and returns its ID.
fun team_schedule_id<T>(created: &VestingCreated, beneficiary: address, total_amount: u64): ID {
    let (
        vesting_id,
        coin_type,
        created_beneficiary,
        refund_recipient,
        cancel_cap_id,
        created_total_amount,
        start_ms,
        cliff_ms,
        period_ms,
        periods,
    ) = created.vesting_created_fields();
    assert_eq!(coin_type, type_name::with_original_ids<T>());
    assert_eq!(created_beneficiary, beneficiary);
    assert!(refund_recipient.is_none());
    assert!(cancel_cap_id.is_none());
    assert_eq!(
        vector[created_total_amount, start_ms, cliff_ms, period_ms, periods],
        vector[total_amount, END_MS, VESTING_CLIFF_MS, VESTING_PERIOD_MS, VESTING_PERIODS],
    );

    vesting_id
}

/// Asserts the single `PresaleOpened` event fixes the fixture's window and uncapped start.
fun assert_opened_event(presale_id: ID, uncapped_from_ms: u64) {
    let (opened_presale_id, start_ms, end_ms, deadline_ms, opened_uncapped_from_ms) = only_event<
        PresaleOpened<BLAST_PRESALE_TESTS, QUOTE>,
    >().opened_fields();
    assert_eq!(opened_presale_id, presale_id);
    assert_eq!(
        vector[start_ms, end_ms, deadline_ms, opened_uncapped_from_ms],
        vector[START_MS, END_MS, LIQUIDITY_DEADLINE_MS, uncapped_from_ms],
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
        liquidity_token_allocation_bps: LIQUIDITY_TOKEN_ALLOCATION_BPS,
        recipient_allocations: recipient_allocations(),
        burnable: false,
        raise_target: RAISE_TARGET,
        raise_allocations: vector[],
        duration_ms: DURATION_MS,
        liquidity_window_ms: LIQUIDITY_WINDOW_MS,
        eligibility: single_wallet_eligibility(),
        uncapped: option::none(),
        fee_recipients: fee_recipients(),
        holder_rewards_bps: HOLDER_REWARDS_BPS,
    }
}

/// One wallet slot whose minimum is the whole raise, so a single commitment funds the sale.
fun single_wallet_eligibility(): EligibilityPolicy {
    presale::open_eligibility(WALLET_CAP, 1, RAISE_TARGET)
}

/// Calls `presale::new` with `terms` and the fixture's migrator, pool tier, and BPS wrappers.
fun new_presale<Quote>(
    treasury_cap: TreasuryCap<BLAST_PRESALE_TESTS>,
    currency: &mut Currency<BLAST_PRESALE_TESTS>,
    terms: SaleTerms,
    creation_policy: &CreationPolicy,
    fee_policy: &FeePolicy,
    ctx: &mut TxContext,
): (Presale<BLAST_PRESALE_TESTS, Quote>, PresaleCap) {
    let SaleTerms {
        token_supply,
        token_allocation_bps,
        liquidity_token_allocation_bps,
        recipient_allocations,
        burnable,
        raise_target,
        raise_allocations,
        duration_ms,
        liquidity_window_ms,
        eligibility,
        uncapped,
        fee_recipients,
        holder_rewards_bps,
    } = terms;

    presale::new<BLAST_PRESALE_TESTS, Quote, TEST_MIGRATOR>(
        treasury_cap,
        currency,
        token_supply,
        bps::new(token_allocation_bps),
        bps::new(liquidity_token_allocation_bps),
        recipient_allocations,
        burnable,
        raise_target,
        raise_allocations,
        duration_ms,
        liquidity_window_ms,
        eligibility,
        uncapped,
        TEST_MIGRATOR(),
        TICK_SPACING,
        POOL_FEE_RATE,
        fee_recipients,
        bps::new(holder_rewards_bps),
        creation_policy,
        fee_policy,
        ctx,
    )
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

fun create_with_windows(duration_ms: u64, liquidity_window_ms: u64) {
    let mut terms = valid_sale_terms();
    terms.duration_ms = duration_ms;
    terms.liquidity_window_ms = liquidity_window_ms;

    create_sale<QUOTE>(terms);
}

/// Creates a Bluefin sale under a creation policy that allows only `AllowedQuote` and
/// `AllowedWitness`.
fun create_bluefin_sale<AllowedQuote, AllowedWitness>(symbol: vector<u8>) {
    let mut ctx = tx_context::dummy();
    let (treasury_cap, mut currency) = new_currency_with_symbol(symbol, &mut ctx);
    let fee_policy = fee_policy::new_for_testing(&mut ctx);
    let creation_policy = creation_policy::allowing_for_testing<AllowedQuote, AllowedWitness>(
        &mut ctx,
    );

    let (sale, cap) = bluefin::new<BLAST_PRESALE_TESTS, QUOTE>(
        treasury_cap,
        &mut currency,
        TOKEN_SUPPLY,
        bps::new(TOKEN_ALLOCATION_BPS),
        bps::new(LIQUIDITY_TOKEN_ALLOCATION_BPS),
        recipient_allocations(),
        false,
        RAISE_TARGET,
        vector[],
        DURATION_MS,
        LIQUIDITY_WINDOW_MS,
        single_wallet_eligibility(),
        option::none(),
        fee_recipients(),
        bps::new(HOLDER_REWARDS_BPS),
        &creation_policy,
        &fee_policy,
        TICK_SPACING,
        POOL_FEE_RATE,
        &mut ctx,
    );

    destroy(sale);
    destroy(cap);
    destroy(currency);
    destroy(fee_policy);
    destroy(creation_policy);
    destroy(ctx);
}

fun new_currency(
    ctx: &mut TxContext,
): (TreasuryCap<BLAST_PRESALE_TESTS>, Currency<BLAST_PRESALE_TESTS>) {
    new_currency_with_symbol(b"SALE", ctx)
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
    presale::vesting_terms(VESTING_CLIFF_MS, VESTING_PERIOD_MS, VESTING_PERIODS)
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
    self.next_tx!(sender, |fixture| {
        let mut sale = fixture.take_presale();
        sale
            .commit_open(
                coin::mint_for_testing(amount, fixture.ctx!()),
                &fixture.clock,
                fixture.scenario.ctx(),
            )
            .destroy_zero();
        fixture.return_presale(sale);
    });

    self.committed_totals(amount)
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
    self.next_tx!(sender, |fixture| {
        let mut sale = fixture.take_presale();
        sale
            .commit_allowlisted(
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
    let mut change = vector[];
    self.next_tx!(sender, |fixture| {
        let mut sale = fixture.take_presale();
        change.push_back(
            sale
                .commit_open(
                    coin::mint_for_testing(amount, fixture.ctx!()),
                    &fixture.clock,
                    fixture.scenario.ctx(),
                )
                .burn_for_testing(),
        );
        fixture.return_presale(sale);
    });
    let (_, accepted, _, _, _) = only_event<
        Committed<BLAST_PRESALE_TESTS, QUOTE>,
    >().committed_fields();

    vector[accepted, change[0]]
}

/// Commits through the open-to-anyone uncapped route and returns `[accepted, change]`.
fun commit_uncapped(self: &mut Fixture, sender: address, amount: u64): vector<u64> {
    let mut change = vector[];
    self.next_tx!(sender, |fixture| {
        let mut sale = fixture.take_presale();
        change.push_back(
            sale
                .commit_uncapped(
                    coin::mint_for_testing(amount, fixture.ctx!()),
                    &fixture.clock,
                    fixture.scenario.ctx(),
                )
                .burn_for_testing(),
        );
        fixture.return_presale(sale);
    });
    let (_, accepted, _, _, _) = only_event<
        Committed<BLAST_PRESALE_TESTS, QUOTE>,
    >().committed_fields();

    vector[accepted, change[0]]
}

fun settle(self: &mut Fixture, sender: address) {
    self.next_tx!(sender, |fixture| {
        let mut sale = fixture.take_presale();
        sale.settle(&fixture.clock);
        fixture.return_presale(sale);
    });
}

/// Migrates with the allowed witness and returns the released `[liquidity_tokens, quote]`.
fun migrate(self: &mut Fixture): vector<u64> {
    let mut released = vector[];
    self.next_tx!(KEEPER, |fixture| {
        let mut sale = fixture.take_presale();
        let (liquidity_tokens, quote) = sale.migrate(
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
    self.next_tx!(CREATOR, |fixture| destroy(fixture.scenario.take_from_sender<PresaleCap>()));
}

fun cancel_unlaunched(self: &mut Fixture, sender: address) {
    self.next_tx!(sender, |fixture| {
        let mut sale = fixture.take_presale();
        sale.cancel_unlaunched(&fixture.clock);
        fixture.return_presale(sale);
    });
}

/// Claims for `participant` and returns `[commitment, tokens, quote_refund, remaining]`.
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
        assert_eq!(
            fixture.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(),
            quote,
        );
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

/// Returns `[total_commitments, remaining_commitments, participants, quote, sale_tokens,
/// liquidity_tokens, recipient_tokens, protocol_tokens]`.
fun custody(self: &mut Fixture): vector<u64> {
    let mut balances = vector[];
    self.next_tx!(KEEPER, |fixture| {
        let sale = fixture.take_presale();
        let (
            total_commitments,
            remaining_commitments,
            participants,
            quote,
            sale_tokens,
            liquidity_tokens,
            recipient_tokens,
            protocol_tokens,
        ) = sale.custody_for_testing();
        balances.append(vector[
            total_commitments,
            remaining_commitments,
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

// === Imports ===

use blast_presale::{bluefin, cetus, migration_math, blast_presale::{
    Self as presale,
    Claimed,
    Committed,
    EligibilityPolicy,
    RaiseAllocated,
    RecipientAllocated,
    Presale,
    PresaleCancelled,
    PresaleCap,
    PresaleCreated,
    PresaleFunded,
    PresaleMigrated,
    PresaleOpened,
    RecipientShare,
    UncappedPhase,
    VestingTerms,
}};

use blast_admin::blast_acl;

use blast_fun_vesting::blast_fun_linear_vesting::{Vesting, VestingCreated};

use blast_presale::{
    blast_presale::ProtocolFeesPaid,
    blast_presale_domain::{FeeAdmin, TreasuryAdmin},
    bps,
    creation_policy::{Self, CreationPolicy},
    fee_policy::{Self, FeePolicy},
};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin, TreasuryCap},
    coin_registry::{Self, Currency},
    event,
    test_scenario::{Self, Scenario},
    test_utils,
};
