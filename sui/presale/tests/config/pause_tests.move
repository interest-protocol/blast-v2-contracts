// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// The presale's unpause: it clears bits through `blast_admin::package_admin` only while every
/// presale delay and the core treasury's delay are guarded. Pause-bit arithmetic and the upgrade
/// delay are the generic administration's and are tested there.
module blast_presale::pause_tests;

// === Constants ===

const TREASURY: address = @0x7EA5;

// === Test-Only Types ===

public struct ReleaseFixture {
    version: PackageVersion<BLAST_PRESALE_PACKAGE>,
    package_admin: PackageAdmin<BLAST_PRESALE_PACKAGE>,
    fee_policy: FeePolicy,
    creation_policy: CreationPolicy,
    treasury: Treasury,
}

public struct VENUE() has drop;

// === Tests ===

#[test]
/// Pins the on-chain pause layout that operators and the admin console address by number.
fun pause_bit_layout_is_stable() {
    assert_eq!(constants::create_pause_bit!(), 1);
    assert_eq!(constants::commit_pause_bit!(), 2);
    assert_eq!(constants::migration_pause_bit!(), 4);
    assert_eq!(constants::valid_pause_bits!(), 7);
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EVersionMismatch,
    location = blast_admin::package_version,
)]
fun stale_version_is_rejected_before_the_delay_gate() {
    let mut f = release_fixture_with(
        creation_policy::new_publication_for_testing(&mut tx_context::dummy()),
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
        constants::commit_pause_bit!() | constants::migration_pause_bit!(),
    );
    f.end();
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EUnguardedDelay,
    location = blast_presale::creation_policy,
)]
fun unpause_rejects_the_zero_publication_delay() {
    let mut f = release_fixture_with(
        creation_policy::new_publication_for_testing(&mut tx_context::dummy()),
    );
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EUnguardedDelay,
    location = blast_presale::creation_policy,
)]
fun unpause_rejects_a_pending_change_to_a_zero_delay() {
    let mut f = release_fixture().with_zero_delay_fees_proposal();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EUnguardedDelay,
    location = blast_presale::creation_policy,
)]
fun unpause_rejects_a_pending_venue_admission() {
    let mut f = release_fixture().with_pending_venue_admission();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_presale::errors::EUnguardedDelay,
    location = blast_presale::creation_policy,
)]
fun unpause_rejects_a_pending_change_to_a_zero_treasury_delay() {
    let mut f = release_fixture().with_zero_delay_treasury_proposal();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EUnguardedUpgradeDelay,
    location = blast_admin::package_admin,
)]
fun unpause_rejects_a_pending_zero_upgrade_delay() {
    let mut f = release_fixture().with_zero_upgrade_delay_proposal();
    f.unpause(constants::create_pause_bit!());
    abort
}

#[test]
/// Publication keeps an owned publication proof and shares nothing; `wrap` then shares the
/// generic administration and the version with every presale bit paused.
fun publication_wraps_into_a_fully_paused_version() {
    let mut scenario = test_scenario::begin(@0xD);
    otw::init_for_testing(scenario.ctx());
    scenario.next_tx(@0xD);
    let publication = scenario.take_from_sender<Publication<BLAST_PRESALE_PACKAGE>>();
    let upgrade_cap = sui::package::test_publish(@blast_presale.to_id(), scenario.ctx());
    package_admin::wrap(publication, upgrade_cap, scenario.ctx());
    scenario.next_tx(@0xD);
    let version = scenario.take_shared<PackageVersion<BLAST_PRESALE_PACKAGE>>();
    assert_eq!(version.paused_for_testing(), constants::valid_pause_bits!());
    assert_eq!(version.valid_pause_bits_for_testing(), constants::valid_pause_bits!());
    test_scenario::return_shared(version);
    scenario.end();
}

// === Test Helpers ===

/// A fully paused version with the 48-hour upgrade delay, policies whose delays were raised to
/// two days, and the core treasury at its 48-hour publication delay.
fun release_fixture(): ReleaseFixture {
    release_fixture_with(creation_policy::new_for_testing(&mut tx_context::dummy()))
}

fun release_fixture_with(creation_policy: CreationPolicy): ReleaseFixture {
    let ctx = &mut tx_context::dummy();
    let mut version = otw::version_for_testing(ctx);
    package_admin::pause(&mut version, &pause_admin(), constants::valid_pause_bits!());

    ReleaseFixture {
        version,
        package_admin: otw::package_admin_for_testing(ctx),
        fee_policy: fee_policy::new_zero_fees_for_testing(ctx),
        creation_policy,
        treasury: blast_treasury::new_for_testing(TREASURY, ctx),
    }
}

fun with_zero_delay_fees_proposal(self: ReleaseFixture): ReleaseFixture {
    let ReleaseFixture { version, package_admin, mut fee_policy, creation_policy, treasury } = self;
    let clock = sui::clock::create_for_testing(&mut tx_context::dummy());
    fee_policy.schedule_fees(
        &version,
        &blast_acl::witness_for_testing<FeeAdmin>(),
        bps::new(0),
        bps::new(0),
        bps::new(0),
        bps::new(1),
        0,
        &clock,
    );
    destroy(clock);

    ReleaseFixture { version, package_admin, fee_policy, creation_policy, treasury }
}

fun with_pending_venue_admission(self: ReleaseFixture): ReleaseFixture {
    let ReleaseFixture { version, package_admin, fee_policy, mut creation_policy, treasury } = self;
    let clock = sui::clock::create_for_testing(&mut tx_context::dummy());
    creation_policy.schedule_venue<VENUE>(
        &version,
        &blast_acl::witness_for_testing<VenueAdmin>(),
        &clock,
    );
    destroy(clock);

    ReleaseFixture { version, package_admin, fee_policy, creation_policy, treasury }
}

fun with_zero_delay_treasury_proposal(self: ReleaseFixture): ReleaseFixture {
    let ReleaseFixture { version, package_admin, fee_policy, creation_policy, mut treasury } = self;
    let clock = sui::clock::create_for_testing(&mut tx_context::dummy());
    treasury.schedule_destination(
        &blast_acl::witness_for_testing<TreasuryAdmin>(),
        TREASURY,
        0,
        &clock,
    );
    destroy(clock);

    ReleaseFixture { version, package_admin, fee_policy, creation_policy, treasury }
}

fun with_zero_upgrade_delay_proposal(self: ReleaseFixture): ReleaseFixture {
    let ReleaseFixture { version, mut package_admin, fee_policy, creation_policy, treasury } = self;
    let clock = sui::clock::create_for_testing(&mut tx_context::dummy());
    package_admin.schedule_upgrade_delay(
        &blast_acl::witness_for_testing<UpgradeAdmin<BLAST_PRESALE_PACKAGE>>(),
        0,
        &clock,
    );
    destroy(clock);

    ReleaseFixture { version, package_admin, fee_policy, creation_policy, treasury }
}

fun unpause(self: &mut ReleaseFixture, bits: u8) {
    self.creation_policy.unpause(
        &mut self.version,
        &blast_acl::witness_for_testing<UnpauseAdmin<BLAST_PRESALE_PACKAGE>>(),
        &self.package_admin,
        &self.fee_policy,
        &self.treasury,
        bits,
    );
}

fun end(self: ReleaseFixture) {
    destroy(self);
}

fun pause_admin(): AdminWitness<PauseAdmin<BLAST_PRESALE_PACKAGE>> {
    blast_acl::witness_for_testing()
}

// === Imports ===

use blast_admin::{
    blast_acl::{Self, AdminWitness},
    package_admin::{Self, PackageAdmin, PauseAdmin, UnpauseAdmin, UpgradeAdmin},
    package_version::{PackageVersion, Publication}
};

use blast_core::{
    blast_domain::{VenueAdmin, FeeAdmin, TreasuryAdmin},
    blast_treasury::{Self, Treasury},
    bps
};

use blast_presale::{
    blast_presale_package::{Self as otw, BLAST_PRESALE_PACKAGE},
    constants,
    creation_policy::{Self, CreationPolicy},
    fee_policy::{Self, FeePolicy}
};

use std::unit_test::{assert_eq, destroy};

use sui::test_scenario;
