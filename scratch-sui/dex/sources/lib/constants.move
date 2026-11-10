// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// The version and pause domains shared by the DEX's stateful entry points.
module blast_fun_dex::constants;

// === Package Constants ===

/// The package version this bytecode serves.
macro public(package) fun version(): u64 { 1 }

/// Stops pool creation, hook registration on new pools, finalization and sharing.
macro public(package) fun create_pause_bit(): u8 { 1 }

/// Stops both directions of swapping.
macro public(package) fun swap_pause_bit(): u8 { 2 }

/// Stops adding liquidity and donating to existing pools.
macro public(package) fun liquidity_in_pause_bit(): u8 { 4 }

/// All supported DEX pause flags. Removing liquidity never requires unpausing.
macro public(package) fun valid_pause_bits(): u8 {
    blast_fun_dex::constants::create_pause_bit!()
        | blast_fun_dex::constants::swap_pause_bit!()
        | blast_fun_dex::constants::liquidity_in_pause_bit!()
}
