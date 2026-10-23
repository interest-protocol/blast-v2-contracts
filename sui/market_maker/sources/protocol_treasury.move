// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Custody of this protocol's earned assets, separate from every market maker's principal and claims.
module blast_market_maker::protocol_treasury;

// === Public Types ===

public struct BlastMarketMakerTreasury has key { id: UID, payout: Option<address> }

public struct TreasuryBalanceKey<phantom Asset>() has copy, drop, store;

/// Records the reason each already-earned balance entered the treasury.
public enum RevenueSource has copy, drop, store {
    LocalLp,
    CurveRaise,
}

// === Public Functions ===

public fun set_payout(
    self: &mut BlastMarketMakerTreasury,
    version: &PackageVersion,
    _: &AdminWitness<TreasuryAdmin>,
    destination: address,
) {
    self.assert_canonical(version);
    assert!(destination != @0x0, EZeroDestination);
    assert!(!self.payout.contains(&destination), EDestinationUnchanged);
    let previous = self.payout;

    self.payout = option::some(destination);
    sui::event::emit(BlastTreasuryDestinationChanged {
        treasury_id: self.id.to_inner(),
        previous,
        destination,
    });
}

/// Withdraws only already-earned treasury assets, to the configured destination.
public fun withdraw_earned<Asset>(
    self: &mut BlastMarketMakerTreasury,
    version: &PackageVersion,
    _: &AdminWitness<TreasuryAdmin>,
    amount: u64,
    ctx: &mut TxContext,
) {
    self.assert_canonical(version);
    assert!(amount > 0, EZeroWithdrawal);
    assert!(self.payout.is_some(), EUnconfiguredTreasury);
    let key = TreasuryBalanceKey<Asset>();
    assert!(self.id.has_dynamic_field(key), EInsufficientTreasuryBalance);
    let balance = self.id.borrow_dynamic_field_mut<_, Balance<Asset>>(key);
    assert!(balance.value() >= amount, EInsufficientTreasuryBalance);
    let destination = *self.payout.borrow();

    transfer::public_transfer(balance.split(amount).into_coin(ctx), destination);
    sui::event::emit(BlastTreasuryWithdrawn<Asset> {
        treasury_id: self.id.to_inner(),
        amount,
        destination,
    });
}

// === Package Functions ===

public(package) fun curve_raise(): RevenueSource { RevenueSource::CurveRaise }

public(package) fun local_lp(): RevenueSource { RevenueSource::LocalLp }

public(package) fun new(ctx: &mut TxContext): BlastMarketMakerTreasury {
    BlastMarketMakerTreasury { id: object::new(ctx), payout: option::none() }
}

public(package) fun share(self: BlastMarketMakerTreasury) { transfer::share_object(self); }

public(package) fun assert_configured(self: &BlastMarketMakerTreasury, version: &PackageVersion) {
    self.assert_canonical(version);
    assert!(self.payout.is_some(), EUnconfiguredTreasury);
}

public(package) fun credit<Asset>(
    self: &mut BlastMarketMakerTreasury,
    version: &PackageVersion,
    vault_id: ID,
    source: RevenueSource,
    balance: Balance<Asset>,
) {
    self.assert_canonical(version);
    let amount = balance.value();
    if (amount == 0) return balance.destroy_zero();
    let key = TreasuryBalanceKey<Asset>();

    if (self.id.has_dynamic_field(key)) {
        self.id.borrow_dynamic_field_mut<_, Balance<Asset>>(key).join(balance);
    } else {
        self.id.add_dynamic_field(key, balance);
    };
    sui::event::emit(BlastTreasuryCredited<Asset> {
        treasury_id: self.id.to_inner(),
        vault_id,
        source,
        amount,
    });
}

// === Private Functions ===

fun assert_canonical(self: &BlastMarketMakerTreasury, version: &PackageVersion) {
    version.assert_treasury(self.id.to_inner());
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): BlastMarketMakerTreasury { new(ctx) }

#[test_only]
public fun balance_for_testing<Asset>(self: &BlastMarketMakerTreasury): u64 {
    let key = TreasuryBalanceKey<Asset>();
    if (self.id.has_dynamic_field(key))
        dynamic_field::borrow<_, Balance<Asset>>(&self.id, key).value() else 0
}

#[test_only]
public fun share_for_testing(self: BlastMarketMakerTreasury) { self.share(); }

// === Events ===

public struct BlastTreasuryDestinationChanged has copy, drop {
    treasury_id: ID,
    previous: Option<address>,
    destination: address,
}
public struct BlastTreasuryCredited<phantom Asset> has copy, drop {
    treasury_id: ID,
    vault_id: ID,
    source: RevenueSource,
    amount: u64,
}
public struct BlastTreasuryWithdrawn<phantom Asset> has copy, drop {
    treasury_id: ID,
    amount: u64,
    destination: address,
}

// === Errors ===

#[error(code = 0)]
const EZeroDestination: vector<u8> = b"The treasury destination must be nonzero.";
#[error(code = 1)]
const EDestinationUnchanged: vector<u8> = b"The treasury destination must change.";
#[error(code = 2)]
const EZeroWithdrawal: vector<u8> = b"A treasury withdrawal must be positive.";
#[error(code = 3)]
const EUnconfiguredTreasury: vector<u8> =
    b"Configure the protocol treasury payout before creating market makers.";
#[error(code = 4)]
const EInsufficientTreasuryBalance: vector<u8> = b"The earned treasury balance is insufficient.";

// === Imports ===

use blast_admin::blast_acl::AdminWitness;
use blast_market_maker::{
    blast_market_maker_domain::TreasuryAdmin,
    package_version::BlastMarketMakerVersion as PackageVersion,
};
use sui::{balance::Balance, dynamic_field};

use fun dynamic_field::add as UID.add_dynamic_field;
use fun dynamic_field::borrow_mut as UID.borrow_dynamic_field_mut;
use fun dynamic_field::exists as UID.has_dynamic_field;
