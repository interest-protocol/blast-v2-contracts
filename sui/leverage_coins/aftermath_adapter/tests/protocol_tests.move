#[test_only]
/// Tests for adapter versioning against the shared Series1 authority.
module blast_leverage_aftermath::protocol_tests;

use blast_leverage_aftermath::{events, protocol};
use blast_leverage_series_one::acl;
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario;

// === Constants ===

const ROOT: address = @0xA11CE;
const ADMIN: address = @0xAD;

// === Test-Only Types ===

public struct Fixture {
    scenario: test_scenario::Scenario,
    protocol: protocol::Protocol,
    authority: acl::ProtocolAuthority,
    super_admin_cap: acl::SuperAdminCap,
    admin_cap: Option<acl::AdminCap>,
}

// === Tests ===

#[test]
fun global_series_package_admin_activates_the_exact_next_adapter_version() {
    let mut scenario = test_scenario::begin(ROOT);
    let mut protocol = protocol::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(scenario.ctx());

    authority.grant_admin(
        &super_admin_cap,
        16,
        ADMIN,
        scenario.ctx(),
    );
    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let admin_witness = authority.sign_in(&admin_cap);
    protocol.set_version_for_testing(0);

    protocol.activate_package_version(&admin_witness);

    let advanced = events::collect_one<events::PackageVersionAdvanced>(0);
    let (previous_version, new_version) = advanced.package_version_advanced_fields();
    assert_eq!(previous_version, 0);
    assert_eq!(new_version, 1);
    assert_eq!(protocol.version_for_testing(), 1);

    destroy(Fixture {
        scenario,
        protocol,
        authority,
        super_admin_cap,
        admin_cap: option::some(admin_cap),
    });
}

#[test]
fun series_acl_management_does_not_depend_on_adapter_version() {
    let mut scenario = test_scenario::begin(ROOT);
    let mut protocol = protocol::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(scenario.ctx());
    protocol.set_version_for_testing(2);

    authority.grant_admin(
        &super_admin_cap,
        16,
        ADMIN,
        scenario.ctx(),
    );
    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let admin_witness = authority.sign_in(&admin_cap);
    admin_witness.assert_package_admin();

    destroy(Fixture {
        scenario,
        protocol,
        authority,
        super_admin_cap,
        admin_cap: option::some(admin_cap),
    });
}
