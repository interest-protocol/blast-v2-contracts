// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Vault custody, protocol residual claims, and every LP-fee collection split under Blast's live
/// share and the fee split the vault holds from its launch, with the auto-LP balances an adapter
/// takes and keeps.
module blast_fun_migrators::vault_tests;

// === Constants ===

/// Publishes the policy, so it is the initial protocol destination.
const PROTOCOL: address = @0xB1A57;

const ADMIN: address = @0xAD;

const DESTINATION_A: address = @0xA;

const DESTINATION_B: address = @0xB;

const POOL: address = @0x9001;

const MAX_ADMINS: u64 = 16;

const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct VAULT_TESTS has drop {}

public struct QUOTE() has drop;

/// The test adapter's launch witness, which is also its vault venue marker.
public struct TestVenue() has drop;

public struct OtherVenue() has drop;

public struct TestPosition has key, store { id: UID }

/// One owned launch whose fee split and Meme type every prepared vault copies.
public struct VaultFixture {
    scenario: Scenario,
    authority: Authority<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    migrators_version: MigratorsVersion,
    policy: LpFeePolicy,
    launch: Launch<VAULT_TESTS, QUOTE>,
}

/// Independently encoded `VaultCreated` in ABI order.
public struct ExpectedVaultCreated has copy, drop {
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
    venue: TypeName,
    meme: TypeName,
    quote: TypeName,
    residual_meme: u64,
    residual_quote: u64,
    liquidity: u128,
    fee_split: FeeSplit,
}

/// Independently encoded `FeesCollected` in ABI order, also the decoded form of an emitted one.
public struct Collection has copy, drop {
    vault_id: ID,
    generation: u64,
    gross_meme: u64,
    gross_quote: u64,
    protocol_destination: address,
    protocol_meme: u64,
    protocol_quote: u64,
    creator_meme: u64,
    creator_quote: u64,
    auto_lp_meme: u64,
    auto_lp_quote: u64,
    rewards_meme: u64,
    rewards_quote: u64,
    recipient_meme: vector<u64>,
    recipient_quote: vector<u64>,
}

/// Independently encoded `AutoLpPositionOpened` in ABI order.
public struct ExpectedAutoLpPositionOpened has copy, drop {
    vault_id: ID,
    position_id: ID,
}

/// Independently encoded `AutoLiquidityAdded` in ABI order.
public struct ExpectedAutoLiquidityAdded has copy, drop {
    vault_id: ID,
    meme_amount: u64,
    quote_amount: u64,
    meme_pending: u64,
    quote_pending: u64,
}

// === Tests ===

// Custody

#[test]
fun attaching_announces_the_residuals_liquidity_and_launch_fee_split_at_generation_zero() {
    let mut f = start(mixed_split());

    f.scenario.next_tx(ADMIN);
    let vault = f.new_vault(3, 4);

    assert_eq!(vault.generation_for_testing(), 0);
    assert_eq!(vault.fee_split_for_testing(), f.launch.lp_fee_split());
    assert_eq!(vault.fee_split_for_testing(), mixed_split());
    assert_balances!(|| vault.creator_balances_for_testing(), 0, 0);
    assert_balances!(|| vault.auto_lp_balances_for_testing(), 0, 0);
    assert_balances!(|| vault.rewards_balances(), 0, 0);
    assert_eq!(vault.next_round(), 0);
    assert_eq!(vault.last_checkpoint(), option::none());
    let events = event::events_by_type<blast_events::VaultCreated>();
    assert_eq!(events.length(), 1);
    assert_eq!(
        bcs::to_bytes(&events[0]),
        bcs::to_bytes(
            &ExpectedVaultCreated {
                vault_id: object::id(&vault),
                pool_id: object::id_from_address(POOL),
                position_id: vault.position_id_for_testing<_, _, TestVenue>().destroy_some(),
                venue: type_name::with_original_ids<TestVenue>(),
                meme: type_name::with_original_ids<VAULT_TESTS>(),
                quote: type_name::with_original_ids<QUOTE>(),
                residual_meme: 3,
                residual_quote: 4,
                liquidity: 1,
                fee_split: mixed_split(),
            },
        ),
    );

    destroy(vault);
    f.end();
}

#[test]
fun prepared_vault_keeps_its_id_when_attached_and_shared() {
    let mut f = start(mixed_split());
    let vault = f.new_vault(0, 0);
    let vault_id = object::id(&vault);
    vault.share(&TestVenue());

    f.scenario.next_tx(ADMIN);
    let shared = f.scenario.take_shared<LpVault<VAULT_TESTS, QUOTE>>();
    assert_eq!(object::id(&shared), vault_id);
    assert_eq!(shared.pool_id(), object::id_from_address(POOL));
    test_scenario::return_shared(shared);

    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EWrongVenue, location = blast_fun_migrators::vault)]
fun sharing_under_another_venue_fails_closed() {
    let mut f = start(mixed_split());
    let vault = f.new_vault(0, 0);

    vault.share(&OtherVenue());

    f.end();
}

#[test]
fun borrow_returns_the_attached_position() {
    let mut f = start(mixed_split());
    let mut vault = f.new_vault(0, 0);
    let position_id = vault.position_id_for_testing<_, _, TestVenue>().destroy_some();

    let position = vault.position_mut<_, _, _, TestPosition>(&TestVenue());

    assert_eq!(object::id(position), position_id);
    assert_eq!(vault.position_id_for_testing<_, _, OtherVenue>(), option::none());
    destroy(vault);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::EWrongVenue, location = blast_fun_migrators::vault)]
fun wrong_venue_borrow_fails_closed() {
    let mut f = start(mixed_split());
    let mut vault = f.new_vault(0, 0);

    vault.position_mut<_, _, _, TestPosition>(&OtherVenue());

    destroy(vault);
    f.end();
}

// Auto-LP Position

#[test]
fun the_auto_lp_position_attaches_once_announced_and_apart_from_the_main_position() {
    let mut f = start(mixed_split());
    let mut vault = f.new_vault(0, 0);
    let main_id = vault.position_id_for_testing<_, _, TestVenue>().destroy_some();
    assert!(!vault.has_auto_lp_position(&TestVenue()));
    assert_eq!(vault.auto_lp_position_id_for_testing<_, _, TestVenue>(), option::none());

    f.scenario.next_tx(ADMIN);
    let position = TestPosition { id: object::new(f.scenario.ctx()) };
    let position_id = object::id(&position);
    vault.attach_auto_lp_position(&TestVenue(), position);

    let opened = event::events_by_type<blast_events::AutoLpPositionOpened>();
    assert_eq!(opened.length(), 1);
    assert_eq!(
        bcs::to_bytes(&opened[0]),
        bcs::to_bytes(&ExpectedAutoLpPositionOpened { vault_id: object::id(&vault), position_id }),
    );
    assert!(vault.has_auto_lp_position(&TestVenue()));
    assert_eq!(vault.auto_lp_position_id_for_testing<_, _, TestVenue>(), option::some(position_id));
    let position = vault.auto_lp_position<_, _, _, TestPosition>(&TestVenue());
    assert_eq!(object::id(position), position_id);
    assert_eq!(
        object::id(vault.auto_lp_position_mut<_, _, _, TestPosition>(&TestVenue())),
        position_id,
    );
    // The main slot is untouched, and another venue sees neither slot.
    assert!(main_id != position_id);
    assert_eq!(vault.position_id_for_testing<_, _, TestVenue>(), option::some(main_id));
    assert_eq!(object::id(vault.position<_, _, _, TestPosition>(&TestVenue())), main_id);
    assert!(!vault.has_auto_lp_position(&OtherVenue()));
    assert_eq!(vault.auto_lp_position_id_for_testing<_, _, OtherVenue>(), option::none());

    destroy(vault);
    f.end();
}

#[test]
fun a_vault_without_an_auto_lp_position_still_shares() {
    let mut f = start(mixed_split());
    let vault = f.new_vault(0, 0);
    let vault_id = object::id(&vault);

    vault.share(&TestVenue());

    f.scenario.next_tx(ADMIN);
    let shared = f.scenario.take_shared_by_id<LpVault<VAULT_TESTS, QUOTE>>(vault_id);
    assert_eq!(shared.auto_lp_position_id_for_testing<_, _, TestVenue>(), option::none());
    test_scenario::return_shared(shared);
    f.end();
}

#[test]
#[expected_failure(abort_code = dynamic_field::EFieldAlreadyExists, location = sui::dynamic_field)]
fun a_second_auto_lp_position_cannot_replace_the_first() {
    let mut f = start(mixed_split());
    let mut vault = f.new_vault(0, 0);
    let first = TestPosition { id: object::new(f.scenario.ctx()) };
    let second = TestPosition { id: object::new(f.scenario.ctx()) };
    vault.attach_auto_lp_position(&TestVenue(), first);

    vault.attach_auto_lp_position(&TestVenue(), second);

    destroy(vault);
    f.end();
}

#[test]
#[expected_failure(abort_code = dynamic_field::EFieldDoesNotExist, location = sui::dynamic_field)]
fun an_absent_auto_lp_position_cannot_be_borrowed() {
    let mut f = start(mixed_split());
    let mut vault = f.new_vault(0, 0);

    vault.auto_lp_position_mut<_, _, _, TestPosition>(&TestVenue());

    destroy(vault);
    f.end();
}

#[test]
#[expected_failure(abort_code = dynamic_field::EFieldDoesNotExist, location = sui::dynamic_field)]
fun an_auto_lp_position_is_sealed_to_its_venue() {
    let mut f = start(mixed_split());
    let mut vault = f.new_vault(0, 0);
    let position = TestPosition { id: object::new(f.scenario.ctx()) };
    vault.attach_auto_lp_position(&TestVenue(), position);

    vault.auto_lp_position<_, _, _, TestPosition>(&OtherVenue());

    destroy(vault);
    f.end();
}

// Protocol Residuals

#[test]
fun protocol_claim_pays_both_residuals_once_and_emits_the_exact_claim() {
    let mut f = start(mixed_split());
    let mut vault = f.new_vault(3, 4);

    f.scenario.next_tx(ADMIN);
    let admin = f.sign_in();
    let (meme, quote) = vault.claim_protocol_fees(&f.migrators_version, &admin, f.scenario.ctx());

    assert_eq!(meme.value(), 3);
    assert_eq!(quote.value(), 4);
    assert_eq!(vault.protocol_meme_residual_for_testing(), 0);
    assert_eq!(vault.protocol_quote_residual_for_testing(), 0);
    let events = event::events_by_type<blast_events::ProtocolFeesClaimed>();
    let mut expected = bcs::to_bytes(&object::id(&vault));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<VAULT_TESTS>()));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<QUOTE>()));
    let claimant = ADMIN;
    expected.append(bcs::to_bytes(&claimant));
    expected.append(bcs::to_bytes(&3u64));
    expected.append(bcs::to_bytes(&4u64));
    assert_eq!(events.length(), 1);
    assert_eq!(bcs::to_bytes(&events[0]), expected);

    destroy(meme);
    destroy(quote);
    destroy(vault);
    f.end();
}

#[test]
fun protocol_claim_pays_a_one_sided_residual() {
    let mut f = start(mixed_split());
    let mut vault = f.new_vault(5, 0);

    let admin = f.sign_in();
    let (meme, quote) = vault.claim_protocol_fees(&f.migrators_version, &admin, f.scenario.ctx());

    assert_eq!(meme.value(), 5);
    assert_eq!(quote.value(), 0);
    destroy(meme);
    destroy(quote);
    destroy(vault);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::ENothingClaimable, location = blast_fun_migrators::vault)]
fun protocol_claim_rejects_a_vault_without_residuals() {
    let mut f = start(mixed_split());
    let mut vault = f.new_vault(0, 0);

    let admin = f.sign_in();
    let (meme, quote) = vault.claim_protocol_fees(&f.migrators_version, &admin, f.scenario.ctx());

    destroy(meme);
    destroy(quote);
    destroy(vault);
    f.end();
}

#[test]
#[expected_failure(abort_code = vault::ENothingClaimable, location = blast_fun_migrators::vault)]
fun drained_residuals_cannot_be_claimed_again() {
    let mut f = start(mixed_split());
    let mut vault = f.new_vault(3, 4);
    let admin = f.sign_in();
    let (meme, quote) = vault.claim_protocol_fees(&f.migrators_version, &admin, f.scenario.ctx());
    destroy(meme);
    destroy(quote);

    let (meme, quote) = vault.claim_protocol_fees(&f.migrators_version, &admin, f.scenario.ctx());

    destroy(meme);
    destroy(quote);
    destroy(vault);
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun a_stale_generation_rejects_the_protocol_claim_before_the_residual_check() {
    let mut f = start(mixed_split());
    let mut vault = f.new_vault(0, 0);
    let admin = f.sign_in();
    f.migrators_version.set_for_testing(2);

    let (meme, quote) = vault.claim_protocol_fees(&f.migrators_version, &admin, f.scenario.ctx());

    destroy(meme);
    destroy(quote);
    destroy(vault);
    f.end();
}

// Fee Split

#[test]
fun split_rounds_blast_up_then_credits_every_balance_and_pays_every_recipient_exactly() {
    let mut f = start(mixed_split());
    f.set_defaults(1_000, 2_500);
    let mut vault = f.new_vault(0, 0);

    f.scenario.next_tx(ADMIN);
    f.split(&mut vault, 11, 7);

    // Blast takes ceil(11 * 10%) = 2 Meme and ceil(7 * 25%) = 2 Quote. The rest, 9 Meme and 5
    // Quote, splits 20/30/10 to creator, auto-LP, and rewards and 15/25 to A and B, with each
    // unit of dust going to the largest remainder, then to the earlier part.
    let events = event::events_by_type<blast_events::FeesCollected>();
    assert_eq!(events.length(), 1);
    assert_eq!(
        bcs::to_bytes(&events[0]),
        bcs::to_bytes(
            &Collection {
                vault_id: object::id(&vault),
                generation: 0,
                gross_meme: 11,
                gross_quote: 7,
                protocol_destination: PROTOCOL,
                protocol_meme: 2,
                protocol_quote: 2,
                creator_meme: 2,
                creator_quote: 1,
                auto_lp_meme: 3,
                auto_lp_quote: 2,
                rewards_meme: 1,
                rewards_quote: 0,
                recipient_meme: vector[1, 2],
                recipient_quote: vector[1, 1],
            },
        ),
    );
    assert_balances!(|| vault.creator_balances_for_testing(), 2, 1);
    assert_balances!(|| vault.auto_lp_balances_for_testing(), 3, 2);
    assert_balances!(|| vault.rewards_balances(), 1, 0);
    f.assert_received(PROTOCOL, 2, 2);
    f.assert_received(DESTINATION_A, 1, 1);
    f.assert_received(DESTINATION_B, 2, 1);

    destroy(vault);
    f.end();
}

#[test]
fun blast_share_is_the_coins_own_pair_or_the_defaults_read_at_each_collection() {
    let mut f = start(mixed_split());
    f.set_defaults(1_000, 2_500);
    let mut vault = f.new_vault(0, 0);

    f.scenario.next_tx(ADMIN);
    f.split(&mut vault, 100, 100);
    f.assert_protocol_amounts(10, 25);

    f.scenario.next_tx(ADMIN);
    f.administer!(|policy, version, admin| {
        policy.set_coin_shares<VAULT_TESTS>(version, admin, bps::new(10_000), bps::new(0));
    });
    f.split(&mut vault, 100, 100);
    f.assert_protocol_amounts(100, 0);

    // A default change does not reach a coin with its own pair.
    f.scenario.next_tx(ADMIN);
    f.set_defaults(5_000, 5_000);
    f.split(&mut vault, 100, 100);
    f.assert_protocol_amounts(100, 0);

    // Clearing the pair falls back to the defaults current now.
    f.scenario.next_tx(ADMIN);
    f.administer!(|policy, version, admin| {
        policy.clear_coin_shares<VAULT_TESTS>(version, admin);
    });
    f.split(&mut vault, 100, 100);
    f.assert_protocol_amounts(50, 50);

    // Without its own pair, the coin pays every default change from the next collection.
    f.scenario.next_tx(ADMIN);
    f.set_defaults(0, 10_000);
    f.split(&mut vault, 100, 100);
    f.assert_protocol_amounts(0, 100);

    destroy(vault);
    f.end();
}

#[test]
fun protocol_destination_is_read_live_at_each_collection() {
    let mut f = start(mixed_split());
    f.set_defaults(10_000, 10_000);
    let mut vault = f.new_vault(0, 0);

    f.scenario.next_tx(ADMIN);
    f.split(&mut vault, 3, 5);
    f.administer!(|policy, version, admin| {
        policy.set_protocol_destination(version, admin, @0xCAFE);
    });
    f.split(&mut vault, 7, 11);

    assert_eq!(collection(0).protocol_destination, PROTOCOL);
    assert_eq!(collection(1).protocol_destination, @0xCAFE);
    f.assert_received(PROTOCOL, 3, 5);
    f.assert_received(@0xCAFE, 7, 11);

    destroy(vault);
    f.end();
}

#[test]
fun zero_collection_is_eventless_and_one_sided_collections_pay_only_the_nonzero_asset() {
    let mut f = start(mixed_split());
    let mut vault = f.new_vault(0, 0);

    f.scenario.next_tx(ADMIN);
    f.split(&mut vault, 0, 0);
    assert_eq!(event::num_events(), 0);
    assert_balances!(|| vault.creator_balances_for_testing(), 0, 0);
    assert_balances!(|| vault.auto_lp_balances_for_testing(), 0, 0);
    assert_balances!(|| vault.rewards_balances(), 0, 0);
    f.split(&mut vault, 0, 9);

    let quote = collection(0);
    assert_eq!(quote.gross_meme, 0);
    assert_eq!(quote.gross_quote, 9);
    assert_eq!(quote.recipient_meme, vector[0, 0]);
    assert_eq!(quote.recipient_quote, vector[1, 2]);
    assert_balances!(|| vault.creator_balances_for_testing(), 0, 2);
    assert_balances!(|| vault.auto_lp_balances_for_testing(), 0, 3);
    assert_balances!(|| vault.rewards_balances(), 0, 1);
    f.assert_received(DESTINATION_A, 0, 1);
    f.assert_received(DESTINATION_B, 0, 2);
    f.assert_received(PROTOCOL, 0, 0);

    f.scenario.next_tx(ADMIN);
    f.split(&mut vault, 9, 0);
    let meme = collection(0);
    assert_eq!(meme.recipient_meme, vector[1, 2]);
    assert_eq!(meme.recipient_quote, vector[0, 0]);
    assert_balances!(|| vault.creator_balances_for_testing(), 2, 2);
    f.assert_received(DESTINATION_A, 1, 0);
    f.assert_received(DESTINATION_B, 2, 0);

    destroy(vault);
    f.end();
}

#[test]
fun full_blast_share_pays_only_the_protocol_destination() {
    let mut f = start(mixed_split());
    f.set_defaults(10_000, 10_000);
    let mut vault = f.new_vault(0, 0);

    f.scenario.next_tx(ADMIN);
    f.split(&mut vault, 17, 19);

    let paid = collection(0);
    assert_eq!(paid.protocol_meme, 17);
    assert_eq!(paid.protocol_quote, 19);
    assert_eq!(
        vector[paid.creator_meme, paid.auto_lp_meme, paid.rewards_meme],
        vector[0, 0, 0],
    );
    assert_eq!(
        vector[paid.creator_quote, paid.auto_lp_quote, paid.rewards_quote],
        vector[0, 0, 0],
    );
    assert_eq!(paid.recipient_meme, vector[0, 0]);
    assert_eq!(paid.recipient_quote, vector[0, 0]);
    assert_balances!(|| vault.creator_balances_for_testing(), 0, 0);
    assert_balances!(|| vault.auto_lp_balances_for_testing(), 0, 0);
    assert_balances!(|| vault.rewards_balances(), 0, 0);
    f.assert_received(PROTOCOL, 17, 19);
    f.assert_received(DESTINATION_A, 0, 0);
    f.assert_received(DESTINATION_B, 0, 0);

    destroy(vault);
    f.end();
}

#[test]
fun dense_small_totals_match_an_independent_oracle_at_a_partial_share() {
    dense_totals(1_000);
}

#[test]
fun dense_small_totals_match_an_independent_oracle_at_zero_share() {
    dense_totals(0);
}

#[test]
fun dense_small_totals_match_an_independent_oracle_at_the_minimum_share() {
    dense_totals(1);
}

#[test]
fun dense_small_totals_match_an_independent_oracle_at_the_maximum_partial_share() {
    dense_totals(9_999);
}

#[test]
fun dense_small_totals_match_an_independent_oracle_at_the_full_share() {
    dense_totals(10_000);
}

#[test]
fun u64_max_collection_uses_wide_products_and_conserves_every_unit() {
    let mut f = start(mixed_split());
    f.set_defaults(1_000, 9_999);
    let mut vault = f.new_vault(0, 0);
    let max = std::u64::max_value!();

    f.scenario.next_tx(ADMIN);
    f.split(&mut vault, max, max);

    let paid = collection(0);
    assert_eq!(paid.protocol_meme, 1_844_674_407_370_955_162);
    assert_eq!(paid.protocol_quote, 18_444_899_399_302_180_660);
    let project_meme = max - paid.protocol_meme;
    let project_quote = max - paid.protocol_quote;
    assert_eq!(
        paid.creator_meme + paid.auto_lp_meme + paid.rewards_meme
            + paid.recipient_meme[0] + paid.recipient_meme[1],
        project_meme,
    );
    assert_eq!(
        paid.creator_quote + paid.auto_lp_quote + paid.rewards_quote
            + paid.recipient_quote[0] + paid.recipient_quote[1],
        project_quote,
    );
    assert_balances!(|| vault.creator_balances_for_testing(), paid.creator_meme, paid.creator_quote);
    assert_balances!(|| vault.auto_lp_balances_for_testing(), paid.auto_lp_meme, paid.auto_lp_quote);
    assert_balances!(|| vault.rewards_balances(), paid.rewards_meme, paid.rewards_quote);
    f.assert_received(PROTOCOL, paid.protocol_meme, paid.protocol_quote);
    f.assert_received(DESTINATION_A, paid.recipient_meme[0], paid.recipient_quote[0]);
    f.assert_received(DESTINATION_B, paid.recipient_meme[1], paid.recipient_quote[1]);

    destroy(vault);
    f.end();
}

#[test]
fun sixteen_recipients_are_canonical_and_all_paid() {
    let mut recipients = vector[];
    16u64.do!(|i| recipients.push_back(route(sui::address::from_u256(16 - (i as u256)), 625)));
    let split = allocation::fee_split(bps::new(0), bps::new(0), bps::new(0), recipients);
    let mut f = start(split);
    let mut vault = f.new_vault(0, 0);

    f.scenario.next_tx(ADMIN);
    f.split(&mut vault, 17, 9);

    // Sorted by address, recipient 0x1 comes first and takes the single Meme dust unit; each of
    // the first nine takes one Quote unit.
    let paid = collection(0);
    let mut quote = vector::tabulate!(9, |_| 1);
    quote.append(vector::tabulate!(7, |_| 0));
    let mut meme = vector[2];
    meme.append(vector::tabulate!(15, |_| 1));
    assert_eq!(paid.recipient_meme, meme);
    assert_eq!(paid.recipient_quote, quote);
    assert_eq!(vector[paid.creator_meme, paid.auto_lp_meme, paid.rewards_meme], vector[0, 0, 0]);
    let recipients = *vault.fee_split_for_testing().recipients();
    16u64.do!(|i| {
        let destination = sui::address::from_u256((i as u256) + 1);
        assert_eq!(recipients[i].destination(), destination);
        f.assert_received(destination, meme[i], quote[i]);
    });

    destroy(vault);
    f.end();
}

// Auto-LP

#[test]
fun take_auto_lp_hands_over_every_waiting_unit_and_empties_the_balances() {
    let mut f = start(auto_lp_split());
    let mut vault = f.new_vault(0, 0);
    f.split(&mut vault, 5, 7);

    let (meme, quote) = vault.take_auto_lp();

    assert_eq!(meme.value(), 5);
    assert_eq!(quote.value(), 7);
    assert_balances!(|| vault.auto_lp_balances_for_testing(), 0, 0);
    destroy(meme);
    destroy(quote);
    destroy(vault);
    f.end();
}

#[test]
fun kept_residuals_wait_for_the_next_collection_and_only_an_addition_is_announced() {
    let mut f = start(auto_lp_split());
    let mut vault = f.new_vault(0, 0);
    f.split(&mut vault, 5, 7);

    f.scenario.next_tx(ADMIN);
    let (mut meme, quote) = vault.take_auto_lp();
    destroy(meme.split(4));
    vault.keep_auto_lp(4, 0, meme, quote);

    assert_balances!(|| vault.auto_lp_balances_for_testing(), 1, 7);
    let added = event::events_by_type<blast_events::AutoLiquidityAdded>();
    assert_eq!(added.length(), 1);
    assert_eq!(
        bcs::to_bytes(&added[0]),
        bcs::to_bytes(
            &ExpectedAutoLiquidityAdded {
                vault_id: object::id(&vault),
                meme_amount: 4,
                quote_amount: 0,
                meme_pending: 1,
                quote_pending: 7,
            },
        ),
    );

    // Nothing added: the balances return whole and no event is emitted.
    f.scenario.next_tx(ADMIN);
    let (meme, quote) = vault.take_auto_lp();
    vault.keep_auto_lp(0, 0, meme, quote);
    assert_balances!(|| vault.auto_lp_balances_for_testing(), 1, 7);
    assert_eq!(event::num_events(), 0);

    // The residual joins the next collection's auto-LP share.
    f.split(&mut vault, 2, 3);
    assert_balances!(|| vault.auto_lp_balances_for_testing(), 3, 10);

    destroy(vault);
    f.end();
}

// === Test Helpers ===

fun start(fee_split: FeeSplit): VaultFixture {
    let mut scenario = test_scenario::begin(PROTOCOL);
    let version = package_version::new_for_testing(scenario.ctx());
    let migrators_version = migrators_version::new_for_testing(scenario.ctx());
    let (root, mut authority) = acl::new_for_testing<BLAST_FUN_DOMAIN>(
        MAX_ADMINS,
        ROOT_TRANSFER_DELAY_MS,
        scenario.ctx(),
    );
    authority.grant_admin(&root, 0, ADMIN, scenario.ctx());
    destroy(root);
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());
    let mut config = launch_config::new_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    launch_fixture::admit<QUOTE, TestVenue>(&mut config, &version, &authority.sign_in(&admin_cap));
    let launch = launch_fixture::open_launch<_, QUOTE, _>(
        &mut scenario,
        test_utils::create_one_time_witness<VAULT_TESTS>(),
        &version,
        &config,
        TestVenue(),
        fee_split,
    );
    destroy(config);
    destroy(version);

    VaultFixture {
        scenario,
        authority,
        admin_cap,
        migrators_version,
        policy,
        launch,
    }
}

/// Prepares a vault from the fixture launch, then attaches a position.
fun new_vault(
    self: &mut VaultFixture,
    protocol_meme_residual: u64,
    protocol_quote_residual: u64,
): LpVault<VAULT_TESTS, QUOTE> {
    let mut vault = vault::prepare(
        &self.launch,
        balance::create_for_testing(protocol_meme_residual),
        balance::create_for_testing(protocol_quote_residual),
        self.scenario.ctx(),
    );
    let position = TestPosition { id: object::new(self.scenario.ctx()) };
    vault.attach(&TestVenue(), object::id_from_address(POOL), position, 1);

    vault
}

/// Splits totals 1 through 32 of both assets at `share` for both, comparing every part with an
/// independent largest-remainder oracle, and finally every balance and paid coin with the sums.
fun dense_totals(share: u64) {
    let mut f = start(mixed_split());
    if (share != 0) f.set_defaults(share, share);
    let mut vault = f.new_vault(0, 0);
    // Creator, auto-LP, rewards, then A and B in canonical address order.
    let weights = vector[2_000, 3_000, 1_000, 1_500, 2_500];
    let mut sums = vector[0, 0, 0, 0, 0, 0];

    32u64.do!(|i| {
        let total = i + 1;
        f.scenario.next_tx(ADMIN);
        f.split(&mut vault, total, total);

        let protocol = (((total as u128) * (share as u128) + 9_999) / 10_000) as u64;
        let parts = largest_remainder(weights, total - protocol);
        let paid = collection(0);
        assert_eq!(paid.protocol_meme, protocol);
        assert_eq!(paid.protocol_quote, protocol);
        let meme = vector[
            paid.creator_meme,
            paid.auto_lp_meme,
            paid.rewards_meme,
            paid.recipient_meme[0],
            paid.recipient_meme[1],
        ];
        let quote = vector[
            paid.creator_quote,
            paid.auto_lp_quote,
            paid.rewards_quote,
            paid.recipient_quote[0],
            paid.recipient_quote[1],
        ];
        assert_eq!(meme, parts);
        assert_eq!(quote, parts);
        *&mut sums[0] = sums[0] + protocol;
        5u64.do!(|part| *&mut sums[part + 1] = sums[part + 1] + parts[part]);
    });

    assert_balances!(|| vault.creator_balances_for_testing(), sums[1], sums[1]);
    assert_balances!(|| vault.auto_lp_balances_for_testing(), sums[2], sums[2]);
    assert_balances!(|| vault.rewards_balances(), sums[3], sums[3]);
    assert_eq!(f.received<VAULT_TESTS>(PROTOCOL), sums[0]);
    assert_eq!(f.received<QUOTE>(PROTOCOL), sums[0]);
    assert_eq!(f.received<VAULT_TESTS>(DESTINATION_A), sums[4]);
    assert_eq!(f.received<QUOTE>(DESTINATION_A), sums[4]);
    assert_eq!(f.received<VAULT_TESTS>(DESTINATION_B), sums[5]);
    assert_eq!(f.received<QUOTE>(DESTINATION_B), sums[5]);

    destroy(vault);
    f.end();
}

/// Floors every weighted part, then gives each remaining unit to the part with the largest
/// remaining fraction, earliest first, at most once per part.
fun largest_remainder(weights: vector<u64>, total: u64): vector<u64> {
    let mut parts = weights.map_ref!(|weight| total * *weight / 10_000);
    let mut fractions = weights.map_ref!(|weight| total * *weight % 10_000);
    let mut dust = total - parts.fold!(0, |sum, part| sum + part);
    while (dust > 0) {
        let mut largest = 0;
        fractions.length().do!(|i| if (fractions[i] > fractions[largest]) largest = i);
        *&mut parts[largest] = parts[largest] + 1;
        *&mut fractions[largest] = 0;
        dust = dust - 1;
    };

    parts
}

fun sign_in(self: &VaultFixture): AdminWitness<BLAST_FUN_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

/// Runs one policy administration under a fresh sign-in and the live migrators generation.
macro fun administer(
    $self: &mut VaultFixture,
    $fn: |&mut LpFeePolicy, &MigratorsVersion, &AdminWitness<BLAST_FUN_DOMAIN>|,
) {
    let self = $self;
    let admin = self.sign_in();

    $fn(&mut self.policy, &self.migrators_version, &admin);
}

fun set_defaults(self: &mut VaultFixture, meme_bps: u64, quote_bps: u64) {
    self.administer!(|policy, version, admin| {
        policy.set_default_shares(version, admin, bps::new(meme_bps), bps::new(quote_bps));
    });
}

/// Splits minted balances standing in for one collection of the position's fees.
fun split(
    self: &mut VaultFixture,
    vault: &mut LpVault<VAULT_TESTS, QUOTE>,
    meme: u64,
    quote: u64,
) {
    vault.split_fees(
        &self.policy,
        balance::create_for_testing(meme),
        balance::create_for_testing(quote),
        self.scenario.ctx(),
    );
}

/// Decodes the `index`th `FeesCollected` of this transaction, consuming every byte.
fun collection(index: u64): Collection {
    let events = event::events_by_type<blast_events::FeesCollected>();
    let mut r = bcs::new(bcs::to_bytes(&events[index]));
    let collection = Collection {
        vault_id: object::id_from_address(r.peel_address()),
        generation: r.peel_u64(),
        gross_meme: r.peel_u64(),
        gross_quote: r.peel_u64(),
        protocol_destination: r.peel_address(),
        protocol_meme: r.peel_u64(),
        protocol_quote: r.peel_u64(),
        creator_meme: r.peel_u64(),
        creator_quote: r.peel_u64(),
        auto_lp_meme: r.peel_u64(),
        auto_lp_quote: r.peel_u64(),
        rewards_meme: r.peel_u64(),
        rewards_quote: r.peel_u64(),
        recipient_meme: r.peel_vec_u64(),
        recipient_quote: r.peel_vec_u64(),
    };
    assert!(r.into_remainder_bytes().is_empty());

    collection
}

/// Asserts the Blast amounts of this transaction's only collection.
fun assert_protocol_amounts(self: &VaultFixture, meme: u64, quote: u64) {
    let events = event::events_by_type<blast_events::FeesCollected>();
    assert_eq!(events.length(), 1);
    let paid = collection(0);

    assert_eq!(paid.protocol_destination, self.policy.protocol_destination());
    assert_eq!(paid.protocol_meme, meme);
    assert_eq!(paid.protocol_quote, quote);
}

/// Asserts the Meme and Quote amounts `$balances` reads.
macro fun assert_balances($balances: || -> (u64, u64), $meme: u64, $quote: u64) {
    let (meme_balance, quote_balance) = $balances();

    assert_eq!(meme_balance, $meme);
    assert_eq!(quote_balance, $quote);
}

/// Asserts `owner` received exactly one coin per nonzero asset since its last check.
fun assert_received(self: &mut VaultFixture, owner: address, meme: u64, quote: u64) {
    self.scenario.next_tx(owner);
    if (meme > 0) {
        assert_eq!(self.scenario.take_from_sender<Coin<VAULT_TESTS>>().burn_for_testing(), meme);
    };
    if (quote > 0) {
        assert_eq!(self.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), quote);
    };
    assert!(!self.scenario.has_most_recent_for_sender<Coin<VAULT_TESTS>>());
    assert!(!self.scenario.has_most_recent_for_sender<Coin<QUOTE>>());
}

/// Burns and sums every `Coin<T>` `owner` holds.
fun received<T>(self: &mut VaultFixture, owner: address): u64 {
    self.scenario.next_tx(owner);
    test_scenario::ids_for_address<Coin<T>>(owner).fold!(0, |sum, id| {
        sum + self.scenario.take_from_address_by_id<Coin<T>>(owner, id).burn_for_testing()
    })
}

fun end(self: VaultFixture) {
    destroy(self);
}

fun route(destination: address, route_bps: u64): Route {
    allocation::route(destination, bps::new(route_bps))
}

/// Creator 20%, auto-LP 30%, rewards 10%, A 15%, and B 25%; recipients given out of order.
fun mixed_split(): FeeSplit {
    allocation::fee_split(
        bps::new(2_000),
        bps::new(3_000),
        bps::new(1_000),
        vector[route(DESTINATION_B, 2_500), route(DESTINATION_A, 1_500)],
    )
}

/// Everything after Blast's share goes back into the position.
fun auto_lp_split(): FeeSplit {
    allocation::fee_split(bps::new(0), bps::new(10_000), bps::new(0), vector[])
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap, AdminWitness};

use blast_fun::{
    allocation::{Self, FeeSplit, Route},
    blast_fun_domain::BLAST_FUN_DOMAIN,
    bps,
    launch::Launch,
    launch_config,
    package_version,
};

use blast_fun_migrators::{
    blast_events,
    launch_fixture,
    lp_fee_policy::{Self, LpFeePolicy},
    package_version::{Self as migrators_version, PackageVersion as MigratorsVersion},
    vault::{Self, LpVault},
};

use std::{type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::{
    balance,
    bcs,
    coin::Coin,
    dynamic_field,
    event,
    test_scenario::{Self, Scenario},
    test_utils,
};
