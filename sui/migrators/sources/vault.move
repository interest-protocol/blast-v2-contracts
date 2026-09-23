// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Sealed dynamic-object custody for migration positions and their protocol residuals.
module blast_fun_migrators::vault;

// === Errors ===

#[error(code = 0)]
const EWrongVenue: vector<u8> = b"Venue witness must match the vault's attached position marker.";

#[error(code = 1)]
const ENothingClaimable: vector<u8> = b"No protocol migration residuals are available to claim.";

#[error(code = 2)]
const EVaultAlreadyInitialized: vector<u8> = b"Prepared vault must not already contain a pool.";

// === Public Types ===

/// A sealed field name that binds one venue position type to one vault.
public struct PositionKey<phantom Venue>() has copy, drop, store;

/// Shared per-launch custody for one position and its protocol migration residuals.
///
/// The vault holds no LP fees: the adapter collects the bound position and settles every
/// collection through the launch's `FeeRouter` in the same transaction.
public struct LpVault<phantom Meme, phantom Quote> has key {
    id: UID,
    pool_id: ID,
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
}

// === Public Functions ===

/// Claims the protocol-owned migration residuals under a live admin witness.
public fun claim_protocol_fees<Meme, Quote>(
    self: &mut LpVault<Meme, Quote>,
    migrators_version: &MigratorsVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    ctx: &mut TxContext,
): (Coin<Meme>, Coin<Quote>) {
    migrators_version.assert_current();
    assert!(
        self.protocol_meme_residual.value() > 0 || self.protocol_quote_residual.value() > 0,
        ENothingClaimable,
    );

    let meme = self.protocol_meme_residual.withdraw_all().into_coin(ctx);
    let quote = self.protocol_quote_residual.withdraw_all().into_coin(ctx);

    blast_events::protocol_fees_claimed<Meme, Quote>(
        self.id.to_inner(),
        ctx.sender(),
        meme.value(),
        quote.value(),
    );

    (meme, quote)
}

/// Returns the venue pool the attached position belongs to.
public fun pool_id<Meme, Quote>(self: &LpVault<Meme, Quote>): ID {
    self.pool_id
}

/// Returns the ID of the position attached under `Venue`, or none for any other venue.
public fun position_id<Meme, Quote, Venue>(self: &LpVault<Meme, Quote>): Option<ID> {
    dynamic_object_field::id(&self.id, PositionKey<Venue>())
}

/// Returns the unclaimed protocol-owned Meme residual that migration left in the vault.
public fun protocol_meme_residual<Meme, Quote>(self: &LpVault<Meme, Quote>): u64 {
    self.protocol_meme_residual.value()
}

/// Returns the unclaimed protocol-owned Quote residual that migration left in the vault.
public fun protocol_quote_residual<Meme, Quote>(self: &LpVault<Meme, Quote>): u64 {
    self.protocol_quote_residual.value()
}

// === Package Functions ===

/// Creates unshared vault state whose address can be bound into an external position.
public(package) fun prepare<Meme, Quote>(
    protocol_meme_residual: Balance<Meme>,
    protocol_quote_residual: Balance<Quote>,
    ctx: &mut TxContext,
): LpVault<Meme, Quote> {
    LpVault {
        id: object::new(ctx),
        pool_id: object::id_from_address(@0x0),
        protocol_meme_residual,
        protocol_quote_residual,
    }
}

/// Borrows the exact residual balances that will remain in the shared vault.
public(package) fun pending_residuals<Meme, Quote>(
    self: &LpVault<Meme, Quote>,
): (&Balance<Meme>, &Balance<Quote>) {
    (&self.protocol_meme_residual, &self.protocol_quote_residual)
}

/// Attaches the exact venue position while retaining owned vault construction state.
public(package) fun attach<Meme, Quote, Venue, Position: key + store>(
    self: &mut LpVault<Meme, Quote>,
    _venue: &Venue,
    pool_id: ID,
    position: Position,
) {
    assert!(
        self.pool_id == object::id_from_address(@0x0),
        EVaultAlreadyInitialized,
    );
    self.pool_id = pool_id;
    let position_id = object::id(&position);
    self.id.add_dynamic_object_field(PositionKey<Venue>(), position);
    blast_events::vault_created<Meme, Quote, Venue>(
        self.id.to_inner(),
        pool_id,
        position_id,
    );
}

/// Shares a fully attached vault; attachment already emitted the custody record.
public(package) fun share<Meme, Quote, Venue>(self: LpVault<Meme, Quote>, _venue: &Venue) {
    assert!(
        self.id.has_dynamic_object_field(PositionKey<Venue>()),
        EWrongVenue,
    );
    transfer::share_object(self);
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

/// Immutably borrows the exact attached venue position for atomic settlement validation.
public(package) fun position<
    Meme,
    Quote,
    Venue,
    Position: key + store,
>(
    self: &LpVault<Meme, Quote>,
    _venue: &Venue,
): &Position {
    assert!(
        self.id.has_dynamic_object_field(PositionKey<Venue>()),
        EWrongVenue,
    );

    self.id.dynamic_object_field(PositionKey<Venue>())
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::blast_fun_domain::BLAST_FUN_DOMAIN;

use blast_fun_migrators::{blast_events, package_version::PackageVersion as MigratorsVersion};

use sui::{balance::Balance, coin::Coin, dynamic_object_field};

use fun dynamic_object_field::add as UID.add_dynamic_object_field;

use fun dynamic_object_field::borrow as UID.dynamic_object_field;

use fun dynamic_object_field::borrow_mut as UID.dynamic_object_field_mut;

use fun dynamic_object_field::exists as UID.has_dynamic_object_field;
