// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// A worthless Quote coin for the presale mainnet end-to-end run. Anyone may mint any amount.
module blast_presale_testkit::test_sui;

// === Public Types ===

/// The test coin's type, registered by `create`. It is never constructed.
public struct TEST_SUI has key {
    id: UID,
}

/// Shared mint authority open to every caller.
public struct Faucet has key {
    id: UID,
    treasury_cap: TreasuryCap<TEST_SUI>,
}

// === Public Functions ===

/// Registers TEST_SUI in the Coin Registry and shares its faucet. The registry admits a type
/// once, so a second call aborts.
public fun create(registry: &mut CoinRegistry, ctx: &mut TxContext) {
    let (initializer, treasury_cap) = coin_registry::new_currency<TEST_SUI>(
        registry,
        DECIMALS,
        b"TSUI".to_string(),
        b"Test SUI".to_string(),
        b"Worthless Quote for Blast presale mainnet tests.".to_string(),
        b"".to_string(),
        ctx,
    );

    initializer.finalize_and_delete_metadata_cap(ctx);
    transfer::share_object(Faucet { id: object::new(ctx), treasury_cap });
}

/// Mints `amount` TEST_SUI to the caller's transaction.
public fun mint(self: &mut Faucet, amount: u64, ctx: &mut TxContext): Coin<TEST_SUI> {
    self.treasury_cap.mint(amount, ctx)
}

// === Constants ===

/// SUI's decimals, so test amounts read like SUI amounts.
const DECIMALS: u8 = 9;

// === Imports ===

use sui::{coin::{Coin, TreasuryCap}, coin_registry::{Self, CoinRegistry}};
