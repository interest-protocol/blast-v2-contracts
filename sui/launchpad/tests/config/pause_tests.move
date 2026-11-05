// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// The launchpad's unpause: it clears bits through `blast_admin::package_admin` only while every
/// launchpad delay and the core treasury's delay are guarded. Pause-bit arithmetic and the
/// upgrade delay are the generic administration's and are tested there.
module blast_fun::pause_tests;

// === Constants ===

const TREASURY: address = @0x7EA5;

// === Test-Only Types ===

public struct ReleaseFixture {
    version: PackageVersion<BLAST_FUN>,
    package_admin: PackageAdmin<BLAST_FUN>,
    runtime_config: RuntimeConfig,
    launch_config: LaunchConfig,
    treasury: Treasury,
}

// === Tests ===

#[test]
#[expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun stale_version_is_rejected_before_the_delay_gate() {
    let mut f = release_fixture_with(
        runtime_config::new_publication_for_testing(&mut tx_context::dummy()),
    );
    f.version.set_version_for_testing(2);
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
fun unpause_releases_once_every_delay_is_guarded() {
    let mut f = release_fixture();
    f.unpause(constants::valid_pause_bits!());
    assert_eq!(f.version.paused_for_testing(), 0);
    f.end();
}

#[test]
fun unpause_clears_only_the_requested_bits() {
    let mut f = release_fixture();
    f.unpause(constants::create_pause_bit!());
    assert_eq!(
        f.version.paused_for_testing(),
        constants::trading_pause_bit!() | constants::migration_pause_bit!(),
    );
    f.end();
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EUnguardedDelay, location = blast_fun::launch_config)]
fun unpause_rejects_the_zero_publication_delays() {
    let mut f = release_fixture_with(
        runtime_config::new_publication_for_testing(&mut tx_context::dummy()),
    );
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EUnguardedDelay, location = blast_fun::launch_config)]
fun unpause_rejects_a_pending_change_to_a_zero_delay() {
    let mut f = release_fixture().with_zero_delay_fee_share_proposal();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EUnguardedDelay, location = blast_fun::launch_config)]
fun unpause_rejects_a_pending_lp_fee_change_to_a_zero_delay() {
    let mut f = release_fixture().with_zero_delay_lp_fee_proposal();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EUnguardedDelay, location = blast_fun::launch_config)]
fun unpause_rejects_a_pending_signer_admission() {
    let mut f = release_fixture().with_pending_signer_admission();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_fun::errors::EUnguardedDelay, location = blast_fun::launch_config)]
fun unpause_rejects_a_pending_change_to_a_zero_treasury_delay() {
    let mut f = release_fixture().with_zero_delay_treasury_proposal();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EUnguardedUpgradeDelay, location = blast_admin::package_admin)]
fun unpause_rejects_a_pending_zero_upgrade_delay() {
    let mut f = release_fixture().with_zero_upgrade_delay_proposal();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
fun pause_flags_name_three_independent_operations() {
    assert_eq!(constants::create_pause_bit!(), 1);
    assert_eq!(constants::trading_pause_bit!(), 2);
    assert_eq!(constants::migration_pause_bit!(), 4);
    assert_eq!(constants::valid_pause_bits!(), 7);
}

// === Test Helpers ===

/// A fully paused version with the 48-hour upgrade delay, policies whose delays were raised to
/// two days, and the core treasury at its 48-hour publication delay.
fun release_fixture(): ReleaseFixture {
    release_fixture_with(runtime_config::new_zero_fee_share_for_testing(&mut tx_context::dummy()))
}

fun release_fixture_with(runtime_config: RuntimeConfig): ReleaseFixture {
    let ctx = &mut tx_context::dummy();
    let mut version = otw::version_for_testing(ctx);
    package_admin::pause(&mut version, &pause_admin(), constants::valid_pause_bits!());

    ReleaseFixture {
        version,
        package_admin: otw::package_admin_for_testing(ctx),
        runtime_config,
        launch_config: launch_config::new_zero_fees_for_testing(ctx),
        treasury: blast_treasury::new_for_testing(TREASURY, ctx),
    }
}

fun with_zero_delay_fee_share_proposal(self: ReleaseFixture): ReleaseFixture {
    let ReleaseFixture {
        version,
        package_admin,
        mut runtime_config,
        launch_config,
        treasury,
    } = self;
    let clock = sui::clock::create_for_testing(&mut tx_context::dummy());
    runtime_config.schedule_protocol_fee_share(
        &version,
        &blast_acl::witness_for_testing<FeeAdmin>(),
        bps::new(0),
        0,
        &clock,
    );
    destroy(clock);

    ReleaseFixture { version, package_admin, runtime_config, launch_config, treasury }
}

fun with_zero_delay_lp_fee_proposal(self: ReleaseFixture): ReleaseFixture {
    let ReleaseFixture {
        version,
        package_admin,
        runtime_config,
        mut launch_config,
        treasury,
    } = self;
    let clock = sui::clock::create_for_testing(&mut tx_context::dummy());
    launch_config.schedule_protocol_lp_fees(
        &version,
        &blast_acl::witness_for_testing<FeeAdmin>(),
        bps::new(1_500),
        bps::new(1_500),
        0,
        &clock,
    );
    destroy(clock);

    ReleaseFixture { version, package_admin, runtime_config, launch_config, treasury }
}

fun with_pending_signer_admission(self: ReleaseFixture): ReleaseFixture {
    let ReleaseFixture {
        version,
        package_admin,
        mut runtime_config,
        launch_config,
        treasury,
    } = self;
    let clock = sui::clock::create_for_testing(&mut tx_context::dummy());
    runtime_config.schedule_creator_claim_signer(
        &version,
        &blast_acl::witness_for_testing<ClaimSignerAdmin>(),
        x"0101010101010101010101010101010101010101010101010101010101010101",
        &clock,
    );
    destroy(clock);

    ReleaseFixture { version, package_admin, runtime_config, launch_config, treasury }
}

fun with_zero_delay_treasury_proposal(self: ReleaseFixture): ReleaseFixture {
    let ReleaseFixture {
        version,
        package_admin,
        runtime_config,
        launch_config,
        mut treasury,
    } = self;
    let clock = sui::clock::create_for_testing(&mut tx_context::dummy());
    treasury.schedule_destination(
        &blast_acl::witness_for_testing<TreasuryAdmin>(),
        TREASURY,
        0,
        &clock,
    );
    destroy(clock);

    ReleaseFixture { version, package_admin, runtime_config, launch_config, treasury }
}

fun with_zero_upgrade_delay_proposal(self: ReleaseFixture): ReleaseFixture {
    let ReleaseFixture {
        version,
        mut package_admin,
        runtime_config,
        launch_config,
        treasury,
    } = self;
    let clock = sui::clock::create_for_testing(&mut tx_context::dummy());
    package_admin.schedule_upgrade_delay(
        &blast_acl::witness_for_testing<UpgradeAdmin<BLAST_FUN>>(),
        0,
        &clock,
    );
    destroy(clock);

    ReleaseFixture { version, package_admin, runtime_config, launch_config, treasury }
}

fun unpause(self: &mut ReleaseFixture, bits: u8) {
    self.launch_config.unpause(
        &mut self.version,
        &blast_acl::witness_for_testing<UnpauseAdmin<BLAST_FUN>>(),
        &self.package_admin,
        &self.runtime_config,
        &self.treasury,
        bits,
    );
}

fun end(self: ReleaseFixture) {
    destroy(self);
}

fun pause_admin(): AdminWitness<PauseAdmin<BLAST_FUN>> {
    blast_acl::witness_for_testing()
}

// === Imports ===

use blast_admin::{
    blast_acl::{Self, AdminWitness},
    package_admin::{Self, PackageAdmin, PauseAdmin, UnpauseAdmin, UpgradeAdmin},
    package_version::PackageVersion
};

use blast_core::{
    blast_domain::{ClaimSignerAdmin, FeeAdmin, TreasuryAdmin},
    blast_treasury::{Self, Treasury},
    bps
};

use blast_fun::{
    blast_fun::{Self as otw, BLAST_FUN},
    constants,
    launch_config::{Self, LaunchConfig},
    runtime_config::{Self, RuntimeConfig}
};

use std::unit_test::{assert_eq, destroy};
