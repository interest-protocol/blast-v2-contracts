// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the configuration's abort location.
#[allow(lint(abort_without_constant))]
/// Blast's fee on presales: its rate, which each new presale snapshots, and where it is paid.
module blast_presale::presale_config;

// === Public Types ===

/// Singleton fee policy for presales.
public struct BlastPresaleConfig has key {
    id: UID,
    fee_bps: u64,
    fee_destination: address,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(BlastPresaleConfig {
        id: object::new(ctx),
        fee_bps: 0,
        fee_destination: ctx.sender(),
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

// === Package Functions ===

public(package) fun fee_bps(self: &BlastPresaleConfig): u64 {
    self.fee_bps
}

public(package) fun fee_destination(self: &BlastPresaleConfig): address {
    self.fee_destination
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
