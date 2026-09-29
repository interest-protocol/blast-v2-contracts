// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::blast_presale_tests;

// === Constants ===

const CREATOR: address = @0xC0FFEE;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const KEEPER: address = @0x4EE9;

const START_MS: u64 = 1_000;
const DURATION_MS: u64 = 100;
const END_MS: u64 = START_MS + DURATION_MS;
const LIQUIDITY_WINDOW_MS: u64 = 50;
const LIQUIDITY_DEADLINE_MS: u64 = END_MS + LIQUIDITY_WINDOW_MS;

const RAISE_TARGET: u64 = 1_000;
const TOKEN_ALLOCATION: u64 = 10_000;
const LIQUIDITY_TOKENS: u64 = 2_000;
const WALLET_CAP: u64 = 5_000;

// === Test-Only Types ===

public struct SALE_TOKEN() has drop;
public struct QUOTE() has drop;

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
        PresaleFunded<SALE_TOKEN, QUOTE>,
    >().funded_fields();
    assert_eq!(presale_id, fixture.presale_id);
    assert_eq!(vector[commitments, accepted, refundable, tokens], vector[4_000, 1_000, 3_000, 10_000]);
    assert!(fixture.is_funded());

    assert_eq!(fixture.launch(), vector[LIQUIDITY_TOKENS, RAISE_TARGET]);
    let (presale_id, quote, liquidity_tokens) = only_event<
        PresaleLaunched<SALE_TOKEN, QUOTE>,
    >().launched_fields();
    assert_eq!(presale_id, fixture.presale_id);
    assert_eq!(vector[quote, liquidity_tokens], vector[RAISE_TARGET, LIQUIDITY_TOKENS]);

    assert_eq!(fixture.claim(KEEPER, ALICE), vector[1_000, 2_500, 750, 3_000]);
    fixture.take_payout(ALICE, 2_500, 750);
    assert_eq!(fixture.claim(KEEPER, BOB), vector[3_000, 7_500, 2_250, 0]);
    fixture.take_payout(BOB, 7_500, 2_250);
    assert_eq!(fixture.custody(), vector[4_000, 0, 2, 0, 0, 0]);

    fixture.destroy_cap();
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
        vector[400, 400, 1, 400, TOKEN_ALLOCATION, LIQUIDITY_TOKENS],
    );
    fixture.commit_open(ALICE, 100);
    assert_eq!(
        fixture.custody(),
        vector[500, 500, 1, 500, TOKEN_ALLOCATION, LIQUIDITY_TOKENS],
    );

    fixture.set_time(END_MS);
    fixture.settle(KEEPER);
    fixture.claim(KEEPER, ALICE);
    fixture.take_quote(ALICE, 500);
    fixture.reclaim_and_destroy_cap();
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
fun underfunded_sale_refunds_every_commitment_and_returns_creator_tokens() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 2),
    );
    fixture.commit_open(ALICE, 500);
    fixture.set_time(END_MS);

    fixture.settle(KEEPER);

    let (presale_id, commitments, refundable) = only_event<
        PresaleCancelled<SALE_TOKEN, QUOTE>,
    >().cancelled_fields();
    assert_eq!(presale_id, fixture.presale_id);
    assert_eq!(vector[commitments, refundable], vector[500, 500]);
    assert!(fixture.is_cancelled());
    assert_eq!(fixture.claim(KEEPER, ALICE), vector[500, 0, 500, 0]);
    fixture.take_quote(ALICE, 500);
    assert_eq!(fixture.reclaim_and_destroy_cap(), vector[TOKEN_ALLOCATION, LIQUIDITY_TOKENS]);
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
    fixture.reclaim_and_destroy_cap();
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
    fixture.reclaim_and_destroy_cap();
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
#[expected_failure(abort_code = presale::ELiquidityDeadlinePassed, location = blast_presale::blast_presale)]
fun launch_at_the_exact_liquidity_deadline_is_rejected() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 1),
    );
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);
    fixture.set_time(LIQUIDITY_DEADLINE_MS);

    fixture.launch();
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EWrongPresaleCap, location = blast_presale::blast_presale)]
fun another_presales_cap_cannot_release_escrow() {
    let mut fixture = start(
        RAISE_TARGET,
        presale::open_eligibility(WALLET_CAP, 1),
    );
    fixture.commit_open(ALICE, RAISE_TARGET);
    fixture.set_time(END_MS);
    fixture.settle(KEEPER);

    fixture.next_tx!(CREATOR, |fixture| {
        let (other, other_cap) = presale::new<SALE_TOKEN, QUOTE>(
            coin::mint_for_testing(TOKEN_ALLOCATION, fixture.ctx!()),
            coin::mint_for_testing(LIQUIDITY_TOKENS, fixture.ctx!()),
            RAISE_TARGET,
            DURATION_MS,
            LIQUIDITY_WINDOW_MS,
            presale::open_eligibility(WALLET_CAP, 1),
            fixture.ctx!(),
        );
        other.share(&fixture.clock);
        let mut sale = fixture.take_presale();
        let (liquidity_tokens, quote) = sale.launch(&other_cap, &fixture.clock, fixture.ctx!());
        liquidity_tokens.burn_for_testing();
        quote.burn_for_testing();
        fixture.return_presale(sale);
        transfer::public_transfer(other_cap, CREATOR);
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

    let (sale, cap) = presale::new<QUOTE, QUOTE>(
        coin::mint_for_testing(1, &mut ctx),
        coin::mint_for_testing(1, &mut ctx),
        1,
        1,
        1,
        policy,
        &mut ctx,
    );
    sale.share(&clock);
    transfer::public_transfer(cap, CREATOR);
    clock.destroy_for_testing();
    destroy(ctx);
}

// === Test Helpers ===

fun start(raise_target: u64, eligibility: EligibilityPolicy): Fixture {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(START_MS);
    let (presale, cap) = presale::new<SALE_TOKEN, QUOTE>(
        coin::mint_for_testing(TOKEN_ALLOCATION, scenario.ctx()),
        coin::mint_for_testing(LIQUIDITY_TOKENS, scenario.ctx()),
        raise_target,
        DURATION_MS,
        LIQUIDITY_WINDOW_MS,
        eligibility,
        scenario.ctx(),
    );
    let presale_id = object::id(&presale);
    let cap_id = object::id(&cap);
    let (
        created_id,
        created_cap_id,
        created_raise,
        created_tokens,
        created_liquidity_tokens,
        created_duration,
        created_liquidity_window,
        created_eligibility,
    ) = only_event<PresaleCreated<SALE_TOKEN, QUOTE>>().created_fields();
    assert_eq!(created_id, presale_id);
    assert_eq!(created_cap_id, cap_id);
    assert_eq!(
        vector[
            created_raise,
            created_tokens,
            created_liquidity_tokens,
            created_duration,
            created_liquidity_window,
        ],
        vector[
            raise_target,
            TOKEN_ALLOCATION,
            LIQUIDITY_TOKENS,
            DURATION_MS,
            LIQUIDITY_WINDOW_MS,
        ],
    );
    assert_eq!(created_eligibility, eligibility);
    presale.share(&clock);
    let (opened_id, start_ms, end_ms, deadline_ms) = only_event<
        PresaleOpened<SALE_TOKEN, QUOTE>,
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

fun take_presale(self: &Fixture): Presale<SALE_TOKEN, QUOTE> {
    self.scenario.take_shared_by_id(self.presale_id)
}

fun return_presale(_self: &Fixture, presale: Presale<SALE_TOKEN, QUOTE>) {
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
        Committed<SALE_TOKEN, QUOTE>,
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
        Committed<SALE_TOKEN, QUOTE>,
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

fun launch(self: &mut Fixture): vector<u64> {
    let mut amounts = vector[];
    self.next_tx!(CREATOR, |fixture| {
        let cap = fixture.scenario.take_from_sender<PresaleCap>();
        let mut sale = fixture.take_presale();
        let (liquidity_tokens, quote) = sale.launch(&cap, &fixture.clock, fixture.ctx!());
        amounts.push_back(liquidity_tokens.burn_for_testing());
        amounts.push_back(quote.burn_for_testing());
        fixture.return_presale(sale);
        transfer::public_transfer(cap, CREATOR);
    });
    amounts
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
        Claimed<SALE_TOKEN, QUOTE>,
    >().claim_fields();
    assert_eq!(presale_id, self.presale_id);
    assert_eq!(delivered_to, participant);

    vector[commitment, tokens, quote_refund, remaining]
}

fun take_payout(self: &mut Fixture, participant: address, tokens: u64, quote: u64) {
    self.next_tx!(participant, |fixture| {
        assert_eq!(
            fixture.scenario.take_from_sender<Coin<SALE_TOKEN>>().burn_for_testing(),
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

fun reclaim_and_destroy_cap(self: &mut Fixture): vector<u64> {
    let mut amounts = vector[];
    self.next_tx!(CREATOR, |fixture| {
        let cap = fixture.scenario.take_from_sender<PresaleCap>();
        let mut sale = fixture.take_presale();
        let (sale_tokens, liquidity_tokens) = sale.reclaim_cancelled_tokens(&cap, fixture.ctx!());
        amounts.push_back(sale_tokens.burn_for_testing());
        amounts.push_back(liquidity_tokens.burn_for_testing());
        let (presale_id, reclaimed_sale, reclaimed_liquidity) = only_event<
            CancelledTokensReclaimed<SALE_TOKEN, QUOTE>,
        >().reclaimed_fields();
        assert_eq!(presale_id, fixture.presale_id);
        assert_eq!(vector[reclaimed_sale, reclaimed_liquidity], amounts);
        sale.destroy_cap(cap);
        fixture.return_presale(sale);
    });
    amounts
}

fun destroy_cap(self: &mut Fixture) {
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
        let (total, remaining, participants, quote, sale_tokens, liquidity_tokens) = sale.custody_for_testing();
        values.append(vector[total, remaining, participants, quote, sale_tokens, liquidity_tokens]);
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

use blast_presale::blast_presale::{
    Self as presale,
    CancelledTokensReclaimed,
    Claimed,
    Committed,
    EligibilityPolicy,
    Presale,
    PresaleCancelled,
    PresaleCap,
    PresaleCreated,
    PresaleFunded,
    PresaleLaunched,
    PresaleOpened,
};

use std::unit_test::{assert_eq, destroy};

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    event,
    test_scenario::{Self, Scenario},
};
