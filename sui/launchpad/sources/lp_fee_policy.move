// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one package registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
/// Launchpad-owned policy copied once into each router when migration activates it.
module blast_fun::lp_fee_policy;

// === Public Types ===

/// Shared singleton holding independent Meme/Quote Blast shares for future activations and the
/// live address every router pays the protocol share to.
/// Partner entries use original Meme type identity and require no iteration or cardinality cap.
public struct LpFeePolicy has key {
    id: UID,
    destination: address,
    defaults: SharePair,
    partners: Table<TypeName, SharePair>,
}

/// Atomic pair of validated shares; an override always replaces both assets together.
public struct SharePair has copy, drop, store {
    meme_bps: Bps,
    quote_bps: Bps,
}

/// Frozen source and independent asset shares stored by an activated router.
/// Later policy administration cannot change this copied value.
public struct PolicySnapshot has copy, drop, store {
    partner: bool,
    meme_bps: Bps,
    quote_bps: Bps,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Redirects every future protocol share payout; shares already frozen in routers are unaffected.
public fun set_protocol_destination(
    self: &mut LpFeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    destination: address,
) {
    package_version.assert_current();
    assert!(
        destination != @0x0 && destination != self.destination,
        blast_fun::errors::protocol_destination_unchanged!(),
    );
    let old_destination = self.destination;

    self.destination = destination;

    events::lp_fee_destination_changed(old_destination, destination);
}

/// Returns the address paid the protocol share of every collection.
public fun protocol_destination(self: &LpFeePolicy): address {
    self.destination
}

/// Changes both default shares for later activations without changing partner overrides.
public fun set_default_shares(
    self: &mut LpFeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    meme_bps: Bps,
    quote_bps: Bps,
) {
    package_version.assert_current();
    let shares = SharePair { meme_bps, quote_bps };
    assert!(shares != self.defaults, blast_fun::errors::protocol_fee_share_unchanged!());
    let old = self.defaults;

    self.defaults = shares;

    events::lp_fee_policy_changed(
        option::none(),
        option::some(old.meme_bps.value()),
        option::some(old.quote_bps.value()),
        option::some(meme_bps.value()),
        option::some(quote_bps.value()),
    );
}

/// Returns the Meme and Quote shares an activation freezes when its Meme has no partner pair.
public fun default_shares(self: &LpFeePolicy): (Bps, Bps) {
    (self.defaults.meme_bps, self.defaults.quote_bps)
}

/// Pins both shares for this original Meme type at later activations.
/// Pinning current defaults is a real transition because later default changes are ignored.
public fun set_partner_shares<Meme>(
    self: &mut LpFeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    meme_bps: Bps,
    quote_bps: Bps,
) {
    package_version.assert_current();
    let meme = type_name::with_original_ids<Meme>();
    let shares = SharePair { meme_bps, quote_bps };
    let old = if (self.partners.contains(meme)) {
        let old = self.partners[meme];
        assert!(shares != old, blast_fun::errors::protocol_fee_share_unchanged!());
        option::some(old)
    } else {
        option::none()
    };

    if (old.is_some()) {
        *&mut self.partners[meme] = shares;
    } else {
        self.partners.add(meme, shares);
    };

    events::lp_fee_policy_changed(
        option::some(meme),
        old.map!(|pair| pair.meme_bps.value()),
        old.map!(|pair| pair.quote_bps.value()),
        option::some(meme_bps.value()),
        option::some(quote_bps.value()),
    );
}

/// Removes a partner override so later activations use the defaults again.
public fun clear_partner_shares<Meme>(
    self: &mut LpFeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
) {
    package_version.assert_current();
    let meme = type_name::with_original_ids<Meme>();
    assert!(self.partners.contains(meme), blast_fun::errors::protocol_fee_share_unchanged!());
    let old = self.partners[meme];

    self.partners.remove(meme);

    events::lp_fee_policy_changed(
        option::some(meme),
        option::some(old.meme_bps.value()),
        option::some(old.quote_bps.value()),
        option::none(),
        option::none(),
    );
}

/// Selects one complete partner pair, otherwise the complete default pair, for activation.
///
/// Read before activation, it names the source and pair a router for `Meme` would freeze now,
/// which is how a pinned partner pair is read.
public fun snapshot<Meme>(self: &LpFeePolicy): PolicySnapshot {
    let meme = type_name::with_original_ids<Meme>();
    let partner = self.partners.contains(meme);
    let shares = if (partner) self.partners[meme] else self.defaults;

    PolicySnapshot { partner, meme_bps: shares.meme_bps, quote_bps: shares.quote_bps }
}

/// Reports whether activation selected a Meme-specific partner pair.
public fun is_partner(self: &PolicySnapshot): bool {
    self.partner
}

/// Returns the frozen Blast share of collected Meme fees.
public fun meme_share(self: &PolicySnapshot): Bps {
    self.meme_bps
}

/// Returns the frozen Blast share of collected Quote fees.
public fun quote_share(self: &PolicySnapshot): Bps {
    self.quote_bps
}

// === Private Functions ===

/// The publisher receives the protocol share until an administrator redirects it.
fun new(ctx: &mut TxContext): LpFeePolicy {
    LpFeePolicy {
        id: object::new(ctx),
        destination: ctx.sender(),
        defaults: SharePair { meme_bps: bps::new(0), quote_bps: bps::new(0) },
        partners: table::new(ctx),
    }
}

// === Test-Only Functions ===

#[test_only]
/// Runs eventless publication initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Creates unshared zero-share policy for focused and router tests.
public fun new_for_testing(ctx: &mut TxContext): LpFeePolicy {
    new(ctx)
}

#[test_only]
/// Returns the number of stored partner pairs for type-key and cleanup tests.
public fun partner_count_for_testing(self: &LpFeePolicy): u64 {
    self.partners.length()
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::{
    blast_fun_domain::BLAST_FUN_DOMAIN,
    bps::{Self, Bps},
    events,
    package_version::PackageVersion,
};

use std::type_name::{Self, TypeName};

use sui::table::{Self, Table};
