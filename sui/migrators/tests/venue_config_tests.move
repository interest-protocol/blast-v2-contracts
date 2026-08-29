#[test_only]
module blast_fun_migrators::venue_config_tests;

use blast_fun::{acl, package_version};
use blast_fun_migrators::venue_config::{Self, VenueConfig};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self, Scenario};

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;

// === Test-Only Types ===

/// Admin-pinned tier policy through the core ACL sign-in seam.
public struct TierFixture {
    scenario: Scenario,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
    package_version: package_version::PackageVersion,
    config: VenueConfig,
}

// === Tests ===

#[test]
fun pins_and_reads_every_venue_tier() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_bluefin_tier(&admin_witness, 60, 3_000);
        f.config.set_cetus_tick_spacing(&admin_witness, 200);
        f.config.set_fullsail_tick_spacing(&admin_witness, 220);
        f.config.set_mmt_fee_rate(&admin_witness, 10_000);
        f.config.set_turbos_tier(&admin_witness, 100, 10_000);

        let (bluefin_tick_spacing, bluefin_fee_rate) =
            f.config.bluefin_tier();
        assert_eq!(bluefin_tick_spacing, 60);
        assert_eq!(bluefin_fee_rate, 3_000);
        assert_eq!(f.config.cetus_tick_spacing(), 200);
        assert_eq!(f.config.fullsail_tick_spacing(), 220);
        assert_eq!(f.config.mmt_fee_rate(), 10_000);
        let (turbos_tick_spacing, turbos_fee_rate) = f.config.turbos_tier();
        assert_eq!(turbos_tick_spacing, 100);
        assert_eq!(turbos_fee_rate, 10_000);

        f.config.set_bluefin_tier(&admin_witness, 60, 4_000);
        let (bluefin_tick_spacing, bluefin_fee_rate) =
            f.config.bluefin_tier();
        assert_eq!(bluefin_tick_spacing, 60);
        assert_eq!(bluefin_fee_rate, 4_000);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = venue_config::EVenueTierUnset,
    location = blast_fun_migrators::venue_config,
)]
fun unset_bluefin_tier_read_fails_closed() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let (_, _) = f.config.bluefin_tier();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = venue_config::EVenueTierUnset,
    location = blast_fun_migrators::venue_config,
)]
fun unset_cetus_tier_read_fails_closed() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.config.cetus_tick_spacing();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = venue_config::EVenueTierUnset,
    location = blast_fun_migrators::venue_config,
)]
fun unset_fullsail_tier_read_fails_closed() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.config.fullsail_tick_spacing();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = venue_config::EVenueTierUnset,
    location = blast_fun_migrators::venue_config,
)]
fun unset_mmt_tier_read_fails_closed() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.config.mmt_fee_rate();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = venue_config::EVenueTierUnset,
    location = blast_fun_migrators::venue_config,
)]
fun unset_turbos_tier_read_fails_closed() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let (_, _) = f.config.turbos_tier();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = venue_config::EInvalidTickSpacing,
    location = blast_fun_migrators::venue_config,
)]
fun rejects_zero_tick_spacing() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_bluefin_tier(&admin_witness, 0, 3_000);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = venue_config::EInvalidTickSpacing,
    location = blast_fun_migrators::venue_config,
)]
fun rejects_zero_single_tick_spacing() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_cetus_tick_spacing(&admin_witness, 0);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = venue_config::EInvalidFeeRate,
    location = blast_fun_migrators::venue_config,
)]
fun rejects_zero_fee_rate() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_mmt_fee_rate(&admin_witness, 0);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = venue_config::EUnchangedTier,
    location = blast_fun_migrators::venue_config,
)]
fun rejects_unchanged_tier() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_turbos_tier(&admin_witness, 100, 10_000);
        f.config.set_turbos_tier(&admin_witness, 100, 10_000);
    });

    fixture.end();
}

// === Private Test Helpers ===

macro fun next_tx(
    $fixture: &mut TierFixture,
    $sender: address,
    $fn: |&mut TierFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start(): TierFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(PUBLISHER, scenario.ctx());
    authority.grant_admin(
        &package_version,
        &super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );
    destroy(super_admin_cap);
    venue_config::init_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let config = scenario.take_shared<VenueConfig>();

    TierFixture { scenario, authority, admin_cap, package_version, config }
}

fun sign_in(self: &TierFixture): acl::AdminWitness {
    self.authority.sign_in(&self.package_version, &self.admin_cap)
}

fun end(self: TierFixture) {
    destroy(self);
}
