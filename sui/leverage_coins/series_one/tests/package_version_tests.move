#[test_only]
module blast_leverage_series_one::package_version_tests;

use blast_leverage_series_one::{errors, events, package_version};
use std::unit_test::{assert_eq, destroy};
use sui::{event, test_scenario};

// === Constants ===

const PUBLISHER: address = @0xA11CE;

// === Tests ===

#[test]
fun current_package_version_is_accepted() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());

    package_version.assert_current();

    destroy(package_version);
    scenario.end();
}

#[test]
fun exact_next_package_version_activation_is_replay_complete() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let mut package_version = package_version::new_for_testing(scenario.ctx());
    package_version.set_for_testing(0);

    package_version.activate();

    let advanced = events::collect_one<events::PackageVersionAdvanced>(0);
    let (previous_version, new_version) = advanced.package_version_advanced_fields();
    assert_eq!(previous_version, 0);
    assert_eq!(new_version, 1);
    assert_eq!(package_version.version_for_testing(), 1);
    assert!(event::events_by_type<events::PackageVersionAdvanced>().is_empty());

    destroy(package_version);
    scenario.end();
}

#[test]
fun package_version_initialization_is_eventless_and_shares_one_object() {
    let mut scenario = test_scenario::begin(PUBLISHER);

    package_version::init_for_testing(scenario.ctx());
    assert_eq!(event::num_events(), 0);

    scenario.next_tx(PUBLISHER);
    let package_version = scenario.take_shared<package_version::PackageVersion>();
    package_version.assert_current();

    destroy(package_version);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionMismatch,
    location = blast_leverage_series_one::package_version,
)]
fun stale_package_version_is_rejected() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let mut package_version = package_version::new_for_testing(scenario.ctx());
    package_version.set_for_testing(0);

    package_version.assert_current();

    destroy(package_version);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionMismatch,
    location = blast_leverage_series_one::package_version,
)]
fun activation_rejects_a_skipped_generation() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let mut package_version = package_version::new_for_testing(scenario.ctx());
    package_version.set_for_testing(2);

    package_version.activate();

    destroy(package_version);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionMismatch,
    location = blast_leverage_series_one::package_version,
)]
fun activation_rejects_the_already_active_generation() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let mut package_version = package_version::new_for_testing(scenario.ctx());

    package_version.activate();

    destroy(package_version);
    scenario.end();
}

#[test]
#[expected_failure(
    abort_code = errors::EPackageVersionOverflow,
    location = blast_leverage_series_one::package_version,
)]
fun activation_rejects_version_overflow() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let mut package_version = package_version::new_for_testing(scenario.ctx());
    package_version.set_for_testing(std::u64::max_value!());

    package_version.activate();

    destroy(package_version);
    scenario.end();
}
