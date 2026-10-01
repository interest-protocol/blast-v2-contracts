// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast's fees on presales: a share of every successful raise, of every token supply, and of
/// every collected LP fee.
///
/// Each presale snapshots the rates when it is created, so a sale's economics are fixed before
/// commitments open. Every payout reads the current destination.
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
    raise_bps: u64,
    token_bps: u64,
    lp_meme_bps: u64,
    lp_quote_bps: u64,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Sets the rates presales created afterward snapshot; existing presales keep theirs.
public fun set_fees(
    self: &mut FeePolicy,
    _: &AdminWitness<FeeAdmin>,
    raise_bps: u64,
    token_bps: u64,
    lp_meme_bps: u64,
    lp_quote_bps: u64,
) {
    assert!(
        raise_bps < BASIS_POINTS
            && token_bps <= MAX_TOKEN_BPS
            && lp_meme_bps <= BASIS_POINTS
            && lp_quote_bps <= BASIS_POINTS,
        EInvalidFees,
    );
    let fees = ProtocolFees { raise_bps, token_bps, lp_meme_bps, lp_quote_bps };
    assert!(fees != self.fees, EFeesUnchanged);

    self.fees = fees;

    event::emit(FeesChanged { raise_bps, token_bps, lp_meme_bps, lp_quote_bps });
}

/// Redirects every later protocol payout, including those of existing presales.
public fun set_destination(
    self: &mut FeePolicy,
    _: &AdminWitness<TreasuryAdmin>,
    destination: address,
) {
    assert!(destination != @0x0 && destination != self.destination, EInvalidDestination);

    self.destination = destination;

    event::emit(DestinationChanged { destination });
}

// === Package Functions ===

public(package) fun fees(self: &FeePolicy): ProtocolFees {
    self.fees
}

public(package) fun destination(self: &FeePolicy): address {
    self.destination
}

public(package) fun raise_bps(self: &ProtocolFees): u64 {
    self.raise_bps
}

public(package) fun token_bps(self: &ProtocolFees): u64 {
    self.token_bps
}

public(package) fun lp_meme_bps(self: &ProtocolFees): u64 {
    self.lp_meme_bps
}

public(package) fun lp_quote_bps(self: &ProtocolFees): u64 {
    self.lp_quote_bps
}

// === Private Functions ===

fun new(ctx: &mut TxContext): FeePolicy {
    FeePolicy {
        id: object::new(ctx),
        destination: ctx.sender(),
        fees: ProtocolFees { raise_bps: 0, token_bps: 0, lp_meme_bps: 0, lp_quote_bps: 0 },
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
    lp_meme_bps: u64,
    lp_quote_bps: u64,
): ProtocolFees {
    ProtocolFees { raise_bps, token_bps, lp_meme_bps, lp_quote_bps }
}

#[test_only]
public fun destroy_for_testing(self: FeePolicy) {
    let FeePolicy { id, destination: _, fees: _ } = self;
    id.delete();
}

#[test_only]
public fun fees_changed_fields(event: &FeesChanged): (u64, u64, u64, u64) {
    (event.raise_bps, event.token_bps, event.lp_meme_bps, event.lp_quote_bps)
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
    lp_meme_bps: u64,
    lp_quote_bps: u64,
}

/// Every later protocol payout goes to `destination`.
public struct DestinationChanged has copy, drop {
    destination: address,
}

// === Constants ===

const BASIS_POINTS: u64 = 10_000;

/// The sale and LP allocations each keep at least one BPS of the supply.
const MAX_TOKEN_BPS: u64 = 9_998;

// === Errors ===

#[error(code = 0)]
const EInvalidFees: vector<u8> = b"Blast's raise share must be below 10,000 BPS, its token share at most 9,998, and each LP-fee share at most 10,000.";

#[error(code = 1)]
const EFeesUnchanged: vector<u8> = b"A fee update must change the stored rates.";

#[error(code = 2)]
const EInvalidDestination: vector<u8> = b"The protocol destination must be a new nonzero address.";

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_presale::blast_presale_domain::{FeeAdmin, TreasuryAdmin};

use sui::event;
