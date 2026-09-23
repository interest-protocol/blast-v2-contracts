// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one append-only registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
/// Small live protocol settings read by bonding-curve trades and creator claims.
///
/// Fees collected from migrated liquidity use `blast_fun_migrators::lp_fee_policy::LpFeePolicy` instead.
module blast_fun::runtime_config;

// === Public Structs ===

/// Shared singleton for immediately effective protocol-wide runtime settings.
public struct RuntimeConfig has key {
    id: UID,
    creator_claim_signer_public_key: vector<u8>,
    protocol_fee_share_bps: Bps,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Sets the current creator-claim signer, replacing any previously configured key.
public fun set_creator_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    signer_public_key: vector<u8>,
) {
    package_version.assert_current();
    validate_creator_claim_public_key(&signer_public_key);
    assert!(
        self.creator_claim_signer_public_key != signer_public_key,
        blast_fun::errors::creator_claim_signer_unchanged!(),
    );

    self.creator_claim_signer_public_key = signer_public_key;

    events::creator_claim_signer_set(self.creator_claim_signer_public_key);
}

/// Revokes the creator-claim signer immediately by clearing the only active key.
public fun revoke_creator_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
) {
    package_version.assert_current();
    self.assert_creator_claim_active();

    self.creator_claim_signer_public_key = vector[];

    events::creator_claim_signer_revoked();
}

/// Updates the live protocol share used by every subsequent bonding-curve trade-fee accrual.
public fun set_protocol_fee_share(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    protocol_fee_share_bps: Bps,
) {
    package_version.assert_current();
    assert!(
        protocol_fee_share_bps != self.protocol_fee_share_bps,
        blast_fun::errors::protocol_fee_share_unchanged!(),
    );

    self.protocol_fee_share_bps = protocol_fee_share_bps;

    events::protocol_fee_share_changed(protocol_fee_share_bps.value());
}

// === Package Functions ===

/// Rejects use of the account claim path while no backend signer is authorized.
public(package) fun assert_creator_claim_active(self: &RuntimeConfig) {
    assert!(
        !self.creator_claim_signer_public_key.is_empty(),
        blast_fun::errors::creator_claim_signer_inactive!(),
    );
}

/// Asserts that `signature` came from the one currently authorized Blast backend key.
public(package) fun assert_creator_claim_signature(
    self: &RuntimeConfig,
    message: &vector<u8>,
    signature: &vector<u8>,
) {
    assert!(
        sui::ed25519::ed25519_verify(
            signature,
            &self.creator_claim_signer_public_key,
            message,
        ),
        blast_fun::errors::invalid_creator_claim_signature!(),
    );
}

/// Returns the validated live protocol share for package-owned fee arithmetic.
public(package) fun protocol_fee_share(self: &RuntimeConfig): Bps {
    self.protocol_fee_share_bps
}

// === Private Functions ===

/// Starts with no creator-claim signer and zero protocol fee share.
fun new(ctx: &mut TxContext): RuntimeConfig {
    RuntimeConfig {
        id: object::new(ctx),
        creator_claim_signer_public_key: vector[],
        protocol_fee_share_bps: bps::new(0),
    }
}

fun validate_creator_claim_public_key(signer_public_key: &vector<u8>) {
    assert!(
        signer_public_key.length() == constants::ed25519_public_key_length!(),
        blast_fun::errors::invalid_creator_claim_public_key!(),
    );
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Creates disabled unshared runtime state for focused tests.
public fun new_disabled_for_testing(ctx: &mut TxContext): RuntimeConfig {
    new(ctx)
}

#[test_only]
/// Creates active unshared runtime state for focused signature tests.
public fun new_for_testing(
    signer_public_key: vector<u8>,
    ctx: &mut TxContext,
): RuntimeConfig {
    validate_creator_claim_public_key(&signer_public_key);

    RuntimeConfig {
        id: object::new(ctx),
        creator_claim_signer_public_key: signer_public_key,
        protocol_fee_share_bps: bps::new(0),
    }
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::{
    bps::{Self, Bps},
    constants,
    events,
    blast_fun_domain::BLAST_FUN_DOMAIN,
    package_version::PackageVersion,
};
