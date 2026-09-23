// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun_distributor::distributor_tests;

// === Constants ===

const CREATOR: address = @0xC;

const ALICE: address = @0xA;

const BOT: address = @0xB;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct DISTRIBUTOR_TESTS has drop {}

public struct QUOTE() has drop;

public struct Venue() has drop;

public struct DistributionFixture {
    scenario: Scenario,
    launch: Option<Launch<DISTRIBUTOR_TESTS, QUOTE>>,
    version: package_version::PackageVersion,
    control: Version,
    admin: AdminCap,
    distributor: Distributor<DISTRIBUTOR_TESTS, QUOTE>,
    publisher: PublisherCap,
    creator_cap_id: ID,
}

// === Tests ===

#[test]
fun init_sends_admin_cap_to_publisher_and_shares_current_unpaused_version() {
    let mut scenario = test_scenario::begin(CREATOR);
    distributor::init_for_testing(scenario.ctx());
    scenario.next_tx(CREATOR);
    let admin = scenario.take_from_sender<AdminCap>();
    let version = scenario.take_shared<Version>();
    assert_eq!(version.version_for_testing(), 1);
    assert!(!version.paused_for_testing());
    scenario.return_to_sender(admin);
    test_scenario::return_shared(version);
    scenario.end();
}

#[test]
fun enrollment_destroys_the_creator_cap_and_binds_curve_fees_forever() {
    let f = start();
    assert_eq!(
        f.launch.borrow().fee_custodian_for_testing(),
        option::some(type_name::with_original_ids<distributor::Witness>()),
    );
    assert!(f.launch.borrow().curve_fee_cap_id_for_testing().is_none());
    {
        let (meme, quote) = f.distributor.balances_for_testing();
        assert_eq!(meme, 0);
        assert_eq!(quote, 0);
    };
    f.end();
}

#[test]
fun permissionless_collection_moves_only_creator_fees_into_distributor() {
    let mut f = start();
    let (protocol_meme, creator_meme, protocol_quote, creator_quote) = f
        .launch
        .borrow()
        .fee_totals_for_testing();
    assert!(creator_meme > 0 && creator_quote > 0);
    f.next_tx!(BOT, |f| { f.collect!(); });
    {
        let (meme, quote) = f.distributor.balances_for_testing();
        assert_eq!(meme, creator_meme);
        assert_eq!(quote, creator_quote);
    };
    let (pm, cm, pq, cq) = f.launch.borrow().fee_totals_for_testing();
    assert_eq!(pm, protocol_meme);
    assert_eq!(cm, 0);
    assert_eq!(pq, protocol_quote);
    assert_eq!(cq, 0);
    f.end();
}

#[test]
fun bot_pays_proven_holder_directly_and_leaves_other_funds_in_custody() {
    let mut f = start_funded();
    let (before_meme, before_quote) = f.distributor.balances_for_testing();
    let mut round = f.round!(0, 10, 20);
    {
        let (meme, quote) = f.distributor.balances_for_testing();
        assert_eq!(meme, before_meme - 10);
        assert_eq!(quote, before_quote - 20);
    };
    f.next_tx!(BOT, |f| {
        f.claim!(&mut round, 0, ALICE, 10, 20, vector[]);
    });
    {
        let (meme, quote) = round.balances_for_testing();
        assert_eq!(meme, 0);
        assert_eq!(quote, 0);
    };
    assert!(round.is_claimed_for_testing(0));
    f.next_tx!(ALICE, |f| {
        assert_eq!(f.received_meme!().into_balance().destroy_for_testing(), 10);
        assert_eq!(f.received_quote!().into_balance().destroy_for_testing(), 20);
    });
    destroy(round);
    f.end();
}

#[test]
fun quote_only_round_does_not_create_a_zero_meme_coin() {
    let mut f = start_funded();
    let mut round = f.round!(0, 0, 20);
    f.claim!(&mut round, 0, ALICE, 0, 20, vector[]);
    f.next_tx!(ALICE, |f| {
        assert!(!f.has_meme!());
        assert_eq!(f.received_quote!().into_balance().destroy_for_testing(), 20);
    });
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EAlreadyClaimed,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun payout_cannot_be_replayed_even_after_budget_is_drained() {
    let mut f = start_funded();
    let mut round = f.round!(0, 10, 20);
    f.claim!(&mut round, 0, ALICE, 10, 20, vector[]);
    f.claim!(&mut round, 0, ALICE, 10, 20, vector[]);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EInvalidProof,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun relayer_cannot_substitute_its_own_address() {
    let mut f = start_funded();
    let mut round = f.round!(0, 10, 20);
    f.claim!(&mut round, 0, BOT, 10, 20, vector[]);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EInvalidProof,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun holder_cannot_change_an_amount() {
    let mut f = start_funded();
    let mut round = f.round!(0, 10, 20);
    f.claim!(&mut round, 0, ALICE, 9, 20, vector[]);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EInvalidIndex,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun claim_rejects_out_of_range_index_before_proof_work() {
    let mut f = start_funded();
    let mut round = f.round!(0, 10, 20);
    f.claim!(&mut round, 1, ALICE, 10, 20, vector[]);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EWrongRound,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun stale_publication_cannot_fund_another_round() {
    let mut f = start_funded();
    destroy(f.round!(0, 10, 20));
    destroy(f.round!(0, 10, 20));
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EInsufficientFunds,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun unfunded_round_is_rejected() {
    let mut f = start();
    destroy(f.round!(0, 10, 20));
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EEmptyBudget,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun empty_round_is_rejected() {
    let mut f = start_funded();
    destroy(f.round!(0, 0, 0));
    f.end();
}

#[test]
fun later_round_does_not_invalidate_earlier_unclaimed_entitlements() {
    let mut f = start_funded();
    let mut first = f.round!(0, 10, 20);
    let mut second = f.round!(1, 20, 40);
    f.claim!(&mut second, 0, ALICE, 20, 40, vector[]);
    f.claim!(&mut first, 0, ALICE, 10, 20, vector[]);
    {
        let (meme, quote) = first.balances_for_testing();
        assert_eq!(meme, 0);
        assert_eq!(quote, 0);
    };
    {
        let (meme, quote) = second.balances_for_testing();
        assert_eq!(meme, 0);
        assert_eq!(quote, 0);
    };
    destroy(first);
    destroy(second);
    f.end();
}

#[test]
fun shared_custody_and_transferred_publisher_cap_support_later_transactions() {
    start_funded().complete_shared_round();
}

#[test]
fun maximum_round_claims_last_bitmap_bit_and_emits_exact_payment() {
    let mut f = start_funded();
    let leaf = merkle::leaf(object::id(&f.distributor), 0, 65_535, ALICE, 1, 0);
    let sibling = merkle::leaf(object::id(&f.distributor), 0, 0, ALICE, 1, 0);
    let proof = vector::tabulate!(16, |_| sibling);
    let mut root = leaf;
    proof.do_ref!(|sibling| { root = merkle::node_for_testing(*sibling, root); });
    let mut round = f.publish_round!(0, 0, 1, root, root, 65_536, 1, 0);
    f.claim!(&mut round, 65_535, ALICE, 1, 0, proof);
    assert!(round.is_claimed_for_testing(65_535));
    assert!(!round.is_claimed_for_testing(65_534));
    let events = sui::event::events_by_type<distributor::RewardPaid>();
    assert_eq!(events.length(), 1);
    let mut expected = bcs::to_bytes(&object::id(&round));
    expected.append(bcs::to_bytes(&65_535u64));
    let beneficiary = ALICE;
    expected.append(bcs::to_bytes(&beneficiary));
    expected.append(bcs::to_bytes(&1u64));
    expected.append(bcs::to_bytes(&0u64));
    expected.append(bcs::to_bytes(&0u64));
    expected.append(bcs::to_bytes(&0u64));
    assert_eq!(bcs::to_bytes(&events[0]), expected);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EInvalidInterval,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun overlapping_intervals_abort() {
    let mut f = start_funded();
    destroy(f.round!(0, 1, 1));
    let valid = vector::tabulate!(32, |_| 1u8);
    let round = f.publish_round!(1, 9, 20, valid, valid, 1, 1, 1);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EInvalidInterval,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun gapped_intervals_abort() {
    let mut f = start_funded();
    destroy(f.round!(0, 1, 1));
    let valid = vector::tabulate!(32, |_| 1u8);
    let round = f.publish_round!(1, 11, 20, valid, valid, 1, 1, 1);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EInvalidInterval,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun empty_intervals_abort() {
    let mut f = start_funded();
    let valid = vector::tabulate!(32, |_| 1u8);
    let round = f.publish_round!(0, 10, 10, valid, valid, 1, 1, 1);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EInvalidCommitment,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun malformed_commitments_abort() {
    let mut f = start_funded();
    let valid = vector::tabulate!(32, |_| 1u8);
    let round = f.publish_round!(0, 0, 10, vector[], valid, 1, 1, 1);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EInvalidLeafCount,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun empty_leaf_set_aborts() {
    let mut f = start_funded();
    let valid = vector::tabulate!(32, |_| 1u8);
    let round = f.publish_round!(0, 0, 10, valid, valid, 0, 1, 1);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EInvalidLeafCount,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun first_over_capacity_leaf_set_aborts() {
    let mut f = start_funded();
    let valid = vector::tabulate!(32, |_| 1u8);
    let round = f.publish_round!(0, 0, 10, valid, valid, 65537, 1, 1);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EPaused,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun pause_stops_collection_before_fees_move() {
    let mut f = start();
    f.pause!(true);
    f.collect!();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EPaused,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun pause_stops_new_rounds() {
    let mut f = start_funded();
    f.pause!(true);
    destroy(f.round!(0, 1, 1));
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EPaused,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun pause_stops_existing_claims_before_proof_validation() {
    let mut f = start_funded();
    let mut round = f.round!(0, 1, 1);
    f.pause!(true);
    f.claim!(&mut round, 99, ALICE, 1, 1, vector[]);
    destroy(round);
    f.end();
}

#[test]
fun admin_can_resume_existing_funded_claims() {
    let mut f = start_funded();
    let mut round = f.round!(0, 1, 1);
    f.pause!(true);
    f.pause!(false);
    f.claim!(&mut round, 0, ALICE, 1, 1, vector[]);
    assert!(round.is_claimed_for_testing(0));
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EWrongVersion,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun retired_code_cannot_pay_existing_claims_even_if_also_paused() {
    let mut f = start_funded();
    let mut round = f.round!(0, 1, 1);
    f.pause!(true);
    f.control.set_version_for_testing(2);
    f.claim!(&mut round, 0, ALICE, 1, 1, vector[]);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EWrongVersion,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun retired_code_cannot_collect() {
    let mut f = start();
    f.control.set_version_for_testing(2);
    f.collect!();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EWrongVersion,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun retired_code_cannot_publish() {
    let mut f = start_funded();
    f.control.set_version_for_testing(2);
    destroy(f.round!(0, 1, 1));
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EWrongVersion,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun unmigrated_version_rejects_claims_until_admin_migrates() {
    let mut f = start_funded();
    let mut round = f.round!(0, 1, 1);
    f.control.set_version_for_testing(0);
    f.claim!(&mut round, 0, ALICE, 1, 1, vector[]);
    destroy(round);
    f.end();
}

#[test]
fun migration_preserves_pause_and_round_state() {
    let mut f = start_funded();
    let mut round = f.round!(0, 1, 1);
    f.pause!(true);
    f.control.set_version_for_testing(0);

    f.migrate!();

    assert_eq!(f.control.version_for_testing(), 1);
    assert!(f.control.paused_for_testing());
    f.pause!(false);
    f.claim!(&mut round, 0, ALICE, 1, 1, vector[]);
    assert!(round.is_claimed_for_testing(0));
    let (meme, quote) = round.balances_for_testing();
    assert_eq!(meme, 0);
    assert_eq!(quote, 0);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::ENotUpgrade,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun migration_rejects_a_current_version() {
    let mut f = start();
    f.migrate!();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::ENotUpgrade,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun migration_rejects_a_rollback() {
    let mut f = start();
    f.control.set_version_for_testing(2);
    f.migrate!();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EPaused,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun pause_rejects_enrollment_before_taking_creator_cap() {
    destroy(start_with_control(true, 1));
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EWrongVersion,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun retired_code_rejects_enrollment() {
    destroy(start_with_control(false, 2));
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EUnchangedPause,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun no_op_pause_does_not_emit_a_false_transition() {
    let mut f = start();
    f.pause!(false);
    f.end();
}

#[test]
fun pause_changes_emit_replayable_events() {
    let mut f = start();
    f.pause!(true);
    f.pause!(false);
    let pauses = sui::event::events_by_type<distributor::PauseChanged>();
    assert_eq!(pauses.length(), 2);
    assert_eq!(bcs::to_bytes(&pauses[0]), vector[1u8]);
    assert_eq!(bcs::to_bytes(&pauses[1]), vector[0u8]);
    assert!(!f.control.paused_for_testing());
    f.end();
}

#[test]
fun enrollment_collection_and_publication_events_reconcile_every_funding_field() {
    let mut f = start();
    let enrolled = sui::event::events_by_type<distributor::Enrolled>();
    assert_eq!(enrolled.length(), 1);
    let mut expected = bcs::to_bytes(&object::id(&f.distributor));
    expected.append(bcs::to_bytes(&object::id(f.launch.borrow())));
    expected.append(bcs::to_bytes(&f.creator_cap_id));
    expected.append(bcs::to_bytes(&object::id(&f.publisher)));
    assert_eq!(bcs::to_bytes(&enrolled[0]), expected);

    f.collect!();
    let (meme, quote) = f.distributor.balances_for_testing();
    let collected = sui::event::events_by_type<distributor::FeesCollected>();
    assert_eq!(collected.length(), 1);
    let mut expected = bcs::to_bytes(&object::id(&f.distributor));
    expected.append(bcs::to_bytes(&object::id(f.launch.borrow())));
    expected.append(bcs::to_bytes(&meme));
    expected.append(bcs::to_bytes(&quote));
    expected.append(bcs::to_bytes(&meme));
    expected.append(bcs::to_bytes(&quote));
    assert_eq!(bcs::to_bytes(&collected[0]), expected);

    let round = f.round!(0, 10, 20);
    let published = sui::event::events_by_type<distributor::RoundPublished>();
    assert_eq!(published.length(), 1);
    let mut expected = bcs::to_bytes(&object::id(&f.distributor));
    expected.append(bcs::to_bytes(&object::id(&round)));
    expected.append(bcs::to_bytes(&0u64));
    expected.append(bcs::to_bytes(&0u64));
    expected.append(bcs::to_bytes(&10u64));
    let root = merkle::leaf(object::id(&f.distributor), 0, 0, ALICE, 10, 20);
    expected.append(bcs::to_bytes(&root));
    expected.append(bcs::to_bytes(&vector::tabulate!(32, |_| 1u8)));
    expected.append(bcs::to_bytes(&1u64));
    expected.append(bcs::to_bytes(&10u64));
    expected.append(bcs::to_bytes(&20u64));
    let (remaining_meme, remaining_quote) = f.distributor.balances_for_testing();
    assert_eq!(remaining_meme + 10, meme);
    assert_eq!(remaining_quote + 20, quote);
    expected.append(bcs::to_bytes(&remaining_meme));
    expected.append(bcs::to_bytes(&remaining_quote));
    assert_eq!(bcs::to_bytes(&published[0]), expected);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EInvalidBeneficiary,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun zero_beneficiary_is_rejected_before_proof_work() {
    let mut f = start_funded();
    let mut round = f.round!(0, 1, 1);
    f.claim!(&mut round, 0, @0x0, 1, 1, vector[]);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EEmptyBudget,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun empty_claim_cannot_consume_a_bitmap_bit() {
    let mut f = start_funded();
    let mut round = f.round!(0, 1, 1);
    f.claim!(&mut round, 0, ALICE, 0, 0, vector[]);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EInsufficientFunds,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun claim_cannot_exceed_its_reserved_budget() {
    let mut f = start_funded();
    let mut round = f.round!(0, 1, 1);
    f.claim!(&mut round, 0, ALICE, 2, 1, vector[]);
    destroy(round);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EWrongVersion,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun retired_code_cannot_resume_paused_rewards() {
    let mut f = start();
    f.pause!(true);
    f.control.set_version_for_testing(2);
    f.pause!(false);
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = distributor::EWrongSource,
        location = blast_fun_distributor::blast_fun_distributor,
    ),
]
fun collecting_curve_fees_rejects_an_unenrolled_launch() {
    let mut f = start();
    let unenrolled = f.new_unenrolled_launch();
    let unenrolled_id = object::id(&unenrolled);
    test_scenario::return_shared(unenrolled);

    f.next_tx!(BOT, |f| {
        let mut unenrolled = f
            .scenario
            .take_shared_by_id<Launch<DISTRIBUTOR_TESTS, QUOTE>>(unenrolled_id);
        f.distributor.collect_curve_fees(&f.control, &mut unenrolled, &f.version, f.ctx!());
        test_scenario::return_shared(unenrolled);
    });

    f.end();
}

// === Test Helpers ===

/// A second launch of the same pair that no distributor custodies.
fun new_unenrolled_launch(
    self: &mut DistributionFixture,
): Launch<DISTRIBUTOR_TESTS, QUOTE> {
    // The test-only witness is constructible again; production has one initializer per package.

    let config = self.scenario.take_shared<launch_config::LaunchConfig>();
    let mut ticket = launch_ticket::new(
        test_utils::create_one_time_witness<DISTRIBUTOR_TESTS>(),
        9,
        b"OTHER".to_string(),
        b"Other".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(CREATOR),
        false,
        0,
        self.ctx!(),
    );
    ticket.bind_migration_witness<_, QUOTE, _>(&config, Venue());
    self.next_transaction(CREATOR);
    let mut currency = self.scenario.take_from_address<Currency<DISTRIBUTOR_TESTS>>(@0xc);
    let mut launch = launch::new<_, QUOTE>(
        ticket,
        &mut currency,
        &self.version,
        &config,
        25_000_000,
        default_allocation_plan(),
        0,
        bps::new(0),
        bps::new(0),
        self.ctx!(),
    );
    let (router, config_cap) = launch.new_fee_router(
        &self.version,
        default_fee_routes(),
        self.ctx!(),
    );
    let launch_id = object::id(&launch);
    let clock = clock::create_for_testing(self.ctx!());
    launch.share(&self.version, config_cap, router, &clock);
    clock.destroy_for_testing();
    test_scenario::return_shared(config);
    test_scenario::return_to_address(@0xc, currency);
    self.next_transaction(CREATOR);
    self.scenario.take_shared_by_id(launch_id)
}

fun complete_shared_round(f: DistributionFixture) {
    let DistributionFixture {
        mut scenario,
        launch,
        version,
        control,
        admin,
        distributor,
        publisher,
        creator_cap_id: _,
    } = f;
    assert_eq!(
        launch.borrow().fee_custodian_for_testing(),
        option::some(type_name::with_original_ids<distributor::Witness>()),
    );
    test_scenario::return_shared(launch.destroy_some());
    distributor.share();
    transfer::public_transfer(publisher, BOT);
    scenario.next_tx(BOT);
    let mut distributor = scenario.take_shared<
        Distributor<DISTRIBUTOR_TESTS, QUOTE>,
    >();
    let publisher = scenario.take_from_sender<PublisherCap>();
    let root = merkle::leaf(object::id(&distributor), 0, 0, ALICE, 1, 1);
    let round = distributor.publish_round(
        &publisher,
        &control,
        0,
        0,
        1,
        root,
        root,
        1,
        1,
        1,
        scenario.ctx(),
    );
    round.share_round();
    test_scenario::return_shared(distributor);
    transfer::public_transfer(publisher, CREATOR);
    scenario.next_tx(ALICE);
    let mut round = scenario.take_shared<Round<DISTRIBUTOR_TESTS, QUOTE>>();
    round.claim(&control, 0, ALICE, 1, 1, vector[], scenario.ctx());
    test_scenario::return_shared(round);
    scenario.next_tx(CREATOR);
    let publisher = scenario.take_from_sender<PublisherCap>();
    scenario.return_to_sender(publisher);
    destroy(version);
    destroy(control);
    destroy(admin);
    scenario.end();
}

macro fun pause($f: &mut DistributionFixture, $paused: bool) {
    let f = $f;
    f.control.set_paused(&f.admin, $paused);
}

macro fun migrate($f: &mut DistributionFixture) {
    let f = $f;
    f.control.migrate(&f.admin);
}

macro fun claim(
    $f: &mut DistributionFixture,
    $round: &mut Round<DISTRIBUTOR_TESTS, QUOTE>,
    $index: u64,
    $beneficiary: address,
    $meme: u64,
    $quote: u64,
    $proof: vector<vector<u8>>,
) {
    let f = $f;
    let round = $round;
    round.claim(&f.control, $index, $beneficiary, $meme, $quote, $proof, f.ctx!());
}

macro fun ctx($f: &mut DistributionFixture): &mut TxContext {
    let f = $f;
    f.scenario.ctx()
}

macro fun next_tx($f: &mut DistributionFixture, $sender: address, $fn: |&mut DistributionFixture|) {
    let f = $f;
    f.next_transaction($sender);
    $fn(f);
}

macro fun collect($f: &mut DistributionFixture) {
    let f = $f;
    f.distributor.collect_curve_fees(&f.control, f.launch.borrow_mut(), &f.version, f.ctx!());
}

macro fun publish_round(
    $f: &mut DistributionFixture,
    $number: u64,
    $start_checkpoint: u64,
    $end_checkpoint: u64,
    $root: vector<u8>,
    $manifest_digest: vector<u8>,
    $leaf_count: u64,
    $meme: u64,
    $quote: u64,
): Round<DISTRIBUTOR_TESTS, QUOTE> {
    let f = $f;
    f
        .distributor
        .publish_round(
            &f.publisher,
            &f.control,
            $number,
            $start_checkpoint,
            $end_checkpoint,
            $root,
            $manifest_digest,
            $leaf_count,
            $meme,
            $quote,
            f.ctx!(),
        )
}

macro fun round(
    $f: &mut DistributionFixture,
    $number: u64,
    $meme: u64,
    $quote: u64,
): Round<DISTRIBUTOR_TESTS, QUOTE> {
    let f = $f;
    let number = $number;
    let meme = $meme;
    let quote = $quote;
    let root = merkle::leaf(object::id(&f.distributor), number, 0, ALICE, meme, quote);
    f
        .distributor
        .publish_round(
            &f.publisher,
            &f.control,
            number,
            number * 10,
            (number + 1) * 10,
            root,
            vector::tabulate!(32, |_| 1u8),
            1,
            meme,
            quote,
            f.ctx!(),
        )
}

macro fun received_meme($f: &mut DistributionFixture): Coin<DISTRIBUTOR_TESTS> {
    let f = $f;
    f.scenario.take_from_sender<Coin<DISTRIBUTOR_TESTS>>()
}

macro fun received_quote($f: &mut DistributionFixture): Coin<QUOTE> {
    let f = $f;
    f.scenario.take_from_sender<Coin<QUOTE>>()
}

macro fun has_meme($f: &DistributionFixture): bool {
    let f = $f;
    f.scenario.has_most_recent_for_sender<Coin<DISTRIBUTOR_TESTS>>()
}

fun start_funded(): DistributionFixture {
    let mut f = start();
    f.collect!();
    f
}

fun start(): DistributionFixture { start_with_control(false, 1) }

fun start_with_control(paused: bool, version_number: u64): DistributionFixture {
    let mut scenario = test_scenario::begin(@0x0);
    let version = package_version::new_for_testing(scenario.ctx());
    let (root, mut authority) = new_authority(scenario.ctx());
    authority.grant_admin(&root, 0, CREATOR, scenario.ctx());
    launch_config::init_for_testing(scenario.ctx());
    scenario.next_tx(CREATOR);
    let launchpad_admin = scenario.take_from_sender<LaunchpadAdminCap<BLAST_FUN_DOMAIN>>();
    let witness = authority.sign_in(&launchpad_admin);
    let mut config = scenario.take_shared<launch_config::LaunchConfig>();
    config.allow_quote<QUOTE>(&version, &witness, 5_000_000);
    config.allow_migration_witness<Venue>(&version, &witness);
    config.set_trade_fees(&version, &witness, bps::new(100), bps::new(100));
    config.set_protocol_allocation(&version, &witness, 1, CREATOR, bps::new(0), bps::new(0));
    let runtime = runtime_config::new_disabled_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let mut ticket = launch_ticket::new(
        test_utils::create_one_time_witness<DISTRIBUTOR_TESTS>(),
        9,
        b"TEST".to_string(),
        b"Test".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(CREATOR),
        false,
        0,
        scenario.ctx(),
    );
    ticket.bind_migration_witness<_, QUOTE, _>(&config, Venue());
    let sender = scenario.sender();
    scenario.next_tx(sender);
    let mut currency = scenario.take_from_address<Currency<DISTRIBUTOR_TESTS>>(@0xc);
    let mut launch = launch::new<_, QUOTE>(
        ticket,
        &mut currency,
        &version,
        &config,
        25_000_000,
        default_allocation_plan(),
        0,
        bps::new(0),
        bps::new(0),
        scenario.ctx(),
    );
    let (router, config_cap) = launch.new_fee_router(
        &version,
        default_fee_routes(),
        scenario.ctx(),
    );
    launch.share(&version, config_cap, router, &clock);
    test_scenario::return_shared(config);
    test_scenario::return_to_address(@0xc, currency);
    scenario.next_tx(CREATOR);
    let mut launch = scenario.take_shared<Launch<DISTRIBUTOR_TESTS, QUOTE>>();
    let (creator_cap, metadata_cap, config_cap) = launch.claim_setup_caps(
        &version,
        &runtime,
        option::none(),
        &clock,
        scenario.ctx(),
    );
    transfer::public_transfer(config_cap, CREATOR);
    destroy(metadata_cap);
    let creator_cap_id = object::id(&creator_cap);
    let quote = coin::mint_for_testing<QUOTE>(1_000_000, scenario.ctx());
    let (meme, refund) = launch.buy(&version, &runtime, quote, 1, &clock, scenario.ctx());
    destroy(meme);
    destroy(refund);
    let admin = distributor::new_admin_cap_for_testing(scenario.ctx());
    let mut control = distributor::new_version_for_testing(scenario.ctx());
    if (paused) control.set_paused(&admin, true);
    control.set_version_for_testing(version_number);
    let (distributor, publisher) = distributor::new(
        &control,
        creator_cap,
        &mut launch,
        &version,
        scenario.ctx(),
    );
    destroy(witness);
    destroy(launchpad_admin);
    destroy(authority);
    destroy(root);
    destroy(runtime);
    clock.destroy_for_testing();
    DistributionFixture {
        scenario,
        launch: option::some(launch),
        version,
        control,
        admin,
        distributor,
        publisher,
        creator_cap_id,
    }
}

fun default_allocation_plan(): AllocationPlan {
    allocation::new(
        vector[allocation::channel(2, allocation::liquidity_role(), CREATOR)],
        vector[allocation::weight(0, bps::new(8_000)), allocation::weight(2, bps::new(2_000))],
        vector[allocation::weight(2, bps::new(10_000))],
    )
}

fun default_fee_routes(): allocation::Routes {
    let route = vector[allocation::route(CREATOR, bps::new(10_000))];
    allocation::routes(route, route)
}

/// Unshared Launchpad-domain authority used only to configure the test launch.
fun new_authority(
    ctx: &mut TxContext,
): (SuperAdminCap<BLAST_FUN_DOMAIN>, Authority<BLAST_FUN_DOMAIN>) {
    acl::new_for_testing<BLAST_FUN_DOMAIN>(16, 7 * 24 * 60 * 60 * 1_000, ctx)
}

fun next_transaction(self: &mut DistributionFixture, sender: address) {
    let launch = self.launch.extract();
    let launch_id = object::id(&launch);
    test_scenario::return_shared(launch);
    self.scenario.next_tx(sender);
    self.launch.fill(self.scenario.take_shared_by_id(launch_id));
}

fun end(f: DistributionFixture) {
    let DistributionFixture {
        scenario,
        launch,
        version,
        control,
        admin,
        distributor,
        publisher,
        creator_cap_id: _,
    } = f;
    test_scenario::return_shared(launch.destroy_some());
    destroy(version);
    destroy(control);
    destroy(admin);
    destroy(distributor);
    destroy(publisher);
    scenario.end();
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap as LaunchpadAdminCap, SuperAdminCap};

use blast_fun::{
    allocation::{Self as allocation, AllocationPlan},
    blast_fun_domain::BLAST_FUN_DOMAIN,
    bps,
    creator_authority,
    fee_router,
    launch::{Self, Launch},
    launch_config,
    launch_ticket,
    package_version,
    runtime_config,
};

use blast_fun_distributor::{
    blast_fun_distributor::{
        Self as distributor,
        AdminCap,
        Distributor,
        PublisherCap,
        Round,
        Version,
    },
    merkle,
};

use std::{bcs, type_name, unit_test::{assert_eq, destroy}};

use sui::{
    clock,
    coin::{Self, Coin},
    coin_registry::Currency,
    test_scenario::{Self, Scenario},
    test_utils,
};
