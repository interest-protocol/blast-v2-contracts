// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Asset-generic accounting for received fees, distinct from trading principal.
module blast_market_maker::fee_ledger;

// === Public Types ===

public struct FeeAllocation has copy, drop, store { keep: u64, share: u64, reinvest: u64 }
public struct FeeLedger<phantom Asset> has store {
    available: Balance<Asset>,
    reserved: Balance<Asset>,
    accumulator: u256,
    distribution_remainder: u256,
}
public struct FeeClaim has drop, store { paid_index: u256, scaled_remainder: u256 }

// === Public Functions ===

/// Zero allocations are useful when allocating only the other asset in a vault.
public fun allocation(keep: u64, share: u64, reinvest: u64): FeeAllocation {
    assert!(
        (keep as u128) + (share as u128) + (reinvest as u128) <= (U64_MAX as u128),
        EAllocationOverflow,
    );
    FeeAllocation { keep, share, reinvest }
}

public fun amounts(self: &FeeAllocation): (u64, u64, u64) { (self.keep, self.share, self.reinvest) }

public fun is_empty(self: &FeeAllocation): bool {
    self.keep == 0 && self.share == 0 && self.reinvest == 0
}

// === Package Functions ===

public(package) fun new<Asset>(): FeeLedger<Asset> {
    FeeLedger {
        available: balance::zero(),
        reserved: balance::zero(),
        accumulator: 0,
        distribution_remainder: 0,
    }
}

public(package) fun new_claim(): FeeClaim { FeeClaim { paid_index: 0, scaled_remainder: 0 } }

public(package) fun available<Asset>(self: &FeeLedger<Asset>): u64 { self.available.value() }

public(package) fun reserved<Asset>(self: &FeeLedger<Asset>): u64 { self.reserved.value() }

public(package) fun credit<Asset>(self: &mut FeeLedger<Asset>, fees: Balance<Asset>) {
    self.available.join(fees);
}

/// The caller must freeze weights before permitting allocation; there is no reserve sweep.
public(package) fun allocate<Asset>(
    self: &mut FeeLedger<Asset>,
    allocation: FeeAllocation,
    total_weight: u64,
): (Balance<Asset>, Balance<Asset>) {
    let FeeAllocation { keep, share, reinvest } = allocation;
    assert!(keep + share + reinvest <= self.available.value(), EInsufficientFees);
    assert!(share == 0 || total_weight > 0, ENoBackers);
    if (share > 0) {
        let (accumulator, remainder) = market_maker_math::accrue(
            self.accumulator,
            self.distribution_remainder,
            share,
            total_weight,
        );
        self.accumulator = accumulator;
        self.distribution_remainder = remainder;
        self.reserved.join(self.available.split(share));
    };
    (self.available.split(keep), self.available.split(reinvest))
}

/// Presale allocations reserve rewards without creating any wrapper contribution index.
public(package) fun allocate_rewards<Asset>(
    self: &mut FeeLedger<Asset>,
    allocation: FeeAllocation,
): (Balance<Asset>, Balance<Asset>) {
    let FeeAllocation { keep, share, reinvest } = allocation;
    assert!(keep + share + reinvest <= self.available.value(), EInsufficientFees);

    self.reserved.join(self.available.split(share));
    (self.available.split(keep), self.available.split(reinvest))
}

/// Only the vault's presale round funding path consumes this reserve.
public(package) fun take_rewards<Asset>(self: &mut FeeLedger<Asset>, amount: u64): Balance<Asset> {
    self.reserved.split(amount)
}

public(package) fun claimable<Asset>(self: &FeeLedger<Asset>, claim: &FeeClaim, weight: u64): u64 {
    let (amount, _) = market_maker_math::claim(
        self.accumulator,
        claim.paid_index,
        claim.scaled_remainder,
        weight,
    );
    amount
}

public(package) fun claim<Asset>(
    self: &mut FeeLedger<Asset>,
    claim: &mut FeeClaim,
    weight: u64,
): Balance<Asset> {
    let (amount, remainder) = market_maker_math::claim(
        self.accumulator,
        claim.paid_index,
        claim.scaled_remainder,
        weight,
    );
    claim.paid_index = self.accumulator;
    claim.scaled_remainder = remainder;
    self.reserved.split(amount)
}

// === Constants ===

const U64_MAX: u64 = 18_446_744_073_709_551_615;

// === Errors ===

#[error(code = 0)]
const EAllocationOverflow: vector<u8> = b"The total fee allocation must fit u64.";
#[error(code = 1)]
const EInsufficientFees: vector<u8> = b"Only unallocated received fees may be allocated.";
#[error(code = 2)]
const ENoBackers: vector<u8> = b"Sharing requires a frozen, nonempty backer set.";

// === Imports ===

use blast_market_maker::market_maker_math;
use sui::balance::{Self, Balance};
