#[test_only]
module blast_sui::currency_tests;

use blast_sui::{blast_sui::{Self, BLAST_SUI}, fun_sui::{Self, FUN_SUI}};
use std::unit_test::{assert_eq, destroy};
use sui::{coin::TreasuryCap, test_scenario::{Self, Scenario}};

use fun currency_ctx as CurrencyFixture.ctx;
use fun currency_end as CurrencyFixture.end;
use fun currency_next_tx as CurrencyFixture.next_tx;

// === Constants ===

const ADMIN: address = @0xAD;

/// Both protocol currencies freshly created through their production constructors.
public struct CurrencyFixture {
    scenario: Scenario,
    fun_cap: TreasuryCap<FUN_SUI>,
    blast_cap: TreasuryCap<BLAST_SUI>,
}

// === Tests ===

#[test]
fun both_protocol_coins_have_independent_flexible_supplies() {
    let mut fixture = start();

    fixture.next_tx!(ADMIN, |f| {
        let fun_coin = f.fun_cap.mint(7, f.ctx!());
        let blast_coin = f.blast_cap.mint(11, f.ctx!());
        assert_eq!(fun_coin.value(), 7);
        assert_eq!(blast_coin.value(), 11);
        assert_eq!(f.fun_cap.total_supply(), 7);
        assert_eq!(f.blast_cap.total_supply(), 11);

        f.fun_cap.burn(fun_coin);
        f.blast_cap.burn(blast_coin);
        assert_eq!(f.fun_cap.total_supply(), 0);
        assert_eq!(f.blast_cap.total_supply(), 0);
    });

    fixture.end();
}

/// The production initializers must deliver both caps empty to the publisher.
#[test]
fun package_initialization_delivers_empty_treasury_caps_to_the_sender() {
    let mut fixture = start_from_init();

    fixture.next_tx!(ADMIN, |f| {
        assert_eq!(f.fun_cap.total_supply(), 0);
        assert_eq!(f.blast_cap.total_supply(), 0);
    });

    fixture.end();
}

// === Fixture Macros ===

macro fun currency_next_tx(
    $fixture: &mut CurrencyFixture,
    $sender: address,
    $fn: |&mut CurrencyFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun currency_ctx($fixture: &mut CurrencyFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

// === Fixture Setup ===

fun start(): CurrencyFixture {
    let mut scenario = test_scenario::begin(ADMIN);
    let fun_cap = fun_sui::new_for_testing(scenario.ctx());
    let blast_cap = blast_sui::new_for_testing(scenario.ctx());

    CurrencyFixture { scenario, fun_cap, blast_cap }
}

/// Runs both production coin initializers and takes the delivered caps.
fun start_from_init(): CurrencyFixture {
    let mut scenario = test_scenario::begin(ADMIN);
    fun_sui::init_for_testing(scenario.ctx());
    blast_sui::init_for_testing(scenario.ctx());

    scenario.next_tx(ADMIN);
    let fun_cap = scenario.take_from_sender<TreasuryCap<FUN_SUI>>();
    let blast_cap = scenario.take_from_sender<TreasuryCap<BLAST_SUI>>();

    CurrencyFixture { scenario, fun_cap, blast_cap }
}

fun currency_end(self: CurrencyFixture) {
    destroy(self);
}
