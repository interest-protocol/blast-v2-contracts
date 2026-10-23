// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Custody of this protocol's earned assets, separate from every market maker's principal and claims.
module blast_market_maker::protocol_treasury;

// === Public Types ===

public struct BlastMarketMakerTreasury has key { id: UID, payout: address }

public struct TreasuryBalanceKey<phantom Asset>() has copy, drop, store;

// === Public Functions ===

public fun set_payout(
    self: &mut BlastMarketMakerTreasury,
    _: &AdminWitness<TreasuryAdmin>,
    version: &PackageVersion,
    destination: address,
) {
    self.assert_canonical(version);
    assert!(destination != @0x0, EZeroDestination);
    assert!(self.payout != destination, EDestinationUnchanged);
    let previous = self.payout;

    self.payout = destination;
    sui::event::emit(BlastTreasuryDestinationChanged {
        treasury_id: self.id.to_inner(),
        previous,
        destination,
    });
}

/// Withdraws only already-earned treasury assets, to the configured destination.
public fun pay_earned<Asset>(
    self: &mut BlastMarketMakerTreasury,
    _: &AdminWitness<TreasuryAdmin>,
    version: &PackageVersion,
    amount: u64,
    ctx: &mut TxContext,
) {
    self.assert_canonical(version);
    assert!(amount > 0, EZeroWithdrawal);
    let key = TreasuryBalanceKey<Asset>();
    assert!(self.id.has_dynamic_field(key), EInsufficientTreasuryBalance);
    let balance = self.id.borrow_dynamic_field_mut<_, Balance<Asset>>(key);
    assert!(balance.value() >= amount, EInsufficientTreasuryBalance);
    let destination = self.payout;

    transfer::public_transfer(balance.split(amount).into_coin(ctx), destination);
    sui::event::emit(BlastTreasuryWithdrawn<Asset> {
        treasury_id: self.id.to_inner(),
        amount,
        destination,
    });
}

// === Package Functions ===

public(package) fun new(ctx: &mut TxContext): BlastMarketMakerTreasury {
    BlastMarketMakerTreasury { id: object::new(ctx), payout: ctx.sender() }
}

public(package) fun share(self: BlastMarketMakerTreasury) { transfer::share_object(self); }

public(package) fun assert_canonical(self: &BlastMarketMakerTreasury, version: &PackageVersion) {
    version.assert_treasury(self.id.to_inner());
}

public(package) fun credit<Asset>(
    self: &mut BlastMarketMakerTreasury,
    version: &PackageVersion,
    vault_id: ID,
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
        amount,
    });
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
    previous: address,
    destination: address,
}
public struct BlastTreasuryCredited<phantom Asset> has copy, drop {
    treasury_id: ID,
    vault_id: ID,
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
