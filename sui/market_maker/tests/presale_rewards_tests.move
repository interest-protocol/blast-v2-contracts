// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_market_maker::presale_rewards_tests;

// === Constants ===

const ROOT: address = @0xA;
const BUYER: address = @0xB;
const RELAYER: address = @0xC;

// === Test-Only Types ===

public struct MEME has drop {}
public struct QUOTE has drop {}
public struct RewardFixture {
    scenario: Scenario,
    root: SuperAdminCap,
    acl: ACL,
    admin: AdminCap,
    vault: BlastMarketMakerVault<MEME, QUOTE>,
    version: PackageVersion,
    creator: BlastMarketMakerCreatorCap,
    treasury: BlastMarketMakerTreasury,
    policy: BlastMarketMakerFeePolicy,
}

public struct PublishedPayload has copy, drop {
    vault_id: ID,
    round_id: ID,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    root: vector<u8>,
    manifest_digest: vector<u8>,
    leaf_count: u64,
    meme_amount: u64,
    quote_amount: u64,
    meme_unallocated: u64,
    quote_unallocated: u64,
}
public struct PaidPayload has copy, drop {
    round_id: ID,
    index: u64,
    beneficiary: address,
    meme_amount: u64,
    quote_amount: u64,
    meme_remaining: u64,
    quote_remaining: u64,
}

// === Tests ===

#[test]
fun relayer_pays_the_committed_buyer_while_vault_is_paused_and_creator_has_left() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 10, 20);
    let round_id = f.publish(0, 10, 20, root, 1, 30, 40);
    let expected = PublishedPayload {
        vault_id: object::id(&f.vault), round_id, number: 0,
        start_checkpoint: 10, end_checkpoint: 20, root,
        manifest_digest: vector::tabulate!(32, |_| 9), leaf_count: 1,
        meme_amount: 30, quote_amount: 40, meme_unallocated: 70, quote_unallocated: 160,
    };
    assert_eq!(std::bcs::to_bytes(&f.last_publication()), std::bcs::to_bytes(&expected));
    f.pause_and_withdraw_capital();
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 0, BUYER, 10, 20, vector[]);
        let paid = sui::event::events_by_type<rewards::BlastPresaleRewardPaid<MEME, QUOTE>>();
        let expected = PaidPayload {
            round_id, index: 0, beneficiary: BUYER, meme_amount: 10, quote_amount: 20,
            meme_remaining: 20, quote_remaining: 20,
        };
        assert_eq!(paid.length(), 1);
        assert_eq!(std::bcs::to_bytes(&paid[0]), std::bcs::to_bytes(&expected));
        f.assert_round_balances(&round, 20, 20);
        f.return_round(round);
        assert!(!f.has_sender_coin<MEME>());
        assert!(!f.has_sender_coin<QUOTE>());
    });
    f.next_tx!(BUYER, |f| { f.assert_payment(10, 20); });
    f.assert_reserves(70, 160);
    f.end();
}

#[test]
fun epochs_allow_skipped_intervals_and_keep_old_claims_independently_funded() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 2);
    let first = f.publish(0, 10, 20, root, 1, 1, 2);
    let root = f.leaf(1, 0, BUYER, 3, 4);
    let second = f.publish(1, 30, 40, root, 1, 3, 4);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(second);
        f.claim(&mut round, 0, BUYER, 3, 4, vector[]);
        f.assert_round_balances(&round, 0, 0);
        f.return_round(round);
        let mut round = f.take_round(first);
        f.claim(&mut round, 0, BUYER, 1, 2, vector[]);
        f.assert_round_balances(&round, 0, 0);
        f.return_round(round);
    });
    f.assert_reserves(96, 194);
    f.end();
}

#[test]
fun creator_cannot_reinvest_or_keep_reserved_fees_and_capital_withdrawals_preserve_them() {
    let mut f = start();
    f.pause_and_withdraw_capital();
    f.assert_reserves(100, 200);
    let root = f.leaf(0, 0, BUYER, 100, 200);
    let round_id = f.publish(0, 0, 1, root, 1, 100, 200);
    f.assert_reserves(0, 0);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 0, BUYER, 100, 200, vector[]);
        f.assert_round_balances(&round, 0, 0);
        f.return_round(round);
    });
    f.next_tx!(BUYER, |f| { f.assert_payment(100, 200); });
    f.end();
}

#[test]
fun a_maximum_size_bitmap_accepts_the_last_leaf_with_a_bounded_proof() {
    let mut f = start();
    let mut root = f.leaf(0, 65_535, BUYER, 1, 1);
    let sibling = vector::tabulate!(32, |_| 0);
    let proof = vector::tabulate!(16, |_| sibling);
    proof.do_ref!(|item| { root = rewards::node_for_testing(*item, root); });
    let round_id = f.publish(0, 0, 1, root, 65_536, 1, 1);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 65_535, BUYER, 1, 1, proof);
        f.assert_round_balances(&round, 0, 0);
        f.return_round(round);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = market_maker::EInvalidRewardInterval, location = blast_market_maker::market_maker)]
fun publication_rejects_empty_interval() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let _ = f.publish(0, 10, 10, root, 1, 1, 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = market_maker::EInvalidRewardInterval, location = blast_market_maker::market_maker)]
fun publication_rejects_reversed_interval() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let _ = f.publish(0, 11, 10, root, 1, 1, 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = market_maker::EInvalidRewardInterval, location = blast_market_maker::market_maker)]
fun publication_rejects_overlapping_interval() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let _ = f.publish(0, 10, 20, root, 1, 1, 1);
    let root = f.leaf(1, 0, BUYER, 1, 1);
    let _ = f.publish(1, 19, 30, root, 1, 1, 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = market_maker::EWrongRewardRound, location = blast_market_maker::market_maker)]
fun publication_rejects_duplicate_round() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let _ = f.publish(0, 10, 20, root, 1, 1, 1);
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let _ = f.publish(0, 20, 30, root, 1, 1, 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = market_maker::EWrongRewardRound, location = blast_market_maker::market_maker)]
fun publication_rejects_skipped_round_number() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let _ = f.publish(0, 10, 20, root, 1, 1, 1);
    let root = f.leaf(2, 0, BUYER, 1, 1);
    let _ = f.publish(2, 20, 30, root, 1, 1, 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidLeafCount, location = blast_market_maker::presale_rewards)]
fun publication_rejects_zero_leaves() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let _ = f.publish(0, 0, 1, root, 0, 1, 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidLeafCount, location = blast_market_maker::presale_rewards)]
fun publication_rejects_too_many_leaves() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let _ = f.publish(0, 0, 1, root, 65537, 1, 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EEmptyBudget, location = blast_market_maker::presale_rewards)]
fun publication_rejects_empty_budget() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let _ = f.publish(0, 0, 1, root, 1, 0, 0);
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidCommitment, location = blast_market_maker::presale_rewards)]
fun publication_rejects_malformed_root() {
    let mut f = start();
    let _ = f.publish(0, 0, 1, vector[1u8], 1, 1, 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = market_maker::EInsufficientRewards, location = blast_market_maker::market_maker)]
fun publication_cannot_spend_capital_or_unallocated_fees() {
    let mut f = start();
    f.credit_more_fees();
    let root = f.leaf(0, 0, BUYER, 101, 201);
    let _ = f.publish(0, 0, 1, root, 1, 101, 201);
    f.end();
}

#[test]
#[expected_failure(abort_code = fee_ledger::EInsufficientFees, location = blast_market_maker::fee_ledger)]
fun creator_cannot_reallocate_a_reward_reserve() {
    let mut f = start();
    f.keep_one_fee();
    f.end();
}

#[test]
#[expected_failure(abort_code = market_maker::EWrongRoute, location = blast_market_maker::market_maker)]
fun presale_rejects_curve_claim_endpoint() {
    let mut f = start();
    f.claim_curve_fees();
    f.end();
}

#[test]
#[expected_failure(abort_code = package_version::EVersionMismatch, location = blast_market_maker::package_version)]
fun version_check_precedes_publication_inputs() {
    let mut f = start();
    f.version.set_generation_for_testing(999);
    let _ = f.publish(0, 0, 0, vector[], 0, 0, 0);
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EAlreadyClaimed, location = blast_market_maker::presale_rewards)]
fun claims_reject_duplicate_claim() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let round_id = f.publish(0, 0, 1, root, 1, 100, 200);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 0, BUYER, 1, 1, vector[]);
        f.claim(&mut round, 0, BUYER, 1, 1, vector[]);
        f.return_round(round);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidProof, location = blast_market_maker::presale_rewards)]
fun claims_reject_redirected_beneficiary() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let round_id = f.publish(0, 0, 1, root, 1, 100, 200);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 0, RELAYER, 1, 1, vector[]);
        f.return_round(round);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidProof, location = blast_market_maker::presale_rewards)]
fun claims_reject_altered_amounts() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let round_id = f.publish(0, 0, 1, root, 1, 100, 200);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 0, BUYER, 2, 1, vector[]);
        f.return_round(round);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidProof, location = blast_market_maker::presale_rewards)]
fun claims_reject_wrong_vault_domain() {
    let mut f = start();
    let round_id = f.publish(0, 0, 1, rewards::leaf_for_testing(object::id_from_address(@0xBAD), 0, 0, BUYER, 1, 1), 1, 100, 200);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 0, BUYER, 1, 1, vector[]);
        f.return_round(round);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidProof, location = blast_market_maker::presale_rewards)]
fun claims_reject_wrong_epoch_domain() {
    let mut f = start();
    let root = f.leaf(1, 0, BUYER, 1, 1);
    let round_id = f.publish(0, 0, 1, root, 1, 100, 200);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 0, BUYER, 1, 1, vector[]);
        f.return_round(round);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidIndex, location = blast_market_maker::presale_rewards)]
fun claims_reject_out_of_range_index() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let round_id = f.publish(0, 0, 1, root, 1, 100, 200);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 1, BUYER, 1, 1, vector[]);
        f.return_round(round);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidBeneficiary, location = blast_market_maker::presale_rewards)]
fun claims_reject_zero_beneficiary() {
    let mut f = start();
    let root = f.leaf(0, 0, @0x0, 1, 1);
    let round_id = f.publish(0, 0, 1, root, 1, 100, 200);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 0, @0x0, 1, 1, vector[]);
        f.return_round(round);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EEmptyClaim, location = blast_market_maker::presale_rewards)]
fun claims_reject_empty_claim() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 0, 0);
    let round_id = f.publish(0, 0, 1, root, 1, 100, 200);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 0, BUYER, 0, 0, vector[]);
        f.return_round(round);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidProof, location = blast_market_maker::presale_rewards)]
fun claims_reject_wrong_proof_depth() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let round_id = f.publish(0, 0, 1, root, 1, 100, 200);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 0, BUYER, 1, 1, vector[vector::tabulate!(32, |_| 0)]);
        f.return_round(round);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EInsufficientBudget, location = blast_market_maker::presale_rewards)]
fun claims_reject_underfunded_manifest() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 101, 1);
    let round_id = f.publish(0, 0, 1, root, 1, 100, 200);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 0, BUYER, 101, 1, vector[]);
        f.return_round(round);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = 6, location = blast_admin::blast_acl)]
fun publication_rejects_revoked_role() {
    let mut f = start();
    f.revoke_reward_role();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let _ = f.publish(0, 0, 1, root, 1, 1, 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = 6, location = blast_admin::blast_acl)]
fun publication_rejects_wrong_role() {
    let mut f = start();
    f.replace_with_fee_role();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let _ = f.publish(0, 0, 1, root, 1, 1, 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = 1, location = blast_admin::blast_acl)]
fun publication_rejects_revoked_admin() {
    let mut f = start();
    f.revoke_admin();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let _ = f.publish(0, 0, 1, root, 1, 1, 1);
    f.end();
}

#[test]
fun odd_width_tree_duplicates_the_last_leaf_and_accepts_its_full_proof() {
    let mut f = start();
    let first = f.leaf(0, 0, ROOT, 1, 1);
    let second = f.leaf(0, 1, RELAYER, 1, 1);
    let third = f.leaf(0, 2, BUYER, 1, 1);
    let left = rewards::node_for_testing(first, second);
    let root = rewards::node_for_testing(left, rewards::node_for_testing(third, third));
    let round_id = f.publish(0, 0, 1, root, 3, 3, 3);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 2, BUYER, 1, 1, vector[third, left]);
        f.claim(&mut round, 0, ROOT, 1, 1, vector[second, rewards::node_for_testing(third, third)]);
        f.claim(&mut round, 1, RELAYER, 1, 1, vector[first, rewards::node_for_testing(third, third)]);
        f.assert_round_balances(&round, 0, 0);
        f.return_round(round);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidProof, location = blast_market_maker::presale_rewards)]
fun claims_reject_a_malformed_sibling() {
    let mut f = start();
    let first = f.leaf(0, 0, BUYER, 1, 1);
    let second = f.leaf(0, 1, ROOT, 1, 1);
    let round_id = f.publish(0, 0, 1, rewards::node_for_testing(first, second), 2, 2, 2);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 0, BUYER, 1, 1, vector[vector[1u8]]);
        f.return_round(round);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = package_version::EVersionMismatch, location = blast_market_maker::package_version)]
fun stale_version_rejects_claim_before_index_and_proof() {
    let mut f = start();
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let round_id = f.publish(0, 0, 1, root, 1, 1, 1);
    f.version.set_generation_for_testing(999);
    f.next_tx!(RELAYER, |f| {
        let mut round = f.take_round(round_id);
        f.claim(&mut round, 999, @0x0, 0, 0, vector[]);
        f.return_round(round);
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = market_maker::EWrongRoute, location = blast_market_maker::market_maker)]
fun curve_vault_cannot_publish_a_presale_reward_round() {
    let mut f = start_unfunded(market_maker::curve_route());
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let _ = f.publish(0, 0, 1, root, 1, 1, 1);
    f.end();
}

#[test]
#[expected_failure(abort_code = market_maker::EWrongPhase, location = blast_market_maker::market_maker)]
fun unmigrated_presale_cannot_publish_a_reward_round() {
    let mut f = start_unfunded(market_maker::presale_route());
    let root = f.leaf(0, 0, BUYER, 1, 1);
    let _ = f.publish(0, 0, 1, root, 1, 1, 1);
    f.end();
}

#[test]
fun leaf_and_node_encodings_match_independent_blake2b_bcs_vectors() {
    // Expected digests were independently computed with Python hashlib and little-endian u64s.
    let digest = rewards::leaf_for_testing(object::id_from_address(@0x123), 7, 2, @0xB, 123, 456);
    assert_eq!(digest, x"ea748894a0c1d0ec5f34b36fe6f10ae2be8bb262fceac27cca7c33baea2e9a95");
    assert_eq!(rewards::node_for_testing(digest, digest), x"7303faa90bb22f0ebfa8edf96d635a8e951884e7f18f466cdfce171b3c2aac72");
}

// === Test Helpers ===

macro fun fixture_next_tx($fixture: &mut RewardFixture, $sender: address, $body: |&mut RewardFixture|) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $body(fixture);
}

fun start(): RewardFixture {
    let mut f = start_unfunded(market_maker::presale_route());
    f.vault.activate_pool(object::id_from_address(@0xFACE));
    f.vault.join_capital(balance::create_for_testing<MEME>(7), balance::create_for_testing<QUOTE>(11));
    f.credit_more_fees();
    f.allocate_all();
    f
}

fun allocate_all(f: &mut RewardFixture) {
    let RewardFixture { vault, creator, version, scenario, .. } = f;
    let (meme, quote) = vault.allocate_fees(
        creator, version, fee_ledger::allocation(0, 100, 0),
        fee_ledger::allocation(0, 200, 0), scenario.ctx(),
    );
    meme.burn_for_testing();
    quote.burn_for_testing();
}

fun start_unfunded(route: market_maker::Route): RewardFixture {
    let mut scenario = test_scenario::begin(ROOT);
    let (root, mut acl) = blast_acl::new_for_testing(scenario.ctx());
    acl.grant_admin(&root, ROOT, scenario.ctx());
    scenario.next_tx(ROOT);
    let admin = scenario.take_from_sender<AdminCap>();
    acl.grant_role<RewardsAdmin>(&root, object::id(&admin));
    let ctx = scenario.ctx();
    let creator = market_maker::new_creator_cap(ctx);
    let treasury = protocol_treasury::new_for_testing(ctx);
    let policy = market_maker_fee_policy::new_for_testing(object::id(&treasury), ctx);
    let version = package_version::new_for_testing(object::id(&treasury), object::id(&policy), ctx);
    let mut vault = market_maker::new<MEME, QUOTE>(
        route, 67_108_864, 10_000, ROOT, &creator,
        vector::tabulate!(32, |_| 0), &version, &policy, &treasury, ctx,
    );
    vault.set_trading_limits(market_maker::trading_limits(1, 1, 100, 100, 0, 10));
    RewardFixture { scenario, root, acl, admin, vault, version, creator, treasury, policy }
}

fun leaf(f: &RewardFixture, number: u64, index: u64, buyer: address, meme: u64, quote: u64): vector<u8> {
    rewards::leaf_for_testing(object::id(&f.vault), number, index, buyer, meme, quote)
}

fun publish(f: &mut RewardFixture, number: u64, start: u64, end: u64, root: vector<u8>, leaves: u64, meme: u64, quote: u64): ID {
    let witness = f.acl.sign_in<RewardsAdmin>(&f.admin);
    let RewardFixture { vault, version, scenario, .. } = f;
    rewards::publish_round(
        vault, version, &witness, number, start, end, root,
        vector::tabulate!(32, |_| 9), leaves, meme, quote, scenario.ctx(),
    );
    rewards::published_round_id(&f.last_publication())
}

fun last_publication(f: &RewardFixture): rewards::BlastPresaleRewardRoundPublished<MEME, QUOTE> {
    let _ = f;
    let events = sui::event::events_by_type<rewards::BlastPresaleRewardRoundPublished<MEME, QUOTE>>();
    events[events.length() - 1]
}

fun take_round(f: &RewardFixture, id: ID): BlastPresaleRewardRound<MEME, QUOTE> {
    f.scenario.take_shared_by_id(id)
}

fun return_round(_: &RewardFixture, round: BlastPresaleRewardRound<MEME, QUOTE>) {
    test_scenario::return_shared(round);
}

fun claim(f: &mut RewardFixture, round: &mut BlastPresaleRewardRound<MEME, QUOTE>, index: u64, buyer: address, meme: u64, quote: u64, proof: vector<vector<u8>>) {
    let RewardFixture { version, scenario, .. } = f;
    round.claim(version, index, buyer, meme, quote, proof, scenario.ctx());
}

fun assert_reserves(f: &RewardFixture, meme: u64, quote: u64) {
    let (available_meme, available_quote, reserved_meme, reserved_quote) = f.vault.fee_balances();
    assert_eq!(available_meme, 0);
    assert_eq!(available_quote, 0);
    assert_eq!(reserved_meme, meme);
    assert_eq!(reserved_quote, quote);
}

fun assert_round_balances(_: &RewardFixture, round: &BlastPresaleRewardRound<MEME, QUOTE>, meme: u64, quote: u64) {
    let (held_meme, held_quote) = round.balances_for_testing();
    assert_eq!(held_meme, meme);
    assert_eq!(held_quote, quote);
}

fun pause_and_withdraw_capital(f: &mut RewardFixture) {
    let RewardFixture { vault, creator, version, scenario, .. } = f;
    vault.set_paused(creator, version, true);
    let (meme, quote) = vault.withdraw_capital(creator, version, 7, 11, scenario.ctx());
    assert_eq!(meme.value(), 7);
    assert_eq!(quote.value(), 11);
    meme.burn_for_testing();
    quote.burn_for_testing();
}

fun assert_payment(f: &RewardFixture, meme: u64, quote: u64) {
    let received_meme = f.scenario.take_from_sender<Coin<MEME>>();
    let received_quote = f.scenario.take_from_sender<Coin<QUOTE>>();
    assert_eq!(received_meme.value(), meme);
    assert_eq!(received_quote.value(), quote);
    received_meme.burn_for_testing();
    received_quote.burn_for_testing();
}

fun has_sender_coin<Asset>(f: &RewardFixture): bool { f.scenario.has_most_recent_for_sender<Coin<Asset>>() }

fun revoke_reward_role(f: &mut RewardFixture) {
    f.acl.revoke_role<RewardsAdmin>(&f.root, object::id(&f.admin));
}

fun replace_with_fee_role(f: &mut RewardFixture) {
    f.revoke_reward_role();
    f.acl.grant_role<FeeAdmin>(&f.root, object::id(&f.admin));
}

fun revoke_admin(f: &mut RewardFixture) { f.acl.revoke_admin(&f.root, object::id(&f.admin)); }

fun credit_more_fees(f: &mut RewardFixture) {
    f.vault.credit_curve_fees(balance::create_for_testing<MEME>(100), balance::create_for_testing<QUOTE>(200));
}

fun keep_one_fee(f: &mut RewardFixture) {
    let RewardFixture { vault, creator, version, scenario, .. } = f;
    let (meme, quote) = vault.allocate_fees(creator, version, fee_ledger::allocation(1, 0, 0), fee_ledger::allocation(0, 0, 0), scenario.ctx());
    meme.burn_for_testing();
    quote.burn_for_testing();
}

fun claim_curve_fees(f: &mut RewardFixture) {
    let RewardFixture { vault, version, scenario, .. } = f;
    let (meme, quote) = vault.claim_fees(version, scenario.ctx());
    meme.burn_for_testing();
    quote.burn_for_testing();
}

fun end(f: RewardFixture) {
    let RewardFixture { scenario, root, acl, admin, vault, version, creator, treasury, policy } = f;
    destroy(root);
    destroy(acl);
    destroy(admin);
    destroy(vault);
    destroy(version);
    destroy(creator);
    destroy(treasury);
    destroy(policy);
    scenario.end();
}

// === Imports ===

use blast_admin::blast_acl::{Self, ACL, AdminCap, SuperAdminCap};
use blast_market_maker::{
    blast_market_maker_domain::{FeeAdmin, RewardsAdmin},
    market_maker::{Self, BlastMarketMakerVault, BlastMarketMakerCreatorCap},
    market_maker_fee_policy::{Self, BlastMarketMakerFeePolicy},
    protocol_treasury::{Self, BlastMarketMakerTreasury},
    package_version::{Self, BlastMarketMakerVersion as PackageVersion},
    fee_ledger,
    presale_rewards::{Self as rewards, BlastPresaleRewardRound},
};
use std::unit_test::{assert_eq, destroy};
use sui::{balance, coin::Coin, test_scenario::{Self, Scenario}};

use fun fixture_next_tx as RewardFixture.next_tx;
