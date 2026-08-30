#[test_only]
module blast_fun_migrators::venue_config_tests;

use blast_fun::{acl, package_version};
use blast_fun_migrators::{
    bluefin,
    cetus,
    fullsail,
    mmt,
    turbos,
    venue_config::{Self, VenueConfig},
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self, Scenario};

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;

// === Test-Only Types ===

public struct TestVenue() has drop;

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
fun substrate_pins_reads_and_replaces_one_sealed_entry() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        assert_eq!(f.config.has_tier_override<TestVenue>(), false);

        f.config.set_tier(TestVenue(), 60, 3_000);
        assert_eq!(f.config.has_tier_override<TestVenue>(), true);
        let (tick_spacing, fee_rate) = f.config.tier_override<TestVenue>();
        assert_eq!(tick_spacing, 60);
        assert_eq!(fee_rate, 3_000);

        f.config.set_tier(TestVenue(), 60, 4_000);
        let (tick_spacing, fee_rate) = f.config.tier_override<TestVenue>();
        assert_eq!(tick_spacing, 60);
        assert_eq!(fee_rate, 4_000);
    });

    fixture.end();
}

#[test]
fun venue_defaults_hold_until_an_admin_pin_replaces_them() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        // The compiled highest-tier defaults identified from live mainnet
        // registries on 2026-08-30.
        let (tick_spacing, fee_rate) =
            bluefin::effective_tier_for_testing(&f.config);
        assert_eq!(tick_spacing, 200);
        assert_eq!(fee_rate, 10_000);
        let (tick_spacing, fee_rate) =
            cetus::effective_tier_for_testing(&f.config);
        assert_eq!(tick_spacing, 260);
        assert_eq!(fee_rate, 40_000);
        let (tick_spacing, fee_rate) =
            fullsail::effective_tier_for_testing(&f.config);
        assert_eq!(tick_spacing, 20);
        assert_eq!(fee_rate, 10_000);
        let (tick_spacing, fee_rate) = mmt::effective_tier_for_testing(&f.config);
        assert_eq!(tick_spacing, 400);
        assert_eq!(fee_rate, 20_000);
        let (tick_spacing, fee_rate) =
            turbos::effective_tier_for_testing(&f.config);
        assert_eq!(tick_spacing, 800);
        assert_eq!(fee_rate, 40_000);

        let admin_witness = f.sign_in();
        bluefin::set_tier(&mut f.config, &admin_witness, 220, 20_000);
        cetus::set_tier(&mut f.config, &admin_witness, 220, 20_000);
        fullsail::set_tier(&mut f.config, &admin_witness, 40, 2_000);
        mmt::set_tier(&mut f.config, &admin_witness, 200, 10_000);
        turbos::set_tier(&mut f.config, &admin_witness, 220, 20_000);

        let (tick_spacing, fee_rate) =
            bluefin::effective_tier_for_testing(&f.config);
        assert_eq!(tick_spacing, 220);
        assert_eq!(fee_rate, 20_000);
        let (tick_spacing, fee_rate) =
            cetus::effective_tier_for_testing(&f.config);
        assert_eq!(tick_spacing, 220);
        assert_eq!(fee_rate, 20_000);
        let (tick_spacing, fee_rate) =
            fullsail::effective_tier_for_testing(&f.config);
        assert_eq!(tick_spacing, 40);
        assert_eq!(fee_rate, 2_000);
        let (tick_spacing, fee_rate) = mmt::effective_tier_for_testing(&f.config);
        assert_eq!(tick_spacing, 200);
        assert_eq!(fee_rate, 10_000);
        let (tick_spacing, fee_rate) =
            turbos::effective_tier_for_testing(&f.config);
        assert_eq!(tick_spacing, 220);
        assert_eq!(fee_rate, 20_000);
    });

    fixture.end();
}

#[test]
fun venue_pins_stay_sealed_per_witness_type() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        bluefin::set_tier(&mut f.config, &admin_witness, 220, 20_000);

        // Only the Bluefin entry changed; every other venue keeps its default.
        let (tick_spacing, fee_rate) =
            cetus::effective_tier_for_testing(&f.config);
        assert_eq!(tick_spacing, 260);
        assert_eq!(fee_rate, 40_000);
        assert_eq!(f.config.has_tier_override<TestVenue>(), false);
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
        f.config.set_tier(TestVenue(), 0, 3_000);
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
        f.config.set_tier(TestVenue(), 60, 0);
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
        f.config.set_tier(TestVenue(), 100, 10_000);
        f.config.set_tier(TestVenue(), 100, 10_000);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = venue_config::EVenueTierUnset,
    location = blast_fun_migrators::venue_config,
)]
fun unpinned_tier_read_fails_closed() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let (_, _) = f.config.tier_override<TestVenue>();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = turbos::EInvalidFeeRate,
    location = blast_fun_migrators::turbos,
)]
fun turbos_pin_rejects_a_fee_no_venue_tier_can_carry() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        turbos::set_tier(
            &mut f.config,
            &admin_witness,
            800,
            (std::u32::max_value!() as u64) + 1,
        );
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
        acl::new_protocol_for_testing(scenario.ctx());
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
