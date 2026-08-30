/// Shared fee accounting and sealed dynamic-object custody for migration positions.
module blast_fun_migrators::vault;

use blast_fun::{
    acl::AdminWitness,
    creator_authority::CreatorCap,
    fees::{Self, FeeLedger},
    runtime_config::RuntimeConfig,
};
use blast_fun_migrators::events;
use sui::{balance::Balance, coin::Coin, dynamic_object_field};

// === Constants ===

const EWrongVenue: u64 = 0;

// === Public Structs ===

/// A sealed field name that binds one venue position type to one vault.
public struct PositionKey<phantom Venue>() has copy, drop, store;

/// Shared per-launch custody and normalized Meme/Quote fee accounting.
public struct LpVault<phantom Meme, phantom Quote> has key {
    id: UID,
    pool_id: ID,
    fee_ledger: FeeLedger<Meme, Quote>,
}

// === Public Functions ===

/// Drains only creator-owned LP fees as composable coins.
public fun claim_creator_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    creator_cap: &CreatorCap<Meme>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    let vault_id = object::id(self);
    let (meme, quote) = self.fee_ledger.claim_creator_fees(creator_cap, ctx);
    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let (
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
    ) = self.fee_ledger.totals();

    events::creator_fees_claimed<Meme, Quote>(
        vault_id,
        meme_amount,
        quote_amount,
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
    );

    (meme, quote)
}

/// Drains only protocol-owned LP fees under a live core admin witness.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    admin_witness: &AdminWitness,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    let vault_id = object::id(self);
    let (meme, quote) =
        self.fee_ledger.claim_protocol_fees(admin_witness, ctx);
    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let (
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
    ) = self.fee_ledger.totals();

    events::protocol_fees_claimed<Meme, Quote>(
        vault_id,
        meme_amount,
        quote_amount,
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
    );

    (meme, quote)
}

// === Package Functions ===

/// Creates and shares one vault with its only venue position as a child object.
public(package) fun new<Meme, Quote, Venue: drop, Position: key + store>(
    _venue: Venue,
    pool_id: ID,
    position: Position,
    ctx: &mut TxContext,
): ID {
    let position_id = object::id(&position);
    let mut vault = LpVault {
        id: object::new(ctx),
        pool_id,
        fee_ledger: fees::new<Meme, Quote>(),
    };
    let vault_id = object::id(&vault);
    dynamic_object_field::add<PositionKey<Venue>, Position>(
        &mut vault.id,
        PositionKey(),
        position,
    );
    transfer::share_object(vault);
    events::vault_created<Meme, Quote, Venue>(
        vault_id,
        pool_id,
        position_id,
    );
    vault_id
}

/// Mutably borrows the venue position without providing a removal path.
public(package) fun borrow_position_mut<
    Meme,
    Quote,
    Venue,
    Position: key + store,
>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
): &mut Position {
    assert!(
        dynamic_object_field::exists(&self.id, PositionKey<Venue>()),
        EWrongVenue,
    );

    dynamic_object_field::borrow_mut<PositionKey<Venue>, Position>(
        &mut self.id,
        PositionKey(),
    )
}

/// Returns the venue pool associated with the locked position.
public(package) fun pool_id<Meme, Quote>(
    self: &LpVault<Meme, Quote>,
): ID {
    self.pool_id
}

/// Accrues one completed venue collection and emits its replay snapshot.
public(package) fun accrue_fees<Meme, Quote, Venue>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
    position_id: ID,
    meme_fee: Balance<Meme>,
    quote_fee: Balance<Quote>,
    principal_liquidity_before: u128,
    principal_liquidity_after: u128,
    runtime_config: &RuntimeConfig,
    _: &TxContext,
) {
    assert!(
        dynamic_object_field::exists(&self.id, PositionKey<Venue>()),
        EWrongVenue,
    );

    let gross_meme_fee = meme_fee.value();
    let gross_quote_fee = quote_fee.value();
    let protocol_fee_share_bps = runtime_config.protocol_fee_share_bps();
    let (
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
    ) = self.fee_ledger.accrue_from_runtime(
        meme_fee,
        quote_fee,
        runtime_config,
    );

    events::lp_fees_collected<Meme, Quote, Venue>(
        object::id(self),
        self.pool_id,
        position_id,
        gross_meme_fee,
        gross_quote_fee,
        protocol_fee_share_bps,
        protocol_meme_fee_delta,
        creator_meme_fee_delta,
        protocol_quote_fee_delta,
        creator_quote_fee_delta,
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
        principal_liquidity_before,
        principal_liquidity_after,
    );
}
