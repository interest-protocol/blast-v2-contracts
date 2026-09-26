// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the tranche's abort location.
#[allow(lint(abort_without_constant))]
/// One fixed-price tier of a presale: `tokens` offered for `quote` in total within its own window,
/// public or whitelisted, filled first come or pro rata, and optionally vested.
module blast_presale::tranche;

// === Public Types ===

/// How a tranche fills when more Quote arrives than it raises.
public enum Allocation has copy, drop, store {
    /// Commits fill in arrival order until the tranche's Quote is reached.
    FirstCome,
    /// Every commit counts; at the end each fills in the same proportion and the rest is refunded.
    ProRata,
}

/// A Merkle root over `(index, address, max_quote)` leaves, and how many leaves it has.
public struct Whitelist has copy, drop, store {
    root: vector<u8>,
    leaves: u64,
}

/// One tranche. Its price is `quote / tokens`.
public struct Tranche has copy, drop, store {
    tokens: u64,
    quote: u64,
    start_ms: u64,
    end_ms: u64,
    allocation: Allocation,
    /// Most Quote one address may commit to a public tranche; zero for no limit. A whitelist leaf
    /// sets each address's limit instead.
    wallet_cap: u64,
    whitelist: Option<Whitelist>,
    /// Linear vesting of the tranche's tokens from the presale's claim time; zero for none.
    vesting_ms: u64,
    /// Quote accepted so far.
    committed: u64,
}

// === Public Functions ===

public fun first_come(): Allocation {
    Allocation::FirstCome
}

public fun pro_rata(): Allocation {
    Allocation::ProRata
}

/// A whitelist of `leaves` entries under `root`.
public fun whitelist(root: vector<u8>, leaves: u64): Whitelist {
    assert!(
        root.length() == constants::digest_length!() && leaves > 0,
        blast_presale::errors::invalid_whitelist!(),
    );

    Whitelist { root, leaves }
}

/// A tranche selling `tokens` for `quote` in total from `start_ms` until `end_ms`.
public fun new(
    tokens: u64,
    quote: u64,
    start_ms: u64,
    end_ms: u64,
    allocation: Allocation,
    wallet_cap: u64,
    whitelist: Option<Whitelist>,
    vesting_ms: u64,
): Tranche {
    assert!(
        tokens > 0 && quote > 0 && start_ms < end_ms,
        blast_presale::errors::invalid_tranche!(),
    );

    Tranche {
        tokens,
        quote,
        start_ms,
        end_ms,
        allocation,
        wallet_cap,
        whitelist,
        vesting_ms,
        committed: 0,
    }
}

// === Package Functions ===

public(package) fun tokens(self: &Tranche): u64 {
    self.tokens
}

public(package) fun quote(self: &Tranche): u64 {
    self.quote
}

public(package) fun end_ms(self: &Tranche): u64 {
    self.end_ms
}

public(package) fun wallet_cap(self: &Tranche): u64 {
    self.wallet_cap
}

public(package) fun committed(self: &Tranche): u64 {
    self.committed
}

public(package) fun is_whitelisted(self: &Tranche): bool {
    self.whitelist.is_some()
}

/// Whether the tranche accepts commits at `now_ms`: from its start, until its end.
public(package) fun is_open(self: &Tranche, now_ms: u64): bool {
    self.start_ms <= now_ms && now_ms < self.end_ms
}

/// Whether `account`, allowed `max_quote`, is leaf `index` of the tranche's whitelist.
public(package) fun is_listed(
    self: &Tranche,
    index: u64,
    account: address,
    max_quote: u64,
    proof: &vector<vector<u8>>,
): bool {
    let whitelist = self.whitelist.borrow();

    index < whitelist.leaves
        && merkle::verify(
            whitelist.root,
            merkle::leaf(index, account, max_quote),
            index,
            whitelist.leaves,
            proof,
        )
}

/// Accepts up to `amount` Quote from an address that has committed `position` under `cap` (zero
/// for no limit) and returns what it accepted: a first-come tranche stops at its Quote, and either
/// kind stops at the cap.
public(package) fun accept(self: &mut Tranche, amount: u64, position: u64, cap: u64): u64 {
    let mut accepted = amount;
    if (self.allocation == Allocation::FirstCome) {
        assert!(self.committed < self.quote, blast_presale::errors::tranche_sold_out!());
        accepted = accepted.min(self.quote - self.committed);
    };
    if (cap > 0) {
        assert!(position < cap, blast_presale::errors::wallet_cap_reached!());
        accepted = accepted.min(cap - position);
    };
    self.committed = self.committed + accepted;

    accepted
}

/// The Quote the tranche raised: what it accepted, at most its Quote.
public(package) fun raised(self: &Tranche): u64 {
    self.committed.min(self.quote)
}

/// The tokens the tranche sold, rounded down.
public(package) fun sold(self: &Tranche): u64 {
    if (self.committed >= self.quote) self.tokens
    else self.committed.mul_div(self.tokens, self.quote)
}

/// The tokens and Quote refund a position of `committed` Quote is owed, both rounded down. An
/// oversubscribed tranche, which only pro rata allows, fills every commit in the proportion
/// `quote / committed` and refunds the rest.
public(package) fun owed(self: &Tranche, committed: u64): (u64, u64) {
    if (self.committed <= self.quote) (committed.mul_div(self.tokens, self.quote), 0)
    else (
        committed.mul_div(self.tokens, self.committed),
        committed.mul_div(self.committed - self.quote, self.committed),
    )
}

/// How many of `tokens` have vested at `now_ms` for claims opening at `claim_ms`: none before,
/// then linearly over the tranche's vesting period, rounded down.
public(package) fun vested(self: &Tranche, tokens: u64, claim_ms: u64, now_ms: u64): u64 {
    if (now_ms < claim_ms) 0
    else if (now_ms - claim_ms >= self.vesting_ms) tokens
    else tokens.mul_div(now_ms - claim_ms, self.vesting_ms)
}

// === Imports ===

use blast_presale::{constants, merkle};
