#[test_only]
/// Tests for construction of adapter-custodied Series1 state.
module blast_leverage_series_one::state_tests;

use blast_leverage_series_one::{
    acl,
    constants,
    errors,
    policy::{Self, TierPolicy},
    state::{Self, State},
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self, Scenario};

// === Constants ===

const ROOT: address = @0xA11CE;
const ISSUER: address = @0x1;
const MAX_ORDER_NOTIONAL_MINIMUM: u64 = 100;
const MAX_ORDER_NOTIONAL_CURRENT: u64 = 250;
const MAX_ORDER_NOTIONAL_MAXIMUM: u64 = 1_000;

// === Test-Only Types ===

public struct Product {}

public struct Fixture {
    scenario: Scenario,
    authority: acl::ProtocolAuthority,
    super_admin_cap: acl::SuperAdminCap,
    admin_cap: acl::AdminCap,
}

// === Tests ===

#[test]
fun authorized_constructor_returns_valid_uninitialized_state() {
    let fixture = start(constants::vault_issuer_role!());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let expected_policy = standard_tier_policy();
    let state = state::new<Product>(
        &witness,
        expected_policy,
        MAX_ORDER_NOTIONAL_MINIMUM,
        MAX_ORDER_NOTIONAL_CURRENT,
        MAX_ORDER_NOTIONAL_MAXIMUM,
    );

    assert!(state.is_uninitialized_for_testing());
    assert_eq!(state.maintenance_reserve_for_testing(), 0);
    assert_eq!(state.tier_policy_for_testing(), expected_policy);
    let (minimum, current, maximum) = state.max_order_notional_for_testing();
    assert_eq!(minimum, MAX_ORDER_NOTIONAL_MINIMUM);
    assert_eq!(current, MAX_ORDER_NOTIONAL_CURRENT);
    assert_eq!(maximum, MAX_ORDER_NOTIONAL_MAXIMUM);

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EAdminRoleNotGranted,
    location = blast_leverage_series_one::acl,
)]
fun constructor_requires_the_vault_issuer_role() {
    let fixture = start(constants::risk_admin_role!());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let state = state::new<Product>(
        &witness,
        standard_tier_policy(),
        MAX_ORDER_NOTIONAL_MINIMUM,
        MAX_ORDER_NOTIONAL_CURRENT,
        MAX_ORDER_NOTIONAL_MAXIMUM,
    );

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidMaxOrderNotional,
    location = blast_leverage_series_one::state,
)]
fun max_order_notional_minimum_must_be_positive() {
    let fixture = start(constants::vault_issuer_role!());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let state = state::new<Product>(
        &witness,
        standard_tier_policy(),
        0,
        0,
        MAX_ORDER_NOTIONAL_MAXIMUM,
    );

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidBoundedValue,
    location = blast_leverage_series_one::bounded_value,
)]
fun max_order_notional_values_must_be_ordered() {
    let fixture = start(constants::vault_issuer_role!());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let state = state::new<Product>(
        &witness,
        standard_tier_policy(),
        2,
        1,
        3,
    );

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun max_order_notional_moves_both_directions_inside_frozen_bounds() {
    let fixture = start(constants::vault_issuer_role!());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let mut state = state::new<Product>(
        &witness,
        standard_tier_policy(),
        MAX_ORDER_NOTIONAL_MINIMUM,
        MAX_ORDER_NOTIONAL_CURRENT,
        MAX_ORDER_NOTIONAL_MAXIMUM,
    );

    assert_eq!(
        state.set_max_order_notional(MAX_ORDER_NOTIONAL_MINIMUM),
        MAX_ORDER_NOTIONAL_CURRENT,
    );
    assert_eq!(
        state.set_max_order_notional(MAX_ORDER_NOTIONAL_MAXIMUM),
        MAX_ORDER_NOTIONAL_MINIMUM,
    );
    let (minimum, current, maximum) = state.max_order_notional_for_testing();
    assert_eq!(minimum, MAX_ORDER_NOTIONAL_MINIMUM);
    assert_eq!(current, MAX_ORDER_NOTIONAL_MAXIMUM);
    assert_eq!(maximum, MAX_ORDER_NOTIONAL_MAXIMUM);

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 74,
    location = blast_leverage_series_one::state,
)]
fun max_order_notional_rejects_the_current_value() {
    let fixture = start(constants::vault_issuer_role!());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let mut state = state::new<Product>(
        &witness,
        standard_tier_policy(),
        MAX_ORDER_NOTIONAL_MINIMUM,
        MAX_ORDER_NOTIONAL_CURRENT,
        MAX_ORDER_NOTIONAL_MAXIMUM,
    );

    state.set_max_order_notional(MAX_ORDER_NOTIONAL_CURRENT);

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 34,
    location = blast_leverage_series_one::bounded_value,
)]
fun max_order_notional_rejects_one_below_the_frozen_minimum() {
    let fixture = start(constants::vault_issuer_role!());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let mut state = state::new<Product>(
        &witness,
        standard_tier_policy(),
        MAX_ORDER_NOTIONAL_MINIMUM,
        MAX_ORDER_NOTIONAL_CURRENT,
        MAX_ORDER_NOTIONAL_MAXIMUM,
    );

    state.set_max_order_notional(MAX_ORDER_NOTIONAL_MINIMUM - 1);

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 34,
    location = blast_leverage_series_one::bounded_value,
)]
fun max_order_notional_rejects_one_above_the_frozen_maximum() {
    let fixture = start(constants::vault_issuer_role!());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let mut state = state::new<Product>(
        &witness,
        standard_tier_policy(),
        MAX_ORDER_NOTIONAL_MINIMUM,
        MAX_ORDER_NOTIONAL_CURRENT,
        MAX_ORDER_NOTIONAL_MAXIMUM,
    );

    state.set_max_order_notional(MAX_ORDER_NOTIONAL_MAXIMUM + 1);

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun active_state_enters_reduce_only() {
    let fixture = start(constants::vault_issuer_role!());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let mut state = state::new<Product>(
        &witness,
        standard_tier_policy(),
        MAX_ORDER_NOTIONAL_MINIMUM,
        MAX_ORDER_NOTIONAL_CURRENT,
        MAX_ORDER_NOTIONAL_MAXIMUM,
    );
    state.set_active_for_testing();

    state.enter_reduce_only();

    assert!(state.is_reduce_only_for_testing());
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = 17,
    location = blast_leverage_series_one::lifecycle,
)]
fun uninitialized_state_cannot_enter_reduce_only() {
    let fixture = start(constants::vault_issuer_role!());
    let witness = fixture.authority.sign_in(&fixture.admin_cap);
    let mut state = state::new<Product>(
        &witness,
        standard_tier_policy(),
        MAX_ORDER_NOTIONAL_MINIMUM,
        MAX_ORDER_NOTIONAL_CURRENT,
        MAX_ORDER_NOTIONAL_MAXIMUM,
    );

    state.enter_reduce_only();

    state.destroy_for_testing();
    destroy(fixture);
}

// === Fixture Setup ===

fun start(roles: u8): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        roles,
        ISSUER,
        scenario.ctx(),
    );

    scenario.next_tx(ISSUER);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();

    Fixture { scenario, authority, super_admin_cap, admin_cap }
}

fun standard_tier_policy(): TierPolicy {
    policy::new_tier_policy(
        policy::long(),
        policy::new_rebalance_policy(
            16_000,
            18_000,
            20_000,
            22_000,
            26_000,
            30_000,
            100,
            500,
            10,
        ),
        policy::new_valuation(30_000, 2_000, 100, 500),
        10,
        10,
        100,
        100,
        100,
        1_000_000_000,
    )
}
