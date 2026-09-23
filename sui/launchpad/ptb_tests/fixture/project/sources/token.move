// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Generated-Meme stand-in. The harness publishes this package once per launch, so every launch
/// has its own one-time-witness currency and ticket.
module ptb_project::token;

// === Public Types ===

public struct TOKEN has drop {}

// === Private Initialization ===

/// Creates the currency and its launch ticket and hands the ticket to the publisher.
fun init(otw: TOKEN, ctx: &mut TxContext) {
    let ticket = launch_ticket::new(
        otw,
        9,
        b"PTB".to_string(),
        b"PTB migration".to_string(),
        b"".to_string(),
        b"".to_string(),
        creator_authority::new_address(ctx.sender()),
        false,
        0,
        ctx,
    );

    transfer::public_transfer(ticket, ctx.sender());
}

// === Imports ===

use blast_fun::{creator_authority, launch_ticket};
