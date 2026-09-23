// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// Self-custodial native stake waiting to enter blast custody after activation.
module blast_sui::deposit_receipt;

// === Public Structs ===

/// An owned blastSUI deposit that has not entered vault custody or coin supply.
///
/// `key` is the only ability. The receipt cannot be generically transferred,
/// wrapped, or deleted. Callers can compose with the returned object, then use
/// `keep` to place it in the transaction sender's account.
public struct BlastSuiDepositReceipt has key {
    id: UID,
    vault_id: ID,
    staked_sui: StakedSui,
}

// === Public Functions ===

/// Keeps a returned receipt in the transaction sender's account.
public fun keep(self: BlastSuiDepositReceipt, ctx: &mut TxContext) {
    transfer::transfer(self, ctx.sender());
}

/// Cancels an unclaimed deposit and returns its native principal plus any earned rewards.
///
/// This exit deliberately needs neither the shared vault nor its package-version
/// object. Native withdrawal works before activation and after validator removal.
public fun cancel(
    self: BlastSuiDepositReceipt,
    system_state: &mut SuiSystemState,
    ctx: &mut TxContext,
): Coin<SUI> {
    let BlastSuiDepositReceipt { id, vault_id, staked_sui } = self;
    let receipt_id = id.to_inner();
    let principal_sui = staked_sui.amount();
    let sui_out = system_state.request_withdraw_stake_non_entry(staked_sui, ctx).into_coin(ctx);
    id.delete();
    events::blast_sui_deposit_cancelled(
        receipt_id,
        vault_id,
        principal_sui,
        sui_out.value(),
    );

    sui_out
}

/// Creates the receipt Display V2 and returns its update cap for package custody.
///
/// This is a permissionless deployment step. The system registry derives one
/// canonical display per type and rejects every later creation attempt.
public fun create_display(
    package_version: &PackageVersion,
    registry: &mut DisplayRegistry,
    ctx: &mut TxContext,
): DisplayCap<BlastSuiDepositReceipt> {
    package_version.assert_current();
    let (mut display, cap) = display_registry::new<BlastSuiDepositReceipt>(
        registry,
        internal::permit<BlastSuiDepositReceipt>(),
        ctx,
    );
    display.configure(&cap);

    display.share();
    cap
}

// === Package Functions ===

/// Wraps native stake in a key-only receipt without transferring it.
public(package) fun new(
    vault_id: ID,
    staked_sui: StakedSui,
    ctx: &mut TxContext,
): BlastSuiDepositReceipt {
    BlastSuiDepositReceipt {
        id: object::new(ctx),
        vault_id,
        staked_sui,
    }
}

/// Returns the receipt object identifier.
public(package) fun id(self: &BlastSuiDepositReceipt): ID {
    self.id.to_inner()
}

/// Returns the immutable native principal delegated by this receipt.
public(package) fun principal_sui(self: &BlastSuiDepositReceipt): u64 {
    self.staked_sui.amount()
}

/// Returns the first epoch in which this receipt can enter blast custody.
public(package) fun activation_epoch(self: &BlastSuiDepositReceipt): u64 {
    self.staked_sui.activation_epoch()
}

/// Returns the immutable validator-pool identifier bound to this receipt.
public(package) fun pool_id(self: &BlastSuiDepositReceipt): ID {
    self.staked_sui.pool_id()
}

/// Validates the receipt's immutable vault and validator-pool binding.
public(package) fun assert_binding(
    self: &BlastSuiDepositReceipt,
    expected_vault_id: ID,
    expected_pool_id: ID,
) {
    assert!(self.vault_id == expected_vault_id, blast_sui::errors::wrong_receipt_vault!());
    assert!(self.staked_sui.pool_id() == expected_pool_id, blast_sui::errors::wrong_receipt_pool!());
}

/// Deletes a validated receipt wrapper and releases its native stake.
public(package) fun destroy(self: BlastSuiDepositReceipt): StakedSui {
    let BlastSuiDepositReceipt { id, vault_id: _, staked_sui } = self;
    id.delete();

    staked_sui
}

// === Private Functions ===

/// Applies the canonical wallet metadata to a new Display V2 object.
fun configure_display(
    display: &mut Display<BlastSuiDepositReceipt>,
    cap: &DisplayCap<BlastSuiDepositReceipt>,
) {
    let (fields, values) = display_metadata();
    fields.zip_do!(values, |field, value| display.set(cap, field, value));
}

fun display_metadata(): (vector<String>, vector<String>) {
    (
        vector[
            b"name".to_string(),
            b"description".to_string(),
            b"image_url".to_string(),
            b"link".to_string(),
        ],
        vector[
            b"blastSUI Deposit Receipt".to_string(),
            b"SUI delegated to the Blast validator. Claim blastSUI after activation, or cancel for SUI at any time.".to_string(),
            b"https://www.blast.fun/art/generated/blast-sui-mark-gpt-v4.png".to_string(),
            b"https://www.blast.fun".to_string(),
        ],
    )
}

// === Test-Only Functions ===

#[test_only]
public fun display_metadata_for_testing(): (vector<String>, vector<String>) {
    display_metadata()
}

#[test_only]
public fun fields_for_testing(self: &BlastSuiDepositReceipt): (ID, ID, ID, u64, u64) {
    (
        self.id.to_inner(),
        self.vault_id,
        self.staked_sui.pool_id(),
        self.staked_sui.amount(),
        self.staked_sui.activation_epoch(),
    )
}

// === Imports ===

use blast_sui::{events, package_version::PackageVersion};

use std::string::String;

use sui::{
    coin::Coin,
    display_registry::{Self, Display, DisplayCap, DisplayRegistry},
    sui::SUI,
};

use sui_system::{
    staking_pool::StakedSui,
    sui_system::SuiSystemState,
};

use fun configure_display as Display.configure;
