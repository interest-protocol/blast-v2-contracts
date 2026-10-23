// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_market_maker::presale_adapter_tests;

// === Constants ===

const ROOT: address = @0xA;
const ALICE: address = @0xB;
const BOB: address = @0xC;
const KEEPER: address = @0xD;
const TREASURY: address = @0xE;
const PARTNER_RECIPIENT: address = @0xF;
const START: u64 = 1_000;
const DURATION: u64 = 100;

// === Test-Only Types ===

public struct PRESALE_ADAPTER_TESTS has drop {}
public struct QUOTE has drop {}

public struct Fixture {
    scenario: Scenario,
    clock: Clock,
    version: PackageVersion,
    creator: BlastMarketMakerCreatorCap,
    treasury: BlastMarketMakerTreasury,
    policy: BlastMarketMakerFeePolicy,
    core_version: PresaleVersion,
    core_policy: PresaleFeePolicy,
    partner: Partner,
    vault_id: ID,
    sale_id: ID,
}

// === Tests ===

#[test]
fun core_hard_cap_returns_change_without_local_buyer_accounting() {
    let mut fixture = new_fixture();
    assert_eq!(fixture.commit(ALICE, 500), 0);
    assert_eq!(fixture.commit(BOB, 1_000), 500);
    fixture.assert_weights(0, 0, 0);
    fixture.next_tx!(KEEPER, |f| {
        let sale = f.take_sale();
        let (total, participants, quote, _, _, _, _) = sale.custody_for_testing();
        assert_eq!(total, 1_000);
        assert_eq!(participants, 2);
        assert_eq!(quote, 1_000);
        return_sale(sale);
    });
    fixture.end();
}

#[test]
fun core_buyers_claim_tokens_without_local_contribution_weights() {
    let mut fixture = new_fixture();
    assert_eq!(fixture.commit(ALICE, 500), 0);
    assert_eq!(fixture.commit(BOB, 500), 0);
    fixture.assert_weights(0, 0, 0);
    fixture.migrate_handoff_and_activate(0);
    fixture.next_tx!(KEEPER, |f| {
        let mut sale = f.take_sale();
        sale.claim(&f.core_version, ALICE, &f.clock, f.ctx!());
        assert_eq!(sale.commitment_for_testing(ALICE), 0);
        return_sale(sale);
    });
    fixture.next_tx!(ALICE, |f| {
        let tokens = f.take_coin<PRESALE_ADAPTER_TESTS>();
        assert_eq!(tokens.value(), 40_000);
        tokens.burn_for_testing();
    });
    fixture.end();
}

#[test]
fun core_only_presale_can_migrate_and_creator_can_reinvest() {
    let mut fixture = new_fixture();
    assert_eq!(fixture.commit(ALICE, 1_000), 0);
    fixture.assert_weights(0, 0, 0);
    fixture.migrate_handoff_and_activate(0);
    fixture.next_tx!(KEEPER, |f| {
        let mut vault = f.take_vault();
        vault.credit_lp_fees(
            &f.version,
            &f.policy,
            &mut f.treasury,
            balance::create_for_testing<PRESALE_ADAPTER_TESTS>(7),
            balance::create_for_testing<QUOTE>(100),
        );
        let (
            available_meme,
            available_quote,
            reserved_meme,
            reserved_quote,
        ) = vault.fee_balances(
        );
        assert_eq!(available_meme, 7);
        assert_eq!(available_quote, 100);
        assert_eq!(reserved_meme, 0);
        assert_eq!(reserved_quote, 0);
        f.allocate(&mut vault, 0, 7, 0, 100);
        let (meme_capital, quote_capital) = vault.capital_for_testing();
        assert_eq!(meme_capital, 7);
        assert_eq!(quote_capital, 100);
        assert_eq!(vault.is_pool_for_testing(), true);
        vault.return_vault();
    });
    fixture.end();
}

#[test]
fun failed_presale_refunds_once_through_core_and_holds_no_vault_capital() {
    let mut fixture = new_fixture();
    assert_eq!(fixture.commit(ALICE, 500), 0);
    fixture.clock.set_for_testing(START + DURATION);
    fixture.next_tx!(KEEPER, |f| {
        let mut sale = f.take_sale();
        sale.settle(&f.core_version, &f.clock);
        assert_eq!(sale.is_cancelled_for_testing(), true);
        sale.claim(&f.core_version, ALICE, &f.clock, f.ctx!());
        assert_eq!(sale.commitment_for_testing(ALICE), 0);
        let (_, _, quote, _, _, _, _) = sale.custody_for_testing();
        assert_eq!(quote, 0);
        return_sale(sale);
        let vault = f.take_vault();
        let (meme_capital, quote_capital) = vault.capital_for_testing();
        assert_eq!(meme_capital, 0);
        assert_eq!(quote_capital, 0);
        vault.return_vault();
    });
    fixture.next_tx!(ALICE, |f| {
        let refund = f.take_coin<QUOTE>();
        assert_eq!(refund.value(), 500);
        refund.burn_for_testing();
    });
    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongPhase,
        location = blast_market_maker::market_maker,
    ),
]
fun presale_cannot_refund_through_curve_escrow() {
    let mut fixture = new_fixture();
    fixture.next_tx!(ALICE, |f| {
        let mut vault = f.take_vault();
        let refund = vault.refund(&f.version, f.ctx!());
        refund.burn_for_testing();
        vault.return_vault();
    });
    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = presale_adapter::EInvalidRetention,
        location = blast_market_maker::presale_adapter,
    ),
]
fun retaining_everything_cannot_leave_an_empty_base_pool() {
    let _ = sale_terms(10_000);
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongExternalObject,
        location = blast_market_maker::market_maker,
    ),
]
fun migration_cannot_release_an_unbound_sale() {
    let mut fixture = new_fixture();
    fixture.next_tx!(KEEPER, |f| {
        let vault = f.take_vault();
        vault.assert_external(object::id_from_address(@0xBAD));
        vault.return_vault();
    });
    fixture.end();
}

#[test]
fun retains_both_actual_core_handoff_assets_without_reducing_buyer_tokens() {
    let mut fixture = new_fixture();
    assert_eq!(fixture.commit(ALICE, 1_000), 0);
    fixture.migrate_handoff_and_activate(2_000);
    fixture.next_tx!(KEEPER, |f| {
        let mut sale = f.take_sale();
        sale.claim(&f.core_version, ALICE, &f.clock, f.ctx!());
        return_sale(sale);
    });
    fixture.next_tx!(ALICE, |f| {
        let tokens = f.take_coin<PRESALE_ADAPTER_TESTS>();
        assert_eq!(tokens.value(), 80_000);
        tokens.burn_for_testing();
    });
    fixture.end();
}

#[test]
fun all_core_buyers_receive_epoch_rewards_even_after_claiming_presale_tokens() {
    let mut f = new_fixture();
    assert_eq!(f.commit(ALICE, 600), 0);
    assert_eq!(f.commit(BOB, 500), 100);
    f.assert_weights(0, 0, 0);
    f.migrate_handoff_and_activate(2_000);
    f.next_tx!(KEEPER, |f| {
        let mut sale = f.take_sale();
        sale.claim(&f.core_version, ALICE, &f.clock, f.ctx!());
        assert_eq!(sale.commitment_for_testing(ALICE), 0);
        return_sale(sale);
        let mut vault = f.take_vault();
        vault.credit_lp_fees(
            &f.version, &f.policy, &mut f.treasury,
            balance::create_for_testing<PRESALE_ADAPTER_TESTS>(10),
            balance::create_for_testing<QUOTE>(100),
        );
        f.allocate(&mut vault, 10, 0, 100, 0);
        let (meme, quote) = vault.capital_for_testing();
        assert_eq!(meme, 4_000);
        assert_eq!(quote, 200);
        let alice = rewards::leaf_for_testing(f.vault_id, 0, 0, ALICE, 6, 60);
        let bob = rewards::leaf_for_testing(f.vault_id, 0, 1, BOB, 4, 40);
        rewards::publish_round(
            &mut vault, &blast_acl::witness_for_testing<RewardsAdmin>(), &f.version,
            0, 10, 20, rewards::node_for_testing(alice, bob), vector::tabulate!(32, |_| 7),
            2, 10, 100, f.ctx!(),
    );
        vault.return_vault();
    });
    f.next_tx!(KEEPER, |f| {
        let mut round = f.take_round();
        let alice = rewards::leaf_for_testing(f.vault_id, 0, 0, ALICE, 6, 60);
        let bob = rewards::leaf_for_testing(f.vault_id, 0, 1, BOB, 4, 40);
        round.claim_and_pay(&f.version, 0, ALICE, 6, 60, vector[bob], f.ctx!());
        round.claim_and_pay(&f.version, 1, BOB, 4, 40, vector[alice], f.ctx!());
        let (meme, quote) = round.balances_for_testing();
        assert_eq!(meme, 0);
        assert_eq!(quote, 0);
        f.return_round(round);
    });
    f.next_tx!(ALICE, |f| {
        // Presale tokens and reward tokens are separate coins; Quote is only the reward.
        let quote = f.take_coin<QUOTE>();
        assert_eq!(quote.value(), 60);
        quote.burn_for_testing();
    });
    f.next_tx!(BOB, |f| {
        let meme = f.take_coin<PRESALE_ADAPTER_TESTS>();
        let quote = f.take_coin<QUOTE>();
        assert_eq!(meme.value(), 4);
        assert_eq!(quote.value(), 40);
        meme.burn_for_testing();
        quote.burn_for_testing();
    });
    f.end();
}

#[test]
fun funded_sale_cancelled_at_liquidity_deadline_refunds_and_retires_cap() {
    let mut fixture = new_fixture();
    assert_eq!(fixture.commit(ALICE, 1_000), 0);
    fixture.next_tx!(KEEPER, |f| {
        let mut sale = f.take_sale();
        sale.settle(&f.core_version, &f.clock);
        assert_eq!(sale.is_funded_for_testing(), true);
        f.clock.set_for_testing(START + 604_800_000);
        sale.cancel_unlaunched(&f.core_version, &f.clock);
        let mut vault = f.take_vault();
        vault.destroy_cancelled_presale_cap(&sale, &f.version);
        sale.claim(&f.core_version, ALICE, &f.clock, f.ctx!());
        let (meme_capital, quote_capital) = vault.capital_for_testing();
        assert_eq!(meme_capital, 0);
        assert_eq!(quote_capital, 0);
        vault.return_vault();
        return_sale(sale);
    });
    fixture.next_tx!(ALICE, |f| {
        let refund = f.take_coin<QUOTE>();
        assert_eq!(refund.value(), 1_000);
        refund.burn_for_testing();
    });
    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongPhase,
        location = blast_market_maker::market_maker,
    ),
]
fun presale_cannot_claim_curve_fees_before_migration() {
    let mut fixture = new_fixture();
    assert_eq!(fixture.commit(ALICE, 500), 0);
    let _ = fixture.claim_fees(ALICE);
    fixture.end();
}

#[test]
fun maximum_presale_retention_keeps_half_of_both_actual_handoff_assets() {
    let mut fixture = new_fixture_with_retention(5_000);
    assert_eq!(fixture.commit(ALICE, 1_000), 0);
    fixture.migrate_handoff_and_activate(5_000);
    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = presale_adapter::EInvalidRetention,
        location = blast_market_maker::presale_adapter,
    ),
]
fun first_retention_above_half_rejects_at_construction() {
    let _ = sale_terms(5_001);
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EInvalidTradingLimits,
        location = blast_market_maker::market_maker,
    ),
]
fun presale_rejects_unachievable_idle_floor_before_core_creation() {
    let fixture = new_fixture_with_options(2_000, 1);
    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = presale::EInvalidEligibilityPolicy,
        location = blast_presale::blast_presale,
    ),
]
fun participant_limit_is_owned_by_core_presale() {
    let _ = presale_adapter::new_terms(
        100_000,
        false,
        8_000,
        2_000,
        1_000,
        DURATION,
        604_800_000,
        1_000,
        65_537,
        500,
        10,
        0,
        0,
        0,
    );
}

#[test]
fun retention_uses_net_assets_after_upstream_fees_and_preserves_participant_tokens() {
    let mut fixture = new_fixture_with_upstream_fees(2_000, 0, 1_000, 1_000);
    assert_eq!(fixture.commit(ALICE, 1_000), 0);
    fixture.next_tx!(KEEPER, |f| {
        let mut vault = f.take_vault();
        let mut sale = f.take_sale();
        sale.settle(&f.core_version, &f.clock);
        let (meme, quote) = vault.migration_handoff_for_testing(
            &mut sale,
            &f.version,
            &f.core_version,
            &f.core_policy,
            &f.clock,
            f.ctx!(),
        );
        // Gross supply100000 = participant80000 + protocol10000 + net LP10000.
        // Gross raise1000 = protocol100 + net LP900.
        assert_eq!(meme.value(), 10_000);
        assert_eq!(quote.value(), 900);
        let (meme_seed, quote_seed) = vault.retain_capital_and_return_seed_for_testing(meme, quote, 2_000);
        assert_eq!(meme_seed.value(), 8_000);
        assert_eq!(quote_seed.value(), 720);
        let (retained_meme, retained_quote) = vault.capital_for_testing();
        assert_eq!(retained_meme, 2_000);
        assert_eq!(retained_quote, 180);
        meme_seed.destroy_for_testing();
        quote_seed.destroy_for_testing();
        vault.activate_pool(object::id_from_address(@0xFACE));
        // Upstream LP metadata1000bps does not impose a second receipt deduction here.
        vault.credit_lp_fees(
            &f.version,
            &f.policy,
            &mut f.treasury,
            balance::zero<PRESALE_ADAPTER_TESTS>(),
            balance::create_for_testing<QUOTE>(100),
        );
        let (
            available_meme,
            available_quote,
            reserved_meme,
            reserved_quote,
        ) = vault.fee_balances(
        );
        assert_eq!(available_meme, 0);
        assert_eq!(available_quote, 100);
        assert_eq!(reserved_meme, 0);
        assert_eq!(reserved_quote, 0);
        assert_eq!(sale.unpaid_protocol_quote_for_testing(), option::some(100));
        sale.pay_protocol_fees_with_partner(
            &f.core_version,
            &f.core_policy,
            &f.partner,
            &f.clock,
            f.ctx!(),
        );
        assert_eq!(sale.unpaid_protocol_quote_for_testing(), option::none());
        let paid = sui::event::events_by_type<
            presale::ProtocolFeesPaid<PRESALE_ADAPTER_TESTS, QUOTE>,
        >();
        assert_eq!(paid.length(), 1);
        let (
            paid_sale_id,
            destination,
            protocol_quote,
            protocol_tokens,
        ) = presale::protocol_fees_paid_fields(&paid[0]);
        assert_eq!(paid_sale_id, object::id(&sale));
        assert_eq!(destination, ROOT);
        assert_eq!(protocol_quote, 60);
        assert_eq!(protocol_tokens, 10_000);
        assert_eq!(presale::protocol_fees_paid_partner_quote(&paid[0]), 40);
        let partner_paid = sui::event::events_by_type<partners::PartnerPaid<QUOTE>>();
        assert_eq!(partner_paid.length(), 1);
        let (paid_partner_id, partner_quote) = partners::partner_paid_fields(&partner_paid[0]);
        assert_eq!(paid_partner_id, object::id(&f.partner));
        assert_eq!(partner_quote, 40);
        sale.claim(&f.core_version, ALICE, &f.clock, f.ctx!());
        vault.return_vault();
        return_sale(sale);
    });
    fixture.next_tx!(ROOT, |f| {
        let protocol_meme = f.take_coin<PRESALE_ADAPTER_TESTS>();
        let protocol_quote = f.take_coin<QUOTE>();
        assert_eq!(protocol_meme.value(), 10_000);
        assert_eq!(protocol_quote.value(), 60);
        protocol_meme.burn_for_testing();
        protocol_quote.burn_for_testing();
    });
    fixture.next_tx!(PARTNER_RECIPIENT, |f| {
        let payment = f.take_coin<QUOTE>();
        assert_eq!(payment.value(), 40);
        payment.burn_for_testing();
    });
    fixture.next_tx!(ALICE, |f| {
        let tokens = f.take_coin<PRESALE_ADAPTER_TESTS>();
        assert_eq!(tokens.value(), 80_000);
        tokens.burn_for_testing();
    });
    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = creation_policy::EPartnerNotAccepted,
        location = blast_presale::creation_policy,
    ),
]
fun creator_cannot_select_a_partner_unaccepted_by_presale_core() {
    let fixture = new_fixture_with_partner_options(2_000, 0, 0, 0, false);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::EWrongPartner, location = blast_presale::blast_presale)]
fun migrated_presale_cannot_pay_a_different_partner() {
    let mut fixture = new_fixture_with_upstream_fees(2_000, 0, 1_000, 0);
    assert_eq!(fixture.commit(ALICE, 1_000), 0);
    fixture.next_tx!(KEEPER, |f| { f.migrate_for_partner_payout(); });
    fixture.next_tx!(KEEPER, |f| {
        let other = partners::new_for_testing(KEEPER, 4_000, f.ctx!());
        let mut sale = f.take_sale();
        sale.pay_protocol_fees_with_partner(
            &f.core_version,
            &f.core_policy,
            &other,
            &f.clock,
            f.ctx!(),
        );
        destroy(other);
        return_sale(sale);
    });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::ENoPartnerPayout, location = blast_presale::blast_presale)]
fun presale_partner_payout_cannot_be_repeated() {
    let mut fixture = new_fixture_with_upstream_fees(2_000, 0, 1_000, 0);
    assert_eq!(fixture.commit(ALICE, 1_000), 0);
    fixture.next_tx!(KEEPER, |f| { f.migrate_for_partner_payout(); });
    fixture.next_tx!(KEEPER, |f| { f.pay_partner(); });
    fixture.next_tx!(KEEPER, |f| { f.pay_partner(); });
    fixture.end();
}

#[test]
#[expected_failure(abort_code = presale::ENoPartnerPayout, location = blast_presale::blast_presale)]
fun presale_partner_cannot_be_paid_from_unmigrated_commitments() {
    let mut fixture = new_fixture_with_upstream_fees(2_000, 0, 1_000, 0);
    assert_eq!(fixture.commit(ALICE, 1_000), 0);
    fixture.next_tx!(KEEPER, |f| { f.pay_partner(); });
    fixture.end();
}

#[test]
fun explicit_team_tokens_and_raise_land_in_vault_capital_after_real_core_migration() {
    let mut f = new_team_fixture();
    assert_eq!(f.commit(ALICE, 1_000), 0);
    f.next_tx!(KEEPER, |f| { f.migrate_team_handoff(); });
    f.next_tx!(KEEPER, |f| {
        f.assert_team_coins_owned_by_vault();
        let vault = f.receive_team_assets();
        let (meme, quote) = vault.capital_for_testing();
        // Retained net LP assets2000/140 plus explicit team allocations10000/200.
        assert_eq!(meme, 12_000);
        assert_eq!(quote, 340);
        let (available_meme, available_quote, reserved_meme, reserved_quote) = vault.fee_balances();
        assert_eq!(available_meme, 0);
        assert_eq!(available_quote, 0);
        assert_eq!(reserved_meme, 0);
        assert_eq!(reserved_quote, 0);
        assert_eq!(vault.total_weight_for_testing(), 0);
        vault.return_vault();
        f.assert_capital_receipt_events(10_000, 200);
    });
    f.next_tx!(KEEPER, |f| {
        let mut sale = f.take_sale();
        sale.claim(&f.core_version, ALICE, &f.clock, f.ctx!());
        return_sale(sale);
    });
    f.next_tx!(ALICE, |f| {
        let participants = f.take_coin<PRESALE_ADAPTER_TESTS>();
        assert_eq!(participants.value(), 70_000);
        participants.burn_for_testing();
    });
    f.end();
}

#[test]
fun cancelled_presale_releases_no_team_allocations_and_preserves_full_refund() {
    let mut f = new_team_fixture();
    assert_eq!(f.commit(ALICE, 500), 0);
    f.clock.set_for_testing(START + DURATION);
    f.next_tx!(KEEPER, |f| {
        let mut sale = f.take_sale();
        sale.settle(&f.core_version, &f.clock);
        assert!(sale.is_cancelled_for_testing());
        let (_, _, quote, _, _, team_tokens, _) = sale.custody_for_testing();
        assert_eq!(quote, 500);
        assert_eq!(team_tokens, 10_000);
        assert_eq!(
            sui::event::events_by_type<
                presale::RecipientAllocated<PRESALE_ADAPTER_TESTS, QUOTE>,
            >().length(),
            0,
        );
        assert_eq!(
            sui::event::events_by_type<
                presale::RaiseAllocated<PRESALE_ADAPTER_TESTS, QUOTE>,
            >().length(),
            0,
        );
        f.assert_no_team_coins_at_vault();
        sale.claim(&f.core_version, ALICE, &f.clock, f.ctx!());
        return_sale(sale);
    });
    f.next_tx!(ALICE, |f| {
        let refund = f.take_coin<QUOTE>();
        assert_eq!(refund.value(), 500);
        refund.burn_for_testing();
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongPhase,
        location = blast_market_maker::market_maker,
    ),
]
fun team_receiving_cannot_activate_capital_from_a_cancelled_sale() {
    let mut f = new_team_fixture();
    f.clock.set_for_testing(START + DURATION);
    f.next_tx!(KEEPER, |f| {
        let mut sale = f.take_sale();
        sale.settle(&f.core_version, &f.clock);
        assert!(sale.is_cancelled_for_testing());
        return_sale(sale);
        let recipient = f.vault_id.to_address();
        f.send_quote_to(recipient);
    });
    f.next_tx!(KEEPER, |f| { f.receive_team_quote(); });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = presale_adapter::ENoTeamAllocation,
        location = blast_market_maker::presale_adapter,
    ),
]
fun disabled_team_quote_allocation_has_no_adapter_receiving_path() {
    let mut f = new_fixture();
    assert_eq!(f.commit(ALICE, 1_000), 0);
    f.migrate_handoff_and_activate(0);
    f.next_tx!(KEEPER, |f| {
        let recipient = f.vault_id.to_address();
        f.send_quote_to(recipient);
    });
    f.next_tx!(KEEPER, |f| { f.receive_team_quote(); });
    f.end();
}

#[test]
#[expected_failure(abort_code = sui::transfer::EUnableToReceiveObject, location = sui::transfer)]
fun team_receiving_rejects_a_coin_owned_by_another_address() {
    let mut f = new_team_fixture();
    assert_eq!(f.commit(ALICE, 1_000), 0);
    let foreign_coin;
    f.next_tx!(KEEPER, |f| {
        f.migrate_team_handoff();
        foreign_coin = f.send_quote_to(ROOT);
    });
    f.next_tx!(KEEPER, |f| { f.receive_quote_by_id(foreign_coin); });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongCreator,
        location = blast_market_maker::market_maker,
    ),
]
fun unrelated_creator_cap_cannot_withdraw_received_team_capital() {
    let mut f = new_team_fixture();
    assert_eq!(f.commit(ALICE, 1_000), 0);
    f.next_tx!(KEEPER, |f| { f.migrate_team_handoff(); });
    f.next_tx!(KEEPER, |f| {
        let mut vault = f.receive_team_assets();
        f.withdraw_team_with_foreign_cap(&mut vault);
        vault.return_vault();
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_presale::bps::EInvalidBps, location = blast_presale::bps)]
fun team_raise_share_rejects_first_rate_above_one_hundred_percent() {
    let _ = presale_adapter::new_terms(
        100_000,
        false,
        7_000,
        2_000,
        1_000,
        DURATION,
        604_800_000,
        1_000,
        2,
        500,
        10,
        0,
        1_000,
        10_001,
    );
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongExternalObject,
        location = blast_market_maker::market_maker,
    ),
]
fun team_receiving_rejects_wrong_sale_binding_before_native_receive() {
    let mut f = new_team_fixture();
    assert_eq!(f.commit(ALICE, 1_000), 0);
    f.next_tx!(KEEPER, |f| { f.migrate_team_handoff(); });
    f.next_tx!(KEEPER, |f| { f.receive_with_wrong_sale_binding(); });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = package_version::EVersionMismatch,
        location = blast_market_maker::package_version,
    ),
]
fun stale_version_rejects_before_receiving_a_real_team_payout() {
    let mut f = new_team_fixture();
    assert_eq!(f.commit(ALICE, 1_000), 0);
    f.next_tx!(KEEPER, |f| { f.migrate_team_handoff(); });
    f.version.set_generation_for_testing(2);
    f.next_tx!(KEEPER, |f| { f.receive_team_quote(); });
    f.end();
}

#[test]
fun same_asset_donation_becomes_only_capital_without_fee_weight_or_reserves() {
    let mut f = new_team_fixture();
    assert_eq!(f.commit(ALICE, 1_000), 0);
    f.next_tx!(KEEPER, |f| { f.migrate_team_handoff(); });
    f.next_tx!(KEEPER, |f| {
        let recipient = f.vault_id.to_address();
        f.send_quote_to(recipient);
    });
    f.next_tx!(KEEPER, |f| {
        f.receive_team_quote();
        f.assert_donation_receipt_event();
    });
    f.next_tx!(KEEPER, |f| {
        let vault = f.take_vault();
        let (meme, quote) = vault.capital_for_testing();
        assert_eq!(meme, 2_000);
        assert_eq!(quote, 141);
        assert_eq!(vault.total_weight_for_testing(), 0);
        let (available_meme, available_quote, reserved_meme, reserved_quote) = vault.fee_balances();
        assert_eq!(available_meme, 0);
        assert_eq!(available_quote, 0);
        assert_eq!(reserved_meme, 0);
        assert_eq!(reserved_quote, 0);
        vault.return_vault();
    });
    f.end();
}

// === Test Helpers ===

macro fun fixture_next_tx($fixture: &mut Fixture, $sender: address, $body: |&mut Fixture|) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $body(fixture);
}

macro fun fixture_ctx($fixture: &mut Fixture): &mut TxContext {
    let fixture = $fixture;
    fixture.scenario.ctx()
}

fun take_coin<T>(fixture: &Fixture): Coin<T> {
    fixture.scenario.take_from_sender<Coin<T>>()
}

fun return_sale(sale: Presale<PRESALE_ADAPTER_TESTS, QUOTE>) {
    test_scenario::return_shared(sale);
}

fun return_vault(vault: BlastMarketMakerVault<PRESALE_ADAPTER_TESTS, QUOTE>) {
    test_scenario::return_shared(vault);
}

// The real sale and its actual payout are valid. A separate production-constructed vault
// commits another sale ID, so exact-sale identity must fail before adapter state or native
// ownership checks. No forged Presale layout or external capability is needed by this fixture.
fun receive_with_wrong_sale_binding(f: &mut Fixture) {
    let payment = test_scenario::most_recent_receiving_ticket<Coin<QUOTE>>(&f.vault_id);
    let sale = f.take_sale();
    let Fixture { scenario, creator, version, treasury, policy, .. } = f;
    let mut foreign = market_maker::new_and_transfer_operator_cap<PRESALE_ADAPTER_TESTS, QUOTE>(
        market_maker::presale_route(),
        1_000,
        START + DURATION,
        ROOT,
        creator,
        vector::tabulate!(32, |_| 0),
        version,
        policy,
        treasury,
        scenario.ctx(),
    );
    foreign.bind_external(object::id_from_address(@0xBAD));
    foreign.receive_team_quote(&sale, version, payment);
    destroy(foreign);
    return_sale(sale);
}

fun assert_donation_receipt_event(f: &Fixture) {
    let events = sui::event::events_by_type<
        market_maker::BlastCapitalDeposited<PRESALE_ADAPTER_TESTS, QUOTE>,
    >();
    assert_eq!(events.length(), 1);
    let mut data = sui::bcs::new(std::bcs::to_bytes(&events[0]));
    assert_eq!(data.peel_address(), f.vault_id.to_address());
    assert_eq!(data.peel_u64(), 0);
    assert_eq!(data.peel_u64(), 1);
    assert_eq!(data.into_remainder_bytes(), vector[]);
}

fun new_team_fixture(): Fixture {
    new_fixture_with_team_allocations(2_000, 0, 1_000, 1_000, true, 1_000, 2_000)
}

// Executes the real production presale migration and production retention split. Cetus creation
// and base LP burn are deliberately outside this unit harness, as in the original handoff fixture.
fun migrate_team_handoff(f: &mut Fixture) {
    let mut vault = f.take_vault();
    let mut sale = f.take_sale();
    sale.settle(&f.core_version, &f.clock);
    let (meme, quote) = vault.migration_handoff_for_testing(
        &mut sale,
        &f.version,
        &f.core_version,
        &f.core_policy,
        &f.clock,
        f.ctx!(),
    );
    assert!(sale.is_migrated_for_testing());
    assert_eq!(meme.value(), 10_000);
    assert_eq!(quote.value(), 700);
    let recipients = sui::event::events_by_type<
        presale::RecipientAllocated<PRESALE_ADAPTER_TESTS, QUOTE>,
    >();
    let raises = sui::event::events_by_type<
        presale::RaiseAllocated<PRESALE_ADAPTER_TESTS, QUOTE>,
    >();
    assert_eq!(recipients.length(), 1);
    assert_eq!(raises.length(), 1);
    let (sale_id, recipient, tokens) = presale::recipient_allocated_fields(&recipients[0]);
    assert_eq!(sale_id, f.sale_id);
    assert_eq!(recipient, f.vault_id.to_address());
    assert_eq!(tokens, 10_000);
    assert_eq!(presale::recipient_allocated_vesting_id(&recipients[0]), option::none());
    let (sale_id, recipient, quote_amount) = presale::raise_allocated_fields(&raises[0]);
    assert_eq!(sale_id, f.sale_id);
    assert_eq!(recipient, f.vault_id.to_address());
    assert_eq!(quote_amount, 200);
    assert_eq!(presale::raise_allocated_vesting_id(&raises[0]), option::none());
    let (meme, quote) = vault.retain_capital_and_return_seed_for_testing(meme, quote, 2_000);
    assert_eq!(meme.value(), 8_000);
    assert_eq!(quote.value(), 560);
    meme.destroy_for_testing();
    quote.destroy_for_testing();
    vault.activate_pool(object::id_from_address(@0xCAFE));
    vault.return_vault();
    return_sale(sale);
}

fun assert_team_coins_owned_by_vault(f: &Fixture) {
    assert!(
        test_scenario::has_most_recent_for_address<Coin<PRESALE_ADAPTER_TESTS>>(f
            .vault_id
            .to_address()),
    );
    assert!(test_scenario::has_most_recent_for_address<Coin<QUOTE>>(f.vault_id.to_address()));
    assert!(!f.scenario.has_most_recent_for_sender<Coin<PRESALE_ADAPTER_TESTS>>());
    assert!(!f.scenario.has_most_recent_for_sender<Coin<QUOTE>>());
}

fun assert_no_team_coins_at_vault(f: &Fixture) {
    assert!(
        !test_scenario::has_most_recent_for_address<Coin<PRESALE_ADAPTER_TESTS>>(f
            .vault_id
            .to_address()),
    );
    assert!(!test_scenario::has_most_recent_for_address<Coin<QUOTE>>(f.vault_id.to_address()));
}

fun receive_team_assets(f: &Fixture): BlastMarketMakerVault<PRESALE_ADAPTER_TESTS, QUOTE> {
    let meme = test_scenario::most_recent_receiving_ticket<Coin<PRESALE_ADAPTER_TESTS>>(
        &f.vault_id,
    );
    let quote = test_scenario::most_recent_receiving_ticket<Coin<QUOTE>>(&f.vault_id);
    let mut vault = f.take_vault();
    let sale = f.take_sale();
    vault.receive_team_meme(&sale, &f.version, meme);
    vault.receive_team_quote(&sale, &f.version, quote);
    return_sale(sale);
    vault
}

fun receive_team_quote(f: &Fixture) {
    let payment = test_scenario::most_recent_receiving_ticket<Coin<QUOTE>>(&f.vault_id);
    let mut vault = f.take_vault();
    let sale = f.take_sale();
    vault.receive_team_quote(&sale, &f.version, payment);
    vault.return_vault();
    return_sale(sale);
}

fun send_quote_to(f: &mut Fixture, recipient: address): ID {
    let coin = coin::mint_for_testing<QUOTE>(1, f.ctx!());
    let id = object::id(&coin);
    transfer::public_transfer(coin, recipient);
    id
}

fun receive_quote_by_id(f: &Fixture, id: ID) {
    let payment = test_scenario::receiving_ticket_by_id<Coin<QUOTE>>(id);
    let mut vault = f.take_vault();
    let sale = f.take_sale();
    vault.receive_team_quote(&sale, &f.version, payment);
    vault.return_vault();
    return_sale(sale);
}

fun withdraw_team_with_foreign_cap(
    f: &mut Fixture,
    vault: &mut BlastMarketMakerVault<PRESALE_ADAPTER_TESTS, QUOTE>,
) {
    let Fixture { scenario, version, .. } = f;
    let foreign = market_maker::new_creator_cap(scenario.ctx());
    let (meme, quote) = vault.withdraw_capital(&foreign, version, 1, 1, scenario.ctx());
    meme.burn_for_testing();
    quote.burn_for_testing();
    destroy(foreign);
}

fun assert_capital_receipt_events(f: &Fixture, meme: u64, quote: u64) {
    let events = sui::event::events_by_type<
        market_maker::BlastCapitalDeposited<PRESALE_ADAPTER_TESTS, QUOTE>,
    >();
    assert_eq!(events.length(), 2);
    let mut deposited_meme = 0;
    let mut deposited_quote = 0;
    events.do_ref!(|event| {
        let mut data = sui::bcs::new(std::bcs::to_bytes(event));
        assert_eq!(data.peel_address(), f.vault_id.to_address());
        deposited_meme = deposited_meme + data.peel_u64();
        deposited_quote = deposited_quote + data.peel_u64();
        assert_eq!(data.into_remainder_bytes(), vector[]);
    });
    assert_eq!(deposited_meme, meme);
    assert_eq!(deposited_quote, quote);
}

fun sale_terms(retention_bps: u64): PresaleTerms {
    presale_adapter::new_terms(
        100_000,
        false,
        8_000,
        2_000,
        1_000,
        DURATION,
        604_800_000,
        1_000,
        2,
        500,
        10,
        retention_bps,
        0,
        0,
    )
}

fun new_fixture(): Fixture {
    new_fixture_with_retention(2_000)
}

fun new_fixture_with_retention(retention_bps: u64): Fixture {
    new_fixture_with_options(retention_bps, 0)
}

fun new_fixture_with_options(retention_bps: u64, idle_quote: u64): Fixture {
    new_fixture_with_upstream_fees(retention_bps, idle_quote, 0, 0)
}

fun new_fixture_with_upstream_fees(
    retention_bps: u64,
    idle_quote: u64,
    raise_bps: u64,
    token_bps: u64,
): Fixture {
    new_fixture_with_partner_options(retention_bps, idle_quote, raise_bps, token_bps, true)
}

fun new_fixture_with_partner_options(
    retention_bps: u64,
    idle_quote: u64,
    raise_bps: u64,
    token_bps: u64,
    accepted_partner: bool,
): Fixture {
    new_fixture_with_team_allocations(
        retention_bps,
        idle_quote,
        raise_bps,
        token_bps,
        accepted_partner,
        0,
        0,
    )
}

fun new_fixture_with_team_allocations(
    retention_bps: u64,
    idle_quote: u64,
    raise_bps: u64,
    token_bps: u64,
    accepted_partner: bool,
    team_token_bps: u64,
    team_raise_bps: u64,
): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let ctx = scenario.ctx();
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(START);
    let creator = market_maker::new_creator_cap(ctx);
    let mut treasury = protocol_treasury::new_for_testing(ctx);
    let policy = market_maker_fee_policy::new_for_testing(object::id(&treasury), ctx);
    let version = package_version::new_for_testing(
        object::id(&treasury),
        object::id(&policy),
        ctx,
    );
    treasury.set_payout(&blast_acl::witness_for_testing<TreasuryAdmin>(), &version, TREASURY);
    let core_version = blast_presale_package::new_for_testing(ctx);
    let mut core_policy = fee_policy::new_for_testing(ctx);
    if (raise_bps > 0 || token_bps > 0) {
        fee_policy::set_fees(
            &mut core_policy,
            &core_version,
            &blast_admin::blast_acl::witness_for_testing<
                blast_presale::blast_presale_domain::FeeAdmin,
            >(),
            blast_presale::bps::new(raise_bps),
            blast_presale::bps::new(token_bps),
            blast_presale::bps::new(1_000),
            blast_presale::bps::new(1_000),
        );
    };
    let mut creation = creation_policy::allowing_for_testing<QUOTE, Witness>(ctx);
    let partner = partners::new_for_testing(PARTNER_RECIPIENT, 4_000, ctx);
    if (accepted_partner) {
        creation_policy::add_partner(
            &mut creation,
            &core_version,
            &blast_admin::blast_acl::witness_for_testing<
                blast_presale::blast_presale_domain::FeeAdmin,
            >(),
            &partner,
        );
    };
    let (initializer, cap) = coin_registry::new_currency_with_otw(
        test_utils::create_one_time_witness<PRESALE_ADAPTER_TESTS>(),
        9,
        b"SALE".to_string(),
        b"Sale Token".to_string(),
        b"Presale market maker test".to_string(),
        b"".to_string(),
        ctx,
    );
    let mut currency = coin_registry::unwrap_for_testing(initializer);
    presale_adapter::create_without_venue_for_testing<PRESALE_ADAPTER_TESTS, QUOTE>(
        cap,
        &mut currency,
        &version,
        &policy,
        &treasury,
        &core_version,
        &creation,
        &core_policy,
        &partner,
        presale_adapter::new_terms(
            100_000,
            false,
            8_000 - team_token_bps,
            2_000 - token_bps,
            1_000,
            DURATION,
            604_800_000,
            1_000,
            2,
            500,
            10,
            retention_bps,
            team_token_bps,
            team_raise_bps,
        ),
        market_maker::new_trading_limits(10_000, 10_000, 100_000, 100_000, idle_quote, 1_000),
        ROOT,
        &creator,
        vector::tabulate!(32, |_| 0),
        &clock,
        ctx,
    );
    let opened = sui::event::events_by_type<presale::PresaleOpened<PRESALE_ADAPTER_TESTS, QUOTE>>();
    assert_eq!(opened.length(), 1);
    assert_eq!(presale::opened_partner_id(&opened[0]), option::some(object::id(&partner)));
    let created = sui::event::events_by_type<PresaleCreated<PRESALE_ADAPTER_TESTS, QUOTE>>();
    destroy(currency);
    destroy(creation);
    scenario.next_tx(ROOT);
    let vault = scenario.take_shared<BlastMarketMakerVault<PRESALE_ADAPTER_TESTS, QUOTE>>();
    let sale = scenario.take_shared<Presale<PRESALE_ADAPTER_TESTS, QUOTE>>();
    let vault_id = object::id(&vault);
    let sale_id = object::id(&sale);
    assert_eq!(created.length(), 1);
    let (witness, recipients, shares, holder_rewards_bps) = presale::created_migration_fields(
        &created[0],
    );
    assert_eq!(witness, std::type_name::with_original_ids<Witness>());
    assert_eq!(recipients, vector[vault_id.to_address()]);
    assert_eq!(shares, vector[10_000]);
    assert_eq!(holder_rewards_bps, 0);
    let (team_recipients, team_shares, _) = presale::created_supply_fields(&created[0]);
    assert_eq!(
        team_recipients,
        if (team_token_bps == 0) vector[] else vector[vault_id.to_address()],
    );
    assert_eq!(team_shares, if (team_token_bps == 0) vector[] else vector[team_token_bps]);

    test_scenario::return_shared(vault);
    test_scenario::return_shared(sale);

    Fixture {
        scenario,
        clock,
        version,
        creator,
        treasury,
        policy,
        core_version,
        core_policy,
        partner,
        vault_id,
        sale_id,
    }
}

fun take_vault(fixture: &Fixture): BlastMarketMakerVault<PRESALE_ADAPTER_TESTS, QUOTE> {
    fixture.scenario.take_shared_by_id(fixture.vault_id)
}

fun take_sale(fixture: &Fixture): Presale<PRESALE_ADAPTER_TESTS, QUOTE> {
    fixture.scenario.take_shared_by_id(fixture.sale_id)
}

fun commit(fixture: &mut Fixture, buyer: address, offered: u64): u64 {
    fixture.scenario.next_tx(buyer);
    let mut sale = fixture.take_sale();
    let payment = coin::mint_for_testing<QUOTE>(offered, fixture.scenario.ctx());
    let change = sale.commit_open(&fixture.core_version, payment, &fixture.clock, fixture.scenario.ctx());
    let returned = change.value();
    change.burn_for_testing();
    test_scenario::return_shared(sale);
    returned
}

fun take_round(f: &Fixture): rewards::BlastPresaleRewardRound<PRESALE_ADAPTER_TESTS, QUOTE> {
    f.scenario.take_shared()
}

fun return_round(_: &Fixture, round: rewards::BlastPresaleRewardRound<PRESALE_ADAPTER_TESTS, QUOTE>) {
    test_scenario::return_shared(round);
}

fun allocate(
    f: &mut Fixture,
    vault: &mut BlastMarketMakerVault<PRESALE_ADAPTER_TESTS, QUOTE>,
    share_meme: u64,
    reinvest_meme: u64,
    share_quote: u64,
    reinvest_quote: u64,
) {
    let Fixture { scenario, version, creator, .. } = f;
    let (meme, quote) = vault.allocate_fees(
        creator,
        version,
        fee_ledger::new_allocation(0, share_meme, reinvest_meme),
        fee_ledger::new_allocation(0, share_quote, reinvest_quote),
        scenario.ctx(),
    );
    assert_eq!(meme.value(), 0);
    assert_eq!(quote.value(), 0);
    meme.burn_for_testing();
    quote.burn_for_testing();
}

fun claim_fees(fixture: &mut Fixture, buyer: address): u64 {
    fixture.scenario.next_tx(buyer);
    let mut vault = fixture.take_vault();
    let (meme, quote) = vault.claim_fees(&fixture.version, fixture.scenario.ctx());
    assert_eq!(meme.value(), 0);
    let amount = quote.value();
    meme.burn_for_testing();
    quote.burn_for_testing();
    test_scenario::return_shared(vault);

    amount
}

fun assert_weights(fixture: &mut Fixture, alice: u64, bob: u64, total: u64) {
    fixture.scenario.next_tx(KEEPER);
    let vault = fixture.take_vault();
    assert_eq!(vault.weight_for_testing(ALICE), alice);
    assert_eq!(vault.weight_for_testing(BOB), bob);
    assert_eq!(vault.total_weight_for_testing(), total);
    test_scenario::return_shared(vault);
}

fun migrate_handoff_and_activate(fixture: &mut Fixture, retention_bps: u64) {
    fixture.scenario.next_tx(KEEPER);
    let mut vault = fixture.take_vault();
    let mut sale = fixture.take_sale();
    sale.settle(&fixture.core_version, &fixture.clock);
    let (meme, quote) = vault.migration_handoff_for_testing(
        &mut sale,
        &fixture.version,
        &fixture.core_version,
        &fixture.core_policy,
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    assert!(sale.is_migrated_for_testing());
    assert_eq!(meme.value(), 20_000);
    assert_eq!(quote.value(), 1_000);
    let (meme, quote) = vault.retain_capital_and_return_seed_for_testing(meme, quote, retention_bps);
    if (retention_bps == 2_000) {
        let (meme_capital, quote_capital) = vault.capital_for_testing();
        assert_eq!(meme_capital, 4_000);
        assert_eq!(quote_capital, 200);
        assert_eq!(meme.value(), 16_000);
        assert_eq!(quote.value(), 800);
    } else if (retention_bps == 5_000) {
        let (meme_capital, quote_capital) = vault.capital_for_testing();
        assert_eq!(meme_capital, 10_000);
        assert_eq!(quote_capital, 500);
        assert_eq!(meme.value(), 10_000);
        assert_eq!(quote.value(), 500);
    } else {
        assert_eq!(retention_bps, 0);
        assert_eq!(meme.value(), 20_000);
        assert_eq!(quote.value(), 1_000);
    };
    meme.destroy_for_testing();
    quote.destroy_for_testing();
    vault.activate_pool(object::id_from_address(@0xCAFE));
    test_scenario::return_shared(vault);
    test_scenario::return_shared(sale);
}

fun migrate_for_partner_payout(fixture: &mut Fixture) {
    let vault = fixture.take_vault();
    let mut sale = fixture.take_sale();
    sale.settle(&fixture.core_version, &fixture.clock);
    let (meme, quote) = vault.migration_handoff_for_testing(
        &mut sale,
        &fixture.version,
        &fixture.core_version,
        &fixture.core_policy,
        &fixture.clock,
        fixture.ctx!(),
    );
    meme.destroy_for_testing();
    quote.destroy_for_testing();
    vault.return_vault();
    return_sale(sale);
}

fun pay_partner(fixture: &mut Fixture) {
    let mut sale = fixture.take_sale();
    sale.pay_protocol_fees_with_partner(
        &fixture.core_version,
        &fixture.core_policy,
        &fixture.partner,
        &fixture.clock,
        fixture.ctx!(),
    );
    return_sale(sale);
}

fun end(fixture: Fixture) {
    let Fixture {
        scenario,
        clock,
        version,
        creator,
        treasury,
        policy,
        core_version,
        core_policy,
        partner,
        vault_id: _,
        sale_id: _,
    } = fixture;
    clock.destroy_for_testing();
    destroy(version);
    destroy(creator);
    destroy(treasury);
    destroy(policy);
    destroy(core_version);
    destroy(core_policy);
    destroy(partner);
    scenario.end();
}

// === Imports ===

use blast_partners::blast_partners::{Self as partners, Partner};
use blast_presale::{
    blast_presale::{Self as presale, Presale, PresaleCreated},
    blast_presale_package::{Self, PackageVersion as PresaleVersion},
    creation_policy,
    fee_policy::{Self, FeePolicy as PresaleFeePolicy},
};
use blast_admin::blast_acl;
use blast_market_maker::{
    blast_market_maker_domain::TreasuryAdmin,
    market_maker::{Self, BlastMarketMakerVault, BlastMarketMakerCreatorCap},
    fee_ledger,
    presale_rewards as rewards,
    blast_market_maker_domain::RewardsAdmin,
    market_maker_fee_policy::{Self, BlastMarketMakerFeePolicy},
    cetus_engine,
    package_version::{Self, BlastMarketMakerVersion as PackageVersion},
    presale_adapter::{Self, PresaleTerms, Witness},
    protocol_treasury::{Self, BlastMarketMakerTreasury},
};
use fun fixture_next_tx as Fixture.next_tx;
use fun fixture_ctx as Fixture.ctx;
use std::unit_test::{assert_eq, destroy};
use sui::{
    balance,
    clock::{Self, Clock},
    coin::{Self, Coin},
    coin_registry,
    test_scenario::{Self, Scenario},
    test_utils,
};

use fun cetus_engine::retain_capital_and_return_seed_for_testing as BlastMarketMakerVault.retain_capital_and_return_seed_for_testing;
use fun presale_adapter::destroy_cancelled_presale_cap as BlastMarketMakerVault.destroy_cancelled_presale_cap;
use fun presale_adapter::migration_handoff_for_testing as BlastMarketMakerVault.migration_handoff_for_testing;
use fun presale_adapter::receive_team_meme as BlastMarketMakerVault.receive_team_meme;
use fun presale_adapter::receive_team_quote as BlastMarketMakerVault.receive_team_quote;
use fun return_vault as BlastMarketMakerVault.return_vault;
