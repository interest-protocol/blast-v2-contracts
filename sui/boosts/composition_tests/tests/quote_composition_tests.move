// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Consumer-only native Quote integration; neither production package depends on the other.
module blast_boosts_composition_tests::quote_composition_tests;

// === Constants ===

const POOL_TICK_SPACING: u32 = 200;

const POOL_FEE_RATE: u64 = 10_000;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct QUOTE_COMPOSITION_TESTS has drop {}

public struct Long2x() has drop;

public struct Short2x() has drop;

public struct Migration() has drop;

// === Tests ===

/// Runs real launch custody with the exact native Vault Quote type, not a wrapper.
/// The fixture share coin is test-minted; this is not a venue mint execution claim.
#[test]
fun admitted_vault_quote_buys_and_sells_as_an_ordinary_native_coin() {
    quote_round_trip<BlastBoost<Long2x>>(true);
}

#[test]
fun admitted_short_vault_quote_uses_the_same_native_buy_and_sell_path() {
    quote_round_trip<BlastBoost<Short2x>>(true);
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EQuoteNotAllowed, location = blast_fun::launch_config)]
fun admitting_long_does_not_admit_the_distinct_short_vault_quote() {
    quote_round_trip<BlastBoost<Short2x>>(false);
}

// === Test Helpers ===

fun quote_round_trip<Quote>(admit_exact: bool) {
    let mut scenario = test_scenario::begin(@0x0);
    let version = package_version::new_for_testing(scenario.ctx());
    launch_config::init_for_testing(scenario.ctx());
    scenario.next_tx(@0xa);
    let listing_admin = blast_acl::witness_for_testing<ListingAdmin>();
    let adapter_admin = blast_acl::witness_for_testing<AdapterAdmin>();
    let mut config = scenario.take_shared<LaunchConfig>();
    if (admit_exact) {
        config.set_quote_allowed<Quote>(&version, &listing_admin, true);
    } else {
        config.set_quote_allowed<BlastBoost<Long2x>>(&version, &listing_admin, true);
    };
    config.set_migration_witness_allowed<Migration>(&version, &adapter_admin, true);
    let runtime = runtime_config::new_disabled_for_testing(scenario.ctx());
    let ticket = launch_ticket::new(
        test_utils::create_one_time_witness<QUOTE_COMPOSITION_TESTS>(), 9,
        b"MEME".to_string(), b"Composition".to_string(),
        b"Native Vault Quote test".to_string(), b"".to_string(),
        creator_authority::new_address(@0xa), false, 0, scenario.ctx(),
    );
    scenario.next_tx(@0xa);
    let mut currency = scenario.take_from_address<Currency<QUOTE_COMPOSITION_TESTS>>(@0xc);
    let mut initializer = launch::new<_, Quote, _>(
        ticket, &version, &config, Migration(), POOL_TICK_SPACING, POOL_FEE_RATE,
    );
    initializer.set_virtual_quote(&version, 5_000_000);
    initializer.set_graduation_target(&version, 25_000_000);
    initializer.set_allocation_plan(&version, default_allocation_plan());
    initializer.set_lp_fee_split(&version, default_fee_split());
    let creation_fee = coin::zero(scenario.ctx());
    let market = initializer.finalize(&version, &mut currency, &config, creation_fee, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    market.share(&version, &clock);
    test_scenario::return_shared(config);
    test_scenario::return_to_address(@0xc, currency);
    scenario.next_tx(@0xa);
    let mut market = scenario.take_shared<Launch<QUOTE_COMPOSITION_TESTS, Quote>>();
    let quote = coin::mint_for_testing<Quote>(1_000_000, scenario.ctx());
    let (meme, refund) = market.buy(&version, &runtime, quote, 1, scenario.ctx());
    assert!(meme.value() > 0);
    assert_eq!(refund.value(), 0);
    refund.destroy_zero();
    let quote: Coin<Quote> = market.sell(&version, &runtime, meme, 1, scenario.ctx());
    assert!(quote.value() > 0 && quote.value() <= 1_000_000);
    coin::burn_for_testing(quote);
    test_scenario::return_shared(market);
    clock.destroy_for_testing();
    destroy(runtime);
    destroy(version);
    scenario.end();
}

fun default_allocation_plan(): AllocationPlan {
    allocation::plan(bps::new(8_000), bps::new(2_000), bps::new(10_000), vector[])
}

fun default_fee_split(): allocation::FeeSplit {
    allocation::fee_split(bps::new(10_000), bps::new(0), bps::new(0), bps::new(0), vector[])
}

// Compile-Only Composition Contracts

/// External Quote trading is independent of retirement; returned shares can enter a local claim.
/// This typechecks the actual terminal ABI without requiring a venue or oracle object.
public fun sell_and_redeem_shutdown<Product, Collateral, Meme>(
    market: &mut Launch<Meme, BlastBoost<Product>>,
    version: &PackageVersion,
    runtime: &RuntimeConfig,
    meme: Coin<Meme>,
    minimum_shares: u64,
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    minimum_cash: u64,
    deadline_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Collateral> {
    let shares = market.sell(version, runtime, meme, minimum_shares, ctx);
    vault.redeem_shutdown(protocol, shares, minimum_cash, deadline_at_ms, clock, ctx)
}

/// Typechecks issuance under a published product tag, which carries no
/// abilities; requires the issuer's live objects to run.
public fun issue_published_product<Collateral>(
    protocol: &Protocol,
    admin_witness: &AdminWitness<VaultIssuer>,
    registry: &mut CoinRegistry,
    vault_policy: VaultPolicy,
    max_order_notional: u64,
    nav_cap: u64,
    ctx: &mut TxContext,
): VaultIssuance<BTC_BULL_2X, Collateral> {
    vault::issue<BTC_BULL_2X, Collateral>(
        protocol, admin_witness, registry, vault_policy, max_order_notional, nav_cap,
        b"BTC2X".to_string(), b"BTC 2x Bull".to_string(), b"Two times BTC".to_string(), b"".to_string(), ctx,
    )
}

/// Typechecks the atomic mint -> launch buy handoff; requires authorized live objects to run.
public fun mint_and_buy<Product, Collateral, Meme>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    cash: Coin<Collateral>,
    minimum_shares: u64,
    deadline_at_ms: u64,
    market: &mut Launch<Meme, BlastBoost<Product>>,
    version: &PackageVersion,
    runtime: &RuntimeConfig,
    minimum_meme: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<BlastBoost<Product>>) {
    let (shares, clearing_house) = vault.mint(
        protocol, account, registry, clearing_house,
        base_oracle, collateral_oracle, cash,
        minimum_shares, deadline_at_ms, clock, ctx);
    let (meme, refund) = market.buy(version, runtime, shares, minimum_meme, ctx);
    clearing_house.share();
    (meme, refund)
}

/// Typechecks the atomic launch sell -> redemption handoff without a receipt currency.
public fun sell_and_redeem<Product, Collateral, Meme>(
    market: &mut Launch<Meme, BlastBoost<Product>>,
    version: &PackageVersion,
    runtime: &RuntimeConfig,
    meme: Coin<Meme>,
    minimum_shares: u64,
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    minimum_cash: u64,
    deadline_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Collateral> {
    let shares = market.sell(version, runtime, meme, minimum_shares, ctx);
    let (cash, clearing_house) = vault.redeem(
        protocol, account, registry, clearing_house,
        base_oracle, collateral_oracle, shares,
        minimum_cash, deadline_at_ms, clock, ctx);
    clearing_house.share();
    cash
}

/// Typechecks reuse of the returned market across two completed venue sessions.
public fun mint_and_redeem<Product, Collateral>(
    vault: &mut Vault<Product, Collateral>,
    protocol: &Protocol,
    account: &mut Account<Collateral>,
    registry: &Registry,
    clearing_house: ClearingHouse<Collateral>,
    base_oracle: &PriceFeedStorage,
    collateral_oracle: &PriceFeedStorage,
    cash: Coin<Collateral>,
    minimum_shares: u64,
    minimum_cash: u64,
    deadline_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Collateral> {
    let (shares, clearing_house) = vault.mint(
        protocol, account, registry, clearing_house, base_oracle, collateral_oracle,
        cash, minimum_shares, deadline_at_ms, clock, ctx,
    );
    let (cash, clearing_house) = vault.redeem(
        protocol, account, registry, clearing_house, base_oracle, collateral_oracle,
        shares, minimum_cash, deadline_at_ms, clock, ctx,
    );
    clearing_house.share();
    cash
}

// === Imports ===

use blast_admin::blast_acl::{Self, AdminWitness};

use blast_fun::{
    allocation::{Self, AllocationPlan},
    bps,
    creator_authority,
    launch::{Self, Launch},
    launch_config::{Self, LaunchConfig},
    launch_ticket,
    blast_fun_domain::{AdapterAdmin, ListingAdmin},
    blast_fun::{Self as package_version, PackageVersion},
    runtime_config::{Self, RuntimeConfig},
};

use blast_boosts_aftermath::{blast_boost::BlastBoost, operations, blast_boosts_aftermath::Protocol, vault::{Self, Vault, VaultIssuance}};

use blast_boosts_core::{blast_boosts_core::VaultIssuer, policy::VaultPolicy};

use blast_boosts_products::blast_boosts_products::BTC_BULL_2X;

use oracle_aggregator::price_feed_storage::PriceFeedStorage;

use perpetuals::{account::Account, clearing_house::ClearingHouse, registry::Registry};

use std::{type_name, unit_test::{assert_eq, destroy}};

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    coin_registry::{CoinRegistry, Currency},
    test_scenario,
    test_utils,
};

use fun operations::mint as Vault.mint;

use fun operations::redeem as Vault.redeem;
