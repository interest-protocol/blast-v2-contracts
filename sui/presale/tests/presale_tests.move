// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::presale_tests;

// === Constants ===

const PUBLISHER: address = @0xB0B0;

const ADMIN: address = @0xAD;

const TREASURY: address = @0x7EA5;

const CREATOR: address = @0xC0FFEE;

const ALICE: address = @0xA11CE;

const BOB: address = @0xB0B;

const CAROL: address = @0xCA201;

/// Claims and finalizes for others without holding a position.
const KEEPER: address = @0x4EE9;

/// Blast's fee in the fixture: one percent.
const FEE_BPS: u64 = 100;

const START_MS: u64 = 1_000;

/// The first tranche runs from `START_MS` to here, and the second from here to `SECOND_END_MS`.
const FIRST_END_MS: u64 = 2_000;

const SECOND_END_MS: u64 = 3_000;

const CLAIM_MS: u64 = 5_000;

/// The first tranche sells 1,000 tokens for 300 Quote, first come.
const FIRST_TOKENS: u64 = 1_000;

const FIRST_QUOTE: u64 = 300;

/// The second tranche sells 2,000 tokens for 400 Quote, pro rata.
const SECOND_TOKENS: u64 = 2_000;

const SECOND_QUOTE: u64 = 400;

// === Test-Only Types ===

public struct TOKEN() has drop;

public struct QUOTE() has drop;

/// Configured fee policy, one live administrator holding the fee and treasury roles, and a clock
/// standing at the first tranche's start.
public struct PresaleFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    config: BlastPresaleConfig,
    authority: Authority<BLAST_PRESALE_DOMAIN>,
    admin_cap: AdminCap<BLAST_PRESALE_DOMAIN>,
    clock: Clock,
}

// === Tests ===

// --- Fee policy ---

#[test]
fun the_policy_starts_free_and_paid_to_its_publisher() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    presale_config::init_for_testing(scenario.ctx());
    scenario.next_tx(PUBLISHER);
    let config = scenario.take_shared<BlastPresaleConfig>();

    assert_eq!(config.fee_bps(), 0);
    assert_eq!(config.fee_destination(), PUBLISHER);
    test_scenario::return_shared(config);
    scenario.end();
}

#[test]
fun the_fee_admin_sets_the_fee() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();
        f.config.set_fee_bps(&f.package_version, &witness, 1_000);
    });

    assert_eq!(bcs::to_bytes(&only_event<FeeSet>()), bcs::to_bytes(&1_000u64));
    assert_eq!(fixture.config.fee_bps(), 1_000);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidFeeBps, location = blast_presale::presale_config)]
fun a_fee_above_the_ceiling_is_rejected() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();
        f.config.set_fee_bps(&f.package_version, &witness, 1_001);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EUnchanged, location = blast_presale::presale_config)]
fun setting_the_current_fee_is_rejected() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();
        f.config.set_fee_bps(&f.package_version, &witness, FEE_BPS);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun the_fee_needs_the_fee_admin_role() {
    let mut fixture = start_with_roles(blast_presale_domain::treasury_admin_role());

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();
        f.config.set_fee_bps(&f.package_version, &witness, 1_000);
    });
    fixture.end();
}

#[test]
fun the_treasury_admin_sets_the_fee_destination() {
    let mut fixture = start();

    let destination = CAROL;
    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();
        f.config.set_fee_destination(&f.package_version, &witness, destination);
    });

    assert_eq!(bcs::to_bytes(&only_event<FeeDestinationSet>()), bcs::to_bytes(&destination));
    assert_eq!(fixture.config.fee_destination(), CAROL);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidDestination, location = blast_presale::presale_config)]
fun a_zero_fee_destination_is_rejected() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();
        f.config.set_fee_destination(&f.package_version, &witness, @0x0);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EUnchanged, location = blast_presale::presale_config)]
fun setting_the_current_fee_destination_is_rejected() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();
        f.config.set_fee_destination(&f.package_version, &witness, TREASURY);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun the_fee_destination_needs_the_treasury_admin_role() {
    let mut fixture = start_with_roles(blast_presale_domain::fee_admin_role());

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();
        f.config.set_fee_destination(&f.package_version, &witness, CAROL);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_package_version_rejects_the_fee_before_the_role() {
    let mut fixture = start_with_roles(0);
    fixture.package_version.set_for_testing(2);

    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();
        f.config.set_fee_bps(&f.package_version, &witness, 1_000);
    });
    fixture.end();
}

// --- Creation ---

#[test]
fun creation_holds_the_tokens_and_snapshots_the_fee() {
    let mut fixture = start();
    let tranches = two_tranches();
    let presale_id = fixture.create(tranches, 0, CLAIM_MS);

    let mut expected = bcs::to_bytes(&presale_id);
    expected.append(bcs::to_bytes(&type_name::with_original_ids<TOKEN>()));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<QUOTE>()));
    expected.append(bcs::to_bytes(&tranches));
    expected.append(bcs::to_bytes(&0u64));
    expected.append(u64_bytes(CLAIM_MS));
    expected.append(u64_bytes(FEE_BPS));
    assert_eq!(bcs::to_bytes(&only_event<PresaleCreated>()), expected);
    fixture.next_tx!(KEEPER, |f| {
        let presale = f.take_presale();

        assert!(presale.is_open_for_testing());
        assert_eq!(presale.fee_bps_for_testing(), FEE_BPS);
        assert_balances(&presale, FIRST_TOKENS + SECOND_TOKENS, 0);
        presale.put_back();
    });
    fixture.end();
}

#[test]
fun a_presale_may_have_the_maximum_number_of_tranches() {
    let mut fixture = start();
    let tranches = vector::tabulate!(8, |_| first_tranche());

    fixture.create(tranches, 0, CLAIM_MS);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidTokenQuotePair, location = blast_presale::presale)]
fun a_presale_selling_its_own_quote_is_rejected() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let tokens = coin::mint_for_testing<QUOTE>(FIRST_TOKENS, f.ctx!());
        let presale = presale::new<QUOTE, QUOTE>(
            &f.package_version,
            &f.config,
            tokens,
            vector[first_tranche()],
            0,
            CLAIM_MS,
            &f.clock,
            f.ctx!(),
        );
        destroy(presale);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidTrancheCount, location = blast_presale::presale)]
fun a_presale_without_tranches_is_rejected() {
    let mut fixture = start();

    fixture.create(vector[], 0, CLAIM_MS);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidTrancheCount, location = blast_presale::presale)]
fun a_presale_over_the_maximum_number_of_tranches_is_rejected() {
    let mut fixture = start();

    fixture.create(vector::tabulate!(9, |_| first_tranche()), 0, CLAIM_MS);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::ETrancheAlreadyEnded, location = blast_presale::presale)]
fun a_tranche_that_already_ended_is_rejected() {
    let mut fixture = start();
    fixture.set_time(FIRST_END_MS);

    fixture.create(two_tranches(), 0, CLAIM_MS);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::ETokenDepositMismatch, location = blast_presale::presale)]
fun a_deposit_that_is_not_the_tranches_tokens_is_rejected() {
    let mut fixture = start();

    fixture.create_with_deposit(FIRST_TOKENS + SECOND_TOKENS + 1, two_tranches(), 0, CLAIM_MS);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidClaimTime, location = blast_presale::presale)]
fun claims_opening_before_a_tranche_ends_are_rejected() {
    let mut fixture = start();

    fixture.create(two_tranches(), 0, SECOND_END_MS - 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidMinRaise, location = blast_presale::presale)]
fun a_minimum_above_what_the_tranches_can_raise_is_rejected() {
    let mut fixture = start();

    fixture.create(two_tranches(), FIRST_QUOTE + SECOND_QUOTE + 1, CLAIM_MS);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_package_version_rejects_creation_first() {
    let mut fixture = start();
    fixture.package_version.set_for_testing(2);

    fixture.create(vector[], 0, CLAIM_MS);
    fixture.end();
}

// --- Commits ---

#[test]
fun a_first_come_tranche_fills_in_order_and_returns_the_excess() {
    let mut fixture = start();
    let presale_id = fixture.create(two_tranches(), 0, CLAIM_MS);

    assert_eq!(fixture.commit(ALICE, 0, 200), 0);
    assert_eq!(fixture.commit(BOB, 0, 200), 100);
    assert_eq!(
        bcs::to_bytes(&only_event<Committed>()),
        u64_payload(presale_id, vector[0, 100, FIRST_QUOTE]),
    );
    assert_eq!(fixture.position(ALICE, 0), option::some(vector[200, 0, 0]));
    assert_eq!(fixture.position(BOB, 0), option::some(vector[100, 0, 0]));
    fixture.next_tx!(KEEPER, |f| {
        let presale = f.take_presale();

        assert_balances(&presale, FIRST_TOKENS + SECOND_TOKENS, FIRST_QUOTE);
        presale.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::ETrancheSoldOut, location = blast_presale::tranche)]
fun a_sold_out_first_come_tranche_rejects_a_commit() {
    let mut fixture = start();
    fixture.create(two_tranches(), 0, CLAIM_MS);
    fixture.commit(ALICE, 0, FIRST_QUOTE);

    fixture.commit(BOB, 0, 1);
    fixture.end();
}

#[test]
fun a_pro_rata_tranche_accepts_past_its_quote() {
    let mut fixture = start();
    fixture.create(two_tranches(), 0, CLAIM_MS);
    fixture.set_time(FIRST_END_MS);

    assert_eq!(fixture.commit(ALICE, 1, 500), 0);
    assert_eq!(fixture.commit(ALICE, 1, 100), 0);
    assert_eq!(fixture.position(ALICE, 1), option::some(vector[600, 0, 0]));
    fixture.end();
}

#[test]
fun a_wallet_cap_limits_each_address_in_a_public_tranche() {
    let mut fixture = start();
    let capped = tranche::new(
        FIRST_TOKENS,
        FIRST_QUOTE,
        START_MS,
        FIRST_END_MS,
        tranche::pro_rata(),
        50,
        option::none(),
        0,
    );
    fixture.create(vector[capped], 0, CLAIM_MS);

    assert_eq!(fixture.commit(ALICE, 0, 80), 30);
    assert_eq!(fixture.commit(BOB, 0, 50), 0);
    assert_eq!(fixture.position(ALICE, 0), option::some(vector[50, 0, 0]));
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EWalletCapReached, location = blast_presale::tranche)]
fun an_address_at_its_wallet_cap_is_rejected() {
    let mut fixture = start();
    let capped = tranche::new(
        FIRST_TOKENS,
        FIRST_QUOTE,
        START_MS,
        FIRST_END_MS,
        tranche::pro_rata(),
        50,
        option::none(),
        0,
    );
    fixture.create(vector[capped], 0, CLAIM_MS);
    fixture.commit(ALICE, 0, 50);

    fixture.commit(ALICE, 0, 1);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::ETrancheNotOpen, location = blast_presale::presale)]
fun a_commit_before_the_tranche_starts_is_rejected() {
    let mut fixture = start();
    fixture.create(two_tranches(), 0, CLAIM_MS);

    fixture.commit(ALICE, 1, 100);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::ETrancheNotOpen, location = blast_presale::presale)]
fun a_commit_at_the_tranche_end_is_rejected() {
    let mut fixture = start();
    fixture.create(two_tranches(), 0, CLAIM_MS);
    fixture.set_time(FIRST_END_MS);

    fixture.commit(ALICE, 0, 100);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::ETrancheNotOpen, location = blast_presale::presale)]
fun a_closed_tranche_precedes_a_zero_commit() {
    let mut fixture = start();
    fixture.create(two_tranches(), 0, CLAIM_MS);
    fixture.set_time(FIRST_END_MS);

    fixture.commit(ALICE, 0, 0);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EZeroCommit, location = blast_presale::presale)]
fun a_zero_commit_is_rejected() {
    let mut fixture = start();
    fixture.create(two_tranches(), 0, CLAIM_MS);

    fixture.commit(ALICE, 0, 0);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EUnknownTranche, location = blast_presale::presale)]
fun a_commit_to_a_missing_tranche_is_rejected() {
    let mut fixture = start();
    fixture.create(two_tranches(), 0, CLAIM_MS);

    fixture.commit(ALICE, 2, 100);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_package_version_rejects_a_commit_first() {
    let mut fixture = start();
    fixture.create(two_tranches(), 0, CLAIM_MS);
    fixture.package_version.set_for_testing(2);

    fixture.commit(ALICE, 2, 0);
    fixture.end();
}

// --- Whitelist ---

#[test]
fun a_listed_address_commits_up_to_its_allowance() {
    let mut fixture = start();
    let (root, proofs) = two_leaf_tree();
    fixture.create(vector[whitelisted_tranche(root)], 0, CLAIM_MS);

    assert_eq!(fixture.commit_listed(ALICE, 0, 150, 0, 100, proofs[0]), 50);
    assert_eq!(fixture.commit_listed(BOB, 0, 150, 1, 0, proofs[1]), 0);
    assert_eq!(fixture.position(ALICE, 0), option::some(vector[100, 0, 0]));
    assert_eq!(fixture.position(BOB, 0), option::some(vector[150, 0, 0]));
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidWhitelistProof, location = blast_presale::presale)]
fun another_address_cannot_use_a_listed_leaf() {
    let mut fixture = start();
    let (root, proofs) = two_leaf_tree();
    fixture.create(vector[whitelisted_tranche(root)], 0, CLAIM_MS);

    fixture.commit_listed(CAROL, 0, 50, 0, 100, proofs[0]);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EInvalidWhitelistProof, location = blast_presale::presale)]
fun a_listed_address_cannot_raise_its_allowance() {
    let mut fixture = start();
    let (root, proofs) = two_leaf_tree();
    fixture.create(vector[whitelisted_tranche(root)], 0, CLAIM_MS);

    fixture.commit_listed(ALICE, 0, 150, 0, 200, proofs[0]);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::ETrancheAccessMismatch, location = blast_presale::presale)]
fun a_public_commit_to_a_whitelisted_tranche_is_rejected() {
    let mut fixture = start();
    let (root, _) = two_leaf_tree();
    fixture.create(vector[whitelisted_tranche(root)], 0, CLAIM_MS);

    fixture.commit(ALICE, 0, 50);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::ETrancheAccessMismatch, location = blast_presale::presale)]
fun a_whitelisted_commit_to_a_public_tranche_is_rejected() {
    let mut fixture = start();
    let (_, proofs) = two_leaf_tree();
    fixture.create(two_tranches(), 0, CLAIM_MS);

    fixture.commit_listed(ALICE, 0, 50, 0, 100, proofs[0]);
    fixture.end();
}

// --- Finalization ---

#[test, expected_failure(abort_code = blast_presale::errors::EPresaleNotEnded, location = blast_presale::presale)]
fun finalization_before_the_last_tranche_ends_is_rejected() {
    let mut fixture = start();
    fixture.create(two_tranches(), 0, CLAIM_MS);
    fixture.set_time(SECOND_END_MS - 1);

    fixture.finalize();
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::EPresaleFinalized, location = blast_presale::presale)]
fun a_second_finalization_is_rejected() {
    let mut fixture = start();
    fixture.create(two_tranches(), 0, CLAIM_MS);
    fixture.set_time(SECOND_END_MS);
    fixture.finalize();

    fixture.finalize();
    fixture.end();
}

#[test]
fun a_successful_presale_pays_the_creator_and_blast_and_returns_the_unsold_tokens() {
    let mut fixture = start();
    let presale_id = fixture.reach_the_end(0);
    // The first tranche raised 200 of 300 and sold 666 tokens; the second is full.
    let (raised, fee, unsold) = (600, 6, 334);

    fixture.finalize();
    assert_eq!(
        bcs::to_bytes(&only_event<PresaleFinalized>()),
        finalized_bytes(presale_id, true, raised, fee, TREASURY, unsold),
    );
    assert_eq!(fixture.coin_total<QUOTE>(TREASURY), fee);
    assert_eq!(fixture.coin_total<QUOTE>(CREATOR), raised - fee);
    assert_eq!(fixture.coin_total<TOKEN>(CREATOR), unsold);
    fixture.next_tx!(KEEPER, |f| {
        let presale = f.take_presale();

        assert!(presale.is_succeeded_for_testing());
        assert_balances(&presale, FIRST_TOKENS + SECOND_TOKENS - unsold, 800 - raised);
        presale.put_back();
    });
    fixture.end();
}

#[test]
fun a_presale_under_its_minimum_fails_and_returns_every_token() {
    let mut fixture = start();
    let presale_id = fixture.reach_the_end(601);

    fixture.finalize();
    assert_eq!(
        bcs::to_bytes(&only_event<PresaleFinalized>()),
        finalized_bytes(presale_id, false, 600, 0, TREASURY, FIRST_TOKENS + SECOND_TOKENS),
    );
    assert_eq!(fixture.coin_total<QUOTE>(TREASURY), 0);
    assert_eq!(fixture.coin_total<QUOTE>(CREATOR), 0);
    assert_eq!(fixture.coin_total<TOKEN>(CREATOR), FIRST_TOKENS + SECOND_TOKENS);
    fixture.next_tx!(KEEPER, |f| {
        let presale = f.take_presale();

        assert!(presale.is_failed_for_testing());
        assert_balances(&presale, 0, 800);
        presale.put_back();
    });
    fixture.end();
}

#[test]
fun a_presale_at_its_minimum_succeeds() {
    let mut fixture = start();
    fixture.reach_the_end(600);

    fixture.finalize();
    fixture.next_tx!(KEEPER, |f| {
        let presale = f.take_presale();

        assert!(presale.is_succeeded_for_testing());
        presale.put_back();
    });
    fixture.end();
}

#[test]
fun a_presale_keeps_the_fee_it_was_created_with() {
    let mut fixture = start();
    fixture.reach_the_end(0);
    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();
        f.config.set_fee_bps(&f.package_version, &witness, 1_000);
    });

    fixture.finalize();
    assert_eq!(fixture.coin_total<QUOTE>(TREASURY), 6);
    fixture.end();
}

#[test]
fun an_empty_presale_without_a_minimum_returns_every_token() {
    let mut fixture = start();
    fixture.create(two_tranches(), 0, CLAIM_MS);
    fixture.set_time(SECOND_END_MS);

    fixture.finalize();
    assert_eq!(fixture.coin_total<TOKEN>(CREATOR), FIRST_TOKENS + SECOND_TOKENS);
    assert_eq!(fixture.coin_total<QUOTE>(TREASURY), 0);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_package_version_rejects_finalization_first() {
    let mut fixture = start();
    fixture.create(two_tranches(), 0, CLAIM_MS);
    fixture.package_version.set_for_testing(2);

    fixture.finalize();
    fixture.end();
}

// --- Claims ---

#[test, expected_failure(abort_code = blast_presale::errors::EPresaleNotFinalized, location = blast_presale::presale)]
fun a_claim_before_finalization_is_rejected() {
    let mut fixture = start();
    fixture.create(two_tranches(), 0, CLAIM_MS);
    fixture.commit(ALICE, 0, 100);

    fixture.claim(ALICE, 0);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::ENothingToClaim, location = blast_presale::presale)]
fun a_claim_without_a_position_is_rejected() {
    let mut fixture = start();
    fixture.reach_the_end(0);
    fixture.finalize();
    fixture.set_time(CLAIM_MS);

    fixture.claim(CAROL, 0);
    fixture.end();
}

#[test]
fun a_pro_rata_refund_is_paid_at_once_and_the_tokens_from_the_claim_time() {
    let mut fixture = start();
    let presale_id = fixture.reach_the_end(0);
    fixture.finalize();

    // Bob committed 300 of the second tranche's 600: he buys 1,000 tokens for 200 and gets 100
    // back.
    fixture.claim(BOB, 1);
    assert_eq!(
        bcs::to_bytes(&only_event<Claimed>()),
        claimed_bytes(presale_id, 1, BOB, 0, 100),
    );
    assert_eq!(fixture.coin_total<QUOTE>(BOB), 100);
    assert_eq!(fixture.position(BOB, 1), option::some(vector[300, 0, 1]));

    fixture.set_time(CLAIM_MS);
    fixture.claim(BOB, 1);
    assert_eq!(fixture.coin_total<TOKEN>(BOB), 1_000);
    assert_eq!(fixture.coin_total<QUOTE>(BOB), 100);
    assert_eq!(fixture.position(BOB, 1), option::none());
    fixture.end();
}

#[test, expected_failure(abort_code = blast_presale::errors::ENothingToClaim, location = blast_presale::presale)]
fun a_refunded_position_has_nothing_more_before_the_claim_time() {
    let mut fixture = start();
    fixture.reach_the_end(0);
    fixture.finalize();
    fixture.claim(BOB, 1);

    fixture.claim(BOB, 1);
    fixture.end();
}

#[test]
fun vested_tokens_are_claimed_as_they_vest() {
    let mut fixture = start();
    let vesting = tranche::new(
        FIRST_TOKENS,
        FIRST_QUOTE,
        START_MS,
        FIRST_END_MS,
        tranche::first_come(),
        0,
        option::none(),
        1_000,
    );
    fixture.create(vector[vesting], 0, CLAIM_MS);
    fixture.commit(ALICE, 0, FIRST_QUOTE);
    fixture.set_time(FIRST_END_MS);
    fixture.finalize();

    fixture.set_time(CLAIM_MS + 250);
    fixture.claim(ALICE, 0);
    assert_eq!(fixture.coin_total<TOKEN>(ALICE), 250);
    assert_eq!(fixture.position(ALICE, 0), option::some(vector[FIRST_QUOTE, 250, 1]));

    fixture.set_time(CLAIM_MS + 1_000);
    fixture.claim(ALICE, 0);
    assert_eq!(fixture.coin_total<TOKEN>(ALICE), FIRST_TOKENS);
    assert_eq!(fixture.position(ALICE, 0), option::none());
    fixture.end();
}

#[test]
fun a_failed_presale_refunds_every_commit_in_full() {
    let mut fixture = start();
    fixture.reach_the_end(601);
    fixture.finalize();

    fixture.claim(ALICE, 0);
    fixture.claim(BOB, 1);
    fixture.claim(CAROL, 1);
    assert_eq!(fixture.coin_total<QUOTE>(ALICE), 200);
    assert_eq!(fixture.coin_total<QUOTE>(BOB), 300);
    assert_eq!(fixture.coin_total<QUOTE>(CAROL), 300);
    assert_eq!(fixture.coin_total<TOKEN>(ALICE), 0);
    fixture.next_tx!(KEEPER, |f| {
        let presale = f.take_presale();

        assert_balances(&presale, 0, 0);
        presale.put_back();
    });
    fixture.end();
}

#[test]
fun anyone_may_claim_and_the_buyer_is_paid() {
    let mut fixture = start();
    fixture.reach_the_end(0);
    fixture.finalize();
    fixture.set_time(CLAIM_MS);

    fixture.claim_for(KEEPER, ALICE, 0);
    assert_eq!(fixture.coin_total<TOKEN>(ALICE), 666);
    assert_eq!(fixture.coin_total<TOKEN>(KEEPER), 0);
    fixture.end();
}

#[test]
fun after_every_claim_the_presale_holds_nothing() {
    let mut fixture = start();
    fixture.reach_the_end(0);
    fixture.finalize();
    fixture.set_time(CLAIM_MS);

    fixture.claim(ALICE, 0);
    fixture.claim(BOB, 1);
    fixture.claim(CAROL, 1);
    assert_eq!(fixture.coin_total<TOKEN>(ALICE), 666);
    assert_eq!(fixture.coin_total<TOKEN>(BOB), 1_000);
    assert_eq!(fixture.coin_total<TOKEN>(CAROL), 1_000);
    fixture.next_tx!(KEEPER, |f| {
        let presale = f.take_presale();

        assert_balances(&presale, 0, 0);
        presale.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EOperationalVersionMismatch, location = blast_admin::operational_version)]
fun a_stale_package_version_rejects_a_claim_first() {
    let mut fixture = start();
    fixture.create(two_tranches(), 0, CLAIM_MS);
    fixture.package_version.set_for_testing(2);

    fixture.claim(ALICE, 0);
    fixture.end();
}

// === Test Helpers ===

// --- Fixture ---

macro fun presale_next_tx(
    $fixture: &mut PresaleFixture,
    $sender: address,
    $fn: |&mut PresaleFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun presale_ctx($fixture: &mut PresaleFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

/// A one-percent fee paid to the treasury, and an administrator with the fee and treasury roles.
fun start(): PresaleFixture {
    let mut fixture = start_with_roles(
        blast_presale_domain::fee_admin_role() | blast_presale_domain::treasury_admin_role(),
    );
    fixture.next_tx!(ADMIN, |f| {
        let witness = f.sign_in();
        f.config.set_fee_bps(&f.package_version, &witness, FEE_BPS);
        f.config.set_fee_destination(&f.package_version, &witness, TREASURY);
    });
    fixture.scenario.next_tx(CREATOR);

    fixture
}

/// The initial fee policy and an administrator holding exactly `roles`.
fun start_with_roles(roles: u64): PresaleFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(&super_admin_cap, roles, ADMIN, scenario.ctx());
    destroy(super_admin_cap);
    presale_config::init_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(START_MS);

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_PRESALE_DOMAIN>>();
    let config = scenario.take_shared<BlastPresaleConfig>();

    PresaleFixture { scenario, package_version, config, authority, admin_cap, clock }
}

fun presale_sign_in(self: &PresaleFixture): AdminWitness<BLAST_PRESALE_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun presale_set_time(self: &mut PresaleFixture, timestamp_ms: u64) {
    self.clock.set_for_testing(timestamp_ms);
}

fun presale_end(self: PresaleFixture) {
    destroy(self);
}

// --- Tranches ---

/// 1,000 tokens for 300 Quote, first come, from the start until the first end.
fun first_tranche(): Tranche {
    tranche::new(
        FIRST_TOKENS,
        FIRST_QUOTE,
        START_MS,
        FIRST_END_MS,
        tranche::first_come(),
        0,
        option::none(),
        0,
    )
}

/// The first tranche, then 2,000 tokens for 400 Quote, pro rata, from the first end until the
/// second.
fun two_tranches(): vector<Tranche> {
    let second = tranche::new(
        SECOND_TOKENS,
        SECOND_QUOTE,
        FIRST_END_MS,
        SECOND_END_MS,
        tranche::pro_rata(),
        0,
        option::none(),
        0,
    );

    vector[first_tranche(), second]
}

/// The first tranche's terms, open only to `root`'s two leaves.
fun whitelisted_tranche(root: vector<u8>): Tranche {
    tranche::new(
        FIRST_TOKENS,
        FIRST_QUOTE,
        START_MS,
        FIRST_END_MS,
        tranche::first_come(),
        0,
        option::some(tranche::whitelist(root, 2)),
        0,
    )
}

/// A whitelist allowing Alice 100 Quote and Bob no limit, and each leaf's proof.
fun two_leaf_tree(): (vector<u8>, vector<vector<vector<u8>>>) {
    let alice = merkle::leaf(0, ALICE, 100);
    let bob = merkle::leaf(1, BOB, 0);

    (merkle::node_for_testing(alice, bob), vector[vector[bob], vector[alice]])
}

// --- Presale ---

/// Creates and shares a presale of exactly the tranches' tokens as the creator, and returns its ID.
fun presale_create(
    self: &mut PresaleFixture,
    tranches: vector<Tranche>,
    min_raise: u64,
    claim_ms: u64,
): ID {
    let mut deposit = 0;
    tranches.do_ref!(|tranche| deposit = deposit + tranche.tokens());

    self.create_with_deposit(deposit, tranches, min_raise, claim_ms)
}

fun presale_create_with_deposit(
    self: &mut PresaleFixture,
    deposit: u64,
    tranches: vector<Tranche>,
    min_raise: u64,
    claim_ms: u64,
): ID {
    self.scenario.next_tx(CREATOR);
    let tokens = coin::mint_for_testing<TOKEN>(deposit, self.scenario.ctx());
    let presale = presale::new<TOKEN, QUOTE>(
        &self.package_version,
        &self.config,
        tokens,
        tranches,
        min_raise,
        claim_ms,
        &self.clock,
        self.scenario.ctx(),
    );
    let presale_id = object::id(&presale);
    presale.share();

    presale_id
}

/// The two-tranche presale with `min_raise`, after Alice committed 200 to the first tranche and
/// Bob and Carol 300 each to the second, at the second tranche's end.
fun presale_reach_the_end(self: &mut PresaleFixture, min_raise: u64): ID {
    let presale_id = self.create(two_tranches(), min_raise, CLAIM_MS);
    self.commit(ALICE, 0, 200);
    self.set_time(FIRST_END_MS);
    self.commit(BOB, 1, 300);
    self.commit(CAROL, 1, 300);
    self.set_time(SECOND_END_MS);

    presale_id
}

/// Commits `amount` to public tranche `tranche` as `buyer` and returns what was not accepted.
fun presale_commit(self: &mut PresaleFixture, buyer: address, tranche: u64, amount: u64): u64 {
    self.scenario.next_tx(buyer);
    let mut presale = self.take_presale();
    let quote = coin::mint_for_testing<QUOTE>(amount, self.scenario.ctx());
    let excess = presale.commit(
        &self.package_version,
        tranche,
        quote,
        &self.clock,
        self.scenario.ctx(),
    );
    let excess_value = excess.value();
    destroy(excess);
    presale.put_back();

    excess_value
}

/// Commits to whitelisted tranche `tranche` as `buyer` with its leaf, and returns what was not
/// accepted.
fun presale_commit_listed(
    self: &mut PresaleFixture,
    buyer: address,
    tranche: u64,
    amount: u64,
    index: u64,
    max_quote: u64,
    proof: vector<vector<u8>>,
): u64 {
    self.scenario.next_tx(buyer);
    let mut presale = self.take_presale();
    let quote = coin::mint_for_testing<QUOTE>(amount, self.scenario.ctx());
    let excess = presale.commit_whitelisted(
        &self.package_version,
        tranche,
        quote,
        index,
        max_quote,
        proof,
        &self.clock,
        self.scenario.ctx(),
    );
    let excess_value = excess.value();
    destroy(excess);
    presale.put_back();

    excess_value
}

/// Finalizes the presale as the keeper.
fun presale_finalize(self: &mut PresaleFixture) {
    self.scenario.next_tx(KEEPER);
    let mut presale = self.take_presale();

    presale.finalize(&self.package_version, &self.config, &self.clock, self.scenario.ctx());
    presale.put_back();
}

/// Claims `buyer`'s position in `tranche` as the buyer itself.
fun presale_claim(self: &mut PresaleFixture, buyer: address, tranche: u64) {
    self.claim_for(buyer, buyer, tranche);
}

/// Claims `buyer`'s position in `tranche` as `sender`.
fun presale_claim_for(self: &mut PresaleFixture, sender: address, buyer: address, tranche: u64) {
    self.scenario.next_tx(sender);
    let mut presale = self.take_presale();

    presale.claim(&self.package_version, tranche, buyer, &self.clock, self.scenario.ctx());
    presale.put_back();
}

/// `buyer`'s position in `tranche` as `[committed, claimed_tokens, refunded]`, in a new
/// transaction.
fun presale_position(self: &mut PresaleFixture, buyer: address, tranche: u64): Option<vector<u64>> {
    self.scenario.next_tx(KEEPER);
    let presale = self.take_presale();
    let position = presale.position_for_testing(buyer, tranche);
    presale.put_back();

    position
}

// --- Storage ---

fun presale_take_presale(self: &PresaleFixture): BlastPresale<TOKEN, QUOTE> {
    self.scenario.take_shared()
}

/// Returns a taken presale to shared storage for a later transaction.
fun put_back(presale: BlastPresale<TOKEN, QUOTE>) {
    test_scenario::return_shared(presale);
}

/// Sums every `Coin<T>` `owner` holds, in a new transaction.
fun presale_coin_total<T>(self: &mut PresaleFixture, owner: address): u64 {
    self.scenario.next_tx(KEEPER);

    test_scenario::ids_for_address<Coin<T>>(owner).fold!(0, |sum, id| {
        let coin = self.scenario.take_from_address_by_id<Coin<T>>(owner, id);
        let value = coin.value();
        test_scenario::return_to_address(owner, coin);
        sum + value
    })
}

// --- Assertions ---

fun assert_balances(presale: &BlastPresale<TOKEN, QUOTE>, tokens: u64, quote: u64) {
    let (actual_tokens, actual_quote) = presale.balances_for_testing();

    assert_eq!(actual_tokens, tokens);
    assert_eq!(actual_quote, quote);
}

// --- Events ---

/// This transaction's only event of type `T`.
fun only_event<T: copy + drop>(): T {
    let mut events = event::events_by_type<Event<T>>();
    assert_eq!(events.length(), 1);

    events.pop_back().unwrap()
}

fun u64_bytes(value: u64): vector<u8> {
    bcs::to_bytes(&value)
}

/// Expected bytes of a payload whose fields after the presale ID are all `u64`.
fun u64_payload(presale_id: ID, fields: vector<u64>): vector<u8> {
    let mut expected = bcs::to_bytes(&presale_id);
    fields.do!(|field| expected.append(bcs::to_bytes(&field)));
    expected
}

fun finalized_bytes(
    presale_id: ID,
    succeeded: bool,
    raised: u64,
    fee: u64,
    fee_destination: address,
    unsold: u64,
): vector<u8> {
    let mut expected = bcs::to_bytes(&presale_id);
    expected.append(bcs::to_bytes(&succeeded));
    expected.append(bcs::to_bytes(&raised));
    expected.append(bcs::to_bytes(&fee));
    expected.append(bcs::to_bytes(&fee_destination));
    expected.append(bcs::to_bytes(&unsold));
    expected
}

fun claimed_bytes(
    presale_id: ID,
    tranche: u64,
    buyer: address,
    tokens: u64,
    quote: u64,
): vector<u8> {
    let mut expected = bcs::to_bytes(&presale_id);
    expected.append(bcs::to_bytes(&tranche));
    expected.append(bcs::to_bytes(&buyer));
    expected.append(bcs::to_bytes(&tokens));
    expected.append(bcs::to_bytes(&quote));
    expected
}

// === Imports ===

use blast_admin::acl::{Authority, AdminCap, AdminWitness};

use blast_presale::{
    blast_events::Event,
    blast_presale_domain::{Self, BLAST_PRESALE_DOMAIN},
    domain_fixture,
    events::{
        Claimed,
        Committed,
        FeeDestinationSet,
        FeeSet,
        PresaleCreated,
        PresaleFinalized,
    },
    merkle,
    package_version::{Self, PackageVersion},
    presale::{Self, BlastPresale},
    presale_config::{Self, BlastPresaleConfig},
    tranche::{Self, Tranche},
};

use std::{bcs, type_name, unit_test::{assert_eq, destroy}};

use sui::{clock::{Self, Clock}, coin::{Self, Coin}, event, test_scenario::{Self, Scenario}};

use fun presale_ctx as PresaleFixture.ctx;

use fun presale_end as PresaleFixture.end;

use fun presale_next_tx as PresaleFixture.next_tx;

use fun presale_sign_in as PresaleFixture.sign_in;

use fun presale_set_time as PresaleFixture.set_time;

use fun presale_create as PresaleFixture.create;

use fun presale_create_with_deposit as PresaleFixture.create_with_deposit;

use fun presale_reach_the_end as PresaleFixture.reach_the_end;

use fun presale_commit as PresaleFixture.commit;

use fun presale_commit_listed as PresaleFixture.commit_listed;

use fun presale_finalize as PresaleFixture.finalize;

use fun presale_claim as PresaleFixture.claim;

use fun presale_claim_for as PresaleFixture.claim_for;

use fun presale_position as PresaleFixture.position;

use fun presale_take_presale as PresaleFixture.take_presale;

use fun presale_coin_total as PresaleFixture.coin_total;

use fun put_back as BlastPresale.put_back;
