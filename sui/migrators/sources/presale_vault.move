// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Locked custody for a presale's pool position. Every fee collection pays Blast's live LP share to
/// the protocol destination and the rest to the presale's creator.
module blast_fun_migrators::presale_vault;

// === Errors ===

#[error(code = 0)]
const EZeroLiquidity: vector<u8> = b"Presale position must hold liquidity.";

// === Public Types ===

/// A sealed field name that binds one venue position type to one presale vault.
public struct PositionKey<phantom Venue>() has copy, drop, store;

/// Shared custody for one presale's pool position, with no removal path.
public struct BlastPresaleVault<phantom Token, phantom Quote> has key {
    id: UID,
    pool_id: ID,
    creator: address,
}

// === Package Functions ===

/// Locks `position`, holding `liquidity` in pool `pool_id`, under the venue's sealed key in a new
/// shared vault for `presale`'s creator, and pays the venue's residuals to that creator.
public(package) fun create<Token, Quote, Venue, Position: key + store>(
    presale: &BlastPresale<Token, Quote>,
    _: &Venue,
    pool_id: ID,
    position: Position,
    liquidity: u128,
    residual_token: Balance<Token>,
    residual_quote: Balance<Quote>,
    ctx: &mut TxContext,
) {
    assert!(liquidity > 0, EZeroLiquidity);
    let position_id = object::id(&position);
    let creator = presale.creator();
    let (token_value, quote_value) = (residual_token.value(), residual_quote.value());

    let mut vault = BlastPresaleVault<Token, Quote> { id: object::new(ctx), pool_id, creator };
    vault.id.add_dynamic_object_field(PositionKey<Venue>(), position);
    send(residual_token, creator, ctx);
    send(residual_quote, creator, ctx);

    blast_events::presale_vault_created<Token, Quote, Venue>(
        vault.id.to_inner(),
        object::id(presale),
        pool_id,
        position_id,
        creator,
        token_value,
        quote_value,
        liquidity,
    );

    transfer::share_object(vault);
}

/// Mutably borrows the venue position without providing a removal path. Another venue's key
/// finds no field, so the borrow aborts.
public(package) fun position_mut<Token, Quote, Venue, Position: key + store>(
    self: &mut BlastPresaleVault<Token, Quote>,
    _: &Venue,
): &mut Position {
    self.id.dynamic_object_field_mut(PositionKey<Venue>())
}

public(package) fun pool_id<Token, Quote>(self: &BlastPresaleVault<Token, Quote>): ID {
    self.pool_id
}

/// Pays one collection of the position's fees: Blast's live share, rounded up, to the protocol
/// destination and the rest to the creator. A zero collection moves nothing and emits nothing.
public(package) fun pay_fees<Token, Quote>(
    self: &BlastPresaleVault<Token, Quote>,
    policy: &LpFeePolicy,
    mut token: Balance<Token>,
    mut quote: Balance<Quote>,
    ctx: &mut TxContext,
) {
    let (gross_token, gross_quote) = (token.value(), quote.value());
    let (token_share, quote_share) = policy.shares<Token>();
    let protocol_token = token_share.apply_up(gross_token);
    let protocol_quote = quote_share.apply_up(gross_quote);
    let protocol_destination = policy.protocol_destination();

    send(token.split(protocol_token), protocol_destination, ctx);
    send(quote.split(protocol_quote), protocol_destination, ctx);
    send(token, self.creator, ctx);
    send(quote, self.creator, ctx);

    if (gross_token == 0 && gross_quote == 0) return;
    blast_events::presale_fees_collected(
        self.id.to_inner(),
        gross_token,
        gross_quote,
        protocol_destination,
        protocol_token,
        protocol_quote,
    );
}

// === Private Functions ===

/// Sends `balance` to `recipient` as a coin, or destroys it when empty.
fun send<T>(balance: Balance<T>, recipient: address, ctx: &mut TxContext) {
    if (balance.value() == 0) balance.destroy_zero()
    else transfer::public_transfer(balance.into_coin(ctx), recipient);
}

// === Test-Only Functions ===

#[test_only]
public fun creator_for_testing<Token, Quote>(self: &BlastPresaleVault<Token, Quote>): address {
    self.creator
}

#[test_only]
public fun position_id_for_testing<Token, Quote, Venue>(self: &BlastPresaleVault<Token, Quote>): ID {
    dynamic_object_field::id(&self.id, PositionKey<Venue>()).destroy_some()
}

// === Imports ===

use blast_fun_migrators::{blast_events, lp_fee_policy::LpFeePolicy};

use blast_presale::presale::BlastPresale;

use sui::{balance::Balance, dynamic_object_field};

use fun dynamic_object_field::add as UID.add_dynamic_object_field;

use fun dynamic_object_field::borrow_mut as UID.dynamic_object_field_mut;
