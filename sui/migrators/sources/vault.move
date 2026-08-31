/// Shared fee accounting and sealed dynamic-object custody for migration positions.
module blast_fun_migrators::vault;

use blast_fun::{
    acl::AdminWitness,
    creator_authority::CreatorCap,
    fees::{Self, FeeLedger},
    runtime_config::RuntimeConfig,
};
use blast_fun_migrators::events;
use sui::{balance::{Self, Balance}, coin::Coin, dynamic_object_field};

use fun dynamic_object_field::add as UID.add_dynamic_object_field;
use fun dynamic_object_field::borrow_mut as UID.dynamic_object_field_mut;
use fun dynamic_object_field::exists as UID.has_dynamic_object_field;

// === Constants ===

const EWrongVenue: u64 = 0;
const ENothingClaimable: u64 = 1;

// === Public Structs ===

/// A sealed field name that binds one venue position type to one vault.
public struct PositionKey<phantom Venue>() has copy, drop, store;

/// Shared per-launch custody for one position, protocol residuals, and LP fees.
public struct LpVault<phantom Meme, phantom Quote> has key {
    id: UID,
    pool_id: ID,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    fee_ledger: FeeLedger<Meme, Quote>,
}

// === Public Functions ===

/// Drains only creator-owned LP fees as composable coins.
public fun claim_creator_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    creator_cap: &CreatorCap<Meme>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
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
        self.id.to_inner(),
        meme_amount,
        quote_amount,
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
    );

    (meme, quote)
}

/// Drains protocol-owned migration residuals and LP fees under a live admin witness.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    admin_witness: &AdminWitness,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    let (
        protocol_meme_fee_total,
        _,
        protocol_quote_fee_total,
        _,
    ) = self.fee_ledger.totals();
    let has_protocol_fees =
        protocol_meme_fee_total > 0 || protocol_quote_fee_total > 0;
    let has_residuals =
        self.protocol_meme_residual.value() > 0
            || self.protocol_quote_residual.value() > 0;
    assert!(
        has_protocol_fees || has_residuals,
        ENothingClaimable,
    );

    let (mut meme, mut quote) = if (has_protocol_fees) {
        let (meme_fees, quote_fees) =
            self.fee_ledger.claim_protocol_fees(admin_witness, ctx);
        (meme_fees.into_balance(), quote_fees.into_balance())
    } else {
        (balance::zero(), balance::zero())
    };
    meme.join(self.protocol_meme_residual.withdraw_all());
    quote.join(self.protocol_quote_residual.withdraw_all());
    let meme = meme.into_coin(ctx);
    let quote = quote.into_coin(ctx);
    let meme_amount = meme.value();
    let quote_amount = quote.value();
    let (
        protocol_meme_fee_total,
        creator_meme_fee_total,
        protocol_quote_fee_total,
        creator_quote_fee_total,
    ) = self.fee_ledger.totals();

    events::protocol_fees_claimed<Meme, Quote>(
        self.id.to_inner(),
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
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
): ID {
    let position_id = object::id(&position);
    let mut vault = LpVault {
        id: object::new(ctx),
        pool_id,
        protocol_meme_residual,
        protocol_quote_residual,
        fee_ledger: fees::new<Meme, Quote>(),
    };
    let vault_id = vault.id.to_inner();
    vault.id.add_dynamic_object_field(PositionKey<Venue>(), position);
    transfer::share_object(vault);
    events::vault_created<Meme, Quote, Venue>(
        vault_id,
        pool_id,
        position_id,
    );
    vault_id
}

/// Mutably borrows the venue position without providing a removal path.
public(package) fun position_mut<
    Meme,
    Quote,
    Venue,
    Position: key + store,
>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
): &mut Position {
    assert!(
        self.id.has_dynamic_object_field(PositionKey<Venue>()),
        EWrongVenue,
    );

    self.id.dynamic_object_field_mut(PositionKey<Venue>())
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
        self.id.has_dynamic_object_field(PositionKey<Venue>()),
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
        self.id.to_inner(),
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
