// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast's fees on presales: a share of every successful raise, of every token supply, and of
/// every collected LP fee.
///
/// Each presale snapshots the rates when it is created. Until the sale's window starts, the
/// `FeeAdmin` may change that sale's rates, so its economics are fixed before commitments open;
/// after migration it may change the sale's LP-fee rates on its vault. Every payout reads the
/// current destination.
module blast_presale::fee_policy;

// === Public Types ===

/// Shared singleton holding the rates new presales snapshot and the address paid Blast's fees.
public struct FeePolicy has key {
    id: UID,
    destination: address,
    fees: ProtocolFees,
}

/// Blast's rates, in BPS: of the accepted raise, of the token supply, and of each collected
/// LP-fee asset.
public struct ProtocolFees has copy, drop, store {
    raise_bps: Bps,
    token_bps: Bps,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Sets the rates presales created afterward snapshot; existing presales keep theirs.
public fun set_fees(
    self: &mut FeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    raise_bps: Bps,
    token_bps: Bps,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
) {
    package_version.assert_current();

    let fees = protocol_fees(raise_bps, token_bps, lp_fee_meme_bps, lp_fee_quote_bps);
    assert!(fees != self.fees, EFeesUnchanged);

    self.fees = fees;

    event::emit(FeesChanged {
        raise_bps: raise_bps.value(),
        token_bps: token_bps.value(),
        lp_fee_meme_bps: lp_fee_meme_bps.value(),
        lp_fee_quote_bps: lp_fee_quote_bps.value(),
    });
}

/// Redirects every later protocol payout, including those of existing presales.
public fun set_destination(
    self: &mut FeePolicy,
    package_version: &PackageVersion,
    _: &AdminWitness<TreasuryAdmin>,
    destination: address,
) {
    package_version.assert_current();

    assert!(destination != @0x0 && destination != self.destination, EInvalidDestination);

    self.destination = destination;

    event::emit(DestinationChanged { destination });
}

// === Package Functions ===

/// Blast's rates, within the bounds every presale can apportion: a raise share below 10,000 BPS
/// and a token share of at most 9,998.
public(package) fun protocol_fees(
    raise_bps: Bps,
    token_bps: Bps,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
): ProtocolFees {
    assert!(
        raise_bps.value() < bps::denominator() && token_bps.value() <= MAX_TOKEN_BPS,
        EInvalidFees,
    );

    ProtocolFees { raise_bps, token_bps, lp_fee_meme_bps, lp_fee_quote_bps }
}

public(package) fun fees(self: &FeePolicy): ProtocolFees {
    self.fees
}

public(package) fun destination(self: &FeePolicy): address {
    self.destination
}

public(package) fun raise_bps(self: &ProtocolFees): Bps {
    self.raise_bps
}

public(package) fun token_bps(self: &ProtocolFees): Bps {
    self.token_bps
}

public(package) fun lp_fee_meme_bps(self: &ProtocolFees): Bps {
    self.lp_fee_meme_bps
}

public(package) fun lp_fee_quote_bps(self: &ProtocolFees): Bps {
    self.lp_fee_quote_bps
}

/// Returns these rates with both LP-fee rates replaced.
public(package) fun with_lp_fees(
    mut self: ProtocolFees,
    lp_fee_meme_bps: Bps,
    lp_fee_quote_bps: Bps,
): ProtocolFees {
    self.lp_fee_meme_bps = lp_fee_meme_bps;
    self.lp_fee_quote_bps = lp_fee_quote_bps;
    self
}

// === Private Functions ===

fun new(ctx: &mut TxContext): FeePolicy {
    FeePolicy {
        id: object::new(ctx),
        destination: ctx.sender(),
        fees: ProtocolFees {
            raise_bps: bps::new(0),
            token_bps: bps::new(0),
            lp_fee_meme_bps: bps::new(0),
            lp_fee_quote_bps: bps::new(0),
        },
    }
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): FeePolicy {
    new(ctx)
}

#[test_only]
public fun protocol_fees_for_testing(
    raise_bps: u64,
    token_bps: u64,
    lp_fee_meme_bps: u64,
    lp_fee_quote_bps: u64,
): ProtocolFees {
    ProtocolFees {
        raise_bps: bps::new(raise_bps),
        token_bps: bps::new(token_bps),
        lp_fee_meme_bps: bps::new(lp_fee_meme_bps),
        lp_fee_quote_bps: bps::new(lp_fee_quote_bps),
    }
}

#[test_only]
public fun destroy_for_testing(self: FeePolicy) {
    let FeePolicy { id, destination: _, fees: _ } = self;
    id.delete();
}

#[test_only]
public fun fees_changed_fields(event: &FeesChanged): (u64, u64, u64, u64) {
    (event.raise_bps, event.token_bps, event.lp_fee_meme_bps, event.lp_fee_quote_bps)
}

#[test_only]
public fun destination_changed_fields(event: &DestinationChanged): address {
    event.destination
}

// === Events ===

/// New presales snapshot these rates.
public struct FeesChanged has copy, drop {
    raise_bps: u64,
    token_bps: u64,
    lp_fee_meme_bps: u64,
    lp_fee_quote_bps: u64,
}

/// Every later protocol payout goes to `destination`.
public struct DestinationChanged has copy, drop {
    destination: address,
}

// === Constants ===

/// The sale and LP allocations each keep at least one BPS of the supply.
const MAX_TOKEN_BPS: u64 = 9_998;

// === Errors ===

#[error(code = 0)]
const EInvalidFees: vector<u8> = b"Blast's raise share must be below 10,000 BPS and its token share at most 9,998.";

#[error(code = 1)]
const EFeesUnchanged: vector<u8> = b"A fee update must change the stored rates.";

#[error(code = 2)]
const EInvalidDestination: vector<u8> = b"The protocol destination must be a new nonzero address.";

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_presale::{
    blast_presale_domain::{FeeAdmin, TreasuryAdmin},
    blast_presale_package::PackageVersion,
    bps::{Self, Bps}
};

use sui::event;
