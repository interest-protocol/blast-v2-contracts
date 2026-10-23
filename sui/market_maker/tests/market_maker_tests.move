// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_market_maker::market_maker_tests;

// === Constants ===

const ROOT: address = @0xA;
const ALICE: address = @0xB;
const BOB: address = @0xC;
const PAYOUT: address = @0xD;
const DEADLINE: u64 = 2_000;

// === Test-Only Types ===

public struct MEME has drop {}
public struct CurveFundingPayload has copy, drop {
    vault_id: ID,
    gross: u64,
    raise_fee: u64,
    net: u64,
}
public struct ExternalBoundPayload has copy, drop { vault_id: ID, external_id: ID }
public struct FeesCreditedPayload has copy, drop {
    vault_id: ID,
    meme_received: u64,
    quote_received: u64,
}

public struct CapitalDepositPayload has copy, drop {
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}
public struct CapitalWithdrawalPayload has copy, drop {
    vault_id: ID,
    creator_cap_id: ID,
    meme_amount: u64,
    quote_amount: u64,
}

public struct Fixture {
    scenario: Scenario,
    clock: Clock,
    version: PackageVersion,
    treasury: BlastMarketMakerTreasury,
    policy: BlastMarketMakerFeePolicy,
    vault_id: ID,
}

// === Tests ===

#[test]
fun new_backer_can_fill_one_atom_tail_without_inflating_weight() {
    let mut f = start(10_000_001);
    assert_eq!(f.contribute(ALICE, 10_000_000), 0);
    assert_eq!(f.contribute(BOB, 10_000_000), 9_999_999);
    f.next_tx!(ROOT, |f| {
        let vault = f.take_vault();
        assert_eq!(vault.weight_for_testing(ALICE), 10_000_000);
        assert_eq!(vault.weight_for_testing(BOB), 1);
        assert_eq!(vault.total_weight_for_testing(), 10_000_001);
        vault.return_vault();
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EContributionBelowMinimum,
        location = blast_market_maker::market_maker,
    ),
]
fun cheap_new_address_cannot_consume_backer_capacity() {
    let mut f = start(100_000_000_001);
    let _ = f.contribute(ALICE, 10_000_000);
    f.end();
}

#[test]
fun existing_backer_can_top_up_one_atom_and_refund_full_principal_at_deadline() {
    let mut f = start(20_000_000);
    let _ = f.contribute(ALICE, 10_000_000);
    let _ = f.contribute(ALICE, 1);
    f.clock.set_for_testing(DEADLINE);
    f.next_tx!(ALICE, |f| {
        let mut vault = f.take_vault();
        vault.begin_refunding(&f.version, &f.clock);
        let refund = vault.refund(&f.version, f.ctx!());
        assert_eq!(refund.value(), 10_000_001);
        refund.burn_for_testing();
        let (m, q, rm, rq) = vault.fee_balances();
        assert!(m == 0 && q == 0 && rm == 0 && rq == 0);
        assert_eq!(vault.weight_for_testing(ALICE), 0);
        vault.return_vault();
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::ENothingRefundable,
        location = blast_market_maker::market_maker,
    ),
]
fun refund_cannot_be_claimed_twice() {
    let mut f = start(20_000_000);
    let _ = f.contribute(ALICE, 10_000_000);
    f.clock.set_for_testing(DEADLINE);
    f.next_tx!(ALICE, |f| {
        let mut vault = f.take_vault();
        vault.begin_refunding(&f.version, &f.clock);
        coin::burn_for_testing(vault.refund(&f.version, f.ctx!()));
        coin::burn_for_testing(vault.refund(&f.version, f.ctx!()));
        vault.return_vault();
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EDeadlineReached,
        location = blast_market_maker::market_maker,
    ),
]
fun launch_cannot_take_full_funding_at_exact_deadline() {
    let mut f = start(20_000_000);
    let _ = f.contribute(ALICE, 20_000_000);
    f.clock.set_for_testing(DEADLINE);
    f.activate_curve();
    f.end();
}

#[test]
fun curve_raise_fee_and_lp_deduction_are_separate_from_creator_and_backer_fees() {
    let mut f = start(20_000_000);
    let _ = f.contribute(ALICE, 20_000_000);
    f.activate_curve();
    f.next_tx!(ROOT, |f| {
        f.set_rates(2_000, 2_000);
        let mut vault = f.take_vault();
        vault.credit_lp_fees(
            &f.version,
            &f.policy,
            &mut f.treasury,
            balance::create_for_testing<MEME>(11),
            balance::create_for_testing<SUI>(101),
        );
        assert_eq!(f.treasury.balance_for_testing<MEME>(), 3);
        assert_eq!(f.treasury.balance_for_testing<SUI>(), 21);
        let (m, q, rm, rq) = vault.fee_balances();
        assert!(m == 8 && q == 80 && rm == 0 && rq == 0);
        let creator = f.take_sender<BlastMarketMakerCreatorCap>();
        let (kept_meme, kept_quote) = vault.allocate_fees(
            &creator,
            &f.version,
            fee_ledger::new_allocation(1, 3, 4),
            fee_ledger::new_allocation(10, 64, 6),
            f.ctx!(),
        );
        assert!(kept_meme.value() == 1 && kept_quote.value() == 10);
        kept_meme.burn_for_testing();
        kept_quote.burn_for_testing();
        let (meme, quote) = vault.capital_for_testing();
        assert!(meme == 4 && quote == 19_000_006);
        vault.credit_raise_fees_to_treasury(&f.version, &mut f.treasury);
        assert_eq!(f.treasury.balance_for_testing<SUI>(), 1_000_021);
        f.return_sender(creator);
        vault.return_vault();
    });
    f.next_tx!(ALICE, |f| {
        let mut vault = f.take_vault();
        let (meme, quote) = vault.claim_fees(&f.version, f.ctx!());
        assert!(meme.value() == 2 && quote.value() == 63);
        meme.burn_for_testing();
        quote.burn_for_testing();
        let (m, q, rm, rq) = vault.fee_balances();
        assert!(m == 0 && q == 0 && rm == 1 && rq == 1);
        vault.return_vault();
    });
    f.end();
}

#[test]
fun tiny_lp_receipt_can_be_all_local_deduction_without_unfunded_backer_rights() {
    let mut f = start(20_000_000);
    let _ = f.contribute(ALICE, 20_000_000);
    f.activate_curve();
    f.next_tx!(ROOT, |f| {
        f.set_rates(1, 1);
        let mut vault = f.take_vault();
        vault.credit_lp_fees(
            &f.version,
            &f.policy,
            &mut f.treasury,
            balance::zero<MEME>(),
            balance::create_for_testing<SUI>(1),
        );
        assert_eq!(f.treasury.balance_for_testing<SUI>(), 1);
        let (m, q, rm, rq) = vault.fee_balances();
        assert!(m == 0 && q == 0 && rm == 0 && rq == 0);
        vault.return_vault();
    });
    f.end();
}

#[test]
#[expected_failure(abort_code = risk::EInvalidSignatureShape, location = blast_market_maker::risk)]
fun full_action_signature_is_required_before_any_capital_movement() {
    let mut f = start(20_000_000);
    let _ = f.contribute(ALICE, 20_000_000);
    f.activate_curve();
    f.next_tx!(ROOT, |f| {
        let vault = f.take_vault();
        let cap = f.take_sender<BlastMarketMakerOperatorCap>();
        vault.authorize_action(
            &f.version,
            option::some(object::id(&cap)),
            risk::new_curve_buy(1, 1),
            100,
            200,
            &vector[],
            &f.clock,
        );
        vault.return_vault();
        f.return_sender(cap);
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::ETradingInputLimit,
        location = blast_market_maker::market_maker,
    ),
]
fun gross_input_limit_rejects_before_malformed_signature() {
    let mut f = start(20_000_000);
    let _ = f.contribute(ALICE, 20_000_000);
    f.activate_curve();
    f.next_tx!(ROOT, |f| {
        let vault = f.take_vault();
        let cap = f.take_sender<BlastMarketMakerOperatorCap>();
        vault.authorize_action(
            &f.version,
            option::some(object::id(&cap)),
            risk::new_curve_buy(10_000_001, 1),
            100,
            200,
            &vector[],
            &f.clock,
        );
        vault.return_vault();
        f.return_sender(cap);
    });
    f.end();
}

#[test]
fun canonical_signature_payload_changes_for_action_nonce_epoch_and_target() {
    let action = risk::new_curve_buy(100, 1);
    let base = risk::message_bytes<MEME, SUI>(
        object::id_from_address(@1),
        object::id_from_address(@2),
        option::none(),
        object::id_from_address(@3),
        action,
        0,
        0,
        100,
        200,
    );
    let nonce = risk::message_bytes<MEME, SUI>(
        object::id_from_address(@1),
        object::id_from_address(@2),
        option::none(),
        object::id_from_address(@3),
        action,
        1,
        0,
        100,
        200,
    );
    let epoch = risk::message_bytes<MEME, SUI>(
        object::id_from_address(@1),
        object::id_from_address(@2),
        option::none(),
        object::id_from_address(@3),
        action,
        0,
        1,
        100,
        200,
    );
    let other = risk::message_bytes<MEME, SUI>(
        object::id_from_address(@4),
        object::id_from_address(@2),
        option::none(),
        object::id_from_address(@3),
        action,
        0,
        0,
        100,
        200,
    );
    assert!(base != nonce && base != epoch && base != other);
}

#[test]
fun ed25519_matches_rfc8032_empty_message_vector() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(100);
    risk::verify(
        &x"d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        &x"e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
        &vector[],
        100,
        100,
        &clock,
    );
    clock.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = risk::EAuthorizationExpired, location = blast_market_maker::risk)]
fun expired_signature_rejects_before_signature_shape() {
    let mut ctx = tx_context::dummy();
    let mut clock = clock::create_for_testing(&mut ctx);
    clock.set_for_testing(201);
    risk::verify(&vector[], &vector[], &vector[], 100, 200, &clock);
    clock.destroy_for_testing();
}

#[test]
fun fee_accumulator_preserves_fractional_entitlements_over_many_tiny_receipts() {
    let mut acc = 0;
    let mut rem = 0;
    let mut paid = 0;
    let mut index = 0;
    let mut claim_rem = 0;
    1_000u64.do!(|_| {
        let (next_acc, next_rem) = market_maker_math::accrued_index_down(acc, rem, 1, 7);
        acc = next_acc;
        rem = next_rem;
        let (amount, remainder) = market_maker_math::claim_amount_down(acc, index, claim_rem, 7);
        paid = paid + amount;
        index = acc;
        claim_rem = remainder;
    });
    assert_eq!(paid, 999);
    assert_eq!(claim_rem + rem, 18_446_744_073_709_551_616);
}

#[test]
fun full_unwind_can_finish_below_idle_floor_and_advances_nonce() {
    let mut f = start_with_limits(
        20_000_000,
        market_maker::new_trading_limits(10_000_000, 10_000_000, 100_000_000, 100_000_000, 1, 1),
    );
    let _ = f.contribute(ALICE, 20_000_000);
    f.activate_curve();
    f.next_tx!(ROOT, |f| {
        let mut vault = f.take_vault();
        vault.activate_pool(object::id_from_address(@0xFACE));
        balance::destroy_for_testing(vault.take_capital_quote(19_000_000));
        let action = risk::new_unwind(object::id_from_address(@0xCAFE), 1, 0, 0);
        let before = vault.signing_bytes(action, 100, 200);
        // The production venue adapter has already verified the signature and retained removal output.
        // This regression isolates the post-execution ledger gate; it does not execute a venue stub.
        vault.finish_action(action, 0, 0, 0, 0, &f.clock);
        let after = vault.signing_bytes(action, 100, 200);
        assert!(before != after);
        let (meme, quote) = vault.capital_for_testing();
        assert!(meme == 0 && quote == 0);
        vault.return_vault();
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EIdleQuoteFloor,
        location = blast_market_maker::market_maker,
    ),
]
fun ordinary_removal_cannot_finish_below_idle_floor() {
    let mut f = start_with_limits(
        20_000_000,
        market_maker::new_trading_limits(10_000_000, 10_000_000, 100_000_000, 100_000_000, 1, 1),
    );
    let _ = f.contribute(ALICE, 20_000_000);
    f.activate_curve();
    f.next_tx!(ROOT, |f| {
        let mut vault = f.take_vault();
        vault.activate_pool(object::id_from_address(@0xFACE));
        balance::destroy_for_testing(vault.take_capital_quote(19_000_000));
        vault.finish_action(
            risk::new_remove_liquidity(object::id_from_address(@0xCAFE), 1, 0, 0),
            0,
            0,
            0,
            0,
            &f.clock,
        );
        vault.return_vault();
    });
    f.end();
}

#[test]
fun opening_signature_commits_to_ticks_inputs_and_minimum_liquidity() {
    let lower = risk::new_open_position(10, 20, 100, 200, 300);
    let changed_tick = risk::new_open_position(11, 20, 100, 200, 300);
    let changed_meme = risk::new_open_position(10, 20, 101, 200, 300);
    let changed_quote = risk::new_open_position(10, 20, 100, 201, 300);
    let changed_liquidity = risk::new_open_position(10, 20, 100, 200, 301);
    assert!(
        lower != changed_tick && lower != changed_meme && lower != changed_quote && lower != changed_liquidity,
    );
    let (meme, quote) = lower.inputs();
    assert!(meme == 100 && quote == 200);
}

#[test]
fun external_binding_event_replays_exact_curve_launch_identity() {
    let mut f = start(20_000_000);
    let _ = f.contribute(ALICE, 20_000_000);
    f.activate_curve();
    let events = sui::event::events_by_type<market_maker::BlastExternalBound>();
    assert_eq!(events.length(), 1);
    let expected = ExternalBoundPayload {
        vault_id: f.vault_id,
        external_id: object::id_from_address(@0xCAFE),
    };
    assert_eq!(std::bcs::to_bytes(&events[0]), std::bcs::to_bytes(&expected));
    f.end();
}

#[test]
fun direct_only_fees_remain_unallocated_until_creator_chooses() {
    let mut f = start_route(
        1_000,
        market_maker::presale_route(),
        market_maker::new_trading_limits(100, 100, 1_000, 1_000, 0, 10),
    );
    f.next_tx!(ROOT, |f| {
        let mut vault = f.take_vault();
        vault.bind_external(object::id_from_address(@0xCAFE));
        vault.activate_pool(object::id_from_address(@0xFACE));
        vault.credit_curve_fees(
            balance::create_for_testing<MEME>(7),
            balance::create_for_testing<SUI>(100),
        );
        let events = sui::event::events_by_type<market_maker::BlastFeesCredited<MEME, SUI>>();
        assert_eq!(events.length(), 1);
        let expected = FeesCreditedPayload {
            vault_id: f.vault_id,
            meme_received: 7,
            quote_received: 100,
        };
        assert_eq!(std::bcs::to_bytes(&events[0]), std::bcs::to_bytes(&expected));
        let (m, q, rm, rq) = vault.fee_balances();
        assert!(m == 7 && q == 100 && rm == 0 && rq == 0);
        let creator = f.take_sender<BlastMarketMakerCreatorCap>();
        let (meme, quote) = vault.allocate_fees(
            &creator,
            &f.version,
            fee_ledger::new_allocation(2, 0, 5),
            fee_ledger::new_allocation(20, 0, 80),
            f.ctx!(),
        );
        assert!(meme.value() == 2 && quote.value() == 20);
        meme.burn_for_testing();
        quote.burn_for_testing();
        let (cm, cq) = vault.capital_for_testing();
        assert!(cm == 5 && cq == 80);
        f.return_sender(creator);
        vault.return_vault();
    });
    f.end();
}

#[test]
fun zero_claim_does_not_emit_a_backer_payment_event() {
    let mut f = start(20_000_000);
    let _ = f.contribute(ALICE, 20_000_000);
    f.activate_curve();
    f.next_tx!(ALICE, |f| {
        let mut vault = f.take_vault();
        let (meme, quote) = vault.claim_fees(&f.version, f.ctx!());
        assert!(meme.value() == 0 && quote.value() == 0);
        assert!(
            sui::event::events_by_type<
                market_maker::BlastBackerFeesClaimed<MEME, SUI>,
            >().is_empty(),
        );
        meme.burn_for_testing();
        quote.burn_for_testing();
        vault.return_vault();
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EInvalidTradingLimits,
        location = blast_market_maker::market_maker,
    ),
]
fun shared_presale_constructor_rejects_an_unfunded_idle_quote_floor() {
    let f = start_route(
        1_000,
        market_maker::presale_route(),
        market_maker::new_trading_limits(100, 100, 1_000, 1_000, 1, 10),
    );
    f.end();
}

#[test]
fun curve_raise_and_lp_fees_fund_treasury_while_seed_remainders_stay_creator_capital() {
    let mut f = start(20_000_000);
    let _ = f.contribute(ALICE, 20_000_000);
    f.activate_curve();
    let transition = sui::event::events_by_type<market_maker::BlastCurveFundingActivated<SUI>>()[0];
    let expected = CurveFundingPayload {
        vault_id: f.vault_id,
        gross: 20_000_000,
        raise_fee: 1_000_000,
        net: 19_000_000,
    };
    assert_eq!(std::bcs::to_bytes(&transition), std::bcs::to_bytes(&expected));
    f.set_rates(1_000, 2_000);
    f.next_tx!(ROOT, |f| {
        let mut vault = f.take_vault();
        let (unused_meme, unused_quote) = vault.retain_seed_residuals_for_testing(
            balance::create_for_testing<MEME>(7),
            balance::create_for_testing<SUI>(11),
        );
        assert_eq!(unused_meme, 7);
        assert_eq!(unused_quote, 11);
        vault.credit_curve_fees(balance::zero(), balance::create_for_testing<SUI>(100));
        vault.activate_pool(object::id_from_address(@0xFACE));
        vault.credit_lp_fees(
            &f.version,
            &f.policy,
            &mut f.treasury,
            balance::create_for_testing<MEME>(10),
            balance::create_for_testing<SUI>(100),
        );
        vault.credit_raise_fees_to_treasury(&f.version, &mut f.treasury);
        let credits = sui::event::events_by_type<protocol_treasury::BlastTreasuryCredited<SUI>>();
        assert_eq!(credits.length(), 2);
        let mut credited = 0;
        credits.do!(|credit| {
            let mut data = sui::bcs::new(std::bcs::to_bytes(&credit));
            assert_eq!(data.peel_address(), object::id(&f.treasury).to_address());
            assert_eq!(data.peel_address(), f.vault_id.to_address());
            credited = credited + data.peel_u64();
            assert!(data.into_remainder_bytes().is_empty());
        });
        assert_eq!(credited, 1_000_020);
        assert_eq!(f.treasury.balance_for_testing<SUI>(), credited);
        assert_eq!(f.treasury.balance_for_testing<MEME>(), 1);
        let meme_credits = sui::event::events_by_type<
            protocol_treasury::BlastTreasuryCredited<MEME>,
        >();
        assert_eq!(meme_credits.length(), 1);
        let mut data = sui::bcs::new(std::bcs::to_bytes(&meme_credits[0]));
        assert_eq!(data.peel_address(), object::id(&f.treasury).to_address());
        assert_eq!(data.peel_address(), f.vault_id.to_address());
        assert_eq!(data.peel_u64(), 1);
        assert_eq!(data.into_remainder_bytes(), vector[]);

        let (meme, quote) = vault.capital_for_testing();
        assert_eq!(meme, 7);
        assert_eq!(quote, 19_000_011);
        let creator = f.take_sender<BlastMarketMakerCreatorCap>();
        let (meme, quote) = vault.withdraw_capital(&creator, &f.version, 7, 11, f.ctx!());
        assert_eq!(meme.value(), 7);
        assert_eq!(quote.value(), 11);
        meme.burn_for_testing();
        quote.burn_for_testing();
        let (meme, quote) = vault.capital_for_testing();
        assert_eq!(meme, 0);
        assert_eq!(quote, 19_000_000);
        let (meme_fees, quote_fees, reserved_meme, reserved_quote) = vault.fee_balances();
        assert_eq!(meme_fees, 9);
        assert_eq!(quote_fees, 180);
        assert_eq!(reserved_meme, 0);
        assert_eq!(reserved_quote, 0);
        f.return_sender(creator);
        f.withdraw_quote(20);
        assert_eq!(f.treasury.balance_for_testing<SUI>(), 1_000_000);
        vault.return_vault();
    });
    f.next_tx!(PAYOUT, |f| {
        let earned_lp_fee = f.take_sender<sui::coin::Coin<SUI>>();
        assert_eq!(earned_lp_fee.value(), 20);
        earned_lp_fee.burn_for_testing();
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker_fee_policy::ERateAboveMaximum,
        location = blast_market_maker::market_maker_fee_policy,
    ),
]
fun fee_manager_cannot_raise_local_lp_rate_above_compiled_ceiling() {
    let mut f = start(20_000_000);
    f.set_rates(2_001, 0);
    f.end();
}

#[test]
fun treasury_pays_publisher_before_configuration_and_new_destination_after_rotation() {
    let mut f = start_route_with_payout(
        20_000_000,
        market_maker::curve_route(),
        market_maker::new_trading_limits(10_000_000, 10_000_000, 100_000_000, 100_000_000, 0, 100),
        ROOT,
    );
    f.next_tx!(ROOT, |f| {
        let vault_id = f.vault_id;
        f.treasury.credit(&f.version, vault_id, balance::create_for_testing<SUI>(30));
        f.withdraw_quote(10);
        f.treasury.set_payout(&blast_acl::witness_for_testing<TreasuryAdmin>(), &f.version, PAYOUT);
        let changed = sui::event::events_by_type<protocol_treasury::BlastTreasuryDestinationChanged>();
        assert_eq!(changed.length(), 1);
        let mut data = sui::bcs::new(std::bcs::to_bytes(&changed[0]));
        assert_eq!(data.peel_address(), object::id(&f.treasury).to_address());
        assert_eq!(data.peel_address(), ROOT);
        assert_eq!(data.peel_address(), PAYOUT);
        assert_eq!(data.into_remainder_bytes(), vector[]);
        f.withdraw_quote(20);
        assert_eq!(f.treasury.balance_for_testing<SUI>(), 0);
        let withdrawals = sui::event::events_by_type<protocol_treasury::BlastTreasuryWithdrawn<SUI>>();
        assert_eq!(withdrawals.length(), 2);
        let mut first = sui::bcs::new(std::bcs::to_bytes(&withdrawals[0]));
        assert_eq!(first.peel_address(), object::id(&f.treasury).to_address());
        assert_eq!(first.peel_u64(), 10);
        assert_eq!(first.peel_address(), ROOT);
        assert_eq!(first.into_remainder_bytes(), vector[]);
        let mut second = sui::bcs::new(std::bcs::to_bytes(&withdrawals[1]));
        assert_eq!(second.peel_address(), object::id(&f.treasury).to_address());
        assert_eq!(second.peel_u64(), 20);
        assert_eq!(second.peel_address(), PAYOUT);
        assert_eq!(second.into_remainder_bytes(), vector[]);
    });
    f.next_tx!(ROOT, |f| {
        let earned = f.take_sender<sui::coin::Coin<SUI>>();
        assert_eq!(earned.value(), 10);
        earned.burn_for_testing();
    });
    f.next_tx!(PAYOUT, |f| {
        let earned = f.take_sender<sui::coin::Coin<SUI>>();
        assert_eq!(earned.value(), 20);
        earned.burn_for_testing();
    });
    f.end();
}

#[test]
#[expected_failure(
    abort_code = protocol_treasury::EZeroDestination,
    location = blast_market_maker::protocol_treasury,
)]
fun treasury_payout_rejects_zero_address() {
    let mut f = start(20_000_000);
    f.next_tx!(ROOT, |f| {
        f.treasury.set_payout(&blast_acl::witness_for_testing<TreasuryAdmin>(), &f.version, @0x0);
    });
    f.end();
}

#[test]
#[expected_failure(
    abort_code = protocol_treasury::EDestinationUnchanged,
    location = blast_market_maker::protocol_treasury,
)]
fun treasury_payout_rejects_unchanged_address() {
    let mut f = start(20_000_000);
    f.next_tx!(ROOT, |f| {
        f.treasury.set_payout(&blast_acl::witness_for_testing<TreasuryAdmin>(), &f.version, PAYOUT);
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = protocol_treasury::EInsufficientTreasuryBalance,
        location = blast_market_maker::protocol_treasury,
    ),
]
fun treasury_cannot_withdraw_market_maker_principal() {
    let mut f = start(20_000_000);
    let _ = f.contribute(ALICE, 20_000_000);
    f.next_tx!(ROOT, |f| {
        f.withdraw_quote(1);
    });
    f.end();
}

#[test]
fun creator_can_rotate_operator_and_retire_stale_cap() {
    let mut f = start(20_000_000);
    f.next_tx!(ROOT, |f| {
        let mut vault = f.take_vault();
        let creator = f.take_sender<BlastMarketMakerCreatorCap>();
        let operator = f.take_sender<BlastMarketMakerOperatorCap>();
        vault.rotate_and_transfer_operator_cap(&creator, &f.version, BOB, f.ctx!());
        vault.destroy_stale_operator_cap(operator);
        f.return_sender(creator);
        vault.return_vault();
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::ENotStaleCap,
        location = blast_market_maker::market_maker,
    ),
]
fun current_operator_cap_cannot_be_destroyed_as_stale() {
    let mut f = start(20_000_000);
    f.next_tx!(ROOT, |f| {
        let vault = f.take_vault();
        let operator = f.take_sender<BlastMarketMakerOperatorCap>();
        vault.destroy_stale_operator_cap(operator);
        vault.return_vault();
    });
    f.end();
}

#[test]
fun capacity_guards_admit_last_slot_and_existing_backer_topup() {
    market_maker::assert_backer_slot_for_testing(false, 9_999);
    market_maker::assert_backer_slot_for_testing(true, 10_000);
    cetus_engine::assert_position_slot_for_testing(7);
    cetus_migrator::assert_funding_window_for_testing(100, 604_800_100);
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EBackerCapacity,
        location = blast_market_maker::market_maker,
    ),
]
fun first_new_backer_above_capacity_is_rejected() {
    market_maker::assert_backer_slot_for_testing(false, 10_000);
}

#[test]
#[
    expected_failure(
        abort_code = cetus_engine::EPositionCapacity,
        location = blast_market_maker::cetus_engine,
    ),
]
fun ninth_managed_position_is_rejected() { cetus_engine::assert_position_slot_for_testing(8); }

#[test]
#[
    expected_failure(
        abort_code = cetus_migrator::EInvalidTerms,
        location = blast_market_maker::cetus_migrator,
    ),
]
fun funding_window_rejects_first_millisecond_above_seven_days() {
    cetus_migrator::assert_funding_window_for_testing(100, 604_800_101);
}

#[test]
#[
    expected_failure(
        abort_code = cetus_migrator::EInvalidTerms,
        location = blast_market_maker::cetus_migrator,
    ),
]
fun funding_window_rejects_present_deadline() { cetus_migrator::assert_funding_window_for_testing(100, 100); }

#[test]
fun reusable_creator_cap_controls_two_vaults_after_native_transfer() {
    let mut f = start(20_000_000);
    let second_id;
    {
        let creator = f.take_sender<BlastMarketMakerCreatorCap>();
        let Fixture { scenario, version, policy, treasury, .. } = &mut f;
        let mut second = market_maker::new_and_transfer_operator_cap<MEME, SUI>(
            market_maker::curve_route(),
            20_000_000,
            DEADLINE,
            ROOT,
            &creator,
            x"d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
            version,
            policy,
            treasury,
            scenario.ctx(),
        );
        second.set_trading_limits(market_maker::new_trading_limits(1, 1, 100, 100, 0, 10));
        second_id = object::id(&second);
        second.share();
        sui::transfer::public_transfer(creator, BOB);
    };
    f.next_tx!(
        ROOT,
        |f| { assert!(!f.scenario.has_most_recent_for_sender<BlastMarketMakerCreatorCap>()); },
    );
    f.next_tx!(BOB, |f| {
        let creator = f.take_sender<BlastMarketMakerCreatorCap>();
        let mut first = f.take_vault();
        let mut second = f.scenario.take_shared_by_id<BlastMarketMakerVault<MEME, SUI>>(second_id);
        assert_eq!(first.creator_cap_id_for_testing(), second.creator_cap_id_for_testing());
        first.set_paused(&creator, &f.version, true);
        second.set_paused(&creator, &f.version, true);
        assert_eq!(sui::event::events_by_type<market_maker::BlastPauseChanged>().length(), 2);
        f.return_sender(creator);
        first.return_vault();
        second.return_vault();
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongCreator,
        location = blast_market_maker::market_maker,
    ),
]
fun newly_minted_unbound_creator_cap_cannot_control_vault() {
    let mut f = start(20_000_000);
    let mut vault = f.take_vault();
    let foreign = market_maker::new_creator_cap(f.ctx!());
    vault.set_paused(&foreign, &f.version, true);
    destroy(foreign);
    vault.return_vault();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongPhase,
        location = blast_market_maker::market_maker,
    ),
]
fun creator_cannot_allocate_before_backer_weights_freeze() {
    let mut f = start(20_000_000);
    let mut vault = f.take_vault();
    let creator = f.take_sender<BlastMarketMakerCreatorCap>();
    {
        let (kept_meme, kept_quote) = vault.allocate_fees(
            &creator,
            &f.version,
            fee_ledger::new_allocation(0, 1, 0),
            fee_ledger::new_allocation(0, 0, 0),
            f.ctx!(),
        );
        kept_meme.burn_for_testing();
        kept_quote.burn_for_testing();
    };
    f.return_sender(creator);
    vault.return_vault();
    f.end();
}

#[test]
fun presale_sharing_needs_no_wrapper_backers() {
    let mut f = start_route(
        1_000,
        market_maker::presale_route(),
        market_maker::new_trading_limits(1, 1, 100, 100, 0, 10),
    );
    let mut vault = f.take_vault();
    vault.activate_pool(object::id_from_address(@0xFACE));
    vault.credit_curve_fees(balance::zero(), balance::create_for_testing<SUI>(10));
    let creator = f.take_sender<BlastMarketMakerCreatorCap>();
    {
        let (kept_meme, kept_quote) = vault.allocate_fees(
            &creator,
            &f.version,
            fee_ledger::new_allocation(0, 0, 0),
            fee_ledger::new_allocation(0, 10, 0),
            f.ctx!(),
        );
        kept_meme.burn_for_testing();
        kept_quote.burn_for_testing();
    };
    let (m, q, rm, rq) = vault.fee_balances();
    assert!(m == 0 && q == 0 && rm == 0 && rq == 10);
    f.return_sender(creator);
    vault.return_vault();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = fee_ledger::EInsufficientFees,
        location = blast_market_maker::fee_ledger,
    ),
]
fun fee_allocation_cannot_disguise_principal_as_received_fees() {
    let mut f = start(20_000_000);
    let _ = f.contribute(ALICE, 20_000_000);
    f.activate_curve();
    f.scenario.next_tx(ROOT);
    let mut vault = f.take_vault();
    let creator = f.take_sender<BlastMarketMakerCreatorCap>();
    {
        let (kept_meme, kept_quote) = vault.allocate_fees(
            &creator,
            &f.version,
            fee_ledger::new_allocation(0, 0, 0),
            fee_ledger::new_allocation(1, 0, 0),
            f.ctx!(),
        );
        kept_meme.burn_for_testing();
        kept_quote.burn_for_testing();
    };
    f.return_sender(creator);
    vault.return_vault();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = fee_ledger::EInsufficientFees,
        location = blast_market_maker::fee_ledger,
    ),
]
fun creator_cannot_reallocate_reserved_backer_fees() {
    let mut f = funded_fee_fixture();
    let mut vault = f.take_vault();
    let creator = f.take_sender<BlastMarketMakerCreatorCap>();
    {
        let (kept_meme, kept_quote) = vault.allocate_fees(
            &creator,
            &f.version,
            fee_ledger::new_allocation(0, 100, 0),
            fee_ledger::new_allocation(0, 200, 0),
            f.ctx!(),
        );
        kept_meme.burn_for_testing();
        kept_quote.burn_for_testing();
    };
    {
        let (kept_meme, kept_quote) = vault.allocate_fees(
            &creator,
            &f.version,
            fee_ledger::new_allocation(1, 0, 0),
            fee_ledger::new_allocation(0, 0, 0),
            f.ctx!(),
        );
        kept_meme.burn_for_testing();
        kept_quote.burn_for_testing();
    };
    f.return_sender(creator);
    vault.return_vault();
    f.end();
}

#[test]
fun creator_rebinding_preserves_both_asset_claims_and_reinvests_only_available_fees() {
    let mut f = funded_fee_fixture();
    f.next_tx!(ROOT, |f| {
        let mut vault = f.take_vault();
        let creator = f.take_sender<BlastMarketMakerCreatorCap>();
        {
            let (kept_meme, kept_quote) = vault.allocate_fees(
                &creator,
                &f.version,
                fee_ledger::new_allocation(10, 40, 20),
                fee_ledger::new_allocation(20, 80, 40),
                f.ctx!(),
            );
            kept_meme.burn_for_testing();
            kept_quote.burn_for_testing();
        };
        let successor = market_maker::new_creator_cap(f.ctx!());
        vault.set_creator_cap(&creator, &f.version, &successor);
        {
            let (kept_meme, kept_quote) = vault.allocate_fees(
                &successor,
                &f.version,
                fee_ledger::new_allocation(30, 0, 0),
                fee_ledger::new_allocation(0, 0, 60),
                f.ctx!(),
            );
            kept_meme.burn_for_testing();
            kept_quote.burn_for_testing();
        };
        let (m, q, rm, rq) = vault.fee_balances();
        assert!(m == 0 && q == 0 && rm == 40 && rq == 80);
        let (cm, cq) = vault.capital_for_testing();
        assert!(cm == 20 && cq == 100);
        let (am, aq) = vault.claimable_fees(ALICE);
        let (bm, bq) = vault.claimable_fees(BOB);
        assert!(am == 10 && aq == 20 && bm == 30 && bq == 60);
        sui::transfer::public_transfer(successor, BOB);
        f.return_sender(creator);
        vault.return_vault();
    });
    f.next_tx!(ALICE, |f| {
        let mut vault = f.take_vault();
        let (m, q) = vault.claim_fees(&f.version, f.ctx!());
        assert!(m.value() == 10 && q.value() == 20);
        {
            let (kept_meme, kept_quote) = (m, q);
            kept_meme.burn_for_testing();
            kept_quote.burn_for_testing();
        };
        {
            let (kept_meme, kept_quote) = vault.claim_fees(&f.version, f.ctx!());
            kept_meme.burn_for_testing();
            kept_quote.burn_for_testing();
        };
        vault.return_vault();
    });
    f.next_tx!(BOB, |f| {
        let mut vault = f.take_vault();
        let (m, q) = vault.claim_fees(&f.version, f.ctx!());
        assert!(m.value() == 30 && q.value() == 60);
        {
            let (kept_meme, kept_quote) = (m, q);
            kept_meme.burn_for_testing();
            kept_quote.burn_for_testing();
        };
        let (m, q, rm, rq) = vault.fee_balances();
        assert!(m == 0 && q == 0 && rm == 0 && rq == 0);
        vault.return_vault();
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongCreator,
        location = blast_market_maker::market_maker,
    ),
]
fun creator_rebind_revokes_old_cap_for_that_vault() {
    let mut f = start(20_000_000);
    let mut vault = f.take_vault();
    let creator = f.take_sender<BlastMarketMakerCreatorCap>();
    let successor = market_maker::new_creator_cap(f.ctx!());
    vault.set_creator_cap(&creator, &f.version, &successor);
    vault.set_paused(&creator, &f.version, true);
    destroy(successor);
    f.return_sender(creator);
    vault.return_vault();
    f.end();
}

#[test]
fun creator_can_return_all_idle_capital_while_preserving_user_claims_and_unallocated_fees() {
    let mut f = funded_fee_fixture();
    f.next_tx!(ROOT, |f| {
        let mut vault = f.take_vault();
        let creator = f.take_sender<BlastMarketMakerCreatorCap>();
        let creator_id = object::id(&creator);
        let (m, q) = vault.allocate_fees(
            &creator,
            &f.version,
            fee_ledger::new_allocation(0, 40, 0),
            fee_ledger::new_allocation(0, 80, 0),
            f.ctx!(),
        );
        m.burn_for_testing();
        q.burn_for_testing();
        let meme = coin::mint_for_testing<MEME>(700, f.ctx!());
        let quote = coin::mint_for_testing<SUI>(900, f.ctx!());
        vault.deposit_capital(&f.version, meme, quote);
        vault.set_paused(&creator, &f.version, true);
        let (m, q) = vault.withdraw_capital(&creator, &f.version, 700, 900, f.ctx!());
        assert!(m.value() == 700 && q.value() == 900);
        transfer::public_transfer(m, ALICE);
        transfer::public_transfer(q, BOB);
        let (cm, cq) = vault.capital_for_testing();
        assert!(cm == 0 && cq == 0);
        let (am, aq, rm, rq) = vault.fee_balances();
        assert!(am == 60 && aq == 120 && rm == 40 && rq == 80);
        let (am, aq) = vault.claimable_fees(ALICE);
        assert!(am == 10 && aq == 20);
        let (bm, bq) = vault.claimable_fees(BOB);
        assert!(bm == 30 && bq == 60);
        let deposits = sui::event::events_by_type<market_maker::BlastCapitalDeposited<MEME, SUI>>();
        let withdrawals = sui::event::events_by_type<
            market_maker::BlastCapitalWithdrawn<MEME, SUI>,
        >();
        assert_eq!(deposits.length(), 1);
        assert_eq!(withdrawals.length(), 1);
        assert_eq!(
            std::bcs::to_bytes(&deposits[0]),
            std::bcs::to_bytes(
                &CapitalDepositPayload {
                    vault_id: f.vault_id,
                    meme_amount: 700,
                    quote_amount: 900,
                },
            ),
        );
        assert_eq!(
            std::bcs::to_bytes(&withdrawals[0]),
            std::bcs::to_bytes(
                &CapitalWithdrawalPayload {
                    vault_id: f.vault_id,
                    creator_cap_id: creator_id,
                    meme_amount: 700,
                    quote_amount: 900,
                },
            ),
        );
        f.return_sender(creator);
        vault.return_vault();
    });
    f.next_tx!(ALICE, |f| {
        let returned = f.take_sender<coin::Coin<MEME>>();
        assert_eq!(returned.value(), 700);
        returned.burn_for_testing();
        let mut vault = f.take_vault();
        let (m, q) = vault.claim_fees(&f.version, f.ctx!());
        assert!(m.value() == 10 && q.value() == 20);
        m.burn_for_testing();
        q.burn_for_testing();
        vault.return_vault();
    });
    f.next_tx!(BOB, |f| {
        let returned = f.take_sender<coin::Coin<SUI>>();
        assert_eq!(returned.value(), 900);
        returned.burn_for_testing();
        let mut vault = f.take_vault();
        let (m, q) = vault.claim_fees(&f.version, f.ctx!());
        assert!(m.value() == 30 && q.value() == 60);
        m.burn_for_testing();
        q.burn_for_testing();
        let (am, aq, rm, rq) = vault.fee_balances();
        assert!(am == 60 && aq == 120 && rm == 0 && rq == 0);
        vault.return_vault();
    });
    f.end();
}

#[test]
fun creator_capital_distribution_can_override_delegated_idle_floor_after_curve_launch() {
    let mut f = start_with_limits(
        20_000_000,
        market_maker::new_trading_limits(1, 1, 100, 100, 10, 1),
    );
    let _ = f.contribute(ALICE, 20_000_000);
    f.activate_curve();
    f.next_tx!(ROOT, |f| {
        let mut vault = f.take_vault();
        let creator = f.take_sender<BlastMarketMakerCreatorCap>();
        let (m, q) = vault.withdraw_capital(&creator, &f.version, 0, 19_000_000, f.ctx!());
        assert!(m.value() == 0 && q.value() == 19_000_000);
        m.burn_for_testing();
        q.burn_for_testing();
        let (cm, cq) = vault.capital_for_testing();
        assert!(cm == 0 && cq == 0);
        assert_eq!(vault.raise_fees_for_testing(), 1_000_000);
        f.return_sender(creator);
        vault.return_vault();
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongCreator,
        location = blast_market_maker::market_maker,
    ),
]
fun foreign_creator_cannot_withdraw_capital_even_when_vault_is_empty() {
    let mut f = funded_fee_fixture();
    let mut vault = f.take_vault();
    let foreign = market_maker::new_creator_cap(f.ctx!());
    let (m, q) = vault.withdraw_capital(&foreign, &f.version, 1, 0, f.ctx!());
    m.burn_for_testing();
    q.burn_for_testing();
    destroy(foreign);
    vault.return_vault();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongPhase,
        location = blast_market_maker::market_maker,
    ),
]
fun creator_cannot_withdraw_unlaunched_funding() {
    let mut f = start(20_000_000);
    let _ = f.contribute(ALICE, 20_000_000);
    f.next_tx!(ROOT, |f| {
        let mut vault = f.take_vault();
        let creator = f.take_sender<BlastMarketMakerCreatorCap>();
        let (m, q) = vault.withdraw_capital(&creator, &f.version, 0, 20_000_000, f.ctx!());
        m.burn_for_testing();
        q.burn_for_testing();
        f.return_sender(creator);
        vault.return_vault();
    });
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EInsufficientCapital,
        location = blast_market_maker::market_maker,
    ),
]
fun capital_withdrawal_cannot_spend_unallocated_fees_or_user_reserves() {
    let mut f = funded_fee_fixture();
    let mut vault = f.take_vault();
    let creator = f.take_sender<BlastMarketMakerCreatorCap>();
    let (m, q) = vault.allocate_fees(
        &creator,
        &f.version,
        fee_ledger::new_allocation(0, 40, 0),
        fee_ledger::new_allocation(0, 80, 0),
        f.ctx!(),
    );
    m.burn_for_testing();
    q.burn_for_testing();
    let (m, q) = vault.withdraw_capital(&creator, &f.version, 1, 0, f.ctx!());
    m.burn_for_testing();
    q.burn_for_testing();
    f.return_sender(creator);
    vault.return_vault();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = package_version::EVersionMismatch,
        location = blast_market_maker::package_version,
    ),
]
fun stale_version_rejects_withdrawal_before_foreign_cap_and_empty_amount() {
    let mut f = funded_fee_fixture();
    let mut vault = f.take_vault();
    let foreign = market_maker::new_creator_cap(f.ctx!());
    f.version.set_generation_for_testing(999);
    let (m, q) = vault.withdraw_capital(&foreign, &f.version, 0, 0, f.ctx!());
    m.burn_for_testing();
    q.burn_for_testing();
    destroy(foreign);
    vault.return_vault();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EEmptyCapitalMovement,
        location = blast_market_maker::market_maker,
    ),
]
fun capital_withdrawal_rejects_both_zero_amounts() {
    let mut f = funded_fee_fixture();
    let mut vault = f.take_vault();
    let creator = f.take_sender<BlastMarketMakerCreatorCap>();
    let (m, q) = vault.withdraw_capital(&creator, &f.version, 0, 0, f.ctx!());
    m.burn_for_testing();
    q.burn_for_testing();
    f.return_sender(creator);
    vault.return_vault();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EWrongPhase,
        location = blast_market_maker::market_maker,
    ),
]
fun capital_deposits_cannot_bypass_funding_weights() {
    let mut f = start(20_000_000);
    let mut vault = f.take_vault();
    let meme = coin::mint_for_testing<MEME>(1, f.ctx!());
    let quote = coin::zero<SUI>(f.ctx!());
    vault.deposit_capital(&f.version, meme, quote);
    vault.return_vault();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EInsufficientCapital,
        location = blast_market_maker::market_maker,
    ),
]
fun capital_withdrawal_checks_both_assets_before_splitting_either() {
    let mut f = funded_fee_fixture();
    let mut vault = f.take_vault();
    let creator = f.take_sender<BlastMarketMakerCreatorCap>();
    let meme = coin::mint_for_testing<MEME>(5, f.ctx!());
    let quote = coin::mint_for_testing<SUI>(7, f.ctx!());
    vault.deposit_capital(&f.version, meme, quote);
    let (m, q) = vault.withdraw_capital(&creator, &f.version, 5, 8, f.ctx!());
    m.burn_for_testing();
    q.burn_for_testing();
    f.return_sender(creator);
    vault.return_vault();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = market_maker::EEmptyCapitalMovement,
        location = blast_market_maker::market_maker,
    ),
]
fun capital_deposit_rejects_both_zero_coins() {
    let mut f = funded_fee_fixture();
    let mut vault = f.take_vault();
    let meme = coin::zero<MEME>(f.ctx!());
    let quote = coin::zero<SUI>(f.ctx!());
    vault.deposit_capital(&f.version, meme, quote);
    vault.return_vault();
    f.end();
}

#[test]
#[
    expected_failure(
        abort_code = package_version::EVersionMismatch,
        location = blast_market_maker::package_version,
    ),
]
fun stale_version_rejects_capital_deposit_before_phase_and_zero_amount() {
    let mut f = start(20_000_000);
    let mut vault = f.take_vault();
    let meme = coin::zero<MEME>(f.ctx!());
    let quote = coin::zero<SUI>(f.ctx!());
    f.version.set_generation_for_testing(999);
    vault.deposit_capital(&f.version, meme, quote);
    vault.return_vault();
    f.end();
}

// === Test Helpers ===

fun funded_fee_fixture(): Fixture {
    let mut f = start(67_108_864);
    assert_eq!(f.contribute(ALICE, 16_777_216), 0);
    assert_eq!(f.contribute(BOB, 50_331_648), 0);
    f.next_tx!(ROOT, |f| {
        let mut vault = f.take_vault();
        // This ledger fixture deliberately discards deployment principal, leaving only fees.
        vault.charge_raise_fee_and_enter_curve(&f.version, &f.clock).destroy_for_testing();
        vault.activate_pool(object::id_from_address(@0xFACE));
        vault.credit_curve_fees(
            balance::create_for_testing<MEME>(100),
            balance::create_for_testing<SUI>(200),
        );
        vault.return_vault();
    });
    f.next_tx!(ROOT, |_| {});
    f
}

macro fun fixture_next_tx($fixture: &mut Fixture, $sender: address, $body: |&mut Fixture|) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $body(fixture);
}

macro fun fixture_ctx($fixture: &mut Fixture): &mut TxContext {
    let fixture = $fixture;
    fixture.scenario.ctx()
}

fun take_sender<T: key>(f: &Fixture): T { f.scenario.take_from_sender<T>() }

fun return_sender<T: key>(f: &Fixture, value: T) { f.scenario.return_to_sender(value); }

fun withdraw_quote(f: &mut Fixture, amount: u64) {
    let Fixture { treasury, version, scenario, .. } = f;
    treasury.pay_earned<SUI>(
        &blast_acl::witness_for_testing<TreasuryAdmin>(),
        version,
        amount,
        scenario.ctx(),
    );
}

fun return_vault(vault: BlastMarketMakerVault<MEME, SUI>) { test_scenario::return_shared(vault); }

fun set_rates(f: &mut Fixture, meme: u64, quote: u64) {
    f.policy.set_rates(&blast_acl::witness_for_testing<FeeAdmin>(), &f.version, meme, quote);
}

fun start(target: u64): Fixture {
    start_with_limits(
        target,
        market_maker::new_trading_limits(10_000_000, 10_000_000, 100_000_000, 100_000_000, 0, 100),
    )
}

fun start_with_limits(target: u64, limits: market_maker::TradingLimits): Fixture {
    start_route(target, market_maker::curve_route(), limits)
}

fun start_route(
    target: u64,
    route: market_maker::Route,
    limits: market_maker::TradingLimits,
): Fixture {
    start_route_with_payout(target, route, limits, PAYOUT)
}

fun start_route_with_payout(
    target: u64,
    route: market_maker::Route,
    limits: market_maker::TradingLimits,
    payout: address,
): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let ctx = scenario.ctx();
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(100);
    let creator = market_maker::new_creator_cap(ctx);
    let mut treasury = protocol_treasury::new_for_testing(ctx);
    let policy = market_maker_fee_policy::new_for_testing(object::id(&treasury), ctx);
    let version = package_version::new_for_testing(object::id(&treasury), object::id(&policy), ctx);
    if (payout != ROOT)
        treasury.set_payout(&blast_acl::witness_for_testing<TreasuryAdmin>(), &version, payout);
    let mut vault = market_maker::new_and_transfer_operator_cap<MEME, SUI>(
        route,
        target,
        DEADLINE,
        ROOT,
        &creator,
        x"d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
        &version,
        &policy,
        &treasury,
        ctx,
    );
    vault.set_trading_limits(limits);
    let vault_id = object::id(&vault);
    vault.share();
    sui::transfer::public_transfer(creator, ROOT);
    scenario.next_tx(ROOT);
    Fixture { scenario, clock, version, treasury, policy, vault_id }
}

fun take_vault(f: &Fixture): BlastMarketMakerVault<MEME, SUI> {
    f.scenario.take_shared_by_id(f.vault_id)
}

fun contribute(f: &mut Fixture, sender: address, offered: u64): u64 {
    f.scenario.next_tx(sender);
    let mut vault = f.take_vault();
    let payment = coin::mint_for_testing<SUI>(offered, f.ctx!());
    let change = vault.contribute_and_return_change(&f.version, payment, &f.clock, f.ctx!());
    let returned = change.value();
    change.burn_for_testing();
    vault.return_vault();
    returned
}

/// Ledger transition only; actual launch construction remains a runtime integration gate.
fun activate_curve(f: &mut Fixture) {
    f.next_tx!(ROOT, |f| {
        let mut vault = f.take_vault();
        let funding = vault.charge_raise_fee_and_enter_curve(&f.version, &f.clock);
        vault.join_capital(balance::zero<MEME>(), funding);
        vault.bind_external(object::id_from_address(@0xCAFE));
        vault.return_vault();
    });
}

fun end(f: Fixture) {
    let Fixture { scenario, clock, version, treasury, policy, vault_id: _ } = f;
    clock.destroy_for_testing();
    destroy(version);
    destroy(treasury);
    destroy(policy);
    scenario.end();
}

// === Imports ===

use fun fixture_next_tx as Fixture.next_tx;
use fun fixture_ctx as Fixture.ctx;

use blast_market_maker::{
    market_maker::{
        Self,
        BlastMarketMakerVault,
        BlastMarketMakerOperatorCap,
        BlastMarketMakerCreatorCap,
    },
    market_maker_fee_policy::{Self, BlastMarketMakerFeePolicy},
    market_maker_math,
    cetus_engine,
    cetus_migrator,
    package_version::{Self, BlastMarketMakerVersion as PackageVersion},
    blast_market_maker_domain::{FeeAdmin, TreasuryAdmin},
    fee_ledger,
    protocol_treasury::{Self, BlastMarketMakerTreasury},
    risk,
};
use blast_admin::blast_acl;
use std::unit_test::{assert_eq, destroy};
use sui::{
    balance,
    clock::{Self, Clock},
    coin,
    sui::SUI,
    test_scenario::{Self, Scenario},
    tx_context,
};

use fun cetus_engine::retain_seed_residuals_for_testing as BlastMarketMakerVault.retain_seed_residuals_for_testing;
use fun return_vault as BlastMarketMakerVault.return_vault;
