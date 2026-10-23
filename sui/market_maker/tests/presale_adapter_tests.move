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
fun hard_cap_change_never_inflates_backer_weight() {
    let mut fixture = new_fixture();
    assert_eq!(commit(&mut fixture, ALICE, 500, false), 0);
    assert_eq!(commit(&mut fixture, BOB, 1_000, false), 500);
    assert_weights(&mut fixture, 500, 500, 1_000);
    fixture.next_tx!(KEEPER, |f| {
        let sale = take_sale(f);
        let (total, participants, quote, _, _, _, _) = presale::custody_for_testing(&sale);
        assert_eq!(total, 1_000);
        assert_eq!(participants, 2);
        assert_eq!(quote, 1_000);
        return_sale(sale);
    });
    end(fixture);
}

#[test]
fun direct_core_buyers_keep_tokens_but_receive_no_vault_weight() {
    let mut fixture = new_fixture();
    assert_eq!(commit(&mut fixture, ALICE, 500, true), 0);
    assert_eq!(commit(&mut fixture, BOB, 500, false), 0);
    assert_weights(&mut fixture, 0, 500, 500);
    migrate_handoff_and_activate(&mut fixture, 0);
    fixture.next_tx!(KEEPER, |f| {
        let mut sale = take_sale(f);
        presale::claim(&mut sale, &f.core_version, ALICE, &f.clock, f.ctx!());
        assert_eq!(presale::commitment_for_testing(&sale, ALICE), 0);
        return_sale(sale);
    });
    fixture.next_tx!(ALICE, |f| {
        let tokens = take_coin<PRESALE_ADAPTER_TESTS>(f);
        assert_eq!(tokens.value(), 40_000);
        coin::burn_for_testing(tokens);
    });
    end(fixture);
}

#[test]
fun no_wrapper_backers_cannot_veto_migration_and_creator_can_reinvest() {
    let mut fixture = new_fixture();
    assert_eq!(commit(&mut fixture, ALICE, 1_000, true), 0);
    assert_weights(&mut fixture, 0, 0, 0);
    migrate_handoff_and_activate(&mut fixture, 0);
    fixture.next_tx!(KEEPER, |f| {
        let mut vault = take_vault(f);
        market_maker::credit_lp_fees(
            &mut vault,
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
        ) = market_maker::fee_balances(
            &vault,
        );
        assert_eq!(available_meme, 7);
        assert_eq!(available_quote, 100);
        assert_eq!(reserved_meme, 0);
        assert_eq!(reserved_quote, 0);
        allocate(f, &mut vault, 0, 7, 0, 100);
        let (meme_capital, quote_capital) = market_maker::capital_for_testing(&vault);
        assert_eq!(meme_capital, 7);
        assert_eq!(quote_capital, 100);
        assert_eq!(market_maker::is_pool_for_testing(&vault), true);
        return_vault(vault);
    });
    end(fixture);
}

#[test]
fun failed_presale_refunds_once_through_core_and_holds_no_vault_capital() {
    let mut fixture = new_fixture();
    assert_eq!(commit(&mut fixture, ALICE, 500, false), 0);
    fixture.clock.set_for_testing(START + DURATION);
    fixture.next_tx!(KEEPER, |f| {
        let mut sale = take_sale(f);
        presale::settle(&mut sale, &f.core_version, &f.clock);
        assert_eq!(presale::is_cancelled_for_testing(&sale), true);
        presale::claim(&mut sale, &f.core_version, ALICE, &f.clock, f.ctx!());
        assert_eq!(presale::commitment_for_testing(&sale, ALICE), 0);
        let (_, _, quote, _, _, _, _) = presale::custody_for_testing(&sale);
        assert_eq!(quote, 0);
        return_sale(sale);
        let vault = take_vault(f);
        let (meme_capital, quote_capital) = market_maker::capital_for_testing(&vault);
        assert_eq!(meme_capital, 0);
        assert_eq!(quote_capital, 0);
        return_vault(vault);
    });
    fixture.next_tx!(ALICE, |f| {
        let refund = take_coin<QUOTE>(f);
        assert_eq!(refund.value(), 500);
        coin::burn_for_testing(refund);
    });
    end(fixture);
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
        let mut vault = take_vault(f);
        let refund = market_maker::refund(&mut vault, &f.version, f.ctx!());
        coin::burn_for_testing(refund);
        return_vault(vault);
    });
    end(fixture);
}

#[test]
#[
    expected_failure(
        abort_code = package_version::EVersionMismatch,
        location = blast_market_maker::package_version,
    ),
]
fun stale_local_version_rejects_before_accepting_presale_payment() {
    let mut fixture = new_fixture();
    package_version::set_generation_for_testing(&mut fixture.version, 2);
    let _ = commit(&mut fixture, ALICE, 500, false);
    end(fixture);
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
        let vault = take_vault(f);
        market_maker::assert_external(&vault, object::id_from_address(@0xBAD));
        return_vault(vault);
    });
    end(fixture);
}

#[test]
fun retains_both_actual_core_handoff_assets_without_reducing_buyer_tokens() {
    let mut fixture = new_fixture();
    assert_eq!(commit(&mut fixture, ALICE, 1_000, false), 0);
    migrate_handoff_and_activate(&mut fixture, 2_000);
    fixture.next_tx!(KEEPER, |f| {
        let mut sale = take_sale(f);
        presale::claim(&mut sale, &f.core_version, ALICE, &f.clock, f.ctx!());
        return_sale(sale);
    });
    fixture.next_tx!(ALICE, |f| {
        let tokens = take_coin<PRESALE_ADAPTER_TESTS>(f);
        assert_eq!(tokens.value(), 80_000);
        coin::burn_for_testing(tokens);
    });
    end(fixture);
}

#[test]
fun fragmented_fees_and_repeated_claims_preserve_unequal_presale_weights() {
    let mut fixture = new_fixture();
    assert_eq!(commit(&mut fixture, ALICE, 600, false), 0);
    assert_eq!(commit(&mut fixture, BOB, 500, false), 100);
    migrate_handoff_and_activate(&mut fixture, 0);
    let mut alice_claimed = 0;
    let mut bob_claimed = 0;
    vector[1, 2, 7, 40, 200, 1_000].do!(|received| {
        fixture.next_tx!(KEEPER, |f| {
            let mut vault = take_vault(f);
            market_maker::credit_lp_fees(
                &mut vault,
                &f.version,
                &f.policy,
                &mut f.treasury,
                balance::zero<PRESALE_ADAPTER_TESTS>(),
                balance::create_for_testing<QUOTE>(received),
            );
            allocate(f, &mut vault, 0, 0, received, 0);
            return_vault(vault);
            alice_claimed = alice_claimed + claim_fees(f, ALICE);
            bob_claimed = bob_claimed + claim_fees(f, BOB);
        });
    });
    assert_eq!(alice_claimed, 750);
    assert_eq!(bob_claimed, 500);
    fixture.next_tx!(KEEPER, |f| {
        let vault = take_vault(f);
        let (
            available_meme,
            available_quote,
            reserved_meme,
            reserved_quote,
        ) = market_maker::fee_balances(
            &vault,
        );
        assert_eq!(available_meme, 0);
        assert_eq!(available_quote, 0);
        assert_eq!(reserved_meme, 0);
        assert_eq!(reserved_quote, 0);
        return_vault(vault);
    });
    end(fixture);
}

#[test]
fun funded_sale_cancelled_at_liquidity_deadline_refunds_and_retires_cap() {
    let mut fixture = new_fixture();
    assert_eq!(commit(&mut fixture, ALICE, 1_000, false), 0);
    fixture.next_tx!(KEEPER, |f| {
        let mut sale = take_sale(f);
        presale::settle(&mut sale, &f.core_version, &f.clock);
        assert_eq!(presale::is_funded_for_testing(&sale), true);
        f.clock.set_for_testing(START + 604_800_000);
        presale::cancel_unlaunched(&mut sale, &f.core_version, &f.clock);
        let mut vault = take_vault(f);
        presale_adapter::destroy_cancelled_presale_cap(&mut vault, &sale, &f.version);
        presale::claim(&mut sale, &f.core_version, ALICE, &f.clock, f.ctx!());
        let (meme_capital, quote_capital) = market_maker::capital_for_testing(&vault);
        assert_eq!(meme_capital, 0);
        assert_eq!(quote_capital, 0);
        return_vault(vault);
        return_sale(sale);
    });
    fixture.next_tx!(ALICE, |f| {
        let refund = take_coin<QUOTE>(f);
        assert_eq!(refund.value(), 1_000);
        coin::burn_for_testing(refund);
    });
    end(fixture);
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongPhase,
        location = blast_market_maker::market_maker,
    ),
]
fun presale_fee_claim_rejects_before_weights_freeze() {
    let mut fixture = new_fixture();
    assert_eq!(commit(&mut fixture, ALICE, 500, false), 0);
    let _ = claim_fees(&mut fixture, ALICE);
    end(fixture);
}

#[test]
fun maximum_presale_retention_keeps_half_of_both_actual_handoff_assets() {
    let mut fixture = new_fixture_with_retention(5_000);
    assert_eq!(commit(&mut fixture, ALICE, 1_000, false), 0);
    migrate_handoff_and_activate(&mut fixture, 5_000);
    end(fixture);
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
    end(fixture);
}

#[test]
#[
    expected_failure(
        abort_code = presale_adapter::ETooManyParticipants,
        location = blast_market_maker::presale_adapter,
    ),
]
fun first_participant_limit_above_shared_bound_rejects_at_construction() {
    let _ = presale_adapter::terms(
        100_000,
        false,
        8_000,
        2_000,
        1_000,
        DURATION,
        604_800_000,
        1_000,
        10_001,
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
    assert_eq!(commit(&mut fixture, ALICE, 1_000, false), 0);
    fixture.next_tx!(KEEPER, |f| {
        let mut vault = take_vault(f);
        let mut sale = take_sale(f);
        presale::settle(&mut sale, &f.core_version, &f.clock);
        let (meme, quote) = presale_adapter::migration_handoff_for_testing(
            &vault,
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
        let (meme_seed, quote_seed) = cetus_engine::retain_capital(&mut vault, meme, quote, 2_000);
        assert_eq!(meme_seed.value(), 8_000);
        assert_eq!(quote_seed.value(), 720);
        let (retained_meme, retained_quote) = market_maker::capital_for_testing(&vault);
        assert_eq!(retained_meme, 2_000);
        assert_eq!(retained_quote, 180);
        balance::destroy_for_testing(meme_seed);
        balance::destroy_for_testing(quote_seed);
        market_maker::activate_pool(&mut vault, object::id_from_address(@0xFACE));
        // Upstream LP metadata1000bps does not impose a second receipt deduction here.
        market_maker::credit_lp_fees(
            &mut vault,
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
        ) = market_maker::fee_balances(
            &vault,
        );
        assert_eq!(available_meme, 0);
        assert_eq!(available_quote, 100);
        assert_eq!(reserved_meme, 0);
        assert_eq!(reserved_quote, 0);
        assert_eq!(presale::unpaid_protocol_quote_for_testing(&sale), option::some(100));
        presale::pay_protocol_fees_with_partner(
            &mut sale,
            &f.core_version,
            &f.core_policy,
            &f.partner,
            &f.clock,
            f.ctx!(),
        );
        assert_eq!(presale::unpaid_protocol_quote_for_testing(&sale), option::none());
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
        presale::claim(&mut sale, &f.core_version, ALICE, &f.clock, f.ctx!());
        return_vault(vault);
        return_sale(sale);
    });
    fixture.next_tx!(ROOT, |f| {
        let protocol_meme = take_coin<PRESALE_ADAPTER_TESTS>(f);
        let protocol_quote = take_coin<QUOTE>(f);
        assert_eq!(protocol_meme.value(), 10_000);
        assert_eq!(protocol_quote.value(), 60);
        coin::burn_for_testing(protocol_meme);
        coin::burn_for_testing(protocol_quote);
    });
    fixture.next_tx!(PARTNER_RECIPIENT, |f| {
        let payment = take_coin<QUOTE>(f);
        assert_eq!(payment.value(), 40);
        coin::burn_for_testing(payment);
    });
    fixture.next_tx!(ALICE, |f| {
        let tokens = take_coin<PRESALE_ADAPTER_TESTS>(f);
        assert_eq!(tokens.value(), 80_000);
        coin::burn_for_testing(tokens);
    });
    end(fixture);
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
    end(fixture);
}

#[test]
#[expected_failure(abort_code = presale::EWrongPartner, location = blast_presale::blast_presale)]
fun migrated_presale_cannot_pay_a_different_partner() {
    let mut fixture = new_fixture_with_upstream_fees(2_000, 0, 1_000, 0);
    assert_eq!(commit(&mut fixture, ALICE, 1_000, false), 0);
    fixture.next_tx!(KEEPER, |f| { migrate_for_partner_payout(f); });
    fixture.next_tx!(KEEPER, |f| {
        let other = partners::new_for_testing(KEEPER, 4_000, f.ctx!());
        let mut sale = take_sale(f);
        presale::pay_protocol_fees_with_partner(
            &mut sale,
            &f.core_version,
            &f.core_policy,
            &other,
            &f.clock,
            f.ctx!(),
        );
        destroy(other);
        return_sale(sale);
    });
    end(fixture);
}

#[test]
#[expected_failure(abort_code = presale::ENoPartnerPayout, location = blast_presale::blast_presale)]
fun presale_partner_payout_cannot_be_repeated() {
    let mut fixture = new_fixture_with_upstream_fees(2_000, 0, 1_000, 0);
    assert_eq!(commit(&mut fixture, ALICE, 1_000, false), 0);
    fixture.next_tx!(KEEPER, |f| { migrate_for_partner_payout(f); });
    fixture.next_tx!(KEEPER, |f| { pay_partner(f); });
    fixture.next_tx!(KEEPER, |f| { pay_partner(f); });
    end(fixture);
}

#[test]
#[expected_failure(abort_code = presale::ENoPartnerPayout, location = blast_presale::blast_presale)]
fun presale_partner_cannot_be_paid_from_unmigrated_commitments() {
    let mut fixture = new_fixture_with_upstream_fees(2_000, 0, 1_000, 0);
    assert_eq!(commit(&mut fixture, ALICE, 1_000, false), 0);
    fixture.next_tx!(KEEPER, |f| { pay_partner(f); });
    end(fixture);
}

#[test]
fun explicit_team_tokens_and_raise_land_in_vault_capital_after_real_core_migration() {
    let mut f = new_team_fixture();
    assert_eq!(commit(&mut f, ALICE, 1_000, false), 0);
    f.next_tx!(KEEPER, |f| { migrate_team_handoff(f); });
    f.next_tx!(KEEPER, |f| {
        assert_team_coins_owned_by_vault(f);
        let vault = receive_team_assets(f);
        let (meme, quote) = market_maker::capital_for_testing(&vault);
        // Retained net LP assets2000/140 plus explicit team allocations10000/200.
        assert_eq!(meme, 12_000);
        assert_eq!(quote, 340);
        let (available_meme, available_quote, reserved_meme, reserved_quote) = vault.fee_balances();
        assert_eq!(available_meme, 0);
        assert_eq!(available_quote, 0);
        assert_eq!(reserved_meme, 0);
        assert_eq!(reserved_quote, 0);
        assert_eq!(market_maker::total_weight_for_testing(&vault), 1_000);
        return_vault(vault);
        assert_capital_receipt_events(f, 10_000, 200);
    });
    f.next_tx!(KEEPER, |f| {
        let mut sale = take_sale(f);
        presale::claim(&mut sale, &f.core_version, ALICE, &f.clock, f.ctx!());
        return_sale(sale);
    });
    f.next_tx!(ALICE, |f| {
        let participants = take_coin<PRESALE_ADAPTER_TESTS>(f);
        assert_eq!(participants.value(), 70_000);
        coin::burn_for_testing(participants);
    });
    end(f);
}

#[test]
fun cancelled_presale_releases_no_team_allocations_and_preserves_full_refund() {
    let mut f = new_team_fixture();
    assert_eq!(commit(&mut f, ALICE, 500, false), 0);
    f.clock.set_for_testing(START + DURATION);
    f.next_tx!(KEEPER, |f| {
        let mut sale = take_sale(f);
        presale::settle(&mut sale, &f.core_version, &f.clock);
        assert!(presale::is_cancelled_for_testing(&sale));
        let (_, _, quote, _, _, team_tokens, _) = presale::custody_for_testing(&sale);
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
        assert_no_team_coins_at_vault(f);
        presale::claim(&mut sale, &f.core_version, ALICE, &f.clock, f.ctx!());
        return_sale(sale);
    });
    f.next_tx!(ALICE, |f| {
        let refund = take_coin<QUOTE>(f);
        assert_eq!(refund.value(), 500);
        coin::burn_for_testing(refund);
    });
    end(f);
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
        let mut sale = take_sale(f);
        presale::settle(&mut sale, &f.core_version, &f.clock);
        assert!(presale::is_cancelled_for_testing(&sale));
        return_sale(sale);
        let recipient = f.vault_id.to_address();
        send_quote_to(f, recipient);
    });
    f.next_tx!(KEEPER, |f| { receive_team_quote(f); });
    end(f);
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
    assert_eq!(commit(&mut f, ALICE, 1_000, false), 0);
    migrate_handoff_and_activate(&mut f, 0);
    f.next_tx!(KEEPER, |f| {
        let recipient = f.vault_id.to_address();
        send_quote_to(f, recipient);
    });
    f.next_tx!(KEEPER, |f| { receive_team_quote(f); });
    end(f);
}

#[test]
#[expected_failure(abort_code = sui::transfer::EUnableToReceiveObject, location = sui::transfer)]
fun team_receiving_rejects_a_coin_owned_by_another_address() {
    let mut f = new_team_fixture();
    assert_eq!(commit(&mut f, ALICE, 1_000, false), 0);
    let foreign_coin;
    f.next_tx!(KEEPER, |f| {
        migrate_team_handoff(f);
        foreign_coin = send_quote_to(f, ROOT);
    });
    f.next_tx!(KEEPER, |f| { receive_quote_by_id(f, foreign_coin); });
    end(f);
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
    assert_eq!(commit(&mut f, ALICE, 1_000, false), 0);
    f.next_tx!(KEEPER, |f| { migrate_team_handoff(f); });
    f.next_tx!(KEEPER, |f| {
        let mut vault = receive_team_assets(f);
        withdraw_team_with_foreign_cap(f, &mut vault);
        return_vault(vault);
    });
    end(f);
}

#[test]
#[expected_failure(abort_code = blast_presale::bps::EInvalidBps, location = blast_presale::bps)]
fun team_raise_share_rejects_first_rate_above_one_hundred_percent() {
    let _ = presale_adapter::terms(
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
    assert_eq!(commit(&mut f, ALICE, 1_000, false), 0);
    f.next_tx!(KEEPER, |f| { migrate_team_handoff(f); });
    f.next_tx!(KEEPER, |f| { receive_with_wrong_sale_binding(f); });
    end(f);
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
    assert_eq!(commit(&mut f, ALICE, 1_000, false), 0);
    f.next_tx!(KEEPER, |f| { migrate_team_handoff(f); });
    package_version::set_generation_for_testing(&mut f.version, 2);
    f.next_tx!(KEEPER, |f| { receive_team_quote(f); });
    end(f);
}

#[test]
fun same_asset_donation_becomes_only_capital_without_fee_weight_or_reserves() {
    let mut f = new_team_fixture();
    assert_eq!(commit(&mut f, ALICE, 1_000, false), 0);
    f.next_tx!(KEEPER, |f| { migrate_team_handoff(f); });
    f.next_tx!(KEEPER, |f| {
        let recipient = f.vault_id.to_address();
        send_quote_to(f, recipient);
    });
    f.next_tx!(KEEPER, |f| {
        receive_team_quote(f);
        assert_donation_receipt_event(f);
    });
    f.next_tx!(KEEPER, |f| {
        let vault = take_vault(f);
        let (meme, quote) = market_maker::capital_for_testing(&vault);
        assert_eq!(meme, 2_000);
        assert_eq!(quote, 141);
        assert_eq!(market_maker::total_weight_for_testing(&vault), 1_000);
        let (available_meme, available_quote, reserved_meme, reserved_quote) = vault.fee_balances();
        assert_eq!(available_meme, 0);
        assert_eq!(available_quote, 0);
        assert_eq!(reserved_meme, 0);
        assert_eq!(reserved_quote, 0);
        let (meme_claim, quote_claim) = vault.claimable_fees(ALICE);
        assert_eq!(meme_claim, 0);
        assert_eq!(quote_claim, 0);
        return_vault(vault);
    });
    end(f);
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
    let sale = take_sale(f);
    let Fixture { scenario, creator, version, treasury, policy, .. } = f;
    let mut foreign = market_maker::new<PRESALE_ADAPTER_TESTS, QUOTE>(
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
    market_maker::bind_external(&mut foreign, object::id_from_address(@0xBAD));
    presale_adapter::receive_team_quote(&mut foreign, &sale, version, payment);
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
    let mut vault = take_vault(f);
    let mut sale = take_sale(f);
    presale::settle(&mut sale, &f.core_version, &f.clock);
    let (meme, quote) = presale_adapter::migration_handoff_for_testing(
        &vault,
        &mut sale,
        &f.version,
        &f.core_version,
        &f.core_policy,
        &f.clock,
        f.ctx!(),
    );
    assert!(presale::is_migrated_for_testing(&sale));
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
    let (meme, quote) = cetus_engine::retain_capital(&mut vault, meme, quote, 2_000);
    assert_eq!(meme.value(), 8_000);
    assert_eq!(quote.value(), 560);
    balance::destroy_for_testing(meme);
    balance::destroy_for_testing(quote);
    market_maker::activate_pool(&mut vault, object::id_from_address(@0xCAFE));
    return_vault(vault);
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
    let mut vault = take_vault(f);
    let sale = take_sale(f);
    presale_adapter::receive_team_meme(&mut vault, &sale, &f.version, meme);
    presale_adapter::receive_team_quote(&mut vault, &sale, &f.version, quote);
    return_sale(sale);
    vault
}

fun receive_team_quote(f: &Fixture) {
    let payment = test_scenario::most_recent_receiving_ticket<Coin<QUOTE>>(&f.vault_id);
    let mut vault = take_vault(f);
    let sale = take_sale(f);
    presale_adapter::receive_team_quote(&mut vault, &sale, &f.version, payment);
    return_vault(vault);
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
    let mut vault = take_vault(f);
    let sale = take_sale(f);
    presale_adapter::receive_team_quote(&mut vault, &sale, &f.version, payment);
    return_vault(vault);
    return_sale(sale);
}

fun withdraw_team_with_foreign_cap(
    f: &mut Fixture,
    vault: &mut BlastMarketMakerVault<PRESALE_ADAPTER_TESTS, QUOTE>,
) {
    let Fixture { scenario, version, .. } = f;
    let foreign = market_maker::new_creator_cap(scenario.ctx());
    let (meme, quote) = vault.withdraw_capital(&foreign, version, 1, 1, scenario.ctx());
    coin::burn_for_testing(meme);
    coin::burn_for_testing(quote);
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
    presale_adapter::terms(
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
    treasury.set_payout(&version, &blast_acl::witness_for_testing<TreasuryAdmin>(), TREASURY);
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
        presale_adapter::terms(
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
        market_maker::trading_limits(10_000, 10_000, 100_000, 100_000, idle_quote, 1_000),
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

fun commit(fixture: &mut Fixture, buyer: address, offered: u64, direct: bool): u64 {
    fixture.scenario.next_tx(buyer);
    let mut vault = take_vault(fixture);
    let mut sale = take_sale(fixture);
    let payment = coin::mint_for_testing<QUOTE>(offered, fixture.scenario.ctx());
    let change = if (direct) {
        presale::commit_open(
            &mut sale,
            &fixture.core_version,
            payment,
            &fixture.clock,
            fixture.scenario.ctx(),
        )
    } else {
        presale_adapter::commit(
            &mut vault,
            &mut sale,
            &fixture.version,
            &fixture.core_version,
            payment,
            &fixture.clock,
            fixture.scenario.ctx(),
        )
    };
    let returned = change.value();
    coin::burn_for_testing(change);
    test_scenario::return_shared(vault);
    test_scenario::return_shared(sale);

    returned
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
    let (meme, quote) = market_maker::allocate_fees(
        vault,
        creator,
        version,
        fee_ledger::allocation(0, share_meme, reinvest_meme),
        fee_ledger::allocation(0, share_quote, reinvest_quote),
        scenario.ctx(),
    );
    assert_eq!(meme.value(), 0);
    assert_eq!(quote.value(), 0);
    coin::burn_for_testing(meme);
    coin::burn_for_testing(quote);
}

fun claim_fees(fixture: &mut Fixture, buyer: address): u64 {
    fixture.scenario.next_tx(buyer);
    let mut vault = take_vault(fixture);
    let (meme, quote) = market_maker::claim_fees(
        &mut vault,
        &fixture.version,
        fixture.scenario.ctx(),
    );
    assert_eq!(meme.value(), 0);
    let amount = quote.value();
    coin::burn_for_testing(meme);
    coin::burn_for_testing(quote);
    test_scenario::return_shared(vault);

    amount
}

fun assert_weights(fixture: &mut Fixture, alice: u64, bob: u64, total: u64) {
    fixture.scenario.next_tx(KEEPER);
    let vault = take_vault(fixture);
    assert_eq!(market_maker::weight_for_testing(&vault, ALICE), alice);
    assert_eq!(market_maker::weight_for_testing(&vault, BOB), bob);
    assert_eq!(market_maker::total_weight_for_testing(&vault), total);
    test_scenario::return_shared(vault);
}

fun migrate_handoff_and_activate(fixture: &mut Fixture, retention_bps: u64) {
    fixture.scenario.next_tx(KEEPER);
    let mut vault = take_vault(fixture);
    let mut sale = take_sale(fixture);
    presale::settle(&mut sale, &fixture.core_version, &fixture.clock);
    let (meme, quote) = presale_adapter::migration_handoff_for_testing(
        &vault,
        &mut sale,
        &fixture.version,
        &fixture.core_version,
        &fixture.core_policy,
        &fixture.clock,
        fixture.scenario.ctx(),
    );
    assert!(presale::is_migrated_for_testing(&sale));
    assert_eq!(meme.value(), 20_000);
    assert_eq!(quote.value(), 1_000);
    let (meme, quote) = cetus_engine::retain_capital(&mut vault, meme, quote, retention_bps);
    if (retention_bps == 2_000) {
        let (meme_capital, quote_capital) = market_maker::capital_for_testing(&vault);
        assert_eq!(meme_capital, 4_000);
        assert_eq!(quote_capital, 200);
        assert_eq!(meme.value(), 16_000);
        assert_eq!(quote.value(), 800);
    } else if (retention_bps == 5_000) {
        let (meme_capital, quote_capital) = market_maker::capital_for_testing(&vault);
        assert_eq!(meme_capital, 10_000);
        assert_eq!(quote_capital, 500);
        assert_eq!(meme.value(), 10_000);
        assert_eq!(quote.value(), 500);
    } else {
        assert_eq!(retention_bps, 0);
        assert_eq!(meme.value(), 20_000);
        assert_eq!(quote.value(), 1_000);
    };
    balance::destroy_for_testing(meme);
    balance::destroy_for_testing(quote);
    market_maker::activate_pool(&mut vault, object::id_from_address(@0xCAFE));
    test_scenario::return_shared(vault);
    test_scenario::return_shared(sale);
}

fun migrate_for_partner_payout(fixture: &mut Fixture) {
    let vault = take_vault(fixture);
    let mut sale = take_sale(fixture);
    presale::settle(&mut sale, &fixture.core_version, &fixture.clock);
    let (meme, quote) = presale_adapter::migration_handoff_for_testing(
        &vault,
        &mut sale,
        &fixture.version,
        &fixture.core_version,
        &fixture.core_policy,
        &fixture.clock,
        fixture.ctx!(),
    );
    balance::destroy_for_testing(meme);
    balance::destroy_for_testing(quote);
    return_vault(vault);
    return_sale(sale);
}

fun pay_partner(fixture: &mut Fixture) {
    let mut sale = take_sale(fixture);
    presale::pay_protocol_fees_with_partner(
        &mut sale,
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
