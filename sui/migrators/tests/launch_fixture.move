// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Launch intake shared by the vault, fee-split, and holder-reward suites: the admitted launch
/// policy and one unprotected launch that a test adapter starts for its own witness.
module blast_fun_migrators::launch_fixture;

// === Constants ===

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

/// The ticket's creator recipient, who claims the launch's creator capabilities.
const CREATOR: address = @0xC0FFEE;

const VIRTUAL_QUOTE: u64 = 5_000_000;

const TARGET: u64 = 25_000_000;

const POOL_TICK_SPACING: u32 = 60;

const POOL_FEE_RATE: u64 = 2_500;

// === Test Helpers ===

/// Admits `Quote` and the adapter's `Witness` with fixed trade fees and a zero Blast allocation.
public fun admit<Quote, Witness: drop>(
    config: &mut LaunchConfig,
    version: &PackageVersion,
    admin: &AdminWitness<BLAST_FUN_DOMAIN>,
) {
    config.set_quote<Quote>(version, admin, VIRTUAL_QUOTE);
    config.set_migration_witness_allowed<Witness>(version, admin, true);
    config.set_trade_fees(version, admin, bps::new(100), bps::new(100));
    config.set_protocol_allocation(version, admin, CREATOR, bps::new(0), bps::new(0));
}

/// Mints the ticket, then starts the launch for `witness` at the fixture tier with `fee_split` and
/// finalizes it in the next transaction, once the Coin Registry holds the currency. Returns the
/// launch and its currency, whose supply is burn-only when `burnable` and fixed otherwise.
public fun open_launch<Meme: drop, Quote, Witness: drop>(
    scenario: &mut Scenario,
    otw: Meme,
    version: &PackageVersion,
    config: &LaunchConfig,
    witness: Witness,
    fee_split: FeeSplit,
    burnable: bool,
): (Launch<Meme, Quote>, Currency<Meme>) {
    let ticket = launch_ticket::new(
        otw,
        9,
        b"TEST".to_string(),
        b"Migrator fixture".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(CREATOR),
        burnable,
        0,
        scenario.ctx(),
    );
    let sender = scenario.sender();
    scenario.next_tx(sender);
    let mut currency = scenario.take_from_address<Currency<Meme>>(COIN_REGISTRY);
    let mut initializer = launch::new<Meme, Quote, _>(
        ticket,
        version,
        config,
        witness,
        POOL_TICK_SPACING,
        POOL_FEE_RATE,
    );
    initializer.set_graduation_target(TARGET);
    initializer.set_allocation_plan(
        allocation::plan(bps::new(8_000), bps::new(2_000), bps::new(10_000), vector[]),
    );
    initializer.set_lp_fee_split(fee_split);
    let launch = initializer.finalize(version, &mut currency, config, scenario.ctx());

    (launch, currency)
}

/// Returns the creator recipient of every fixture launch.
public fun creator(): address {
    CREATOR
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::{
    allocation::{Self, FeeSplit},
    blast_fun_domain::BLAST_FUN_DOMAIN,
    bps,
    creator_authority,
    launch::{Self, Launch},
    launch_config::LaunchConfig,
    launch_ticket,
    package_version::PackageVersion,
};

use sui::{coin_registry::Currency, test_scenario::Scenario};
