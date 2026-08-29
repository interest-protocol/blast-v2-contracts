#[test_only]
module blast_sui::custody_tests;

use blast_sui::{constants, custody::{Self, Custody}, errors};
use std::unit_test::{assert_eq, destroy};
use sui::{coin, test_scenario, sui::SUI};
use sui_system::{sui_system::SuiSystemState, test_runner::{Self, TestRunner}};

use fun custody_ctx as CustodyFixture.ctx;
use fun custody_end as CustodyFixture.end;
use fun custody_next_tx as CustodyFixture.next_tx;
use fun custody_system as CustodyFixture.system;

// === Constants ===

const USER: address = @0xA11CE;
const MIST_PER_SUI: u64 = 1_000_000_000;

/// Native system with two genesis validators for direct ledger operations.
public struct CustodyFixture {
    runner: TestRunner,
    system_state: Option<SuiSystemState>,
}

// === Tests ===

#[test]
#[expected_failure(abort_code = errors::EWrongDelegationPool, location = blast_sui::custody)]
fun stake_idle_rejects_delegation_that_lands_in_another_pool() {
    let mut fixture = start();

    fixture.next_tx!(USER, |f| {
        let validators = f.runner.genesis_validator_addresses();
        let wrong_pool = f.system!().validator_staking_pool_id(validators[0]);
        let mut ledger = new_funded_ledger(2 * MIST_PER_SUI, f.ctx!());

        ledger.stake_idle(f.system!(), validators[1], &wrong_pool, 0, f.ctx!());

        destroy(ledger);
    });

    fixture.end();
}

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
        ledger.activate_pending(f.system!(), f.ctx!());
        // A fabricated doubled rate simulates a decreased pool exchange rate.
        ledger.revalue(2, 1);

        let sui_out = ledger.withdraw_exact(f.system!(), 3 * MIST_PER_SUI, 2, 1, f.ctx!());

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
        source.activate_pending(f.system!(), f.ctx!());
        let held = source.active_pool_tokens();
        assert_eq!(held, 2 * MIST_PER_SUI);
        let mut destination = custody::new();

        source.transfer_active_tokens(&mut destination, held, 1, 1, f.ctx!());

        assert_eq!(source.active_pool_tokens(), 0);
        assert_eq!(source.assets(), 0);
        assert_eq!(destination.active_pool_tokens(), held);
        assert_eq!(destination.assets(), held);
        destroy(destination);
    });

    destroy(ledger);
    fixture.end();
}

// === Fixture Macros ===

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

// === Fixture Setup ===

fun start(): CustodyFixture {
    let mut runner = test_runner::new().validators_count(2).build();
    runner.advance_epoch(option::none()).destroy_for_testing();

    CustodyFixture { runner, system_state: option::none() }
}

fun custody_end(self: CustodyFixture) {
    let CustodyFixture { runner, system_state } = self;

    system_state.destroy_none();
    runner.finish();
}

// === Helpers ===

fun new_funded_ledger(amount: u64, ctx: &mut TxContext): Custody {
    let mut ledger = custody::new();
    ledger.deposit(coin::mint_for_testing<SUI>(amount, ctx).into_balance());

    ledger
}

/// A ledger with `amount` delegated to the second genesis validator's pool.
fun new_staked_ledger(self: &mut CustodyFixture, amount: u64): Custody {
    let validator = self.runner.genesis_validator_addresses()[1];
    let pool_id = self.system!().validator_staking_pool_id(validator);
    let mut ledger = new_funded_ledger(amount, self.ctx!());
    ledger.stake_idle(self.system!(), validator, &pool_id, 0, self.ctx!());
    assert_eq!(ledger.pending_sui(), amount);

    ledger
}

fun advance_epoch(self: &mut CustodyFixture) {
    self.runner.advance_epoch(option::none()).destroy_for_testing();
}
