// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::migration_rewards_tests;

// === Constants ===

const CREATOR: address = @0xC0FFEE;
const HOLDER: address = @0xA11CE;
const FEE_RECIPIENT: address = @0xFEE;
const PARTNER_RECIPIENT: address = @0xB1A57;
const PARTNER_CUT_BPS: u64 = 4_000;
const TREASURY: address = @0x7EA5;
const CLAIM_DEADLINE_MS: u64 = 1_000;

// === Test-Only Types ===

public struct MEME() has drop;
public struct QUOTE() has drop;
public struct Venue() has drop;
public struct Position has key, store { id: UID }

// === Tests ===

#[test]
/// Each collection pays every fee recipient and routes holder Meme at once,
/// retains holder Quote, and assigns every atomic unit exactly once.
fun collected_fees_pay_recipients_and_route_only_holder_meme() {
    let mut scenario = test_scenario::begin(CREATOR);
    let presale_id = object::id_from_address(@0xCAFE);
    let presale_cap = presale::cap_for_testing(presale_id, scenario.ctx());
    let mut vault = vault::new_for_testing<MEME, QUOTE>(
        presale_id,
        object::id(&presale_cap),
        presale::fee_split(
            vector[
                presale::recipient_share(CREATOR, bps::new(5_000)),
                presale::recipient_share(FEE_RECIPIENT, bps::new(2_000)),
            ],
            bps::new(3_000),
        ),
        no_protocol_fees(),
        option::none(),
        scenario.ctx(),
    );

    vault.collect_fees(
        coin::mint_for_testing<MEME>(101, scenario.ctx()).into_balance(),
        coin::mint_for_testing<QUOTE>(10, scenario.ctx()).into_balance(),
        &mut scenario,
    );

    let (
        gross_meme,
        gross_quote,
        fee_recipient_meme,
        fee_recipient_quote,
        holder_rewards_meme,
        holder_rewards_quote,
    ) = only_event<FeesCollected<MEME, QUOTE>>().fees_collected_fields();
    assert_eq!(vector[gross_meme, gross_quote], vector[101, 10]);
    assert_eq!(fee_recipient_meme, vector[51, 20]);
    assert_eq!(fee_recipient_quote, vector[5, 2]);
    assert_eq!(vector[holder_rewards_meme, holder_rewards_quote], vector[30, 3]);
    let (vault_meme, vault_quote) = vault.holder_rewards_balances();
    assert_eq!(vector[vault_meme, vault_quote], vector[0, 3]);

    scenario.next_tx(CREATOR);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 51);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 5);

    scenario.next_tx(FEE_RECIPIENT);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 20);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 2);

    vault.destroy_holding(0, 3);
    destroy(presale_cap);
    scenario.end();
}

#[test]
/// Blast's snapshotted LP share of each asset, rounded up, goes to the policy's current
/// destination before the creator's split applies to the rest.
fun collected_fees_pay_blast_its_share_first() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut policy = fee_policy::new_for_testing(scenario.ctx());
    policy.set_destination(&treasury_admin(), TREASURY);
    let mut vault = vault_paying_blast(option::none(), &mut scenario);

    vault.credit_fees_for_testing(
        &policy,
        coin::mint_for_testing<MEME>(101, scenario.ctx()).into_balance(),
        coin::mint_for_testing<QUOTE>(10, scenario.ctx()).into_balance(),
        scenario.ctx(),
    );

    let event = only_event<FeesCollected<MEME, QUOTE>>();
    let (destination, protocol_meme, protocol_quote) = event.fees_collected_protocol_fields();
    assert_eq!(destination, option::some(TREASURY));
    // ceil(101 * 10%) = 11 and ceil(10 * 25%) = 3; the creator's split apportions 90 and 7.
    assert_eq!(vector[protocol_meme, protocol_quote], vector[11, 3]);

    let (
        gross_meme,
        gross_quote,
        fee_recipient_meme,
        fee_recipient_quote,
        holder_rewards_meme,
        holder_rewards_quote,
    ) = event.fees_collected_fields();
    assert_eq!(vector[gross_meme, gross_quote], vector[101, 10]);
    assert_eq!(fee_recipient_meme, vector[45, 18]);
    assert_eq!(fee_recipient_quote, vector[4, 1]);
    assert_eq!(vector[holder_rewards_meme, holder_rewards_quote], vector[27, 2]);

    scenario.next_tx(TREASURY);
    assert_eq!(scenario.sender_total_meme(), 38);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 3);

    vault.destroy_holding(0, 2);
    policy.destroy_for_testing();
    scenario.end();
}

#[test]
/// A vault whose sale named a partner splits its fees exactly as any vault, but holds Blast's LP
/// fees for the partner payout instead of paying them.
fun a_partnered_vault_holds_blasts_lp_fees_for_its_partner() {
    let mut scenario = test_scenario::begin(CREATOR);
    let partner = partners::new_for_testing(PARTNER_RECIPIENT, PARTNER_CUT_BPS, scenario.ctx());
    let mut vault = vault_paying_blast(option::some(object::id(&partner)), &mut scenario);

    vault.collect_fees(
        coin::mint_for_testing<MEME>(101, scenario.ctx()).into_balance(),
        coin::mint_for_testing<QUOTE>(10, scenario.ctx()).into_balance(),
        &mut scenario,
    );

    let event = only_event<FeesCollected<MEME, QUOTE>>();
    let (destination, protocol_meme, protocol_quote) = event.fees_collected_protocol_fields();
    assert_eq!(destination, option::none());
    assert_eq!(vector[protocol_meme, protocol_quote], vector[11, 3]);
    let (_, _, fee_recipient_meme, fee_recipient_quote, holder_rewards_meme, holder_rewards_quote) =
        event.fees_collected_fields();
    assert_eq!(fee_recipient_meme, vector[45, 18]);
    assert_eq!(fee_recipient_quote, vector[4, 1]);
    assert_eq!(vector[holder_rewards_meme, holder_rewards_quote], vector[27, 2]);
    let (unpaid_meme, unpaid_quote) = vault.unpaid_protocol_lp_fees_for_testing();
    assert_eq!(vector[unpaid_meme, unpaid_quote], vector[11, 3]);

    // The collection's fee policy pays the sender, who receives only its recipient share.
    scenario.next_tx(CREATOR);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 45);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 4);
    assert!(!scenario.has_most_recent_for_sender<Coin<MEME>>());
    assert!(!scenario.has_most_recent_for_sender<Coin<QUOTE>>());

    vault.pay_held_lp_fees(&partner, TREASURY, &mut scenario);
    vault.destroy_holding(0, 2);
    destroy(partner);
    scenario.end();
}

#[test]
/// Anyone may pay a partnered vault's held Blast LP fees: the partner its cut of each asset in
/// force now, rounded down, and the fee policy's current destination the rest.
fun anyone_pays_the_partner_its_cut_of_blasts_lp_fees_and_blast_the_rest() {
    let mut scenario = test_scenario::begin(CREATOR);
    let partner = partners::new_for_testing(PARTNER_RECIPIENT, PARTNER_CUT_BPS, scenario.ctx());
    let mut vault = vault_paying_blast(option::some(object::id(&partner)), &mut scenario);
    2u64.do!(|_| vault.collect_fees(
        coin::mint_for_testing<MEME>(101, scenario.ctx()).into_balance(),
        coin::mint_for_testing<QUOTE>(10, scenario.ctx()).into_balance(),
        &mut scenario,
    ));

    scenario.next_tx(HOLDER);
    vault.pay_held_lp_fees(&partner, TREASURY, &mut scenario);

    // The vault held 22 Meme and 6 Quote: 40% is 8.8 and 2.4, so the partner takes 8 and 2.
    let (vault_id, destination, protocol_meme, protocol_quote, partner_meme, partner_quote) =
        only_event<ProtocolLpFeesPaid<MEME, QUOTE>>().protocol_lp_fees_paid_fields();
    assert_eq!(vault_id, object::id(&vault));
    assert_eq!(destination, TREASURY);
    assert_eq!(vector[protocol_meme, protocol_quote, partner_meme, partner_quote], vector[14, 4, 8, 2]);
    let (meme_partner_id, meme_paid) = only_event<PartnerPaid<MEME>>().partner_paid_fields();
    let (quote_partner_id, quote_paid) = only_event<PartnerPaid<QUOTE>>().partner_paid_fields();
    assert_eq!(vector[meme_partner_id, quote_partner_id], vector[object::id(&partner), object::id(&partner)]);
    assert_eq!(vector[meme_paid, quote_paid], vector[8, 2]);
    let (unpaid_meme, unpaid_quote) = vault.unpaid_protocol_lp_fees_for_testing();
    assert_eq!(vector[unpaid_meme, unpaid_quote], vector[0, 0]);

    scenario.next_tx(TREASURY);
    assert_eq!(scenario.sender_total_meme(), 68);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 4);

    vault.destroy_holding(0, 4);
    destroy(partner);
    scenario.end();
}

#[test]
/// Held Blast LP fees go to the destination the fee policy names at the payout, not the one it
/// named when they were collected.
fun held_lp_fees_go_to_the_destination_in_force_at_payout() {
    let mut scenario = test_scenario::begin(CREATOR);
    let partner = partners::new_for_testing(PARTNER_RECIPIENT, PARTNER_CUT_BPS, scenario.ctx());
    let mut vault = vault_paying_blast(option::some(object::id(&partner)), &mut scenario);
    let mut policy = fee_policy::new_for_testing(scenario.ctx());
    policy.set_destination(&treasury_admin(), TREASURY);
    vault.credit_fees_for_testing(
        &policy,
        coin::mint_for_testing<MEME>(101, scenario.ctx()).into_balance(),
        coin::mint_for_testing<QUOTE>(10, scenario.ctx()).into_balance(),
        scenario.ctx(),
    );

    vault.pay_held_lp_fees(&partner, HOLDER, &mut scenario);

    // 40% of the 11 Meme and 3 Quote held is 4.4 and 1.2: Blast's new destination gets 7 and 2.
    scenario.next_tx(HOLDER);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 7);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 2);
    scenario.next_tx(TREASURY);
    assert_eq!(scenario.sender_total_meme(), 27);
    assert!(!scenario.has_most_recent_for_sender<Coin<QUOTE>>());

    vault.destroy_holding(0, 2);
    policy.destroy_for_testing();
    destroy(partner);
    scenario.end();
}

#[test]
/// A partner whose cut is zero is paid nothing and emits no `PartnerPaid`; Blast is paid every
/// held LP fee.
fun a_zero_cut_partner_leaves_blast_every_held_lp_fee() {
    let mut scenario = test_scenario::begin(CREATOR);
    let partner = partners::new_for_testing(PARTNER_RECIPIENT, 0, scenario.ctx());
    let mut vault = vault_paying_blast(option::some(object::id(&partner)), &mut scenario);
    vault.collect_fees(
        coin::mint_for_testing<MEME>(101, scenario.ctx()).into_balance(),
        coin::mint_for_testing<QUOTE>(10, scenario.ctx()).into_balance(),
        &mut scenario,
    );

    vault.pay_held_lp_fees(&partner, TREASURY, &mut scenario);

    let (_, _, protocol_meme, protocol_quote, partner_meme, partner_quote) = only_event<
        ProtocolLpFeesPaid<MEME, QUOTE>,
    >().protocol_lp_fees_paid_fields();
    assert_eq!(vector[protocol_meme, protocol_quote, partner_meme, partner_quote], vector[11, 3, 0, 0]);
    assert!(event::events_by_type<PartnerPaid<MEME>>().is_empty());
    assert!(event::events_by_type<PartnerPaid<QUOTE>>().is_empty());

    vault.destroy_holding(0, 2);
    destroy(partner);
    scenario.end();
}

#[test]
/// A partnered vault holding no Blast LP fees pays nothing and emits nothing, so the payout can
/// follow any collection, an empty one included.
fun a_partner_payout_with_nothing_held_moves_nothing() {
    let mut scenario = test_scenario::begin(CREATOR);
    let partner = partners::new_for_testing(PARTNER_RECIPIENT, PARTNER_CUT_BPS, scenario.ctx());
    let mut vault = vault_paying_blast(option::some(object::id(&partner)), &mut scenario);

    vault.pay_held_lp_fees(&partner, TREASURY, &mut scenario);

    assert!(event::events_by_type<ProtocolLpFeesPaid<MEME, QUOTE>>().is_empty());
    scenario.next_tx(TREASURY);
    assert!(!scenario.has_most_recent_for_sender<Coin<MEME>>());
    assert!(!scenario.has_most_recent_for_sender<Coin<QUOTE>>());

    vault.destroy_for_testing();
    destroy(partner);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = vault::EWrongPartner, location = blast_presale::presale_vault)]
/// Only the partner the sale named can be paid from its vault, even with nothing held.
fun a_vault_cannot_pay_another_partner() {
    let mut scenario = test_scenario::begin(CREATOR);
    let partner = partners::new_for_testing(PARTNER_RECIPIENT, PARTNER_CUT_BPS, scenario.ctx());
    let other_partner = partners::new_for_testing(CREATOR, PARTNER_CUT_BPS, scenario.ctx());
    let mut vault = vault_paying_blast(option::some(object::id(&partner)), &mut scenario);

    vault.pay_held_lp_fees(&other_partner, TREASURY, &mut scenario);

    abort
}

#[test]
#[expected_failure(abort_code = vault::EWrongPartner, location = blast_presale::presale_vault)]
/// A vault whose sale named no partner pays Blast at each collection and has no partner payout.
fun a_vault_without_a_partner_has_no_partner_payout() {
    let mut scenario = test_scenario::begin(CREATOR);
    let partner = partners::new_for_testing(PARTNER_RECIPIENT, PARTNER_CUT_BPS, scenario.ctx());
    let mut vault = vault_paying_blast(option::none(), &mut scenario);

    vault.pay_held_lp_fees(&partner, TREASURY, &mut scenario);

    abort
}

#[test]
/// The administrator changes one vault's LP rates, down to zero and up; its next collection pays
/// Blast at the new rates, and the creator's split applies to the rest.
fun the_admin_changes_a_vaults_lp_fee_rates() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut policy = fee_policy::new_for_testing(scenario.ctx());
    policy.set_destination(&treasury_admin(), TREASURY);
    let mut vault = vault_paying_blast(option::none(), &mut scenario);

    vault.set_protocol_lp_fees(&fee_admin(), bps::new(0), bps::new(5_000));

    let (vault_id, lp_fee_meme_bps, lp_fee_quote_bps) = only_event<
        ProtocolLpFeesChanged<MEME, QUOTE>,
    >().protocol_lp_fees_changed_fields();
    assert_eq!(vault_id, object::id(&vault));
    assert_eq!(vector[lp_fee_meme_bps, lp_fee_quote_bps], vector[0, 5_000]);

    vault.credit_fees_for_testing(
        &policy,
        coin::mint_for_testing<MEME>(101, scenario.ctx()).into_balance(),
        coin::mint_for_testing<QUOTE>(10, scenario.ctx()).into_balance(),
        scenario.ctx(),
    );

    let event = only_event<FeesCollected<MEME, QUOTE>>();
    let (_, protocol_meme, protocol_quote) = event.fees_collected_protocol_fields();
    // Nothing of 101 Meme and ceil(10 * 50%) = 5 Quote; the creator's split apportions 101 and 5.
    assert_eq!(vector[protocol_meme, protocol_quote], vector[0, 5]);
    let (_, _, fee_recipient_meme, fee_recipient_quote, holder_rewards_meme, holder_rewards_quote) =
        event.fees_collected_fields();
    assert_eq!(fee_recipient_meme, vector[51, 20]);
    assert_eq!(fee_recipient_quote, vector[3, 1]);
    assert_eq!(vector[holder_rewards_meme, holder_rewards_quote], vector[30, 1]);

    vault.destroy_holding(0, 1);
    policy.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = vault::EProtocolLpFeesUnchanged,
    location = blast_presale::presale_vault,
)]
fun a_vault_lp_fee_update_must_change_the_rates() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = vault_paying_blast(option::none(), &mut scenario);

    vault.set_protocol_lp_fees(&fee_admin(), bps::new(1_000), bps::new(2_500));
    abort
}

#[test]
/// Blast's administrator, not the presale creator, funds holder rounds.
fun the_admin_publishes_holder_rounds_from_the_holder_share() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = new_vault(vector[], 10_000, &mut scenario);
    vault.credit_holder_for_testing(
        balance::create_for_testing<MEME>(40), balance::create_for_testing<QUOTE>(5),
    );
    let clock = clock::create_for_testing(scenario.ctx());

    let policy = fee_policy::new_for_testing(scenario.ctx());
    rewards::publish_round(
        &mut vault,
        &rewards_admin(), &policy, policy.destination(),
        0,
        0,
        10,
        hash::blake2b256(&b"root"),
        hash::blake2b256(&b"manifest"),
        1,
        40,
        5,
        0,
        CLAIM_DEADLINE_MS,
        &clock,
        scenario.ctx(),
    );
    policy.destroy_for_testing();

    let (vault_meme, vault_quote) = vault.holder_rewards_balances();
    assert_eq!(vector[vault_meme, vault_quote], vector[0, 0]);

    scenario.next_tx(CREATOR);
    let round = scenario.take_shared<Round<MEME, QUOTE>>();
    let (round_meme, round_quote) = round.balances_for_testing();
    assert_eq!(vector[round_meme, round_quote], vector[40, 5]);

    test_scenario::return_shared(round);
    clock.destroy_for_testing();
    vault.destroy_for_testing();
    scenario.end();
}

#[test]
/// Equal fractional remainders favor the fee recipient over the holder-reward share.
fun a_remainder_tie_goes_to_the_fee_recipient_before_holders() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = new_vault(vector[presale::recipient_share(CREATOR, bps::new(5_000))], 5_000, &mut scenario);

    vault.collect_fees(
        coin::mint_for_testing<MEME>(3, scenario.ctx()).into_balance(),
        balance::zero<QUOTE>(),
        &mut scenario,
    );

    let (_, _, fee_recipient_meme, _, holder_rewards_meme, _) = only_event<
        FeesCollected<MEME, QUOTE>,
    >().fees_collected_fields();
    assert_eq!(fee_recipient_meme, vector[2]);
    assert_eq!(holder_rewards_meme, 1);

    scenario.next_tx(CREATOR);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 2);

    vault.destroy_holding(0, 0);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = vault::EWrongPresaleCap, location = blast_presale::presale_vault)]
/// Only the presale's own creator capability reaches the migration residuals.
fun another_presale_cap_cannot_claim_migration_residuals() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = new_vault(vector[], 10_000, &mut scenario);
    let other_cap = presale::cap_for_testing(object::id_from_address(@0xD1FF), scenario.ctx());

    let (meme, quote) = vault.claim_migration_residuals(&other_cap, scenario.ctx());
    destroy(meme);
    destroy(quote);
    abort
}

#[test]
/// A vault created without a presale names none, seals its position on its pool, and pays Blast the
/// policy's current LP-fee rates before the creator's split.
fun a_vault_without_a_presale_takes_the_policys_lp_rates() {
    let mut scenario = test_scenario::begin(CREATOR);
    let policy = policy_with_lp_fees(1_000, 2_500, &mut scenario);
    let pool_id = object::id_from_address(@0x9001);
    let creation_policy = creation_policy::new_for_testing(scenario.ctx());

    new_vault_without_presale(&policy, option::none(), &creation_policy, 7, &mut scenario);

    scenario.next_tx(CREATOR);
    let mut vault = scenario.take_shared<Vault<MEME, QUOTE>>();
    assert_eq!(vault.pool_id(), pool_id);

    vault.credit_fees_for_testing(
        &policy,
        balance::create_for_testing<MEME>(100),
        balance::create_for_testing<QUOTE>(100),
        scenario.ctx(),
    );

    let (_, protocol_meme, protocol_quote) = only_event<FeesCollected<MEME, QUOTE>>()
        .fees_collected_protocol_fields();
    assert_eq!(vector[protocol_meme, protocol_quote], vector[10, 25]);

    test_scenario::return_shared(vault);
    policy.destroy_for_testing();
    creation_policy.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = vault::EWrongPresaleCap, location = blast_presale::presale_vault)]
/// A vault created without a presale has no creator capability, so no `PresaleCap` reaches it.
fun no_presale_cap_reaches_a_vault_without_a_presale() {
    let mut scenario = test_scenario::begin(CREATOR);
    let policy = fee_policy::new_for_testing(scenario.ctx());
    let creation_policy = creation_policy::new_for_testing(scenario.ctx());
    new_vault_without_presale(&policy, option::none(), &creation_policy, 7, &mut scenario);
    scenario.next_tx(CREATOR);
    let mut vault = scenario.take_shared<Vault<MEME, QUOTE>>();
    let cap = presale::cap_for_testing(object::id_from_address(@0x0), scenario.ctx());

    let (meme, quote) = vault.claim_migration_residuals(&cap, scenario.ctx());
    destroy(meme);
    destroy(quote);
    abort
}

#[test]
#[expected_failure(abort_code = vault::EZeroLiquidity, location = blast_presale::presale_vault)]
fun a_vault_without_a_presale_needs_liquidity() {
    let mut scenario = test_scenario::begin(CREATOR);
    let policy = fee_policy::new_for_testing(scenario.ctx());
    let creation_policy = creation_policy::new_for_testing(scenario.ctx());

    new_vault_without_presale(&policy, option::none(), &creation_policy, 0, &mut scenario);
    abort
}

#[test]
/// A vault created without a presale may name a partner Blast accepts; it then holds Blast's LP
/// fees, and the partner is paid its cut of them.
fun a_vault_without_a_presale_pays_its_partner_its_cut_of_blasts_lp_fees() {
    let mut scenario = test_scenario::begin(CREATOR);
    let policy = policy_with_lp_fees(1_000, 2_500, &mut scenario);
    let partner = partners::new_for_testing(PARTNER_RECIPIENT, PARTNER_CUT_BPS, scenario.ctx());
    let mut creation_policy = creation_policy::new_for_testing(scenario.ctx());
    creation_policy.add_partner(&fee_admin(), &partner);

    new_vault_without_presale(
        &policy,
        option::some(object::id(&partner)),
        &creation_policy,
        7,
        &mut scenario,
    );

    scenario.next_tx(CREATOR);
    let mut vault = scenario.take_shared<Vault<MEME, QUOTE>>();
    vault.credit_fees_for_testing(
        &policy,
        balance::create_for_testing<MEME>(100),
        balance::create_for_testing<QUOTE>(100),
        scenario.ctx(),
    );
    let (unpaid_meme, unpaid_quote) = vault.unpaid_protocol_lp_fees_for_testing();
    assert_eq!(vector[unpaid_meme, unpaid_quote], vector[10, 25]);

    vault.pay_held_lp_fees(&partner, TREASURY, &mut scenario);

    let (_, _, protocol_meme, protocol_quote, partner_meme, partner_quote) = only_event<
        ProtocolLpFeesPaid<MEME, QUOTE>,
    >().protocol_lp_fees_paid_fields();
    assert_eq!(vector[protocol_meme, protocol_quote, partner_meme, partner_quote], vector[6, 15, 4, 10]);

    test_scenario::return_shared(vault);
    policy.destroy_for_testing();
    creation_policy.destroy_for_testing();
    destroy(partner);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = creation_policy::EPartnerNotAccepted,
    location = blast_presale::creation_policy,
)]
/// A vault created without a presale cannot name a partner Blast does not accept.
fun a_vault_without_a_presale_cannot_name_an_unaccepted_partner() {
    let mut scenario = test_scenario::begin(CREATOR);
    let policy = fee_policy::new_for_testing(scenario.ctx());
    let creation_policy = creation_policy::new_for_testing(scenario.ctx());

    new_vault_without_presale(
        &policy,
        option::some(object::id_from_address(@0xBAD)),
        &creation_policy,
        7,
        &mut scenario,
    );
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EWrongRound, location = blast_presale::holder_rewards)]
fun a_round_must_use_the_vaults_next_number() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = funded_holder_vault(&mut scenario);

    vault.publish_round(1, 0, 10, &mut scenario);
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidInterval, location = blast_presale::holder_rewards)]
/// A new daily interval may skip checkpoints but cannot overlap a funded round.
fun a_round_cannot_overlap_checkpoints() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = funded_holder_vault(&mut scenario);
    vault.publish_round(0, 0, 10, &mut scenario);

    vault.publish_round(1, 9, 20, &mut scenario);
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EAlreadyClaimed, location = blast_presale::holder_rewards)]
fun a_holder_reward_cannot_be_claimed_twice() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut round = round_owing_holder(20, 0, &mut scenario);
    rewards::claim(&mut round, 0, HOLDER, 20, 0, vector[], scenario.ctx());

    rewards::claim(&mut round, 0, HOLDER, 20, 0, vector[], scenario.ctx());
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EEmptyClaim, location = blast_presale::holder_rewards)]
/// A claim leaf must pay something; an empty one is a claim error, not a round-budget one.
fun a_holder_reward_claim_must_pay_a_positive_amount() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut round = round_owing_holder(0, 0, &mut scenario);

    rewards::claim(&mut round, 0, HOLDER, 0, 0, vector[], scenario.ctx());
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidProof, location = blast_presale::holder_rewards)]
/// A relayer cannot redirect a committed reward to another beneficiary.
fun a_holder_reward_cannot_be_redirected() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut round = round_owing_holder(40, 0, &mut scenario);

    rewards::claim(&mut round, 0, FEE_RECIPIENT, 40, 0, vector[], scenario.ctx());
    abort
}

#[test]
/// Once the claim deadline passes, anyone may return a round's unclaimed rewards to the vault.
fun an_unclaimed_round_returns_to_the_vault_after_its_deadline() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = funded_holder_vault(&mut scenario);
    vault.publish_round(0, 0, 10, &mut scenario);
    let (meme_after_publish, _) = vault.holder_rewards_balances();
    assert_eq!(meme_after_publish, 39);

    vault.close_round_at(CLAIM_DEADLINE_MS, &mut scenario);

    let (vault_meme, vault_quote) = vault.holder_rewards_balances();
    assert_eq!(vector[vault_meme, vault_quote], vector[40, 0]);

    vault.destroy_holding(40, 0);
    scenario.end();
}

#[test]
#[expected_failure(abort_code = rewards::EClaimsStillOpen, location = blast_presale::holder_rewards)]
fun a_round_cannot_close_before_its_claim_deadline() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = funded_holder_vault(&mut scenario);
    vault.publish_round(0, 0, 10, &mut scenario);

    vault.close_round_at(CLAIM_DEADLINE_MS - 1, &mut scenario);
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EWrongVault, location = blast_presale::holder_rewards)]
/// A round's leftovers can only return to the vault that funded it.
fun a_round_cannot_close_into_another_vault() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = funded_holder_vault(&mut scenario);
    vault.publish_round(0, 0, 10, &mut scenario);
    let mut other_vault = new_vault(vector[], 10_000, &mut scenario);

    other_vault.close_round_at(CLAIM_DEADLINE_MS, &mut scenario);
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidClaimDeadline, location = blast_presale::holder_rewards)]
fun a_round_needs_a_future_claim_deadline() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut vault = funded_holder_vault(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(CLAIM_DEADLINE_MS);

    let policy = fee_policy::new_for_testing(scenario.ctx());
    rewards::publish_round(
        &mut vault,
        &rewards_admin(), &policy, policy.destination(),
        0,
        0,
        10,
        hash::blake2b256(&b"root"),
        hash::blake2b256(&b"manifest"),
        1,
        1,
        0,
        0,
        CLAIM_DEADLINE_MS,
        &clock,
        scenario.ctx(),
    );
    policy.destroy_for_testing();
    abort
}

#[test]
fun anyone_can_relay_a_holder_reward_to_the_committed_holder() {
    let mut scenario = test_scenario::begin(CREATOR);
    let mut round = round_owing_holder(40, 5, &mut scenario);

    rewards::claim(&mut round, 0, HOLDER, 40, 5, vector[], scenario.ctx());

    scenario.next_tx(HOLDER);
    assert_eq!(scenario.take_from_sender<Coin<MEME>>().burn_for_testing(), 40);
    assert_eq!(scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 5);

    round.destroy_for_testing();
    scenario.end();
}

#[test]
fun generic_merkle_proofs_preserve_left_and_right_order() {
    let left = hash::blake2b256(&b"left");
    let right = hash::blake2b256(&b"right");
    let root = merkle_tree::node(left, right);

    assert!(merkle_tree::verify(root, left, 0, 2, &vector[right]));
    assert!(merkle_tree::verify(root, right, 1, 2, &vector[left]));
    assert!(!merkle_tree::verify(root, right, 2, 2, &vector[left]));
}

// === Test Helpers ===

fun new_vault(
    fee_recipients: vector<RecipientShare>,
    holder_rewards_bps: u64,
    scenario: &mut Scenario,
): Vault<MEME, QUOTE> {
    vault::new_for_testing<MEME, QUOTE>(
        object::id_from_address(@0xCAFE),
        object::id_from_address(@0xCA9),
        presale::fee_split(fee_recipients, bps::new(holder_rewards_bps)),
        no_protocol_fees(),
        option::none(),
        scenario.ctx(),
    )
}

/// A vault paying Blast 10% of Meme and 25% of Quote, then 50% and 20% to two recipients and
/// 30% to holders, for a sale that named `partner_id`.
fun vault_paying_blast(partner_id: Option<ID>, scenario: &mut Scenario): Vault<MEME, QUOTE> {
    vault::new_for_testing<MEME, QUOTE>(
        object::id_from_address(@0xCAFE),
        object::id_from_address(@0xCA9),
        presale::fee_split(
            vector[
                presale::recipient_share(CREATOR, bps::new(5_000)),
                presale::recipient_share(FEE_RECIPIENT, bps::new(2_000)),
            ],
            bps::new(3_000),
        ),
        fee_policy::protocol_fees_for_testing(0, 0, 1_000, 2_500),
        partner_id,
        scenario.ctx(),
    )
}

fun no_protocol_fees(): ProtocolFees {
    fee_policy::protocol_fees_for_testing(0, 0, 0, 0)
}

/// Collects fees under a zero-rate policy, as every vault without a Blast LP share does.
fun collect_fees(
    self: &mut Vault<MEME, QUOTE>,
    meme: Balance<MEME>,
    quote: Balance<QUOTE>,
    scenario: &mut Scenario,
) {
    let mut policy = fee_policy::new_for_testing(scenario.ctx());
    policy.set_destination(&treasury_admin(), TREASURY);
    self.credit_fees_for_testing(&policy, meme, quote, scenario.ctx());
    policy.destroy_for_testing();
}

/// Pays the vault's held Blast LP fees to `partner` and to a fee policy paying `destination`.
fun pay_held_lp_fees(
    self: &mut Vault<MEME, QUOTE>,
    partner: &Partner,
    destination: address,
    scenario: &mut Scenario,
) {
    let mut policy = fee_policy::new_for_testing(scenario.ctx());
    policy.set_destination(&treasury_admin(), destination);
    let clock = clock::create_for_testing(scenario.ctx());

    vault::pay_protocol_lp_fees_with_partner(self, &policy, partner, &clock, scenario.ctx());

    clock.destroy_for_testing();
    policy.destroy_for_testing();
}

/// Seals a `liquidity` position on pool `@0x9001` in a vault without a presale, paying half of
/// every fee to `CREATOR` and half to holders.
fun new_vault_without_presale(
    policy: &FeePolicy,
    partner_id: Option<ID>,
    creation_policy: &CreationPolicy,
    liquidity: u128,
    scenario: &mut Scenario,
) {
    let clock = clock::create_for_testing(scenario.ctx());

    vault::create_without_presale<MEME, QUOTE, _, _>(
        presale::fee_split(
            vector[presale::recipient_share(CREATOR, bps::new(5_000))],
            bps::new(5_000),
        ),
        partner_id,
        creation_policy,
        policy,
        &clock,
        &Venue(),
        object::id_from_address(@0x9001),
        Position { id: object::new(scenario.ctx()) },
        liquidity,
        scenario.ctx(),
    );

    clock.destroy_for_testing();
}

/// A fee policy whose new vaults pay Blast these LP-fee rates.
fun policy_with_lp_fees(meme_bps: u64, quote_bps: u64, scenario: &mut Scenario): FeePolicy {
    let mut policy = fee_policy::new_for_testing(scenario.ctx());
    policy.set_fees(
        &fee_admin(),
        bps::new(0),
        bps::new(0),
        bps::new(meme_bps),
        bps::new(quote_bps),
    );
    policy
}

/// A vault whose holder share is 40 Meme and no Quote.
fun funded_holder_vault(scenario: &mut Scenario): Vault<MEME, QUOTE> {
    let mut vault = new_vault(vector[], 10_000, scenario);
    vault.credit_holder_for_testing(
        balance::create_for_testing<MEME>(40), balance::zero<QUOTE>(),
    );
    vault
}

/// Publishes a one-leaf round that pays 1 Meme from the holder share.
fun publish_round(
    self: &mut Vault<MEME, QUOTE>,
    number: u64,
    start_checkpoint: u64,
    end_checkpoint: u64,
    scenario: &mut Scenario,
) {
    let clock = clock::create_for_testing(scenario.ctx());
    let policy = fee_policy::new_for_testing(scenario.ctx());
    rewards::publish_round(
        self,
        &rewards_admin(), &policy, policy.destination(),
        number,
        start_checkpoint,
        end_checkpoint,
        hash::blake2b256(&b"root"),
        hash::blake2b256(&b"manifest"),
        1,
        1,
        0,
        0,
        CLAIM_DEADLINE_MS,
        &clock,
        scenario.ctx(),
    );
    policy.destroy_for_testing();
    clock.destroy_for_testing();
}

fun close_round_at(self: &mut Vault<MEME, QUOTE>, now_ms: u64, scenario: &mut Scenario) {
    scenario.next_tx(CREATOR);
    let round = scenario.take_shared<Round<MEME, QUOTE>>();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(now_ms);

    rewards::close_round(round, self, &clock);

    clock.destroy_for_testing();
}

/// A one-leaf round funded with 40 Meme and `quote` Quote, owing `HOLDER` the given amounts.
/// With a single leaf, that leaf is the Merkle root.
fun round_owing_holder(meme: u64, quote: u64, scenario: &mut Scenario): Round<MEME, QUOTE> {
    let vault_id = object::id_from_address(@0xBEEF);
    let root = rewards::leaf_for_testing(vault_id, 0, 0, HOLDER, meme, quote);

    rewards::new_for_testing(
        vault_id,
        0,
        CLAIM_DEADLINE_MS,
        root,
        1,
        balance::create_for_testing<MEME>(40),
        balance::create_for_testing<QUOTE>(quote),
        scenario.ctx(),
    )
}

/// Pays out the holder share as a round would, so destruction aborts unless the share is
/// exactly `meme` and `quote`.
fun destroy_holding(mut self: Vault<MEME, QUOTE>, meme: u64, quote: u64) {
    let (round_meme, round_quote) = self.fund_round(0, meme, quote);
    round_meme.destroy_for_testing();
    round_quote.destroy_for_testing();
    self.destroy_for_testing();
}

fun only_event<Event: copy + drop>(): Event {
    let events = event::events_by_type<Event>();
    assert_eq!(events.length(), 1);
    events[0]
}

fun fee_admin(): AdminWitness<FeeAdmin> {
    blast_acl::witness_for_testing()
}

fun rewards_admin(): AdminWitness<RewardsAdmin> {
    blast_acl::witness_for_testing()
}

fun treasury_admin(): AdminWitness<TreasuryAdmin> {
    blast_acl::witness_for_testing()
}

fun sender_total_meme(self: &Scenario): u64 {
    let mut total = 0;
    while (self.has_most_recent_for_sender<Coin<MEME>>()) {
        total = total + self.take_from_sender<Coin<MEME>>().burn_for_testing();
    };
    total
}

// === Imports ===

use blast_admin::blast_acl::{Self, AdminWitness};

use blast_partners::blast_partners::{Self as partners, Partner, PartnerPaid};

use blast_presale::{
    blast_presale as presale,
    blast_presale_domain::{FeeAdmin, RewardsAdmin, TreasuryAdmin},
    bps,
    creation_policy::{Self, CreationPolicy},
    fee_policy::{Self, FeePolicy, ProtocolFees},
    holder_rewards::{Self as rewards, Round},
    merkle_tree,
    presale_vault::{
        Self as vault,
        FeesCollected,
        Vault,
        ProtocolLpFeesChanged,
        ProtocolLpFeesPaid,
    },
    blast_presale::RecipientShare,
};

use std::unit_test::{assert_eq, destroy};

use sui::{
    balance::{Self, Balance},
    clock,
    coin::{Self, Coin},
    event,
    hash,
    test_scenario::{Self, Scenario},
};

use fun close_round_at as Vault.close_round_at;
use fun collect_fees as Vault.collect_fees;
use fun destroy_holding as Vault.destroy_holding;
use fun pay_held_lp_fees as Vault.pay_held_lp_fees;
use fun publish_round as Vault.publish_round;

use fun sender_total_meme as Scenario.sender_total_meme;
