// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast ACL-governed LP rates; every existing market maker enforces its own creation-time ceiling.
module blast_market_maker::market_maker_fee_policy;

// === Public Types ===

public struct BlastMarketMakerFeePolicy has key {
    id: UID,
    treasury_id: ID,
    meme_bps: u64,
    quote_bps: u64,
}

// === Public Functions ===

public fun set_rates(
    self: &mut BlastMarketMakerFeePolicy,
    _: &AdminWitness<FeeAdmin>,
    version: &PackageVersion,
    meme_bps: u64,
    quote_bps: u64,
) {
    self.assert_canonical(version);
    assert!(meme_bps <= MAX_LOCAL_LP_BPS && quote_bps <= MAX_LOCAL_LP_BPS, ERateAboveMaximum);
    assert!(meme_bps != self.meme_bps || quote_bps != self.quote_bps, ERatesUnchanged);
    let previous_meme_bps = self.meme_bps;
    let previous_quote_bps = self.quote_bps;

    self.meme_bps = meme_bps;
    self.quote_bps = quote_bps;
    sui::event::emit(BlastLpRatesChanged {
        policy_id: self.id.to_inner(),
        previous_meme_bps,
        previous_quote_bps,
        meme_bps,
        quote_bps,
    });
}

// === Package Functions ===

public(package) fun new(treasury_id: ID, ctx: &mut TxContext): BlastMarketMakerFeePolicy {
    BlastMarketMakerFeePolicy { id: object::new(ctx), treasury_id, meme_bps: 0, quote_bps: 0 }
}

public(package) fun share(self: BlastMarketMakerFeePolicy) { transfer::share_object(self); }

public(package) fun maximum_lp_bps(): u64 { MAX_LOCAL_LP_BPS }

public(package) fun capped_rates(
    self: &BlastMarketMakerFeePolicy,
    version: &PackageVersion,
    maximum: u64,
): (u64, u64) {
    self.assert_canonical(version);

    (self.meme_bps.min(maximum), self.quote_bps.min(maximum))
}

public(package) fun assert_canonical(self: &BlastMarketMakerFeePolicy, version: &PackageVersion) {
    version.assert_policy(self.id.to_inner());
    version.assert_treasury(self.treasury_id);
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(treasury_id: ID, ctx: &mut TxContext): BlastMarketMakerFeePolicy {
    new(treasury_id, ctx)
}

#[test_only]
public fun share_for_testing(self: BlastMarketMakerFeePolicy) { self.share(); }

// === Events ===

public struct BlastLpRatesChanged has copy, drop {
    policy_id: ID,
    previous_meme_bps: u64,
    previous_quote_bps: u64,
    meme_bps: u64,
    quote_bps: u64,
}

// === Constants ===

const MAX_LOCAL_LP_BPS: u64 = 2_000;

// === Errors ===

#[error(code = 0)]
const ERateAboveMaximum: vector<u8> = b"The LP rate exceeds this build's admitted maximum.";
#[error(code = 1)]
const ERatesUnchanged: vector<u8> = b"At least one LP rate must change.";

// === Imports ===

use blast_admin::blast_acl::AdminWitness;
use blast_market_maker::{
    blast_market_maker_domain::FeeAdmin,
    package_version::BlastMarketMakerVersion as PackageVersion,
};
