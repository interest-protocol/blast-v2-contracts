// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast's share of the LP fees every migrated position collects.
///
/// Bonding-curve trades read the launchpad's `RuntimeConfig`; migrated positions read this
/// object instead, so the two policies change independently. Every collection reads it live:
/// the coin's own pair when an administrator set one, otherwise the default pair, and the
/// current payout destination.
module blast_fun_migrators::lp_fee_policy;

// === Errors ===

#[error(code = 0)]
const EProtocolDestinationUnchanged: vector<u8> = b"Protocol destination must be a new nonzero address.";

#[error(code = 1)]
const EProtocolFeeSharesUnchanged: vector<u8> = b"LP-fee share update must change the stored pair.";

#[error(code = 2)]
const ECoinSharesMissing: vector<u8> = b"Meme type has no LP-fee shares of its own to clear.";

// === Public Types ===

/// Shared singleton holding independent Meme/Quote Blast shares and the address every vault pays
/// the protocol share to. Per-coin entries use original Meme type identity and require no
/// iteration or cardinality cap.
public struct LpFeePolicy has key {
    id: UID,
    destination: address,
    defaults: SharePair,
    coins: Table<TypeName, SharePair>,
}

/// Atomic pair of validated shares; a per-coin entry always replaces both assets together.
public struct SharePair has copy, drop, store {
    meme_bps: Bps,
    quote_bps: Bps,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Redirects every later protocol share payout.
public fun set_protocol_destination(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    destination: address,
) {
    migrators_version.assert_current();
    assert!(
        destination != @0x0 && destination != self.destination,
        EProtocolDestinationUnchanged,
    );
    let old_destination = self.destination;

    self.destination = destination;

    blast_events::lp_fee_destination_changed(old_destination, destination);
}

/// Changes both default shares for every coin without its own pair, from its next collection.
public fun set_default_shares(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    meme_bps: Bps,
    quote_bps: Bps,
) {
    migrators_version.assert_current();
    let shares = SharePair { meme_bps, quote_bps };
    assert!(shares != self.defaults, EProtocolFeeSharesUnchanged);
    let old = self.defaults;

    self.defaults = shares;

    blast_events::lp_fee_policy_changed(
        option::none(),
        option::some(old.meme_bps.value()),
        option::some(old.quote_bps.value()),
        option::some(meme_bps.value()),
        option::some(quote_bps.value()),
    );
}

/// Sets both shares for this original Meme type, from its next collection.
/// Setting the current defaults is a real transition because later default changes skip the coin.
public fun set_coin_shares<Meme>(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    meme_bps: Bps,
    quote_bps: Bps,
) {
    migrators_version.assert_current();
    let meme = type_name::with_original_ids<Meme>();
    let shares = SharePair { meme_bps, quote_bps };
    let old = if (self.coins.contains(meme)) {
        let old = self.coins[meme];
        assert!(shares != old, EProtocolFeeSharesUnchanged);
        option::some(old)
    } else {
        option::none()
    };

    if (old.is_some()) {
        *&mut self.coins[meme] = shares;
    } else {
        self.coins.add(meme, shares);
    };

    blast_events::lp_fee_policy_changed(
        option::some(meme),
        old.map!(|pair| pair.meme_bps.value()),
        old.map!(|pair| pair.quote_bps.value()),
        option::some(meme_bps.value()),
        option::some(quote_bps.value()),
    );
}

/// Removes the coin's own pair so its later collections use the defaults again.
public fun clear_coin_shares<Meme>(
    self: &mut LpFeePolicy,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
) {
    migrators_version.assert_current();
    let meme = type_name::with_original_ids<Meme>();
    assert!(self.coins.contains(meme), ECoinSharesMissing);
    let old = self.coins[meme];

    self.coins.remove(meme);

    blast_events::lp_fee_policy_changed(
        option::some(meme),
        option::some(old.meme_bps.value()),
        option::some(old.quote_bps.value()),
        option::none(),
        option::none(),
    );
}

// === Package Functions ===

/// Returns the address paid the protocol share of every collection.
public(package) fun protocol_destination(self: &LpFeePolicy): address {
    self.destination
}

/// Returns the Meme and Quote shares a collection for `Meme` pays Blast now.
public(package) fun shares<Meme>(self: &LpFeePolicy): (Bps, Bps) {
    let meme = type_name::with_original_ids<Meme>();
    let shares = if (self.coins.contains(meme)) self.coins[meme] else self.defaults;

    (shares.meme_bps, shares.quote_bps)
}

// === Private Functions ===

/// The publisher receives the protocol share until an administrator redirects it.
fun new(ctx: &mut TxContext): LpFeePolicy {
    LpFeePolicy {
        id: object::new(ctx),
        destination: ctx.sender(),
        defaults: SharePair { meme_bps: bps::new(0), quote_bps: bps::new(0) },
        coins: table::new(ctx),
    }
}

// === Test-Only Functions ===

#[test_only]
/// Runs eventless publication initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Creates unshared zero-share policy for focused and vault tests.
public fun new_for_testing(ctx: &mut TxContext): LpFeePolicy {
    new(ctx)
}

#[test_only]
/// Returns the number of stored per-coin pairs for type-key and cleanup tests.
public fun coin_count_for_testing(self: &LpFeePolicy): u64 {
    self.coins.length()
}

#[test_only]
/// Returns the Meme and Quote shares of every coin without its own pair.
public fun default_shares_for_testing(self: &LpFeePolicy): (Bps, Bps) {
    (self.defaults.meme_bps, self.defaults.quote_bps)
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::{blast_fun_domain::BLAST_FUN_DOMAIN, bps::{Self, Bps}};

use blast_fun_migrators::{blast_events, package_version::PackageVersion as MigratorsVersion};

use std::type_name::{Self, TypeName};

use sui::table::{Self, Table};
