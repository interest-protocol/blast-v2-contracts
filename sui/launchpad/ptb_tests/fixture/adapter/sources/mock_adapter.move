// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Publishable sealed adapter for the programmable-transaction migration harness.
///
/// `new` and `migrate` are the only entry points the harness calls. The adapter owns the private
/// witness: `new` starts a SUI-quoted launch under it, and `migrate` keeps the supplied principal
/// and the explicit residuals in a mock vault and can fail at named points.
module ptb_adapter::mock_adapter;

// === Constants ===

const CUSTODY_FAILURE: u8 = 1;

const ZERO_LIQUIDITY: u8 = 2;

const UNDERFUND_MEME: u8 = 3;

const POST_FINALIZER_FAILURE: u8 = 4;

// === Errors ===

const ECustodyFailure: u64 = 0;

const EPostFinalizerFailure: u64 = 1;

const EUnknownFailpoint: u64 = 2;

// === Public Types ===

/// Adapter identity only this module can construct.
public struct Venue() has drop;

/// Permanent custody: the supplied principal, its liquidity, and the explicit residuals.
public struct MockVault<phantom Meme> has key {
    id: UID,
    meme: Balance<Meme>,
    quote: Balance<SUI>,
    liquidity: u128,
    residual_meme: Balance<Meme>,
    residual_quote: Balance<SUI>,
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

/// Runs the complete migration in one call and returns nothing. `failpoint` selects an injected
/// failure; zero completes.
public fun migrate<Meme>(
    launch: &mut Launch<Meme, SUI>,
    version: &PackageVersion,
    currency: &mut Currency<Meme>,
    failpoint: u8,
    ctx: &mut TxContext,
) {
    assert!(failpoint <= POST_FINALIZER_FAILURE, EUnknownFailpoint);

    let (mut meme, mut quote, migration) = launch.begin_migration(version, Venue());
    let residual_meme = meme.split(1);
    let residual_quote = quote.split(1);
    if (failpoint == UNDERFUND_MEME) {
        transfer::public_transfer(meme.split(1).into_coin(ctx), @0xDEAD);
    };
    let vault = MockVault {
        id: object::new(ctx),
        meme,
        quote,
        liquidity: if (failpoint == ZERO_LIQUIDITY) 0 else 1,
        residual_meme,
        residual_quote,
    };
    assert!(failpoint != CUSTODY_FAILURE, ECustodyFailure);

    launch.complete_migration(
        version,
        currency,
        migration,
        Venue(),
        vault.meme.value(),
        vault.quote.value(),
        &vault.residual_meme,
        &vault.residual_quote,
        vault.liquidity,
        ctx,
    );
    transfer::share_object(vault);
    assert!(failpoint != POST_FINALIZER_FAILURE, EPostFinalizerFailure);
}

// === Imports ===

use blast_fun::{
    launch::{Self, Launch, LaunchInitializer},
    launch_config::LaunchConfig,
    launch_ticket::LaunchTicket,
    package_version::PackageVersion,
};

use sui::{balance::Balance, coin_registry::Currency, sui::SUI};
