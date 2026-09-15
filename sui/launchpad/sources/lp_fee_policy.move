// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one append-only registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
/// Live protocol share of fees collected from migrated liquidity positions.
///
/// Bonding-curve trades read the runtime configuration's share; every migrator that
/// locks launch liquidity reads this object instead, so the two splits change independently.
/// Partner projects may carry a unique share keyed by their Meme type.
module blast_fun::lp_fee_policy;

use blast_admin::acl::AdminWitness;
use blast_fun::{
    bps::{Self, Bps},
    events,
    launchpad_domain::LAUNCHPAD_DOMAIN,
    package_version::PackageVersion,
};
use std::type_name::{Self, TypeName};
use sui::table::{Self, Table};

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
    _: &AdminWitness<LAUNCHPAD_DOMAIN>,
    protocol_fee_share_bps: Bps,
) {
    package_version.assert_current();
    assert!(
        protocol_fee_share_bps != self.protocol_fee_share_bps,
        blast_fun::errors::lp_protocol_fee_share_unchanged!(),
    );

    self.protocol_fee_share_bps = protocol_fee_share_bps;

    events::lp_protocol_fee_share_changed(protocol_fee_share_bps.value());
}

/// Pins one project's LP share, which then ignores later migrator-wide changes.
///
/// A project may be pinned before it launches or migrates. Pinning the value
/// equal to the current default is a real transition because it survives later
/// default changes; only re-pinning the project's own current value is rejected.
public fun set_project_protocol_fee_share<Meme>(
    self: &mut LpFeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<LAUNCHPAD_DOMAIN>,
    protocol_fee_share_bps: Bps,
) {
    package_version.assert_current();

    let meme = type_name::with_original_ids<Meme>();

    if (self.project_protocol_fee_shares.contains(meme)) {
        let share_mut = &mut self.project_protocol_fee_shares[meme];

        assert!(
            protocol_fee_share_bps != *share_mut,
            blast_fun::errors::project_lp_protocol_fee_share_unchanged!(),
        );

        *share_mut = protocol_fee_share_bps;
    } else {
        self.project_protocol_fee_shares.add(meme, protocol_fee_share_bps);
    };

    events::project_lp_protocol_fee_share_set<Meme>(protocol_fee_share_bps.value());
}

/// Removes one project's pinned share so it follows the migrator-wide share again.
public fun clear_project_protocol_fee_share<Meme>(
    self: &mut LpFeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<LAUNCHPAD_DOMAIN>,
) {
    package_version.assert_current();

    let meme = type_name::with_original_ids<Meme>();

    assert!(
        self.project_protocol_fee_shares.contains(meme),
        blast_fun::errors::project_lp_protocol_fee_share_missing!(),
    );

    self.project_protocol_fee_shares.remove(meme);

    events::project_lp_protocol_fee_share_cleared<Meme>();
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
