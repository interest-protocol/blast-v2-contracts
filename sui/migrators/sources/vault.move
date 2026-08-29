/// Shared fee accounting and sealed dynamic-object custody for migration positions.
module blast_fun_migrators::vault;

use blast_fun::{
    acl::AdminWitness,
    creator_authority::CreatorCap,
    fees::{Self, FeeLedger},
};
use sui::{coin::Coin, dynamic_object_field};

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
    self.fee_ledger.claim_creator_fees(creator_cap, ctx)
}

/// Drains only protocol-owned LP fees under a live core admin witness.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    admin_witness: &AdminWitness,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    self.fee_ledger.claim_protocol_fees(admin_witness, ctx)
}

// === Package Functions ===

/// Creates one vault and attaches its only venue position as a child object.
public(package) fun new<Meme, Quote, Venue, Position: key + store>(
    pool_id: ID,
    position: Position,
    ctx: &mut TxContext,
) {
    let mut vault = LpVault {
        id: object::new(ctx),
        pool_id,
        fee_ledger: fees::new<Meme, Quote>(),
    };
    dynamic_object_field::add<PositionKey<Venue>, Position>(
        &mut vault.id,
        PositionKey(),
        position,
    );
    transfer::share_object(vault);
}

/// Borrows the venue position without exposing it outside this package.
public(package) fun borrow_position<
    Meme,
    Quote,
    Venue,
    Position: key + store,
>(self: &LpVault<Meme, Quote>): &Position {
    dynamic_object_field::borrow<PositionKey<Venue>, Position>(
        &self.id,
        PositionKey(),
    )
}

/// Mutably borrows the venue position without providing a removal path.
public(package) fun borrow_position_mut<
    Meme,
    Quote,
    Venue,
    Position: key + store,
>(self: &mut LpVault<Meme, Quote>): &mut Position {
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

/// Borrows the normalized fee ledger for a completed venue collection.
public(package) fun fee_ledger_mut<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
): &mut FeeLedger<Meme, Quote> {
    &mut self.fee_ledger
}
