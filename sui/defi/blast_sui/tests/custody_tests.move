// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_sui::custody_tests;

// === Constants ===

const USER: address = @0xA11CE;

const MIST_PER_SUI: u64 = 1_000_000_000;

// === Test-Only Types ===

/// Native system with two genesis validators for direct ledger operations.
public struct CustodyFixture {
    runner: TestRunner,
    system_state: Option<SuiSystemState>,
    pool_id: Option<ID>,
}

// === Tests ===

/// An overstated valuation cannot underpay: native under-delivery aborts.
#[test]
#[expected_failure(
    abort_code = errors::EInsufficientNativeRedemption,
    location = blast_sui::custody,
)]
fun withdraw_exact_fails_closed_when_native_output_lags_the_valuation() {
    let mut fixture = start();
    let mut ledger = option::none();

    fixture.next_tx!(USER, |f| {
        ledger.fill(f.new_staked_ledger(2 * MIST_PER_SUI));
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        let ledger = ledger.borrow_mut();
        let pool_id = f.pool();
        ledger.activate_pending(f.system!(), &pool_id, f.ctx!());
        // A fabricated doubled rate simulates a decreased pool exchange rate.
        ledger.revalue(&f.pool(), custody::new_rate(0, 2, 1));

        let rates = f.rates_at(2, 1);
        let sui_out = ledger.withdraw_exact(f.system!(), 3 * MIST_PER_SUI, &rates, f.ctx!());

        destroy(sui_out);
    });

    destroy(ledger);
    fixture.end();
}

/// The rounding margin pushes a withdrawal of the whole position past the held tokens, so the
/// entire native position redeems and nothing is left to value.
#[test]
fun withdraw_exact_redeems_the_whole_active_position_when_the_margin_exceeds_it() {
    let mut fixture = start();
    let mut ledger = option::none();

    fixture.next_tx!(USER, |f| {
        ledger.fill(f.new_staked_ledger(2 * MIST_PER_SUI));
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        let ledger = ledger.borrow_mut();
        let pool_id = f.pool();
        ledger.activate_pending(f.system!(), &pool_id, f.ctx!());
        assert_eq!(ledger.active_pool_tokens(&f.pool()), 2 * MIST_PER_SUI);

        let rates = f.rates_at(1, 1);
        let sui_out = ledger.withdraw_exact(f.system!(), 2 * MIST_PER_SUI, &rates, f.ctx!());

        assert_eq!(sui_out.value(), 2 * MIST_PER_SUI);
        assert_eq!(ledger.active_pool_tokens(&f.pool()), 0);
        assert_eq!(ledger.assets(), 0);
        destroy(sui_out);
    });

    destroy(ledger);
    fixture.end();
}

#[test]
fun transferring_every_active_token_moves_the_whole_native_position() {
    let mut fixture = start();
    let mut ledger = option::none();

    fixture.next_tx!(USER, |f| {
        ledger.fill(f.new_staked_ledger(2 * MIST_PER_SUI));
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        let source = ledger.borrow_mut();
        let pool_id = f.pool();
        source.activate_pending(f.system!(), &pool_id, f.ctx!());
        let held = source.active_pool_tokens(&f.pool());
        assert_eq!(held, 2 * MIST_PER_SUI);
        let mut destination = custody::new();
        destination.add_position(f.pool());

        let pool_id = f.pool();
        source.transfer_active_tokens(
            &mut destination,
            &pool_id,
            held,
            custody::new_rate(0, 1, 1),
            f.ctx!(),
        );

        assert_eq!(source.active_pool_tokens(&f.pool()), 0);
        assert_eq!(source.assets(), 0);
        assert_eq!(destination.active_pool_tokens(&f.pool()), held);
        assert_eq!(destination.assets(), held);
        destroy(destination);
    });

    destroy(ledger);
    fixture.end();
}

#[test]
fun stale_receipts_take_their_own_slots_until_the_ledger_cap_skips_delegation() {
    let mut fixture = start();
    let mut ledger = option::none();

    fixture.next_tx!(USER, |f| {
        ledger.fill(f.new_staked_ledger(2 * MIST_PER_SUI));
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        f.stake_more(ledger.borrow_mut(), 3 * MIST_PER_SUI);
        assert_eq!(f.pending(ledger.borrow()), 5 * MIST_PER_SUI);
        assert_eq!(ledger.borrow().liquid_sui(), 0);
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        f.stake_more(ledger.borrow_mut(), 4 * MIST_PER_SUI);
        assert_eq!(f.pending(ledger.borrow()), 9 * MIST_PER_SUI);
        assert_eq!(ledger.borrow().liquid_sui(), 0);
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        // Three stale receipts fill the ledger and the newest cannot join a
        // fourth activation epoch: delegation skips and the deposit stays
        // liquid, still counted at face value.
        f.stake_more(ledger.borrow_mut(), 5 * MIST_PER_SUI);
        assert_eq!(f.pending(ledger.borrow()), 9 * MIST_PER_SUI);
        assert_eq!(ledger.borrow().liquid_sui(), 5 * MIST_PER_SUI);
        assert_eq!(ledger.borrow().assets(), 14 * MIST_PER_SUI);
    });

    destroy(ledger);
    fixture.end();
}

#[test]
fun same_epoch_stake_joins_the_newest_receipt_even_at_the_ledger_cap() {
    let mut fixture = start();
    let mut ledger = option::none();

    fixture.next_tx!(USER, |f| {
        ledger.fill(f.new_staked_ledger(2 * MIST_PER_SUI));
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        f.stake_more(ledger.borrow_mut(), 3 * MIST_PER_SUI);
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        f.stake_more(ledger.borrow_mut(), 4 * MIST_PER_SUI);
        // The ledger is full, but the newest receipt shares this epoch's
        // activation, so a further same-epoch stake joins it instead of
        // skipping.
        f.stake_more(ledger.borrow_mut(), 5 * MIST_PER_SUI);
        assert_eq!(f.pending(ledger.borrow()), 14 * MIST_PER_SUI);
        assert_eq!(ledger.borrow().liquid_sui(), 0);
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        // A new activation epoch cannot join and finds no free slot: skip.
        f.stake_more(ledger.borrow_mut(), 6 * MIST_PER_SUI);
        assert_eq!(f.pending(ledger.borrow()), 14 * MIST_PER_SUI);
        assert_eq!(ledger.borrow().liquid_sui(), 6 * MIST_PER_SUI);
    });

    destroy(ledger);
    fixture.end();
}

#[test]
fun activate_pending_stops_at_the_first_unarrived_receipt() {
    let mut fixture = start();
    let mut ledger = option::none();

    fixture.next_tx!(USER, |f| {
        ledger.fill(f.new_staked_ledger(2 * MIST_PER_SUI));
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        let ledger = ledger.borrow_mut();
        f.stake_more(ledger, 3 * MIST_PER_SUI);

        let pool_id = f.pool();
        ledger.activate_pending(f.system!(), &pool_id, f.ctx!());

        // Only the arrived first receipt converts; the receipt activating
        // next epoch stays pending.
        assert_eq!(ledger.active_pool_tokens(&f.pool()), 2 * MIST_PER_SUI);
        assert_eq!(f.pending(ledger), 3 * MIST_PER_SUI);
    });

    destroy(ledger);
    fixture.end();
}

#[test]
fun unwind_realizes_every_pending_receipt() {
    let mut fixture = start();
    let mut ledger = option::none();

    fixture.next_tx!(USER, |f| {
        ledger.fill(f.new_staked_ledger(2 * MIST_PER_SUI));
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        let ledger = ledger.borrow_mut();
        f.stake_more(ledger, 3 * MIST_PER_SUI);

        ledger.unwind(f.system!(), f.ctx!());

        assert_eq!(f.pending(ledger), 0);
        assert_eq!(ledger.active_pool_tokens(&f.pool()), 0);
        assert!(ledger.liquid_sui() >= 5 * MIST_PER_SUI);
        assert_eq!(ledger.assets(), ledger.liquid_sui());
    });

    destroy(ledger);
    fixture.end();
}

#[test]
fun withdrawing_more_than_principal_is_funded_by_an_activated_receipts_rewards() {
    let mut fixture = start();
    let mut ledger = option::none();

    fixture.next_tx!(USER, |f| {
        ledger.fill(f.new_staked_ledger(2 * MIST_PER_SUI));
    });
    fixture.advance_epoch_with_rewards(130);
    fixture.advance_epoch_with_rewards(130);
    fixture.next_tx!(USER, |f| {
        let ledger = ledger.borrow_mut();

        // One MIST above principal forces the whole-receipt native
        // withdrawal, whose realized rewards over-deliver: the saturating
        // remainder stops at zero, the caller gets the exact amount, and the
        // excess stays liquid.
        let rates = f.rates_at(1, 1);
        let sui_out = ledger.withdraw_exact(f.system!(), 2 * MIST_PER_SUI + 1, &rates, f.ctx!());

        assert_eq!(sui_out.value(), 2 * MIST_PER_SUI + 1);
        assert_eq!(f.pending(ledger), 0);
        assert!(ledger.liquid_sui() > 0);
        destroy(sui_out);
    });

    destroy(ledger);
    fixture.end();
}

#[test]
fun activate_pending_converts_every_arrived_receipt() {
    let mut fixture = start();
    let mut ledger = option::none();

    fixture.next_tx!(USER, |f| {
        ledger.fill(f.new_staked_ledger(2 * MIST_PER_SUI));
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        f.stake_more(ledger.borrow_mut(), 3 * MIST_PER_SUI);
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        let ledger = ledger.borrow_mut();
        let pool_id = f.pool();
        ledger.activate_pending(f.system!(), &pool_id, f.ctx!());

        assert_eq!(f.pending(ledger), 0);
        assert_eq!(ledger.active_pool_tokens(&f.pool()), 5 * MIST_PER_SUI);
        ledger.revalue(&f.pool(), custody::new_rate(0, 1, 1));
        assert_eq!(ledger.assets(), 5 * MIST_PER_SUI);
    });

    destroy(ledger);
    fixture.end();
}

#[test]
fun withdraw_exact_spans_both_pending_receipts_and_active_stake() {
    let mut fixture = start();
    let mut ledger = option::none();

    fixture.next_tx!(USER, |f| {
        ledger.fill(f.new_staked_ledger(2 * MIST_PER_SUI));
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        let ledger = ledger.borrow_mut();
        let pool_id = f.pool();
        ledger.activate_pending(f.system!(), &pool_id, f.ctx!());
        ledger.revalue(&f.pool(), custody::new_rate(0, 1, 1));
        f.stake_more(ledger, 3 * MIST_PER_SUI);
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        let ledger = ledger.borrow_mut();
        f.stake_more(ledger, 4 * MIST_PER_SUI);
        assert_eq!(f.pending(ledger), 7 * MIST_PER_SUI);
        assert_eq!(ledger.active_pool_tokens(&f.pool()), 2 * MIST_PER_SUI);

        let rates = f.rates_at(1, 1);
        let sui_out = ledger.withdraw_exact(f.system!(), 8 * MIST_PER_SUI, &rates, f.ctx!());

        // Both pending receipts drain whole and the active position funds the
        // final SUI, so one exact withdrawal serves from every custody tier.
        assert_eq!(sui_out.value(), 8 * MIST_PER_SUI);
        assert_eq!(f.pending(ledger), 0);
        assert!(ledger.active_pool_tokens(&f.pool()) < 2 * MIST_PER_SUI);
        destroy(sui_out);
    });

    destroy(ledger);
    fixture.end();
}

#[test]
fun withdraw_exact_drains_the_newest_receipt_first() {
    let mut fixture = start();
    let mut ledger = option::none();

    fixture.next_tx!(USER, |f| {
        ledger.fill(f.new_staked_ledger(2 * MIST_PER_SUI));
    });
    fixture.advance_epoch();
    fixture.next_tx!(USER, |f| {
        f.stake_more(ledger.borrow_mut(), 3 * MIST_PER_SUI);
    });
    fixture.next_tx!(USER, |f| {
        let ledger = ledger.borrow_mut();
        let oldest_epoch = ledger.oldest_pending_activation_epoch(&f.pool());

        let rates = f.rates_at(1, 1);
        let sui_out = ledger.withdraw_exact(f.system!(), 4 * MIST_PER_SUI, &rates, f.ctx!());

        // The newest three-SUI receipt is consumed whole and the oldest only
        // splits for the remainder, so the oldest receipt stays delegated.
        assert_eq!(sui_out.value(), 4 * MIST_PER_SUI);
        assert_eq!(f.pending(ledger), MIST_PER_SUI);
        assert_eq!(ledger.oldest_pending_activation_epoch(&f.pool()), oldest_epoch);
        destroy(sui_out);
    });

    destroy(ledger);
    fixture.end();
}

/// A pool whose validator address now runs a different pool cannot receive delegation.
#[test]
#[expected_failure(abort_code = errors::EWrongDelegationPool, location = blast_sui::custody)]
fun delegation_rejects_a_pool_whose_address_now_runs_a_different_pool() {
    let mut fixture = start();
    let validator = fixture.runner.genesis_validator_addresses()[1];
    let pool_id;
    fixture.next_tx!(USER, |f| pool_id = f.pool());

    fixture.runner.set_sender(validator);
    fixture.runner.remove_validator();
    fixture.advance_epoch();
    let replacement = validator_builder::preset(2)
        .sui_address(validator)
        .build(fixture.runner.ctx());
    fixture.runner.add_validator_candidate(replacement);
    fixture.runner.set_sender(USER).stake_with(validator, 100);
    fixture.runner.set_sender(validator).add_validator();
    fixture.advance_epoch();

    fixture.next_tx!(USER, |f| {
        let mut ledger = new_funded_ledger(2 * MIST_PER_SUI, f.ctx!());
        ledger.add_position(pool_id);
        let rate = custody::new_rate(f.ctx!().epoch(), 1, 1);
        ledger.stake_pick(f.system!(), &pool_id, rate, 2 * MIST_PER_SUI, 0, f.ctx!());
        destroy(ledger);
    });

    fixture.end();
}

// === Test Helpers ===

/// Runs `$fn` as one transaction with the shared system state borrowed.
macro fun custody_next_tx(
    $fixture: &mut CustodyFixture,
    $sender: address,
    $fn: |&mut CustodyFixture|,
) {
    let fixture = $fixture;

    fixture.runner.set_sender($sender);
    fixture.system_state.fill(fixture.runner.scenario_mut().take_shared<SuiSystemState>());
    $fn(fixture);
    test_scenario::return_shared(fixture.system_state.extract());
}

macro fun custody_ctx($fixture: &mut CustodyFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.runner.ctx()
}

macro fun custody_system($fixture: &mut CustodyFixture): &mut SuiSystemState {
    let fixture = $fixture;

    fixture.system_state.borrow_mut()
}

fun start(): CustodyFixture {
    let mut runner = test_runner::new().validators_count(2).build();
    runner.advance_epoch(option::none()).destroy_for_testing();

    CustodyFixture { runner, system_state: option::none(), pool_id: option::none() }
}

fun custody_end(self: CustodyFixture) {
    let CustodyFixture { runner, system_state, pool_id: _ } = self;

    system_state.destroy_none();
    runner.finish();
}

fun new_funded_ledger(amount: u64, ctx: &mut TxContext): Custody {
    let mut ledger = custody::new();
    ledger.deposit(coin::mint_for_testing<SUI>(amount, ctx).into_balance());

    ledger
}

/// The second genesis validator's pool, read once.
fun pool(self: &mut CustodyFixture): ID {
    if (self.pool_id.is_none()) {
        let validator = self.runner.genesis_validator_addresses()[1];
        let pool_id = self.system!().validator_staking_pool_id(validator);
        self.pool_id.fill(pool_id);
    };

    *self.pool_id.borrow()
}

/// A rate map holding the fixture's pool at a one-to-one rate for this epoch.
fun current_rates(self: &mut CustodyFixture): VecMap<ID, PoolRate> {
    let epoch = self.ctx!().epoch();
    let mut rates = vec_map::empty();
    rates.insert(self.pool(), custody::new_rate(epoch, 1, 1));

    rates
}

/// A ledger with `amount` delegated to the second genesis validator's pool.
fun new_staked_ledger(self: &mut CustodyFixture, amount: u64): Custody {
    let mut ledger = new_funded_ledger(amount, self.ctx!());
    ledger.add_position(self.pool());
    let rates = self.current_rates();
    ledger.stake_idle(self.system!(), &rates, 0, self.ctx!());
    assert_eq!(self.pending(&ledger), amount);

    ledger
}

/// Deposits `amount` and delegates the ledger's idle SUI to the fixed pool.
fun stake_more(self: &mut CustodyFixture, ledger: &mut Custody, amount: u64) {
    ledger.deposit(coin::mint_for_testing<SUI>(amount, self.ctx!()).into_balance());
    let rates = self.current_rates();
    ledger.stake_idle(self.system!(), &rates, 0, self.ctx!());
}

/// The fixed pool's pending principal in `ledger`.
fun pending(self: &mut CustodyFixture, ledger: &Custody): u64 {
    let (pending_sui, _, _) = ledger.position_custody(&self.pool()).position_custody_fields();

    pending_sui
}

/// A rate map holding the fixture's pool at the given rate.
fun rates_at(self: &mut CustodyFixture, rate_sui: u64, rate_pool_tokens: u64): VecMap<ID, PoolRate> {
    let mut rates = vec_map::empty();
    rates.insert(self.pool(), custody::new_rate(0, rate_sui, rate_pool_tokens));

    rates
}

fun advance_epoch(self: &mut CustodyFixture) {
    self.runner.advance_epoch(option::none()).destroy_for_testing();
}

fun advance_epoch_with_rewards(self: &mut CustodyFixture, computation_charge: u64) {
    let options = self.runner.advance_epoch_opts().computation_charge(computation_charge);
    self.runner.advance_epoch(option::some(options)).destroy_for_testing();
}

// === Imports ===

use blast_sui::{custody::{Self, Custody, PoolRate}, errors};

use std::unit_test::{assert_eq, destroy};

use sui::{coin, test_scenario, sui::SUI, vec_map::{Self, VecMap}};

use sui_system::{sui_system::SuiSystemState, test_runner::{Self, TestRunner}, validator_builder};

use fun custody_ctx as CustodyFixture.ctx;

use fun custody_end as CustodyFixture.end;

use fun custody_next_tx as CustodyFixture.next_tx;

use fun custody_system as CustodyFixture.system;
