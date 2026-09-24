// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the configuration's abort location.
#[allow(lint(abort_without_constant))]
/// Settings every curve trade and creator claim reads live.
module blast_fun::runtime_config;

// === Public Types ===

/// The backend key that signs account claims (empty when none may), and Blast's share of every
/// curve trade fee.
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

/// Replaces the account-claim signer; an empty key revokes it.
public fun set_creator_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    signer_public_key: vector<u8>,
) {
    package_version.assert_current();
    assert!(
        signer_public_key.is_empty()
            || signer_public_key.length() == constants::ed25519_public_key_length!(),
        blast_fun::errors::invalid_creator_claim_public_key!(),
    );
    assert!(signer_public_key != self.creator_claim_signer_public_key, blast_fun::errors::unchanged!());

    self.creator_claim_signer_public_key = signer_public_key;

    events::creator_claim_signer_set(signer_public_key);
}

public fun set_protocol_fee_share(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<BLAST_FUN_DOMAIN>,
    protocol_fee_share_bps: Bps,
) {
    package_version.assert_current();
    assert!(protocol_fee_share_bps != self.protocol_fee_share_bps, blast_fun::errors::unchanged!());

    self.protocol_fee_share_bps = protocol_fee_share_bps;

    events::protocol_fee_share_changed(protocol_fee_share_bps.value());
}

// === Package Functions ===

public(package) fun creator_claim_signer(self: &RuntimeConfig): &vector<u8> {
    &self.creator_claim_signer_public_key
}

public(package) fun protocol_fee_share(self: &RuntimeConfig): Bps {
    self.protocol_fee_share_bps
}

// === Private Functions ===

fun new(ctx: &mut TxContext): RuntimeConfig {
    RuntimeConfig {
        id: object::new(ctx),
        creator_claim_signer_public_key: vector[],
        protocol_fee_share_bps: bps::new(0),
    }
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_disabled_for_testing(ctx: &mut TxContext): RuntimeConfig {
    new(ctx)
}

#[test_only]
public fun new_for_testing(signer_public_key: vector<u8>, ctx: &mut TxContext): RuntimeConfig {
    RuntimeConfig {
        id: object::new(ctx),
        creator_claim_signer_public_key: signer_public_key,
        protocol_fee_share_bps: bps::new(0),
    }
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_fun::{
    blast_fun_domain::BLAST_FUN_DOMAIN,
    bps::{Self, Bps},
    constants,
    events,
    package_version::PackageVersion,
};
