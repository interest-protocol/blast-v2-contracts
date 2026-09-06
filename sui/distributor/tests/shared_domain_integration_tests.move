#[test_only]
/// Cross-package proof for the Launchpad administration domain.
///
/// Package-local suites own their detailed generation and custody matrices.
/// This module proves the integration contract once: one live membership can
/// administer all three consumers, their operational generations remain
/// independent, and one revocation removes access to the whole domain.
module blast_fun_distributor::shared_domain_integration_tests;

use blast_admin::acl::{Self, AdminCap, AdminWitness, Authority, SuperAdminCap};
use blast_fun::{
    launchpad_domain::LAUNCHPAD_DOMAIN,
    package_version::{Self as launchpad_version, PackageVersion as LaunchpadVersion},
    runtime_config::{Self, RuntimeConfig},
};
use blast_fun_distributor::package_version::{
    Self as distributor_version,
    PackageVersion as DistributorVersion,
};
use blast_fun_migrators::{
    cetus,
    package_version::{Self as migrators_version, PackageVersion as MigratorsVersion},
    venue_config::{Self, VenueConfig},
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self, Scenario};

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;
const MAX_ADMINS: u64 = 16;
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

public struct Fixture {
    scenario: Scenario,
    authority: Authority<LAUNCHPAD_DOMAIN>,
    super_admin_cap: SuperAdminCap<LAUNCHPAD_DOMAIN>,
    admin_cap: AdminCap<LAUNCHPAD_DOMAIN>,
    launchpad_version: LaunchpadVersion,
    runtime_config: RuntimeConfig,
    migrators_version: MigratorsVersion,
    venue_config: VenueConfig,
    distributor_version: DistributorVersion,
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidAdminCap,
    location = blast_admin::acl,
)]
/// One membership spans the slice, generations do not, and revocation is global.
fun one_launchpad_admin_governs_the_slice_until_shared_revocation() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let witness = f.sign_in();

        f.runtime_config.set_protocol_fee_share(
            &f.launchpad_version,
            &witness,
            2_500,
        );
        cetus::set_tier(
            &mut f.venue_config,
            &f.migrators_version,
            &witness,
            220,
            20_000,
        );
        f.distributor_version.set_paused(&witness, true);

        assert_eq!(f.runtime_config.protocol_fee_share_bps(), 2_500);
        assert!(f.distributor_version.paused_for_testing());
    });

    fixture.next_tx!(PUBLISHER, |f| {
        f.migrators_version.advance_for_testing();

        assert_eq!(f.launchpad_version.version_for_testing(), 1);
        assert_eq!(f.migrators_version.version_for_testing(), 2);
        assert_eq!(f.distributor_version.version_for_testing(), 1);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let witness = f.sign_in();

        f.runtime_config.set_protocol_fee_share(
            &f.launchpad_version,
            &witness,
            3_000,
        );
        f.distributor_version.set_paused(&witness, false);

        assert_eq!(f.runtime_config.protocol_fee_share_bps(), 3_000);
        assert!(!f.distributor_version.paused_for_testing());
    });

    fixture.next_tx!(PUBLISHER, |f| {
        let admin_cap_id = f.admin_cap.admin_cap_id_for_testing();
        f.authority.revoke_admin(&f.super_admin_cap, admin_cap_id);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let witness = f.sign_in();
        destroy(witness);
    });

    destroy(fixture);
}

macro fun next_tx(
    $fixture: &mut Fixture,
    $sender: address,
    $fn: |&mut Fixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start(): Fixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let launchpad_version = launchpad_version::new_for_testing(scenario.ctx());
    let runtime_config = runtime_config::new_disabled_for_testing(scenario.ctx());
    let migrators_version = migrators_version::new_for_testing(scenario.ctx());
    venue_config::init_for_testing(scenario.ctx());
    let distributor_version = distributor_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = acl::new_for_testing<LAUNCHPAD_DOMAIN>(
        MAX_ADMINS,
        ROOT_TRANSFER_DELAY_MS,
        scenario.ctx(),
    );
    authority.grant_admin(&super_admin_cap, 0, PROTOCOL_ADMIN, scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<LAUNCHPAD_DOMAIN>>();
    let venue_config = scenario.take_shared<VenueConfig>();

    Fixture {
        scenario,
        authority,
        super_admin_cap,
        admin_cap,
        launchpad_version,
        runtime_config,
        migrators_version,
        venue_config,
        distributor_version,
    }
}

fun sign_in(self: &Fixture): AdminWitness<LAUNCHPAD_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}
