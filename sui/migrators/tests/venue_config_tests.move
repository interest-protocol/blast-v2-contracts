#[test_only]
module blast_fun_migrators::venue_config_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;
const MAX_ADMINS: u64 = 16;
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

public struct TestVenue() has drop;

/// Admin-pinned tier policy through the core ACL sign-in seam.
public struct TierFixture {
    scenario: Scenario,
    authority: Authority<LAUNCHPAD_DOMAIN>,
    admin_cap: AdminCap<LAUNCHPAD_DOMAIN>,
    package_version: package_version::PackageVersion,
    config: VenueConfig,
}

// === Tests ===

#[test]
fun substrate_pins_reads_and_replaces_one_sealed_entry() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        assert_eq!(f.config.has_tier<TestVenue>(), false);

        f.config.set_tier(TestVenue(), 60, 3_000);
        assert_eq!(f.config.has_tier<TestVenue>(), true);
        let (tick_spacing, fee_rate) = f.config.tier<TestVenue>();
        assert_eq!(tick_spacing, 60);
        assert_eq!(fee_rate, 3_000);

        f.config.set_tier(TestVenue(), 60, 4_000);
        let (tick_spacing, fee_rate) = f.config.tier<TestVenue>();
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
        let (tick_spacing, fee_rate) = f.config.bluefin_tier_for_testing();
        assert_eq!(tick_spacing, 200);
        assert_eq!(fee_rate, 10_000);
        let (tick_spacing, fee_rate) = f.config.cetus_tier_for_testing();
        assert_eq!(tick_spacing, 260);
        assert_eq!(fee_rate, 40_000);
        let (tick_spacing, fee_rate) = f.config.mmt_tier_for_testing();
        assert_eq!(tick_spacing, 400);
        assert_eq!(fee_rate, 20_000);
        let (tick_spacing, fee_rate) = f.config.turbos_tier_for_testing();
        assert_eq!(tick_spacing, 800);
        assert_eq!(fee_rate, 40_000);
        let (meme_weight, quote_weight, dao_fee_bps) =
            f.config.aftermath_policy_for_testing();
        assert_eq!(meme_weight, 500_000_000_000_000_000);
        assert_eq!(quote_weight, 500_000_000_000_000_000);
        assert_eq!(dao_fee_bps, 200);

        let admin_witness = f.sign_in();
        f.config.set_bluefin_tier(&f.package_version, &admin_witness, 220, 20_000);
        f.config.set_cetus_tier(&f.package_version, &admin_witness, 220, 20_000);
        f.config.set_mmt_tier(&f.package_version, &admin_witness, 200, 10_000);
        f.config.set_turbos_tier(&f.package_version, &admin_witness, 220, 20_000);
        f.config.set_aftermath_policy(
            &f.package_version,
            &admin_witness,
            600_000_000_000_000_000,
            400_000_000_000_000_000,
            300,
        );

        let (tick_spacing, fee_rate) = f.config.bluefin_tier_for_testing();
        assert_eq!(tick_spacing, 220);
        assert_eq!(fee_rate, 20_000);
        let (meme_weight, quote_weight, dao_fee_bps) =
            f.config.aftermath_policy_for_testing();
        assert_eq!(meme_weight, 600_000_000_000_000_000);
        assert_eq!(quote_weight, 400_000_000_000_000_000);
        assert_eq!(dao_fee_bps, 300);
        let (tick_spacing, fee_rate) = f.config.cetus_tier_for_testing();
        assert_eq!(tick_spacing, 220);
        assert_eq!(fee_rate, 20_000);
        let (tick_spacing, fee_rate) = f.config.mmt_tier_for_testing();
        assert_eq!(tick_spacing, 200);
        assert_eq!(fee_rate, 10_000);
        let (tick_spacing, fee_rate) = f.config.turbos_tier_for_testing();
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

        f.config.set_bluefin_tier(&f.package_version, &admin_witness, 220, 20_000);

        // Only the Bluefin entry changed; every other venue keeps its default.
        let (tick_spacing, fee_rate) = f.config.cetus_tier_for_testing();
        assert_eq!(tick_spacing, 260);
        assert_eq!(fee_rate, 40_000);
        assert_eq!(f.config.has_tier<TestVenue>(), false);
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
fun aftermath_accepts_zero_dao_fee() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.config.set_aftermath_policy(
            &f.package_version,
            &admin_witness,
            500_000_000_000_000_000,
            500_000_000_000_000_000,
            0,
        );
        let (_, _, dao_fee_bps) = f.config.aftermath_policy_for_testing();
        assert_eq!(dao_fee_bps, 0);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = aftermath::EInvalidDaoFee,
    location = blast_fun_migrators::aftermath,
)]
fun aftermath_rejects_dao_fee_above_one_hundred_percent() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.config.set_aftermath_policy(
            &f.package_version,
            &admin_witness,
            500_000_000_000_000_000,
            500_000_000_000_000_000,
            10_001,
        );
    });

    fixture.end();
}

#[test]
fun aftermath_accepts_inclusive_dao_fee_boundaries() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.config.set_aftermath_policy(
            &f.package_version,
            &admin_witness,
            500_000_000_000_000_000,
            500_000_000_000_000_000,
            0,
        );
        let (_, _, dao_fee_bps) = f.config.aftermath_policy_for_testing();
        assert_eq!(dao_fee_bps, 0);
        f.config.set_aftermath_policy(
            &f.package_version,
            &admin_witness,
            500_000_000_000_000_000,
            500_000_000_000_000_000,
            10_000,
        );
        let (_, _, dao_fee_bps) = f.config.aftermath_policy_for_testing();
        assert_eq!(dao_fee_bps, 10_000);
    });

    fixture.end();
}

#[test]
fun aftermath_accepts_inclusive_weight_boundaries() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.config.set_aftermath_policy(
            &f.package_version,
            &admin_witness,
            10_000_000_000_000_000,
            990_000_000_000_000_000,
            200,
        );
        let (meme_weight, quote_weight, _) = f.config.aftermath_policy_for_testing();
        assert_eq!(meme_weight, 10_000_000_000_000_000);
        assert_eq!(quote_weight, 990_000_000_000_000_000);

        f.config.set_aftermath_policy(
            &f.package_version,
            &admin_witness,
            990_000_000_000_000_000,
            10_000_000_000_000_000,
            201,
        );
        let (meme_weight, quote_weight, _) = f.config.aftermath_policy_for_testing();
        assert_eq!(meme_weight, 990_000_000_000_000_000);
        assert_eq!(quote_weight, 10_000_000_000_000_000);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = aftermath::EInvalidWeight,
    location = blast_fun_migrators::aftermath,
)]
fun aftermath_rejects_weight_below_venue_minimum() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.config.set_aftermath_policy(
            &f.package_version,
            &admin_witness,
            9_999_999_999_999_999,
            990_000_000_000_000_001,
            200,
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = aftermath::EInvalidWeight,
    location = blast_fun_migrators::aftermath,
)]
fun aftermath_rejects_weights_that_do_not_sum_to_one() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.config.set_aftermath_policy(
            &f.package_version,
            &admin_witness,
            500_000_000_000_000_000,
            499_000_000_000_000_000,
            200,
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = aftermath::EUnchangedPolicy,
    location = blast_fun_migrators::aftermath,
)]
fun aftermath_rejects_a_pin_equal_to_the_compiled_default() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.config.set_aftermath_policy(
            &f.package_version,
            &admin_witness,
            500_000_000_000_000_000,
            500_000_000_000_000_000,
            200,
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = aftermath::EUnchangedPolicy,
    location = blast_fun_migrators::aftermath,
)]
fun aftermath_rejects_a_repeated_pinned_policy() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        f.config.set_aftermath_policy(
            &f.package_version,
            &admin_witness,
            600_000_000_000_000_000,
            400_000_000_000_000_000,
            300,
        );
        f.config.set_aftermath_policy(
            &f.package_version,
            &admin_witness,
            600_000_000_000_000_000,
            400_000_000_000_000_000,
            300,
        );
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
        let (_, _) = f.config.tier<TestVenue>();
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

        f.config.set_turbos_tier(
            &f.package_version,
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
        acl::new_for_testing<LAUNCHPAD_DOMAIN>(MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, scenario.ctx());
    authority.grant_admin(&super_admin_cap, 0, PROTOCOL_ADMIN, scenario.ctx());
    destroy(super_admin_cap);
    venue_config::init_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<LAUNCHPAD_DOMAIN>>();
    let config = scenario.take_shared<VenueConfig>();

    TierFixture { scenario, authority, admin_cap, package_version, config }
}

fun sign_in(self: &TierFixture): AdminWitness<LAUNCHPAD_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun end(self: TierFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap, AdminWitness};

use blast_fun::launchpad_domain::LAUNCHPAD_DOMAIN;

use blast_fun_migrators::{
    aftermath,
    bluefin,
    cetus,
    mmt,
    package_version,
    turbos,
    venue_config::{Self, VenueConfig},
};

use std::unit_test::{assert_eq, destroy};

use sui::test_scenario::{Self, Scenario};

use fun aftermath::effective_policy_for_testing as VenueConfig.aftermath_policy_for_testing;

use fun aftermath::set_policy as VenueConfig.set_aftermath_policy;

use fun bluefin::effective_tier_for_testing as VenueConfig.bluefin_tier_for_testing;

use fun bluefin::set_tier as VenueConfig.set_bluefin_tier;

use fun cetus::effective_tier_for_testing as VenueConfig.cetus_tier_for_testing;

use fun cetus::set_tier as VenueConfig.set_cetus_tier;

use fun mmt::effective_tier_for_testing as VenueConfig.mmt_tier_for_testing;

use fun mmt::set_tier as VenueConfig.set_mmt_tier;

use fun turbos::effective_tier_for_testing as VenueConfig.turbos_tier_for_testing;

use fun turbos::set_tier as VenueConfig.set_turbos_tier;
