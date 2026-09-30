// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Presale-token stand-in. The harness publishes this package once per presale, so every sale
/// has its own one-time-witness currency and zero-supply `TreasuryCap`.
module ptb_presale_token::token;

// === Public Types ===

public struct TOKEN has drop {}

// === Private Initialization ===

/// Registers the currency with an unknown supply and hands its capabilities to the publisher.
fun init(otw: TOKEN, ctx: &mut TxContext) {
    let (initializer, treasury_cap) = coin_registry::new_currency_with_otw(
        otw,
        9,
        b"PTB".to_string(),
        b"PTB presale".to_string(),
        b"".to_string(),
        b"".to_string(),
        ctx,
    );
    let metadata_cap = initializer.finalize(ctx);

    transfer::public_transfer(treasury_cap, ctx.sender());
    transfer::public_transfer(metadata_cap, ctx.sender());
}

// === Imports ===

use sui::coin_registry;
