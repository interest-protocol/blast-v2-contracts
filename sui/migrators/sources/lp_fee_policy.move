// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Live protocol share of fees collected from migrated liquidity positions.
///
/// Bonding-curve trades read the runtime configuration's share; every migrator that
/// locks launch liquidity reads this object instead, so the two splits change independently.
/// Partner projects may carry a unique share keyed by their Meme type.
module blast_fun_migrators::lp_fee_policy;

// === Errors ===

#[error(code = 0)]
const EProtocolFeeShareUnchanged: vector<u8> =
    b"A migrator-wide LP-fee share update must change the active share.";
#[error(code = 1)]
const EProjectProtocolFeeShareUnchanged: vector<u8> =
    b"A project LP-fee share update must change the project's pinned share.";
#[error(code = 2)]
const EProjectProtocolFeeShareMissing: vector<u8> =
    b"A project LP-fee share clear requires a pinned share.";

// === Public Structs ===

/// Shared singleton holding the migrator-wide LP share and per-project overrides.
///
/// Overrides are admin-written Table entries keyed by the Meme's original
/// `TypeName`, mirroring the quote registry: no iteration and no cardinality cap.
public struct LpFeePolicy has key {
    id: UID,
    protocol_fee_share_bps: Bps,
    project_protocol_fee_shares: Table<TypeName, Bps>,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Updates the migrator-wide share applied to every later LP-fee collection without an override.
public fun set_protocol_fee_share(
    self: &mut LpFeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    protocol_fee_share_bps: Bps,
) {
    package_version.assert_current();
    assert!(
        protocol_fee_share_bps != self.protocol_fee_share_bps,
        EProtocolFeeShareUnchanged,
    );

    self.protocol_fee_share_bps = protocol_fee_share_bps;

    blast_events::lp_protocol_fee_share_changed(protocol_fee_share_bps.value());
}

/// Pins one project's LP share, which then ignores later migrator-wide changes.
///
/// A project may be pinned before it launches or migrates. Pinning the value
/// equal to the current default is a real transition because it survives later
/// default changes; only re-pinning the project's own current value is rejected.
public fun set_project_protocol_fee_share<Meme>(
    self: &mut LpFeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    protocol_fee_share_bps: Bps,
) {
    package_version.assert_current();

    let meme = type_name::with_original_ids<Meme>();

    if (self.project_protocol_fee_shares.contains(meme)) {
        let share_mut = &mut self.project_protocol_fee_shares[meme];

        assert!(
            protocol_fee_share_bps != *share_mut,
            EProjectProtocolFeeShareUnchanged,
        );

        *share_mut = protocol_fee_share_bps;
    } else {
        self.project_protocol_fee_shares.add(meme, protocol_fee_share_bps);
    };

    blast_events::project_lp_protocol_fee_share_set<Meme>(protocol_fee_share_bps.value());
}

/// Removes one project's pinned share so it follows the migrator-wide share again.
public fun clear_project_protocol_fee_share<Meme>(
    self: &mut LpFeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
) {
    package_version.assert_current();

    let meme = type_name::with_original_ids<Meme>();

    assert!(
        self.project_protocol_fee_shares.contains(meme),
        EProjectProtocolFeeShareMissing,
    );

    self.project_protocol_fee_shares.remove(meme);

    blast_events::project_lp_protocol_fee_share_cleared<Meme>();
}

/// Returns the share a migrator must apply to newly collected `Meme` LP fees.
///
/// The project's pinned share wins; otherwise the migrator-wide share applies.
public fun protocol_fee_share<Meme>(self: &LpFeePolicy): Bps {
    let meme = type_name::with_original_ids<Meme>();

    if (self.project_protocol_fee_shares.contains(meme)) {
        self.project_protocol_fee_shares[meme]
    } else {
        self.protocol_fee_share_bps
    }
}

// === Private Functions ===

/// Starts with a zero migrator-wide share and no project overrides.
fun new(ctx: &mut TxContext): LpFeePolicy {
    LpFeePolicy {
        id: object::new(ctx),
        protocol_fee_share_bps: bps::new(0),
        project_protocol_fee_shares: table::new(ctx),
    }
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Creates unshared zero-share policy state for focused and downstream tests.
public fun new_for_testing(ctx: &mut TxContext): LpFeePolicy {
    new(ctx)
}

#[test_only]
/// Returns the number of pinned project shares.
public fun project_count_for_testing(self: &LpFeePolicy): u64 {
    self.project_protocol_fee_shares.length()
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::{bps::{Self, Bps}, blast_fun_domain::BLAST_FUN_DOMAIN};

use blast_fun_migrators::{blast_events, package_version::PackageVersion};

use std::type_name::{Self, TypeName};

use sui::table::{Self, Table};
