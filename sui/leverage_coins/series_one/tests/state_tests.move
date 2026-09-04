#[test_only]
/// Tests for construction of adapter-custodied Series1 state.
module blast_leverage_series_one::state_tests;

use blast_leverage_series_one::{
    acl,
    constants,
    errors,
    observation::{Self, FundingSettlement, PositionObservation},
    policy::{Self, PositionSide, TierPolicy},
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
const REFERENCE_TIME_MS: u64 = 100_000;
const SEED_RESERVE: u64 = 100_000;
const SEED_VENUE_EQUITY: u64 = 1_100_000;
const SEED_NAV: u64 = 1_000_000;
const SEED_BASE: u64 = 200_000;
const SEED_NOTIONAL: u64 = 2_000_000;
const LOT_SIZE: u64 = 1_000;
const MIN_EXPOSURE_LOTS: u64 = 100;
const NAV_CAP: u64 = 1_000_000_000;
const HEALTH_SHARE_SUPPLY: u64 = 1_000_000;

// === Test-Only Types ===

public struct Product {}

public struct Fixture {
    scenario: Scenario,
    authority: acl::ProtocolAuthority,
    super_admin_cap: acl::SuperAdminCap,
    admin_cap: acl::AdminCap,
}

public struct ObservationSpec has copy, drop {
    venue_equity: u64,
    absolute_base: u64,
    absolute_notional: u64,
    lot_size: u64,
    observed_side: PositionSide,
    pending_order_count: u64,
    margin_safe: bool,
    venue_operational: bool,
    checkpoint_clean: bool,
    base_price: u64,
    base_confidence: u64,
    base_publish_time_ms: u64,
    collateral_price: u64,
    collateral_confidence: u64,
    collateral_publish_time_ms: u64,
    mark_price: u64,
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

// --- Initialization ---

#[test]
fun initialization_target_excludes_the_seed_reserve() {
    let fixture = start(constants::vault_issuer_role!());
    let state = new_state(&fixture, policy::long());

    assert_eq!(
        state.initialization_target_notional(SEED_VENUE_EQUITY, SEED_RESERVE),
        SEED_NOTIONAL,
    );

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun valid_long_seed_activates_and_records_only_the_reserve() {
    let fixture = start(constants::vault_issuer_role!());
    let mut state = new_state(&fixture, policy::long());

    let seed_nav = state.initialize(
        standard_observation(policy::long()).into_position_observation(),
        SEED_RESERVE,
        REFERENCE_TIME_MS,
    );

    assert_eq!(seed_nav, SEED_NAV);
    assert_eq!(state.maintenance_reserve_for_testing(), SEED_RESERVE);
    assert!(state.is_active_for_testing());
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun valid_short_seed_activates() {
    let fixture = start(constants::vault_issuer_role!());
    let mut state = new_state(&fixture, policy::short());

    let seed_nav = state.initialize(
        standard_observation(policy::short()).into_position_observation(),
        SEED_RESERVE,
        REFERENCE_TIME_MS,
    );

    assert_eq!(seed_nav, SEED_NAV);
    assert!(state.is_active_for_testing());
    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidPositionObservation,
    location = blast_leverage_series_one::state,
)]
fun initialization_rejects_a_permissive_structurally_invalid_observation() {
    let fixture = start(constants::vault_issuer_role!());
    let mut state = new_state(&fixture, policy::long());

    state.initialize(
        standard_observation(policy::long())
            .with_absolute_base(SEED_BASE + 1)
            .into_health_position_observation(),
        SEED_RESERVE,
        REFERENCE_TIME_MS,
    );

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun initialization_admits_nav_cap_equality() {
    let fixture = start(constants::vault_issuer_role!());
    let mut state = new_state(&fixture, policy::long());
    let spec = standard_observation(policy::long())
        .with_venue_equity(NAV_CAP + SEED_RESERVE)
        .with_absolute_notional(2 * NAV_CAP);

    assert_eq!(
        state.initialize(
            spec.into_position_observation(),
            SEED_RESERVE,
            REFERENCE_TIME_MS,
        ),
        NAV_CAP,
    );

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun initialization_admits_both_healthy_leverage_boundaries() {
    let fixture = start(constants::vault_issuer_role!());
    let mut lower = new_state(&fixture, policy::long());
    let mut upper = new_state(&fixture, policy::long());

    lower.initialize(
        standard_observation(policy::long())
            .with_absolute_notional(1_800_000)
            .into_position_observation(),
        SEED_RESERVE,
        REFERENCE_TIME_MS,
    );
    upper.initialize(
        standard_observation(policy::long())
            .with_absolute_notional(2_199_900)
            .into_position_observation(),
        SEED_RESERVE,
        REFERENCE_TIME_MS,
    );

    assert!(lower.is_active_for_testing());
    assert!(upper.is_active_for_testing());
    lower.destroy_for_testing();
    upper.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EMaintenanceReserveExceedsEquity,
    location = blast_leverage_series_one::state,
)]
fun initialization_guard_order_checks_reserve_before_nav() {
    initialize_once(
        standard_observation(policy::long()).with_venue_equity(SEED_RESERVE - 1),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidNav,
    location = blast_leverage_series_one::state,
)]
fun initialization_rejects_zero_shareholder_nav() {
    initialize_once(
        standard_observation(policy::long()).with_venue_equity(SEED_RESERVE),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::ESeriesNavCapExceeded,
    location = blast_leverage_series_one::policy,
)]
fun initialization_rejects_one_unit_above_the_nav_cap() {
    initialize_once(
        standard_observation(policy::long())
            .with_venue_equity(NAV_CAP + SEED_RESERVE + 1)
            .with_absolute_notional(2 * NAV_CAP + 2),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidInitializationObservation,
    location = blast_leverage_series_one::state,
)]
fun initialization_rejects_the_wrong_side() {
    initialize_once(
        standard_observation(policy::long()).with_observed_side(policy::short()),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationOrdersNotEmpty,
    location = blast_leverage_series_one::state,
)]
fun initialization_rejects_pending_orders() {
    initialize_once(
        standard_observation(policy::long()).with_pending_order_count(1),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EStaleValuation,
    location = blast_leverage_series_one::policy,
)]
fun initialization_rejects_a_stale_base_price() {
    initialize_once(
        standard_observation(policy::long()).with_base_publish_time_ms(69_999),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EFutureValuation,
    location = blast_leverage_series_one::policy,
)]
fun initialization_rejects_a_future_base_price() {
    initialize_once(
        standard_observation(policy::long()).with_base_publish_time_ms(102_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EConfidenceExceedsBound,
    location = blast_leverage_series_one::policy,
)]
fun initialization_rejects_a_low_confidence_base_price() {
    initialize_once(
        standard_observation(policy::long()).with_base_confidence(10_000_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EStaleValuation,
    location = blast_leverage_series_one::policy,
)]
fun initialization_rejects_a_stale_collateral_price() {
    initialize_once(
        standard_observation(policy::long()).with_collateral_publish_time_ms(69_999),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EFutureValuation,
    location = blast_leverage_series_one::policy,
)]
fun initialization_rejects_a_future_collateral_price() {
    initialize_once(
        standard_observation(policy::long()).with_collateral_publish_time_ms(102_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EConfidenceExceedsBound,
    location = blast_leverage_series_one::policy,
)]
fun initialization_rejects_a_low_confidence_collateral_price() {
    initialize_once(
        standard_observation(policy::long()).with_collateral_confidence(10_000_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EMarkIndexDivergenceExceedsBound,
    location = blast_leverage_series_one::policy,
)]
fun initialization_rejects_mark_divergence() {
    initialize_once(
        standard_observation(policy::long()).with_mark_price(1_050_000_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationVenueNotOperational,
    location = blast_leverage_series_one::state,
)]
fun initialization_rejects_a_paused_or_frozen_venue() {
    initialize_once(
        standard_observation(policy::long()).with_venue_operational(false),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationCheckpointDirty,
    location = blast_leverage_series_one::state,
)]
fun initialization_rejects_a_dirty_checkpoint() {
    initialize_once(
        standard_observation(policy::long()).with_checkpoint_clean(false),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationMarginUnsafe,
    location = blast_leverage_series_one::state,
)]
fun initialization_rejects_unsafe_margin() {
    initialize_once(
        standard_observation(policy::long()).with_margin_safe(false),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationLeverageUnhealthy,
    location = blast_leverage_series_one::state,
)]
fun initialization_rejects_leverage_one_unit_below_healthy() {
    initialize_once(
        standard_observation(policy::long()).with_absolute_notional(1_799_900),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationLeverageUnhealthy,
    location = blast_leverage_series_one::state,
)]
fun initialization_rejects_leverage_one_unit_above_healthy() {
    initialize_once(
        standard_observation(policy::long()).with_absolute_notional(2_200_000),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationExposureBelowMinimum,
    location = blast_leverage_series_one::state,
)]
fun initialization_rejects_base_below_the_immutable_lot_minimum() {
    initialize_once(
        standard_observation(policy::long()).with_absolute_base(99_000),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun initialization_guard_order_checks_lifecycle_before_reserve() {
    let fixture = start(constants::vault_issuer_role!());
    let mut state = initialized_state(&fixture, policy::long());

    state.initialize(
        standard_observation(policy::long())
            .with_venue_equity(SEED_RESERVE - 1)
            .into_position_observation(),
        SEED_RESERVE,
        REFERENCE_TIME_MS,
    );

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidNav,
    location = blast_leverage_series_one::state,
)]
fun initialization_guard_order_checks_nav_before_base_freshness() {
    initialize_once(
        standard_observation(policy::long())
            .with_venue_equity(SEED_RESERVE)
            .with_base_publish_time_ms(69_999),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EStaleValuation,
    location = blast_leverage_series_one::policy,
)]
fun initialization_guard_order_checks_base_freshness_before_base_confidence() {
    initialize_once(
        standard_observation(policy::long())
            .with_base_publish_time_ms(69_999)
            .with_base_confidence(10_000_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EConfidenceExceedsBound,
    location = blast_leverage_series_one::policy,
)]
fun initialization_guard_order_checks_base_before_collateral_valuation() {
    initialize_once(
        standard_observation(policy::long())
            .with_base_confidence(10_000_001)
            .with_collateral_publish_time_ms(69_999),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EStaleValuation,
    location = blast_leverage_series_one::policy,
)]
fun initialization_guard_order_checks_collateral_freshness_before_confidence() {
    initialize_once(
        standard_observation(policy::long())
            .with_collateral_publish_time_ms(69_999)
            .with_collateral_confidence(10_000_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EConfidenceExceedsBound,
    location = blast_leverage_series_one::policy,
)]
fun initialization_guard_order_checks_collateral_confidence_before_mark() {
    initialize_once(
        standard_observation(policy::long())
            .with_collateral_confidence(10_000_001)
            .with_mark_price(1_050_000_001),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EMarkIndexDivergenceExceedsBound,
    location = blast_leverage_series_one::policy,
)]
fun initialization_guard_order_checks_mark_before_side() {
    initialize_once(
        standard_observation(policy::long())
            .with_mark_price(1_050_000_001)
            .with_observed_side(policy::short()),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidInitializationObservation,
    location = blast_leverage_series_one::state,
)]
fun initialization_guard_order_checks_side_before_orders() {
    initialize_once(
        standard_observation(policy::long())
            .with_observed_side(policy::short())
            .with_pending_order_count(1),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationOrdersNotEmpty,
    location = blast_leverage_series_one::state,
)]
fun initialization_guard_order_checks_orders_before_venue() {
    initialize_once(
        standard_observation(policy::long())
            .with_pending_order_count(1)
            .with_venue_operational(false),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationVenueNotOperational,
    location = blast_leverage_series_one::state,
)]
fun initialization_guard_order_checks_venue_before_checkpoint() {
    initialize_once(
        standard_observation(policy::long())
            .with_venue_operational(false)
            .with_checkpoint_clean(false),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationCheckpointDirty,
    location = blast_leverage_series_one::state,
)]
fun initialization_guard_order_checks_checkpoint_before_margin() {
    initialize_once(
        standard_observation(policy::long())
            .with_checkpoint_clean(false)
            .with_margin_safe(false),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationMarginUnsafe,
    location = blast_leverage_series_one::state,
)]
fun initialization_guard_order_checks_margin_before_nav_cap() {
    initialize_once(
        standard_observation(policy::long())
            .with_margin_safe(false)
            .with_venue_equity(NAV_CAP + SEED_RESERVE + 1),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::ESeriesNavCapExceeded,
    location = blast_leverage_series_one::policy,
)]
fun initialization_guard_order_checks_nav_cap_before_leverage() {
    initialize_once(
        standard_observation(policy::long())
            .with_venue_equity(NAV_CAP + SEED_RESERVE + 1)
            .with_absolute_notional(std::u64::max_value!()),
        policy::long(),
        SEED_RESERVE,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInitializationLeverageUnhealthy,
    location = blast_leverage_series_one::state,
)]
fun initialization_guard_order_checks_leverage_before_minimum_exposure() {
    initialize_once(
        standard_observation(policy::long())
            .with_absolute_notional(3_000_000)
            .with_absolute_base(99_000),
        policy::long(),
        SEED_RESERVE,
    );
}

// --- Per-Order Notional ---

#[test]
fun an_order_at_the_live_maximum_is_allowed() {
    let fixture = start(constants::vault_issuer_role!());
    let state = new_state(&fixture, policy::long());

    state.assert_order_notional_allowed(MAX_ORDER_NOTIONAL_CURRENT);

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
#[expected_failure(
    abort_code = errors::EOrderNotionalExceedsMaximum,
    location = blast_leverage_series_one::state,
)]
fun an_order_one_unit_above_the_live_maximum_is_rejected() {
    let fixture = start(constants::vault_issuer_role!());
    let state = new_state(&fixture, policy::long());

    state.assert_order_notional_allowed(MAX_ORDER_NOTIONAL_CURRENT + 1);

    state.destroy_for_testing();
    destroy(fixture);
}

// --- Funding Settlement ---

#[test]
fun no_funding_leaves_the_reserve_unchanged() {
    assert_funding_settlement(observation::no_funding(), 0, 0, SEED_RESERVE);
}

#[test]
fun positive_funding_leaves_the_reserve_unchanged() {
    assert_funding_settlement(observation::funding_credit(1), 0, 0, SEED_RESERVE);
    assert_funding_settlement(
        observation::funding_credit(std::u64::max_value!()),
        0,
        0,
        SEED_RESERVE,
    );
}

#[test]
fun a_zero_funding_cost_is_an_exact_no_op() {
    assert_funding_settlement(observation::funding_cost(0), 0, 0, SEED_RESERVE);
}

#[test]
fun a_funding_cost_below_the_reserve_is_fully_absorbed() {
    assert_funding_settlement(observation::funding_cost(40_000), 40_000, 0, 60_000);
}

#[test]
fun a_funding_cost_equal_to_the_reserve_exhausts_it_exactly() {
    assert_funding_settlement(
        observation::funding_cost(SEED_RESERVE),
        SEED_RESERVE,
        0,
        0,
    );
}

#[test]
fun a_funding_cost_above_the_reserve_reports_the_uncovered_remainder() {
    assert_funding_settlement(
        observation::funding_cost(150_000),
        SEED_RESERVE,
        50_000,
        0,
    );
}

#[test]
fun the_maximum_funding_cost_cannot_wrap() {
    assert_funding_settlement(
        observation::funding_cost(std::u64::max_value!()),
        SEED_RESERVE,
        std::u64::max_value!() - SEED_RESERVE,
        0,
    );
}

// --- Objective Health ---

#[test]
fun healthy_active_state_stays_active() {
    let fixture = start(constants::vault_issuer_role!());
    let mut state = initialized_state(&fixture, policy::long());

    assert!(!state.sync_health(
        standard_observation(policy::long()).into_position_observation(),
        HEALTH_SHARE_SUPPLY,
        REFERENCE_TIME_MS,
    ));
    assert!(state.is_active_for_testing());

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun reserve_impairment_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_venue_equity(SEED_RESERVE - 1),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun zero_nav_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_venue_equity(SEED_RESERVE),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun stale_oracle_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_base_publish_time_ms(69_999),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun low_confidence_oracle_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_collateral_confidence(10_000_001),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun zero_base_price_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_base_price(0),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun zero_collateral_price_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_collateral_price(0),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun zero_mark_price_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_mark_price(0),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun zero_lot_size_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_lot_size(0),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun structurally_invalid_health_position_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_absolute_notional(0),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun mark_divergence_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_mark_price(1_050_000_001),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun wrong_side_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_observed_side(policy::short()),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun pending_order_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_pending_order_count(1),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun unsafe_margin_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_margin_safe(false),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun paused_or_frozen_venue_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_venue_operational(false),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun dirty_checkpoint_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_checkpoint_clean(false),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun hard_cap_leverage_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_absolute_notional(3_000_000),
        HEALTH_SHARE_SUPPLY,
    );
}

#[test]
fun minimum_operation_exposure_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()).with_absolute_base(MIN_EXPOSURE_LOTS * LOT_SIZE),
        1_000,
    );
}

#[test]
fun redemption_impossible_share_supply_degrades_health_once() {
    assert_health_degrades(
        standard_observation(policy::long()),
        1,
    );
}

#[test]
#[expected_failure(
    abort_code = errors::EInvalidLifecycleTransition,
    location = blast_leverage_series_one::lifecycle,
)]
fun uninitialized_state_cannot_synchronize_health() {
    let fixture = start(constants::vault_issuer_role!());
    let mut state = new_state(&fixture, policy::long());

    state.sync_health(
        standard_observation(policy::long()).into_position_observation(),
        HEALTH_SHARE_SUPPLY,
        REFERENCE_TIME_MS,
    );

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun shutdown_pending_health_never_moves_backward() {
    let fixture = start(constants::vault_issuer_role!());
    let mut state = initialized_state(&fixture, policy::long());
    state.set_shutdown_pending_for_testing();

    assert!(!state.sync_health(
        standard_observation(policy::long())
            .with_venue_equity(SEED_RESERVE - 1)
            .into_position_observation(),
        HEALTH_SHARE_SUPPLY,
        REFERENCE_TIME_MS,
    ));
    assert!(state.is_shutdown_pending_for_testing());

    state.destroy_for_testing();
    destroy(fixture);
}

#[test]
fun shutdown_settled_health_never_moves_backward() {
    let fixture = start(constants::vault_issuer_role!());
    let mut state = initialized_state(&fixture, policy::long());
    state.set_shutdown_settled_for_testing();

    assert!(!state.sync_health(
        standard_observation(policy::long())
            .with_venue_equity(SEED_RESERVE - 1)
            .into_position_observation(),
        HEALTH_SHARE_SUPPLY,
        REFERENCE_TIME_MS,
    ));
    assert!(state.is_shutdown_settled_for_testing());

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
    tier_policy(policy::long())
}

fun tier_policy(side: PositionSide): TierPolicy {
    policy::new_tier_policy(
        side,
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
        MIN_EXPOSURE_LOTS,
        NAV_CAP,
    )
}

fun new_state(fixture: &Fixture, side: PositionSide): State<Product> {
    let witness = fixture.authority.sign_in(&fixture.admin_cap);

    state::new<Product>(
        &witness,
        tier_policy(side),
        MAX_ORDER_NOTIONAL_MINIMUM,
        MAX_ORDER_NOTIONAL_CURRENT,
        MAX_ORDER_NOTIONAL_MAXIMUM,
    )
}

fun initialized_state(fixture: &Fixture, side: PositionSide): State<Product> {
    let mut state = new_state(fixture, side);
    let seed_nav = state.initialize(
        standard_observation(side).into_position_observation(),
        SEED_RESERVE,
        REFERENCE_TIME_MS,
    );
    assert_eq!(seed_nav, SEED_NAV);

    state
}

fun initialize_once(
    spec: ObservationSpec,
    side: PositionSide,
    seed_reserve: u64,
) {
    let fixture = start(constants::vault_issuer_role!());
    let mut state = new_state(&fixture, side);

    state.initialize(
        spec.into_position_observation(),
        seed_reserve,
        REFERENCE_TIME_MS,
    );

    state.destroy_for_testing();
    destroy(fixture);
}

fun assert_funding_settlement(
    settlement: FundingSettlement,
    expected_absorbed: u64,
    expected_uncovered: u64,
    expected_reserve: u64,
) {
    let fixture = start(constants::vault_issuer_role!());
    let mut state = initialized_state(&fixture, policy::long());

    let (absorbed, uncovered) = state.settle_funding(settlement);

    assert_eq!(absorbed, expected_absorbed);
    assert_eq!(uncovered, expected_uncovered);
    assert_eq!(state.maintenance_reserve_for_testing(), expected_reserve);
    assert!(state.is_active_for_testing());
    state.destroy_for_testing();
    destroy(fixture);
}

fun assert_health_degrades(spec: ObservationSpec, share_supply: u64) {
    let fixture = start(constants::vault_issuer_role!());
    let mut state = initialized_state(&fixture, policy::long());

    assert!(state.sync_health(
        spec.into_health_position_observation(),
        share_supply,
        REFERENCE_TIME_MS,
    ));
    assert!(state.is_reduce_only_for_testing());
    assert!(!state.sync_health(
        spec.into_health_position_observation(),
        share_supply,
        REFERENCE_TIME_MS,
    ));
    assert!(state.is_reduce_only_for_testing());
    state.destroy_for_testing();
    destroy(fixture);
}

fun standard_observation(side: PositionSide): ObservationSpec {
    ObservationSpec {
        venue_equity: SEED_VENUE_EQUITY,
        absolute_base: SEED_BASE,
        absolute_notional: SEED_NOTIONAL,
        lot_size: LOT_SIZE,
        observed_side: side,
        pending_order_count: 0,
        margin_safe: true,
        venue_operational: true,
        checkpoint_clean: true,
        base_price: 1_000_000_000,
        base_confidence: 1_000_000,
        base_publish_time_ms: 95_000,
        collateral_price: 1_000_000_000,
        collateral_confidence: 1_000_000,
        collateral_publish_time_ms: 95_000,
        mark_price: 1_000_000_000,
    }
}

fun into_position_observation(self: ObservationSpec): PositionObservation {
    let ObservationSpec {
        venue_equity,
        absolute_base,
        absolute_notional,
        lot_size,
        observed_side,
        pending_order_count,
        margin_safe,
        venue_operational,
        checkpoint_clean,
        base_price,
        base_confidence,
        base_publish_time_ms,
        collateral_price,
        collateral_confidence,
        collateral_publish_time_ms,
        mark_price,
    } = self;

    observation::new_position(
        venue_equity,
        absolute_base,
        absolute_notional,
        lot_size,
        observed_side,
        pending_order_count,
        margin_safe,
        venue_operational,
        checkpoint_clean,
        observation::new_price(base_price, base_confidence, base_publish_time_ms),
        observation::new_price(
            collateral_price,
            collateral_confidence,
            collateral_publish_time_ms,
        ),
        mark_price,
    )
}

fun into_health_position_observation(self: ObservationSpec): PositionObservation {
    let ObservationSpec {
        venue_equity,
        absolute_base,
        absolute_notional,
        lot_size,
        observed_side,
        pending_order_count,
        margin_safe,
        venue_operational,
        checkpoint_clean,
        base_price,
        base_confidence,
        base_publish_time_ms,
        collateral_price,
        collateral_confidence,
        collateral_publish_time_ms,
        mark_price,
    } = self;

    observation::new_health_position(
        venue_equity,
        absolute_base,
        absolute_notional,
        lot_size,
        observed_side,
        pending_order_count,
        margin_safe,
        venue_operational,
        checkpoint_clean,
        observation::new_health_price(base_price, base_confidence, base_publish_time_ms),
        observation::new_health_price(
            collateral_price,
            collateral_confidence,
            collateral_publish_time_ms,
        ),
        mark_price,
    )
}

fun with_venue_equity(mut self: ObservationSpec, venue_equity: u64): ObservationSpec {
    self.venue_equity = venue_equity;
    self
}

fun with_absolute_base(mut self: ObservationSpec, absolute_base: u64): ObservationSpec {
    self.absolute_base = absolute_base;
    self
}

fun with_absolute_notional(mut self: ObservationSpec, absolute_notional: u64): ObservationSpec {
    self.absolute_notional = absolute_notional;
    self
}

fun with_lot_size(mut self: ObservationSpec, lot_size: u64): ObservationSpec {
    self.lot_size = lot_size;
    self
}

fun with_observed_side(mut self: ObservationSpec, observed_side: PositionSide): ObservationSpec {
    self.observed_side = observed_side;
    self
}

fun with_pending_order_count(
    mut self: ObservationSpec,
    pending_order_count: u64,
): ObservationSpec {
    self.pending_order_count = pending_order_count;
    self
}

fun with_margin_safe(mut self: ObservationSpec, margin_safe: bool): ObservationSpec {
    self.margin_safe = margin_safe;
    self
}

fun with_venue_operational(
    mut self: ObservationSpec,
    venue_operational: bool,
): ObservationSpec {
    self.venue_operational = venue_operational;
    self
}

fun with_checkpoint_clean(
    mut self: ObservationSpec,
    checkpoint_clean: bool,
): ObservationSpec {
    self.checkpoint_clean = checkpoint_clean;
    self
}

fun with_base_confidence(mut self: ObservationSpec, base_confidence: u64): ObservationSpec {
    self.base_confidence = base_confidence;
    self
}

fun with_base_price(mut self: ObservationSpec, base_price: u64): ObservationSpec {
    self.base_price = base_price;
    self
}

fun with_base_publish_time_ms(
    mut self: ObservationSpec,
    base_publish_time_ms: u64,
): ObservationSpec {
    self.base_publish_time_ms = base_publish_time_ms;
    self
}

fun with_collateral_confidence(
    mut self: ObservationSpec,
    collateral_confidence: u64,
): ObservationSpec {
    self.collateral_confidence = collateral_confidence;
    self
}

fun with_collateral_price(
    mut self: ObservationSpec,
    collateral_price: u64,
): ObservationSpec {
    self.collateral_price = collateral_price;
    self
}

fun with_collateral_publish_time_ms(
    mut self: ObservationSpec,
    collateral_publish_time_ms: u64,
): ObservationSpec {
    self.collateral_publish_time_ms = collateral_publish_time_ms;
    self
}

fun with_mark_price(mut self: ObservationSpec, mark_price: u64): ObservationSpec {
    self.mark_price = mark_price;
    self
}
