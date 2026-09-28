// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the configuration's abort location.
#[allow(lint(abort_without_constant))]
/// Settings every launch creation, curve trade and creator claim reads live.
module blast_fun::runtime_config;

// === Public Types ===

/// The backend key that signs account claims (empty when none may), Blast's share of every curve
/// trade fee, the SUI every launch pays at creation, and the Blast partners new launches may name.
public struct RuntimeConfig has key {
    id: UID,
    creator_claim_signer_public_key: vector<u8>,
    protocol_fee_share_bps: Bps,
    /// In MIST.
    creation_fee: u64,
}

/// Dynamic-field key of a Blast partner new launches may name. Its value is the time the partner
/// stops being accepted: `u64::MAX` until Blast removes it.
public struct PartnerKey(ID) has copy, drop, store;

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Replaces the account-claim signer; an empty key revokes it.
public fun set_creator_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<ClaimSignerAdmin>,
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
    _: &AdminWitness<FeeAdmin>,
    protocol_fee_share_bps: Bps,
) {
    package_version.assert_current();
    assert!(protocol_fee_share_bps != self.protocol_fee_share_bps, blast_fun::errors::unchanged!());

    self.protocol_fee_share_bps = protocol_fee_share_bps;

    events::protocol_fee_share_changed(protocol_fee_share_bps.value());
}

/// Sets the SUI, in MIST, every launch created afterward pays.
public fun set_creation_fee(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    creation_fee: u64,
) {
    package_version.assert_current();
    assert!(creation_fee != self.creation_fee, blast_fun::errors::unchanged!());

    self.creation_fee = creation_fee;

    events::creation_fee_changed(creation_fee);
}

/// Lets new launches name `partner`, at once. Adding a partner whose removal is pending cancels
/// the removal; adding a removed partner accepts it again.
public fun add_partner(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    partner: &Partner,
) {
    package_version.assert_current();
    let partner_id = object::id(partner);
    let key = PartnerKey(partner_id);

    if (self.id.has_dynamic_field(key)) {
        let accepted_until_ms: &mut u64 = self.id.dynamic_field_mut(key);
        assert!(*accepted_until_ms != std::u64::max_value!(), blast_fun::errors::unchanged!());
        *accepted_until_ms = std::u64::max_value!();
    } else {
        self.id.add_dynamic_field(key, std::u64::max_value!());
    };

    events::partner_added(partner_id);
}

/// Stops new launches naming `partner` after the notice Blast gives for every change to a
/// partner, `blast_partners::delay_ms()`. Launches that already name it keep paying it.
public fun remove_partner(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<FeeAdmin>,
    partner: &Partner,
    clock: &Clock,
) {
    package_version.assert_current();
    let partner_id = object::id(partner);
    let now_ms = clock.timestamp_ms();
    self.assert_partner(partner_id, now_ms);
    let accepted_until_ms = now_ms + partners::delay_ms();

    let current: &mut u64 = self.id.dynamic_field_mut(PartnerKey(partner_id));
    assert!(*current == std::u64::max_value!(), blast_fun::errors::unchanged!());
    *current = accepted_until_ms;

    events::partner_removed(partner_id, accepted_until_ms);
}

// === Package Functions ===

public(package) fun creator_claim_signer(self: &RuntimeConfig): &vector<u8> {
    &self.creator_claim_signer_public_key
}

public(package) fun protocol_fee_share(self: &RuntimeConfig): Bps {
    self.protocol_fee_share_bps
}

public(package) fun creation_fee(self: &RuntimeConfig): u64 {
    self.creation_fee
}

/// Aborts unless new launches may name `partner_id` at `now_ms`.
public(package) fun assert_partner(self: &RuntimeConfig, partner_id: ID, now_ms: u64) {
    let key = PartnerKey(partner_id);

    assert!(self.id.has_dynamic_field(key), blast_fun::errors::partner_not_accepted!());
    let accepted_until_ms: u64 = *dynamic_field::borrow(&self.id, key);
    assert!(now_ms < accepted_until_ms, blast_fun::errors::partner_not_accepted!());
}

// === Private Functions ===

fun new(ctx: &mut TxContext): RuntimeConfig {
    RuntimeConfig {
        id: object::new(ctx),
        creator_claim_signer_public_key: vector[],
        protocol_fee_share_bps: bps::new(0),
        creation_fee: 0,
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
        creation_fee: 0,
    }
}

// === Imports ===

use blast_admin::blast_acl::AdminWitness;

use blast_fun::{
    blast_fun_domain::{ClaimSignerAdmin, FeeAdmin},
    bps::{Self, Bps},
    constants,
    events,
    package_version::PackageVersion,
};

use blast_partners::blast_partners::{Self as partners, Partner};

use sui::{clock::Clock, dynamic_field};

use fun dynamic_field::add as UID.add_dynamic_field;

use fun dynamic_field::borrow_mut as UID.dynamic_field_mut;

use fun dynamic_field::exists as UID.has_dynamic_field;
