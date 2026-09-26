// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::tranche_tests;

// === Constants ===

const ALICE: address = @0xA11CE;

const BOB: address = @0xB0B;

const CAROL: address = @0xCA201;

const DAVE: address = @0xDA4E;

/// Tokens a tranche sells in these tests.
const TOKENS: u64 = 1_000;

/// Quote those tokens cost in total.
const QUOTE: u64 = 300;

// === Tests ===

// --- Construction ---

#[test]
fun a_new_tranche_has_accepted_nothing() {
    let tranche = public_tranche(tranche::first_come(), 0);

    assert_eq!(tranche.tokens(), TOKENS);
    assert_eq!(tranche.quote(), QUOTE);
    assert_eq!(tranche.committed(), 0);
    assert!(!tranche.is_whitelisted());
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidTranche, location = blast_presale::tranche)]
fun a_tranche_selling_no_tokens_is_rejected() {
    tranche::new(0, QUOTE, 0, 10, tranche::first_come(), tranche::public_access(0), 0);
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidTranche, location = blast_presale::tranche)]
fun a_tranche_raising_no_quote_is_rejected() {
    tranche::new(TOKENS, 0, 0, 10, tranche::first_come(), tranche::public_access(0), 0);
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidTranche, location = blast_presale::tranche)]
fun a_tranche_ending_at_its_start_is_rejected() {
    tranche::new(TOKENS, QUOTE, 10, 10, tranche::first_come(), tranche::public_access(0), 0);
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidWhitelist, location = blast_presale::tranche)]
fun a_whitelist_root_that_is_not_a_digest_is_rejected() {
    tranche::whitelisted(vector[1, 2, 3], 2);
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidWhitelist, location = blast_presale::tranche)]
fun a_whitelist_without_leaves_is_rejected() {
    tranche::whitelisted(merkle::leaf(0, ALICE, 0), 0);
}

#[test]
fun a_public_tranche_caps_by_its_wallet_cap_and_lists_nobody() {
    let (root, proofs) = four_leaf_tree();
    let access = tranche::public_access(50);
    let capped = tranche::new(TOKENS, QUOTE, 0, 10, tranche::pro_rata(), access, 0);
    let listed = whitelisted_tranche(root, 4);

    assert_eq!(capped.wallet_cap(), 50);
    assert!(!capped.is_listed(0, ALICE, 100, &proofs[0]));
    assert!(listed.is_whitelisted());
    assert_eq!(listed.wallet_cap(), 0);
}

#[test]
fun a_tranche_is_open_from_its_start_until_its_end() {
    let first_come = tranche::first_come();
    let tranche = tranche::new(TOKENS, QUOTE, 100, 200, first_come, tranche::public_access(0), 0);

    assert!(!tranche.is_open(99));
    assert!(tranche.is_open(100));
    assert!(tranche.is_open(199));
    assert!(!tranche.is_open(200));
}

// --- Filling ---

#[test]
fun first_come_fills_up_to_its_quote() {
    let mut tranche = public_tranche(tranche::first_come(), 0);

    assert_eq!(tranche.accept(200, 0, 0), 200);
    assert_eq!(tranche.accept(200, 0, 0), 100);
    assert_eq!(tranche.committed(), QUOTE);
    assert_eq!(tranche.raised(), QUOTE);
    assert_eq!(tranche.sold_down(), TOKENS);
}

#[test, expected_failure(abort_code = blast_presale::errors::ETrancheSoldOut, location = blast_presale::tranche)]
fun a_sold_out_first_come_tranche_rejects_more() {
    let mut tranche = public_tranche(tranche::first_come(), 0);
    tranche.accept(QUOTE, 0, 0);

    tranche.accept(1, 0, 0);
}

#[test]
fun pro_rata_accepts_past_its_quote() {
    let mut tranche = public_tranche(tranche::pro_rata(), 0);

    assert_eq!(tranche.accept(250, 0, 0), 250);
    assert_eq!(tranche.accept(250, 0, 0), 250);
    assert_eq!(tranche.committed(), 500);
    assert_eq!(tranche.raised(), QUOTE);
    assert_eq!(tranche.sold_down(), TOKENS);
}

#[test]
fun a_cap_clamps_a_commit_to_what_the_address_has_left() {
    let mut tranche = public_tranche(tranche::pro_rata(), 0);

    assert_eq!(tranche.accept(50, 0, 30), 30);
    assert_eq!(tranche.accept(50, 20, 30), 10);
    assert_eq!(tranche.committed(), 40);
}

#[test, expected_failure(abort_code = blast_presale::errors::EWalletCapReached, location = blast_presale::tranche)]
fun an_address_at_its_cap_is_rejected() {
    let mut tranche = public_tranche(tranche::pro_rata(), 0);

    tranche.accept(1, 30, 30);
}

#[test]
fun a_commit_buying_one_token_atom_is_accepted() {
    let mut tranche = one_atom_tranche(tranche::first_come());

    assert_eq!(tranche.accept(1_000, 0, 0), 1_000);
}

#[test, expected_failure(abort_code = blast_presale::errors::EZeroPurchase, location = blast_presale::tranche)]
fun a_commit_buying_less_than_one_token_atom_is_rejected() {
    let mut tranche = one_atom_tranche(tranche::first_come());

    tranche.accept(999, 0, 0);
}

#[test, expected_failure(abort_code = blast_presale::errors::EZeroPurchase, location = blast_presale::tranche)]
fun a_commit_clamped_below_one_token_atom_is_rejected() {
    let mut tranche = one_atom_tranche(tranche::pro_rata());

    tranche.accept(5_000, 0, 999);
}

#[test, expected_failure(abort_code = blast_presale::errors::ETrancheSoldOut, location = blast_presale::tranche)]
fun sold_out_precedes_a_reached_cap() {
    let mut tranche = public_tranche(tranche::first_come(), 0);
    tranche.accept(QUOTE, 0, 0);

    tranche.accept(1, 30, 30);
}

// --- Settlement ---

#[test]
fun an_undersubscribed_tranche_sells_at_its_price_and_refunds_nothing() {
    let mut tranche = public_tranche(tranche::pro_rata(), 0);
    tranche.accept(100, 0, 0);

    assert_eq!(tranche.raised(), 100);
    assert_eq!(tranche.sold_down(), 333);
    let (tokens, refund) = tranche.owed_down(10);
    assert_eq!(tokens, 33);
    assert_eq!(refund, 0);
}

#[test]
fun an_oversubscribed_tranche_fills_each_commit_in_the_same_proportion() {
    let mut tranche = public_tranche(tranche::pro_rata(), 0);
    tranche.accept(450, 0, 0);

    let (tokens, refund) = tranche.owed_down(150);
    assert_eq!(tokens, 333);
    assert_eq!(refund, 50);
}

#[test]
fun claims_never_exceed_what_the_tranche_holds() {
    let commits = vector[1, 7, 13, 99, 250, 3, 64, 41, 500, 2];
    let mut undersubscribed = public_tranche(tranche::pro_rata(), 0);
    let mut oversubscribed = public_tranche(tranche::pro_rata(), 0);
    commits.take(4).do!(|amount| {
        undersubscribed.accept(amount, 0, 0);
    });
    commits.do!(|amount| {
        oversubscribed.accept(amount, 0, 0);
    });

    let (mut tokens, mut refunds) = (0, 0);
    commits.take(4).do!(|amount| {
        let (owed, refund) = undersubscribed.owed_down(amount);
        tokens = tokens + owed;
        refunds = refunds + refund;
    });
    assert!(tokens <= undersubscribed.sold_down());
    assert!(undersubscribed.sold_down() - tokens < 4);
    assert_eq!(refunds, 0);

    let (mut tokens, mut refunds) = (0, 0);
    commits.do!(|amount| {
        let (owed, refund) = oversubscribed.owed_down(amount);
        tokens = tokens + owed;
        refunds = refunds + refund;
    });
    let excess = oversubscribed.committed() - oversubscribed.raised();
    assert!(tokens <= TOKENS && TOKENS - tokens < commits.length());
    assert!(refunds <= excess && excess - refunds < commits.length());
}

// --- Vesting ---

#[test]
fun without_vesting_every_token_is_claimable_from_the_claim_time() {
    let tranche = public_tranche(tranche::first_come(), 0);

    assert_eq!(tranche.vested_down(TOKENS, 1_000, 999), 0);
    assert_eq!(tranche.vested_down(TOKENS, 1_000, 1_000), TOKENS);
}

#[test]
fun vesting_releases_linearly_from_the_claim_time() {
    let tranche = public_tranche(tranche::first_come(), 3_000);

    assert_eq!(tranche.vested_down(TOKENS, 1_000, 999), 0);
    assert_eq!(tranche.vested_down(TOKENS, 1_000, 1_000), 0);
    assert_eq!(tranche.vested_down(TOKENS, 1_000, 2_000), 333);
    assert_eq!(tranche.vested_down(TOKENS, 1_000, 3_999), 999);
    assert_eq!(tranche.vested_down(TOKENS, 1_000, 4_000), TOKENS);
    assert_eq!(tranche.vested_down(TOKENS, 1_000, 9_000), TOKENS);
}

// --- Whitelist ---

#[test]
fun a_listed_address_proves_its_leaf() {
    let (root, proofs) = four_leaf_tree();
    let tranche = whitelisted_tranche(root, 4);

    assert!(tranche.is_listed(0, ALICE, 100, &proofs[0]));
    assert!(tranche.is_listed(1, BOB, 0, &proofs[1]));
    assert!(tranche.is_listed(2, CAROL, 250, &proofs[2]));
    assert!(tranche.is_listed(3, DAVE, 1, &proofs[3]));
}

#[test]
fun a_proof_does_not_verify_for_another_address_limit_or_position() {
    let (root, proofs) = four_leaf_tree();
    let tranche = whitelisted_tranche(root, 4);

    assert!(!tranche.is_listed(0, BOB, 100, &proofs[0]));
    assert!(!tranche.is_listed(0, ALICE, 101, &proofs[0]));
    assert!(!tranche.is_listed(1, ALICE, 100, &proofs[0]));
    assert!(!tranche.is_listed(4, ALICE, 100, &proofs[0]));
    assert!(!tranche.is_listed(0, ALICE, 100, &vector[proofs[0][0]]));
}

#[test]
fun a_one_leaf_whitelist_is_its_own_root_with_an_empty_proof() {
    let leaf = merkle::leaf(0, ALICE, 100);
    let tranche = whitelisted_tranche(leaf, 1);

    assert!(tranche.is_listed(0, ALICE, 100, &vector[]));
    assert!(!tranche.is_listed(0, ALICE, 100, &vector[leaf]));
}

#[test]
fun an_odd_level_pairs_its_last_node_with_itself() {
    let leaves = vector[
        merkle::leaf(0, ALICE, 100),
        merkle::leaf(1, BOB, 0),
        merkle::leaf(2, CAROL, 250),
    ];
    let left = merkle::node_for_testing(leaves[0], leaves[1]);
    let right = merkle::node_for_testing(leaves[2], leaves[2]);
    let tranche = whitelisted_tranche(merkle::node_for_testing(left, right), 3);

    assert!(tranche.is_listed(0, ALICE, 100, &vector[leaves[1], right]));
    assert!(tranche.is_listed(2, CAROL, 250, &vector[leaves[2], left]));
    assert!(!tranche.is_listed(3, CAROL, 250, &vector[leaves[2], left]));
}

#[test]
fun a_proof_with_a_malformed_sibling_is_rejected() {
    let (root, proofs) = four_leaf_tree();
    let tranche = whitelisted_tranche(root, 4);
    let mut short = proofs[0][0];
    short.pop_back();

    assert!(!tranche.is_listed(0, ALICE, 100, &vector[short, proofs[0][1]]));
}

// === Test Helpers ===

fun public_tranche(allocation: Allocation, vesting_ms: u64): Tranche {
    tranche::new(TOKENS, QUOTE, 0, 10, allocation, tranche::public_access(0), vesting_ms)
}

/// One token atom for 1,000 Quote.
fun one_atom_tranche(allocation: Allocation): Tranche {
    tranche::new(1, 1_000, 0, 10, allocation, tranche::public_access(0), 0)
}

fun whitelisted_tranche(root: vector<u8>, leaves: u64): Tranche {
    let access = tranche::whitelisted(root, leaves);

    tranche::new(TOKENS, QUOTE, 0, 10, tranche::first_come(), access, 0)
}

/// A whitelist of Alice (100), Bob (no limit), Carol (250), and Dave (1), and each leaf's proof.
fun four_leaf_tree(): (vector<u8>, vector<vector<vector<u8>>>) {
    let leaves = vector[
        merkle::leaf(0, ALICE, 100),
        merkle::leaf(1, BOB, 0),
        merkle::leaf(2, CAROL, 250),
        merkle::leaf(3, DAVE, 1),
    ];
    let left = merkle::node_for_testing(leaves[0], leaves[1]);
    let right = merkle::node_for_testing(leaves[2], leaves[3]);
    let proofs = vector[
        vector[leaves[1], right],
        vector[leaves[0], right],
        vector[leaves[3], left],
        vector[leaves[2], left],
    ];

    (merkle::node_for_testing(left, right), proofs)
}

// === Imports ===

use blast_presale::{merkle, tranche::{Self, Allocation, Tranche}};

use std::unit_test::assert_eq;
