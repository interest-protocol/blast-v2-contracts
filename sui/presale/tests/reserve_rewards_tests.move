// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::reserve_rewards_tests;

// === Constants ===

const OWNER: address = @0xA;
const HOLDER: address = @0xB;
const TREASURY: address = @0xC;
const DEADLINE_AT_MS: u64 = 604_800_001;

// === Test-Only Types ===

public struct MEME has drop {}
public struct QUOTE has drop {}
public struct ReserveFixture {
    scenario: Scenario,
    vault: Vault<MEME, QUOTE>,
    policy: FeePolicy,
    clock: Clock,
}

// === Tests ===

#[test]
#[expected_failure(
    abort_code = rewards::ETreasuryChanged,
    location = blast_presale::holder_rewards,
)]
fun a_policy_change_after_planning_blocks_publication_with_gas_reimbursement() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.next_tx!(OWNER, |f| {
        f
            .policy
            .set_destination(
                &package_version,
                &blast_acl::witness_for_testing<TreasuryAdmin>(),
                @0xD,
            );
    });
    fixture.publish(30);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = rewards::ETreasuryChanged,
    location = blast_presale::holder_rewards,
)]
fun a_policy_change_after_planning_blocks_publication_without_gas_reimbursement() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.next_tx!(OWNER, |f| {
        f
            .policy
            .set_destination(
                &package_version,
                &blast_acl::witness_for_testing<TreasuryAdmin>(),
                @0xD,
            );
    });
    fixture.publish_budget(1_000, 0);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
#[expected_failure(
    abort_code = rewards::ETreasuryChanged,
    location = blast_presale::holder_rewards,
)]
fun a_changed_treasury_is_rejected_before_an_overcommitted_budget() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.next_tx!(OWNER, |f| {
        f
            .policy
            .set_destination(
                &package_version,
                &blast_acl::witness_for_testing<TreasuryAdmin>(),
                @0xD,
            );
    });
    fixture.publish(31);
    std::unit_test::destroy(package_version);
    abort
}

#[test]
fun publication_accepts_a_new_plan_bound_to_the_changed_treasury() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.next_tx!(OWNER, |f| {
        f
            .policy
            .set_destination(
                &package_version,
                &blast_acl::witness_for_testing<TreasuryAdmin>(),
                @0xD,
            );
    });
    fixture.publish_budget_to(970, 30, @0xD);
    assert_eq!(fixture.vault_balances(), vector[0, 0]);
    fixture.next_tx!(HOLDER, |f| f.close());
    assert_eq!(fixture.vault_balances(), vector[0, 1_000]);
    fixture.end();

    std::unit_test::destroy(package_version);
}

#[test]
fun settlement_pays_measured_cost_returns_unused_reserve_and_preserves_holder_custody() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.publish(30);
    assert_eq!(fixture.vault_balances(), vector[0, 0]);
    fixture.next_tx!(OWNER, |f| {
        let mut round = f.take_round();
        let (meme, quote, reserve) = round.reserve_balances_for_testing();
        assert_eq!(vector[meme, quote], vector[0, 970]);
        assert_eq!(reserve, option::some(30));
        f
            .policy
            .set_destination(
                &package_version,
                &blast_acl::witness_for_testing<TreasuryAdmin>(),
                @0xD,
            );
        f.settle(&mut round, 24);
        assert_eq!(f.vault_balances(), vector[0, 6]);
        let (_, quote, reserve) = round.reserve_balances_for_testing();
        assert_eq!(quote, 970);
        assert_eq!(reserve, option::none());
        f.return_round(round);
    });
    fixture.next_tx!(TREASURY, |f| f.assert_payment(24));
    fixture.next_tx!(HOLDER, |f| f.claim());
    fixture.next_tx!(HOLDER, |f| f.assert_payment(970));
    fixture.next_tx!(OWNER, |f| f.close());
    assert_eq!(fixture.vault_balances(), vector[0, 6]);
    fixture.end();

    std::unit_test::destroy(package_version);
}

#[test]
fun close_returns_unsettled_reserve_and_unclaimed_holders_without_an_admin() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(30);
    fixture.next_tx!(HOLDER, |f| f.close());
    assert_eq!(fixture.vault_balances(), vector[0, 1_000]);
    fixture.end();
}

#[test]
fun zero_reserve_disables_reimbursement_and_allows_claim_and_close() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(0);
    fixture.next_tx!(HOLDER, |f| {
        let round = f.take_round();
        let (_, quote, reserve) = round.reserve_balances_for_testing();
        assert_eq!(quote, 970);
        assert_eq!(reserve, option::none());
        f.return_round(round);
    });
    fixture.next_tx!(HOLDER, |f| f.claim());
    fixture.next_tx!(HOLDER, |f| f.assert_payment(970));
    assert_eq!(fixture.vault_balances(), vector[0, 30]);
    fixture.next_tx!(HOLDER, |f| f.close());
    assert_eq!(fixture.vault_balances(), vector[0, 30]);
    fixture.end();
}

#[test]
fun blast_can_cover_gas_and_fund_the_entire_holder_quote_budget() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.publish_budget(1_000, 0);
    assert_eq!(fixture.vault_balances(), vector[0, 0]);
    fixture.next_tx!(HOLDER, |f| {
        let mut round = f.take_round();
        rewards::claim(&mut round, &package_version, 0, HOLDER, 0, 1_000, vector[], f.ctx!());
        let (_, quote, reserve) = round.reserve_balances_for_testing();
        assert_eq!(quote, 0);
        assert_eq!(reserve, option::none());
        f.return_round(round);
    });
    fixture.next_tx!(HOLDER, |f| f.assert_payment(1_000));
    fixture.next_tx!(HOLDER, |f| f.close());
    assert_eq!(fixture.vault_balances(), vector[0, 0]);
    fixture.end();

    std::unit_test::destroy(package_version);
}

#[test]
#[expected_failure(abort_code = rewards::EReserveSettled, location = blast_presale::holder_rewards)]
fun disabled_reimbursement_cannot_be_settled() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(0);
    fixture.next_tx!(OWNER, |f| {
        let mut round = f.take_round();
        f.settle(&mut round, 0);
        abort
    })
}

#[test]
#[expected_failure(abort_code = rewards::EOverReserve, location = blast_presale::holder_rewards)]
fun settlement_rejects_cost_above_the_reserve() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(30);
    fixture.next_tx!(OWNER, |f| {
        let mut round = f.take_round();
        f.settle(&mut round, 31);
        abort
    })
}

#[test]
#[expected_failure(abort_code = rewards::EReserveSettled, location = blast_presale::holder_rewards)]
fun duplicate_settlement_cannot_pay_twice() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(30);
    fixture.next_tx!(OWNER, |f| {
        let mut round = f.take_round();
        f.settle(&mut round, 24);
        f.settle(&mut round, 1);
        abort
    })
}

#[test]
#[expected_failure(
    abort_code = rewards::EInsufficientBudget,
    location = blast_presale::holder_rewards,
)]
fun publication_cannot_overcommit_holder_and_reserve_quote() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(31);
    abort
}

#[test]
#[expected_failure(
    abort_code = rewards::EClaimsStillOpen,
    location = blast_presale::holder_rewards,
)]
fun close_rejects_the_millisecond_before_the_deadline() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.publish(30);
    fixture.next_tx!(OWNER, |f| {
        let round = f.take_round();
        f.clock.set_for_testing(DEADLINE_AT_MS - 1);
        round.close_round(&package_version, &mut f.vault, &f.clock);
        abort
    })
}

#[test]
#[expected_failure(abort_code = rewards::EWrongVault, location = blast_presale::holder_rewards)]
fun settlement_rejects_another_vault_before_its_amount_check() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.publish(30);
    fixture.next_tx!(OWNER, |f| {
        let mut round = f.take_round();
        let mut other = vault::new_for_testing<MEME, QUOTE>(
            object::id_from_address(@0xCAFE),
            object::id_from_address(@0xCA9),
            presale::fee_split(vector[], bps::new(10_000)),
            fee_policy::protocol_fees_for_testing(0, 0, 0, 0),
            option::none(),
            f.ctx!(),
        );
        round.settle_gas_reserve(
            &package_version,
            &blast_acl::witness_for_testing<RewardsAdmin>(),
            &mut other,
            31,
            f.ctx!(),
        );
        abort
    })
}

#[test]
fun collection_routes_holder_meme_and_preserves_holder_quote() {
    let mut fixture = start_reserve_rewards();
    fixture.collect_holder_fees();
    assert_eq!(fixture.vault_balances(), vector[0, 1_010]);
    fixture.next_tx!(TREASURY, |f| f.assert_meme_payment(100));
    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EAdminRoleNotGranted,
    location = blast_admin::blast_acl,
)]
fun a_cap_without_rewards_authority_cannot_settle() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(30);
    fixture.settle_without_role();
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EAlreadyClaimed, location = blast_presale::holder_rewards)]
fun reserve_holder_leaf_cannot_pay_twice() {
    let mut fixture = start_reserve_rewards();
    fixture.publish(30);
    fixture.next_tx!(HOLDER, |f| f.claim());
    fixture.next_tx!(HOLDER, |f| f.claim());
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidProof, location = blast_presale::holder_rewards)]
fun reserve_holder_payment_cannot_be_redirected() {
    let mut fixture = start_reserve_rewards();
    let package_version = blast_presale::blast_presale_package::new_for_testing(fixture
        .scenario
        .ctx());
    fixture.publish(30);
    fixture.next_tx!(OWNER, |f| {
        let mut round = f.take_round();
        rewards::claim(&mut round, &package_version, 0, OWNER, 0, 970, vector[], f.ctx!());
        abort
    })
}

// === Test Helpers ===

fun start_reserve_rewards(): ReserveFixture {
    let mut scenario = test_scenario::begin(OWNER);
    let package_version = blast_presale::blast_presale_package::new_for_testing(scenario.ctx());
    let result = {
        let mut vault = vault::new_for_testing<MEME, QUOTE>(
            object::id_from_address(@0xCAFE),
            object::id_from_address(@0xCA9),
            presale::fee_split(vector[], bps::new(10_000)),
            fee_policy::protocol_fees_for_testing(0, 0, 0, 0),
            option::none(),
            scenario.ctx(),
        );
        let mut policy = fee_policy::new_for_testing(scenario.ctx());
        policy.set_destination(
            &package_version,
            &blast_acl::witness_for_testing<TreasuryAdmin>(),
            TREASURY,
        );
        vault.credit_fees_for_testing(
            &policy,
            balance::zero(),
            balance::create_for_testing<QUOTE>(1_000),
            scenario.ctx(),
        );
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(1);
        ReserveFixture { scenario, vault, policy, clock }
    };
    std::unit_test::destroy(package_version);
    result
}

macro fun reserve_next_tx(
    $self: &mut ReserveFixture,
    $sender: address,
    $body: |&mut ReserveFixture|,
) {
    let fixture = $self;
    fixture.scenario.next_tx($sender);
    $body(fixture)
}

macro fun reserve_ctx($self: &mut ReserveFixture): &mut TxContext {
    let fixture = $self;
    fixture.scenario.ctx()
}

fun publish(self: &mut ReserveFixture, reserve: u64) {
    self.publish_budget(970, reserve);
}

fun publish_budget(self: &mut ReserveFixture, holder_quote: u64, reserve: u64) {
    self.publish_budget_to(holder_quote, reserve, TREASURY);
}

fun publish_budget_to(
    self: &mut ReserveFixture,
    holder_quote: u64,
    reserve: u64,
    expected_treasury: address,
) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let root = rewards::leaf_for_testing(object::id(&self.vault), 0, 0, HOLDER, 0, holder_quote);
    self.vault.publish_round(
        &package_version,
        &blast_acl::witness_for_testing<RewardsAdmin>(),
        &self.policy,
        expected_treasury,
        0,
        0,
        10,
        root,
        hash::blake2b256(&b"manifest"),
        1,
        0,
        holder_quote,
        reserve,
        DEADLINE_AT_MS,
        &self.clock,
        self.scenario.ctx(),
    );
    let payload = only_event<RoundPublished<MEME, QUOTE>>();
    let round_id = payload.reserve_published_id();
    let (meme_unallocated, quote_unallocated) = self.vault.holder_rewards_balances();
    let deadline_at_ms = DEADLINE_AT_MS;
    let treasury = expected_treasury;
    let mut expected = vector[];
    expected.append(bcs::to_bytes(&(object::id(&self.vault))));
    expected.append(bcs::to_bytes(&(round_id)));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(10u64)));
    expected.append(bcs::to_bytes(&(deadline_at_ms)));
    expected.append(bcs::to_bytes(&(root)));
    expected.append(bcs::to_bytes(&(hash::blake2b256(&b"manifest"))));
    expected.append(bcs::to_bytes(&(1u64)));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(holder_quote)));
    expected.append(bcs::to_bytes(&(meme_unallocated)));
    expected.append(bcs::to_bytes(&(quote_unallocated)));
    expected.append(bcs::to_bytes(&(treasury)));
    expected.append(bcs::to_bytes(&(reserve)));
    assert_eq!(payload.reserve_published_bytes(), expected);

    std::unit_test::destroy(package_version);
}

fun take_round(self: &ReserveFixture): Round<MEME, QUOTE> {
    self.scenario.take_shared()
}

fun return_round(_self: &ReserveFixture, round: Round<MEME, QUOTE>) {
    test_scenario::return_shared(round);
}

fun settle(self: &mut ReserveFixture, round: &mut Round<MEME, QUOTE>, amount: u64) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let (_, _, reserve) = round.reserve_balances_for_testing();
    let reserve_amount = reserve.destroy_or!(0);
    round.settle_gas_reserve(
        &package_version,
        &blast_acl::witness_for_testing<RewardsAdmin>(),
        &mut self.vault,
        amount,
        self.scenario.ctx(),
    );
    let payload = only_event<GasReserveSettled<MEME, QUOTE>>();
    let (_, quote_unallocated) = self.vault.holder_rewards_balances();
    let treasury = TREASURY;
    let mut expected = vector[];
    expected.append(bcs::to_bytes(&(object::id(&self.vault))));
    expected.append(bcs::to_bytes(&(object::id(round))));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(treasury)));
    expected.append(bcs::to_bytes(&(amount)));
    expected.append(bcs::to_bytes(&(reserve_amount - amount)));
    expected.append(bcs::to_bytes(&(quote_unallocated)));
    assert_eq!(payload.reserve_settled_bytes(), expected);

    std::unit_test::destroy(package_version);
}

fun claim(self: &mut ReserveFixture) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let mut round = self.take_round();
    rewards::claim(&mut round, &package_version, 0, HOLDER, 0, 970, vector[], self.ctx!());
    let payload = only_event<RewardClaimed<MEME, QUOTE>>();
    let holder = HOLDER;
    let mut expected = vector[];
    expected.append(bcs::to_bytes(&(object::id(&round))));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(holder)));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(970u64)));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(0u64)));
    assert_eq!(payload.reserve_claimed_bytes(), expected);
    self.return_round(round);

    std::unit_test::destroy(package_version);
}

fun close(self: &mut ReserveFixture) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let round = self.take_round();
    self.clock.set_for_testing(DEADLINE_AT_MS);
    let round_id = object::id(&round);
    let (meme, quote, reserve) = round.reserve_balances_for_testing();
    round.close_round(&package_version, &mut self.vault, &self.clock);
    let payload = only_event<RoundClosed<MEME, QUOTE>>();
    let mut expected = vector[];
    expected.append(bcs::to_bytes(&(object::id(&self.vault))));
    expected.append(bcs::to_bytes(&(round_id)));
    expected.append(bcs::to_bytes(&(0u64)));
    expected.append(bcs::to_bytes(&(meme)));
    expected.append(bcs::to_bytes(&(quote)));
    expected.append(bcs::to_bytes(&(reserve.destroy_or!(0u64))));
    assert_eq!(payload.reserve_closed_bytes(), expected);

    std::unit_test::destroy(package_version);
}

fun assert_payment(self: &ReserveFixture, amount: u64) {
    assert_eq!(self.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), amount);
}

fun vault_balances(self: &ReserveFixture): vector<u64> {
    let (meme, quote) = self.vault.holder_rewards_balances();
    vector[meme, quote]
}

fun end(mut self: ReserveFixture) {
    let (_, remaining) = self.vault.holder_rewards_balances();
    let (meme, quote) = self.vault.fund_round(0, 0, remaining);
    meme.destroy_zero();
    quote.destroy_for_testing();
    let ReserveFixture { scenario, vault, policy, clock } = self;
    vault.destroy_for_testing();
    policy.destroy_for_testing();
    clock.destroy_for_testing();
    scenario.end();
}

fun collect_holder_fees(self: &mut ReserveFixture) {
    self.vault.credit_fees_for_testing(
        &self.policy, balance::create_for_testing<MEME>(100),
        balance::create_for_testing<QUOTE>(10), self.scenario.ctx(),
    );
    let payload = only_event<HolderMemePaid<MEME, QUOTE>>();
    let treasury = TREASURY;
    let mut expected = bcs::to_bytes(&object::id(&self.vault));
    expected.append(bcs::to_bytes(&treasury));
    expected.append(bcs::to_bytes(&100u64));
    expected.append(bcs::to_bytes(&0u64));
    assert_eq!(payload.holder_meme_paid_bytes(), expected);
}

fun assert_meme_payment(self: &ReserveFixture, amount: u64) {
    let mut total = 0;
    while (self.scenario.has_most_recent_for_sender<Coin<MEME>>()) {
        total = total + self.scenario.take_from_sender<Coin<MEME>>().burn_for_testing();
    };
    assert_eq!(total, amount);
}

fun settle_without_role(self: &mut ReserveFixture) {
    let package_version = blast_presale::blast_presale_package::new_for_testing(self
        .scenario
        .ctx());
    let (root, mut acl) = blast_acl::new_for_testing(self.ctx!());
    acl.grant_admin(&root, OWNER, self.ctx!());
    self.scenario.next_tx(OWNER);
    let cap = self.scenario.take_from_sender<AdminCap>();
    let witness = acl.sign_in<RewardsAdmin>(&cap);
    let mut round = self.take_round();
    round.settle_gas_reserve(
        &package_version,
        &witness,
        &mut self.vault,
        24,
        self.scenario.ctx(),
    );
    std::unit_test::destroy(package_version);
    abort
}

fun only_event<Event: copy + drop>(): Event {
    let events = event::events_by_type<Event>();
    assert_eq!(events.length(), 1);
    events[0]
}

// === Imports ===

use blast_admin::blast_acl::{Self, AdminCap};

use blast_presale::{
    blast_presale as presale,
    blast_presale_domain::{RewardsAdmin, TreasuryAdmin},
    bps,
    fee_policy::{Self, FeePolicy},
    holder_rewards::{
        Self as rewards,
        Round,
        RoundPublished,
        RewardClaimed,
        GasReserveSettled,
        RoundClosed,
    },
    presale_vault::{Self as vault, Vault, HolderMemePaid}
};

use std::{bcs, unit_test::assert_eq};

use sui::{balance, clock::{Self, Clock}, coin::Coin, event, hash, test_scenario::{Self, Scenario}};

use fun reserve_next_tx as ReserveFixture.next_tx;

use fun reserve_ctx as ReserveFixture.ctx;

use fun rewards::publish_round as Vault.publish_round;
