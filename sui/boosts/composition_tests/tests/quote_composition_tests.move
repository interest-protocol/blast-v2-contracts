#[test_only]
/// Consumer-only native Quote integration; neither production package depends on the other.
module blast_boosts_composition_tests::quote_composition_tests;

// === Constants ===

const MAX_ADMINS: u64 = 16;
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

public struct QUOTE_COMPOSITION_TESTS() has drop;
public struct Long2x() has drop;
public struct Short2x() has drop;
public struct Migration() has drop;

// === Tests ===

/// Runs real launch custody with the exact native Vault Quote type, not a wrapper.
/// The fixture share coin is test-minted; this is not a venue mint execution claim.
#[test]
fun admitted_vault_quote_buys_and_sells_as_an_ordinary_native_coin() {
    quote_round_trip<Vault<Long2x>>(true);
}

#[test]
fun admitted_short_vault_quote_uses_the_same_native_buy_and_sell_path() {
    quote_round_trip<Vault<Short2x>>(true);
}

#[test]
#[expected_failure(abort_code = 45, location = blast_fun::launch_config)]
fun admitting_long_does_not_admit_the_distinct_short_vault_quote() {
    quote_round_trip<Vault<Short2x>>(false);
}

// === Test Helpers ===

fun quote_round_trip<Quote>(admit_exact: bool) {
    let mut scenario = test_scenario::begin(@0xa);
    let version = package_version::new_for_testing(scenario.ctx());
    let (super_admin, mut authority) = acl::new_for_testing<BLAST_FUN_DOMAIN>(
        MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, scenario.ctx(),
    );
    authority.grant_admin(&super_admin, 0, @0xa, scenario.ctx());
    launch_config::init_for_testing(scenario.ctx());
    scenario.next_tx(@0xa);
    let admin = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    let witness = authority.sign_in(&admin);
    let mut config = scenario.take_shared<LaunchConfig>();
    if (admit_exact) {
        config.allow_quote<Quote>(&version, &witness, 5_000_000, 25_000_000);
    } else {
        config.allow_quote<Vault<Long2x>>(&version, &witness, 5_000_000, 25_000_000);
    };
    config.allow_migration_witness<Migration>(&version, &witness);
    config.set_graduation_defaults(&version, &witness, bps::new(250), bps::new(750), bps::new(2_000));
    let runtime = runtime_config::new_disabled_for_testing(scenario.ctx());
    let ticket = launch_ticket::new(
        QUOTE_COMPOSITION_TESTS(), b"MEME".to_string(), b"Composition".to_string(),
        b"Native Vault Quote test".to_string(), b"".to_string(),
        creator_authority::new_address(@0xa), false, 0, scenario.ctx(),
    );
    let mut market = launch::new<QUOTE_COMPOSITION_TESTS, Quote, Migration>(
        ticket, &version, &config, scenario.ctx(),
    );
    let quote = coin::mint_for_testing<Quote>(1_000_000, scenario.ctx());
    let (meme, refund) = market.buy(&version, &runtime, quote, 1, scenario.ctx());
    assert!(meme.value() > 0);
    assert_eq!(refund.value(), 0);
    refund.destroy_zero();
    let quote: Coin<Quote> = market.sell(&version, &runtime, meme, 1, scenario.ctx());
    assert!(quote.value() > 0 && quote.value() <= 1_000_000);
    coin::burn_for_testing(quote);
    test_scenario::return_shared(config);
    destroy(market);
    destroy(runtime);
    destroy(admin);
    destroy(authority);
    destroy(super_admin);
    destroy(version);
    scenario.end();
}

// === Compile-Only Composition Contracts ===

/// External Quote trading is independent of retirement; returned shares can enter a local claim.
/// This typechecks the actual terminal ABI without requiring a venue or oracle object.
public fun sell_and_redeem_shutdown<Product, Collateral, Meme>(
    market: &mut Launch<Meme, BlastBoost<Product>>, version: &PackageVersion,
    runtime: &RuntimeConfig, meme: Coin<Meme>, minimum_shares: u64,
    vault: &mut Vault<Product>, protocol: &Protocol,
    minimum_cash: u64, deadline: u64, clock: &Clock, ctx: &mut TxContext,
): Coin<Collateral> {
    let shares = market.sell(version, runtime, meme, minimum_shares, ctx);
    vault.redeem_shutdown(protocol, shares, minimum_cash, deadline, clock, ctx)
}

/// Typechecks the atomic mint -> launch buy handoff; requires authorized live objects to run.
public fun mint_and_buy<Product, Collateral, Meme>(
    vault: &mut Vault<Product>, protocol: &Protocol, account: &mut Account<Collateral>,
    registry: &Registry, clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
    base_price: &PriceInfoObject, collateral_price: &PriceInfoObject,
    cash: Coin<Collateral>, minimum_shares: u64, maximum_fee: u64, deadline: u64,
    market: &mut Launch<Meme, BlastBoost<Product>>, version: &PackageVersion,
    runtime: &RuntimeConfig, minimum_meme: u64, clock: &Clock, ctx: &mut TxContext,
): (Coin<Meme>, Coin<BlastBoost<Product>>) {
    let shares = operations::mint(vault, protocol, account, registry, clearing_house,
        base_oracle, collateral_oracle, base_price, collateral_price, cash,
        minimum_shares, maximum_fee, deadline, clock, ctx);
    market.buy(version, runtime, shares, minimum_meme, ctx)
}

/// Typechecks the atomic launch sell -> redemption handoff without a receipt currency.
public fun sell_and_redeem<Product, Collateral, Meme>(
    market: &mut Launch<Meme, BlastBoost<Product>>, version: &PackageVersion,
    runtime: &RuntimeConfig, meme: Coin<Meme>, minimum_shares: u64,
    vault: &mut Vault<Product>, protocol: &Protocol, account: &mut Account<Collateral>,
    registry: &Registry, clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage, collateral_oracle: &PriceFeedStorage,
    base_price: &PriceInfoObject, collateral_price: &PriceInfoObject,
    minimum_cash: u64, maximum_fee: u64, deadline: u64, clock: &Clock, ctx: &mut TxContext,
): Coin<Collateral> {
    let shares = market.sell(version, runtime, meme, minimum_shares, ctx);
    operations::redeem(vault, protocol, account, registry, clearing_house,
        base_oracle, collateral_oracle, base_price, collateral_price, shares,
        minimum_cash, maximum_fee, deadline, clock, ctx)
}

// === Imports ===

use blast_admin::acl::{Self, AdminCap};

use blast_fun::{
    bps, creator_authority, launch::{Self, Launch}, launch_config::{Self, LaunchConfig},
    launch_ticket, blast_fun_domain::BLAST_FUN_DOMAIN,
    package_version::{Self, PackageVersion}, runtime_config::{Self, RuntimeConfig},
};

use blast_boosts_aftermath::{blast_boost::BlastBoost, operations, protocol::Protocol, vault::Vault};

use oracle_aggregator::price_feed_storage::PriceFeedStorage;

use perpetuals::{account::Account, clearing_house::ClearingHouse, registry::Registry};

use pyth::price_info::PriceInfoObject;

use std::unit_test::{assert_eq, destroy};

use sui::{clock::Clock, coin::{Self, Coin}, test_scenario};
