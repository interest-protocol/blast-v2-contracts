// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_presale::daily_rewards_tests;

// === Constants ===

const OWNER: address = @0xA;
const HOLDER: address = @0xB;
const CLAIM_WINDOW_MS: u64 = 604_800_000;

// === Test-Only Types ===

public struct MEME has drop {}
public struct QUOTE has drop {}
public struct DailyRewardsFixture {
    scenario: Scenario,
    vault: Vault<MEME, QUOTE>,
    clock: Clock,
}

// === Tests ===

#[test]
fun skipped_days_allow_a_new_daily_interval_with_an_independent_claim_window() {
    let mut fixture = start_daily_rewards();
    fixture.publish(0, 0, 10);
    assert_eq!(fixture.vault.next_round(), 1);
    fixture.next_tx!(OWNER, |f| {
        f.clock.set_for_testing(1_000_000 + CLAIM_WINDOW_MS);
        f.close();
    });
    assert_eq!(fixture.balances(), vector[0, 100]);
    fixture.publish(1, 21, 30);
    assert_eq!(fixture.vault.next_round(), 2);
    assert_eq!(fixture.vault.last_checkpoint(), option::some(30));
    fixture.next_tx!(HOLDER, |f| f.claim());
    fixture.next_tx!(HOLDER, |f| f.assert_payment());
    fixture.next_tx!(OWNER, |f| {
        f.clock.set_for_testing(1_000_000 + 2 * CLAIM_WINDOW_MS);
        f.close();
    });
    assert_eq!(fixture.balances(), vector[0, 90]);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidInterval, location = blast_presale::holder_rewards)]
fun a_daily_interval_cannot_be_empty() {
    let mut fixture = start_daily_rewards();
    fixture.publish(0, 10, 10);
    abort
}

#[test]
#[expected_failure(abort_code = rewards::EInvalidInterval, location = blast_presale::holder_rewards)]
fun a_daily_interval_cannot_be_reversed() {
    let mut fixture = start_daily_rewards();
    fixture.publish(0, 11, 10);
    abort
}

// === Test Helpers ===

fun start_daily_rewards(): DailyRewardsFixture {
    let mut scenario = test_scenario::begin(OWNER);
    let mut vault = vault::new_for_testing<MEME, QUOTE>(
        object::id_from_address(@0xCAFE),
        object::id_from_address(@0xCA9),
        presale::fee_split(vector[], bps::new(10_000)),
        fee_policy::protocol_fees_for_testing(0, 0, 0, 0),
        option::none(),
        scenario.ctx(),
    );
    let policy = fee_policy::new_for_testing(scenario.ctx());
    vault.credit_fees_for_testing(
        &policy, balance::zero(), balance::create_for_testing<QUOTE>(100), scenario.ctx(),
    );
    policy.destroy_for_testing();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000);
    DailyRewardsFixture { scenario, vault, clock }
}

macro fun daily_rewards_next_tx($self: &mut DailyRewardsFixture, $sender: address, $body: |&mut DailyRewardsFixture|) {
    let fixture = $self;
    fixture.scenario.next_tx($sender);
    $body(fixture);
}

macro fun daily_rewards_ctx($self: &mut DailyRewardsFixture): &mut TxContext {
    let fixture = $self;
    fixture.scenario.ctx()
}

fun publish(self: &mut DailyRewardsFixture, number: u64, start: u64, end: u64) {
    let root = rewards::leaf_for_testing(object::id(&self.vault), number, 0, HOLDER, 0, 10);
    rewards::publish_round(
        &mut self.vault, &blast_acl::witness_for_testing<RewardsAdmin>(), number, start, end,
        root, hash::blake2b256(&b"manifest"), 1, 0, 10,
        self.clock.timestamp_ms() + CLAIM_WINDOW_MS, &self.clock, self.scenario.ctx(),
    );
}

fun claim(self: &mut DailyRewardsFixture) {
    let mut round = self.scenario.take_shared<Round<MEME, QUOTE>>();
    rewards::claim(&mut round, 0, HOLDER, 0, 10, vector[], self.ctx!());
    test_scenario::return_shared(round);
}

fun assert_payment(self: &DailyRewardsFixture) {
    assert_eq!(self.scenario.take_from_sender<Coin<QUOTE>>().burn_for_testing(), 10);
}

fun close(self: &mut DailyRewardsFixture) {
    let round = self.scenario.take_shared<Round<MEME, QUOTE>>();
    rewards::close_round(round, &mut self.vault, &self.clock);
}

fun balances(self: &DailyRewardsFixture): vector<u64> {
    let (meme, quote) = self.vault.holder_rewards_balances();
    vector[meme, quote]
}

fun end(mut self: DailyRewardsFixture) {
    let (_, remaining) = self.vault.holder_rewards_balances();
    let (meme, quote) = self.vault.fund_round(0, 0, remaining);
    meme.destroy_zero();
    quote.destroy_for_testing();
    let DailyRewardsFixture { scenario, vault, clock } = self;
    vault.destroy_for_testing();
    clock.destroy_for_testing();
    scenario.end();
}

// === Imports ===

use blast_admin::blast_acl;
use blast_presale::{
    blast_presale as presale,
    blast_presale_domain::RewardsAdmin,
    bps,
    fee_policy,
    holder_rewards::{Self as rewards, Round},
    presale_vault::{Self as vault, Vault},
};
use std::unit_test::assert_eq;
use sui::{balance, clock::{Self, Clock}, coin::Coin, hash, test_scenario::{Self, Scenario}};

use fun daily_rewards_next_tx as DailyRewardsFixture.next_tx;
use fun daily_rewards_ctx as DailyRewardsFixture.ctx;
