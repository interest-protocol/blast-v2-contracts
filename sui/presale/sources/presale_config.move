// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the configuration's abort location.
#[allow(lint(abort_without_constant))]
/// Blast's fee on presales, its rate, which each new presale snapshots, and where it is paid; and
/// the adapters a presale may hand its liquidity to.
module blast_presale::presale_config;

// === Public Types ===

/// Singleton presale policy.
public struct BlastPresaleConfig has key {
    id: UID,
    fee_bps: u64,
    fee_destination: address,
    /// Witness types of the admitted liquidity adapters.
    adapters: VecSet<TypeName>,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(BlastPresaleConfig {
        id: object::new(ctx),
        fee_bps: 0,
        fee_destination: ctx.sender(),
        adapters: vec_set::empty(),
    });
}

// === Public Functions ===

/// Sets Blast's fee on the Quote raised by presales created from now on.
public fun set_fee_bps(
    self: &mut BlastPresaleConfig,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness<BLAST_PRESALE_DOMAIN>,
    fee_bps: u64,
) {
    package_version.assert_current();
    admin_witness.assert_role(blast_presale_domain::fee_admin_role());
    assert!(fee_bps <= constants::max_fee_bps!(), blast_presale::errors::invalid_fee_bps!());
    assert!(fee_bps != self.fee_bps, blast_presale::errors::unchanged!());

    self.fee_bps = fee_bps;

    events::fee_set(fee_bps);
}

/// Sets where Blast's fee is paid at every later finalization.
public fun set_fee_destination(
    self: &mut BlastPresaleConfig,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness<BLAST_PRESALE_DOMAIN>,
    destination: address,
) {
    package_version.assert_current();
    admin_witness.assert_role(blast_presale_domain::treasury_admin_role());
    assert!(destination != @0x0, blast_presale::errors::invalid_destination!());
    assert!(destination != self.fee_destination, blast_presale::errors::unchanged!());

    self.fee_destination = destination;

    events::fee_destination_set(destination);
}

/// Admits or removes the liquidity adapter that constructs `Adapter` for presales created from
/// now on.
public fun set_adapter_allowed<Adapter>(
    self: &mut BlastPresaleConfig,
    package_version: &PackageVersion,
    admin_witness: &AdminWitness<BLAST_PRESALE_DOMAIN>,
    allowed: bool,
) {
    package_version.assert_current();
    admin_witness.assert_role(blast_presale_domain::adapter_admin_role());
    let adapter = type_name::with_original_ids<Adapter>();
    assert!(self.adapters.contains(&adapter) != allowed, blast_presale::errors::unchanged!());

    if (allowed) self.adapters.insert(adapter) else self.adapters.remove(&adapter);

    events::adapter_set(adapter, allowed);
}

// === Package Functions ===

public(package) fun fee_bps(self: &BlastPresaleConfig): u64 {
    self.fee_bps
}

public(package) fun fee_destination(self: &BlastPresaleConfig): address {
    self.fee_destination
}

public(package) fun is_adapter_allowed(self: &BlastPresaleConfig, adapter: TypeName): bool {
    self.adapters.contains(&adapter)
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_presale::{
    blast_presale_domain::{Self, BLAST_PRESALE_DOMAIN},
    constants,
    events,
    package_version::PackageVersion,
};

use std::type_name::{Self, TypeName};

use sui::vec_set::{Self, VecSet};
