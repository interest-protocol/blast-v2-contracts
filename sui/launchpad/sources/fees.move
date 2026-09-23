// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one append-only registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
/// Dual-asset protocol and creator fee ledger embedded by launches and LP vaults.
module blast_fun::fees;

// === Public Structs ===

/// Creator and protocol dual-asset fee obligations embedded in one owner object.
public struct FeeLedger<phantom Meme, phantom Quote> has store {
    protocol_meme: Balance<Meme>,
    creator_meme: Balance<Meme>,
    protocol_quote: Balance<Quote>,
    creator_quote: Balance<Quote>,
}

// === Public Functions ===

/// Creates an empty dual-asset fee ledger for a launch or locked LP vault.
public fun new<Meme, Quote>(): FeeLedger<Meme, Quote> {
    FeeLedger {
        protocol_meme: balance::zero(),
        creator_meme: balance::zero(),
        protocol_quote: balance::zero(),
        creator_quote: balance::zero(),
    }
}

/// Splits and accrues the meme and quote fees produced by one completed operation.
///
/// Only the module that embeds the ledger can reach it mutably, so that owner chooses
/// `protocol_fee_share` from its accepted policy on every accrual: trades read
/// `RuntimeConfig` and migrated LP positions read `LpFeePolicy`. Protocol amounts
/// round up and the creator receives the exact remainder.
///
/// Returns the protocol and creator deltas for each asset.
public fun accrue<Meme, Quote>(
    self: &mut FeeLedger<Meme, Quote>,
    mut meme_fee: Balance<Meme>,
    mut quote_fee: Balance<Quote>,
    protocol_fee_share_bps: Bps,
): (u64, u64, u64, u64) {
    let meme_fee_amount = meme_fee.value();
    let quote_fee_amount = quote_fee.value();

    assert!(
        meme_fee_amount > 0 || quote_fee_amount > 0,
        blast_fun::errors::zero_fee_accrual!(),
    );

    let protocol_meme_amount = protocol_fee_share_bps.apply_up(meme_fee_amount);
    let protocol_quote_amount = protocol_fee_share_bps.apply_up(quote_fee_amount);
    let creator_meme_amount = meme_fee_amount - protocol_meme_amount;
    let creator_quote_amount = quote_fee_amount - protocol_quote_amount;

    let protocol_meme = meme_fee.split(protocol_meme_amount);
    let protocol_quote = quote_fee.split(protocol_quote_amount);

    self.protocol_meme.join(protocol_meme);
    self.creator_meme.join(meme_fee);
    self.protocol_quote.join(protocol_quote);
    self.creator_quote.join(quote_fee);

    (
        protocol_meme_amount,
        creator_meme_amount,
        protocol_quote_amount,
        creator_quote_amount,
    )
}

/// Returns whether either protocol-owned balance contains fees.
public fun has_protocol_fees<Meme, Quote>(self: &FeeLedger<Meme, Quote>): bool {
    self.protocol_meme.value() > 0 || self.protocol_quote.value() > 0
}

/// Claims both creator balances as composable coins.
///
/// The object embedding the ledger authorizes the claim with the creator capability it
/// currently honors: `Launch` checks `CurveFeeCap`, post-migration vaults check `LpFeeCap`.
public fun claim_creator_fees<Meme, Quote>(
    self: &mut FeeLedger<Meme, Quote>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    assert!(
        self.creator_meme.value() > 0 || self.creator_quote.value() > 0,
        blast_fun::errors::nothing_accrued!(),
    );

    (
        self.creator_meme.withdraw_all().into_coin(ctx),
        self.creator_quote.withdraw_all().into_coin(ctx),
    )
}

/// Claims both protocol balances after an active administrator signs in.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut FeeLedger<Meme, Quote>,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    assert!(
        self.has_protocol_fees(),
        blast_fun::errors::nothing_accrued!(),
    );

    (
        self.protocol_meme.withdraw_all().into_coin(ctx),
        self.protocol_quote.withdraw_all().into_coin(ctx),
    )
}

// === Package Functions ===

/// Accrues protocol-only graduation revenue at terminal migration.
public(package) fun accrue_protocol_fees<Meme, Quote>(
    self: &mut FeeLedger<Meme, Quote>,
    meme_fee: Balance<Meme>,
    quote_fee: Balance<Quote>,
) {
    self.protocol_meme.join(meme_fee);
    self.protocol_quote.join(quote_fee);
}

// === Test-Only Functions ===

#[test_only]
public fun totals_for_testing<Meme, Quote>(
    self: &FeeLedger<Meme, Quote>,
): (u64, u64, u64, u64) {
    (
        self.protocol_meme.value(),
        self.creator_meme.value(),
        self.protocol_quote.value(),
        self.creator_quote.value(),
    )
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::{bps::Bps, blast_fun_domain::BLAST_FUN_DOMAIN};

use sui::{balance::{Self, Balance}, coin::Coin};
