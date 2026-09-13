// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one append-only registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
module blast_fun::fees;

use blast_admin::acl::AdminWitness;
use blast_fun::{
    bps::Bps,
    creator_authority::CreatorCap,
    launchpad_domain::LAUNCHPAD_DOMAIN,
    runtime_config::RuntimeConfig,
};
use sui::{balance::{Self, Balance}, coin::Coin};

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

/// Splits and accrues externally collected fees using the current live protocol share.
public fun accrue_from_runtime<Meme, Quote>(
    self: &mut FeeLedger<Meme, Quote>,
    meme_fee: Balance<Meme>,
    quote_fee: Balance<Quote>,
    runtime_config: &RuntimeConfig,
): (u64, u64, u64, u64) {
    self.accrue(
        meme_fee,
        quote_fee,
        runtime_config.protocol_fee_share(),
    )
}

/// Returns whether either protocol-owned balance contains fees.
public fun has_protocol_fees<Meme, Quote>(self: &FeeLedger<Meme, Quote>): bool {
    self.protocol_meme.value() > 0 || self.protocol_quote.value() > 0
}

/// Drains both creator balances into composable coins.
public fun claim_creator_fees<Meme, Quote>(
    self: &mut FeeLedger<Meme, Quote>,
    _: &CreatorCap<Meme>,
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

/// Drains both protocol balances after an active administrator signs in.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut FeeLedger<Meme, Quote>,
    _: &AdminWitness<LAUNCHPAD_DOMAIN>,
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

/// Splits and accrues the meme and quote fees produced by one completed curve operation.
///
/// `protocol_fee_share_bps` is the current validated value from the shared runtime
/// configuration. The enclosing launch operation must read it for every trade.
///
/// Returns the protocol and creator deltas for each asset.
public(package) fun accrue<Meme, Quote>(
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
