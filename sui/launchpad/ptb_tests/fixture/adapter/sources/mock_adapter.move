// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Publishable sealed adapter for the programmable-transaction migration harness.
///
/// `new` and `migrate` are the only entry points the harness calls. The adapter owns the private
/// witness: `new` starts a SUI-quoted launch under it, and `migrate` keeps the handoff in a mock
/// vault and can fail after the launch has migrated.
module ptb_adapter::mock_adapter;

// === Errors ===

const EAdapterFailure: u64 = 0;

// === Public Types ===

/// Adapter identity only this module can construct.
public struct Venue() has drop;

/// Permanent custody of the handoff.
public struct MockVault<phantom Meme> has key {
    id: UID,
    meme: Balance<Meme>,
    quote: Balance<SUI>,
}

// === Public Functions ===

/// Starts `ticket`'s SUI-quoted launch for this adapter at the given pool tier, as a venue
/// adapter's `new` does. The caller sets the launch settings and finalizes it in the same
/// transaction.
public fun new<Meme>(
    ticket: LaunchTicket<Meme>,
    version: &PackageVersion,
    config: &LaunchConfig,
    tick_spacing: u32,
    fee_rate: u64,
): LaunchInitializer<Meme, SUI> {
    launch::new(ticket, version, config, Venue(), tick_spacing, fee_rate)
}

/// Runs the migration in one call and returns nothing. `fail` aborts after the launch migrated.
public fun migrate<Meme>(
    launch: &mut Launch<Meme, SUI>,
    version: &PackageVersion,
    currency: &mut Currency<Meme>,
    fail: bool,
    ctx: &mut TxContext,
) {
    let (meme, quote) = launch.migrate(version, currency, Venue(), ctx);
    transfer::share_object(MockVault { id: object::new(ctx), meme, quote });
    assert!(!fail, EAdapterFailure);
}

// === Imports ===

use blast_fun::{
    launch::{Self, Launch, LaunchInitializer},
    launch_config::LaunchConfig,
    launch_ticket::LaunchTicket,
    blast_fun::PackageVersion,
};

use sui::{balance::Balance, coin_registry::Currency, sui::SUI};
