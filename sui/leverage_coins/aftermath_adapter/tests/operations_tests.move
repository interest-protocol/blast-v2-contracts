#[test_only]
/// Tests for atomic Aftermath Vault initialization seams.
module blast_leverage_aftermath::operations_tests;

use blast_leverage_aftermath::{events, operations, snapshot, venue_account};
use blast_leverage_series_one::policy;
use std::type_name;
use std::unit_test::assert_eq;

// === Test-Only Types ===

public struct Product {}

public struct Collateral {}

public struct RiskModule {}

public struct RiskModuleV2 {}

public struct ReplayState has drop {
    vault_id: ID,
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
    collateral_type: type_name::TypeName,
    maintenance_reserve: u64,
    lifecycle: u8,
    risk_module_witness: type_name::TypeName,
    max_order_notional: u64,
    checkpoint: venue_account::Checkpoint,
}

// === Tests ===

#[test]
fun target_above_one_order_cap_splits_into_compliant_whole_lot_orders() {
    let orders = operations::order_sizes_for_testing(
        100_000_000,
        30_000_000,
        2_000_000_000,
        1_000_000_000,
        1_000_000,
    );

    assert_eq!(orders, vector[15_000_000_000, 15_000_000_000, 15_000_000_000, 5_000_000_000]);
}

#[test]
fun target_and_order_cap_round_down_to_whole_base_lots() {
    let orders = operations::order_sizes_for_testing(
        10_000_001,
        6_000_001,
        2_000_000_000,
        1_000_000_000,
        1_000_000_000,
    );

    assert_eq!(orders, vector[3_000_000_000, 2_000_000_000]);
}

#[test]
#[expected_failure(abort_code = 32, location = blast_leverage_aftermath::operations)]
fun target_below_one_lot_is_rejected() {
    operations::order_sizes_for_testing(
        1,
        1,
        2_000_000_000,
        1_000_000_000,
        1_000_000_000,
    );
}

#[test]
#[expected_failure(abort_code = 32, location = blast_leverage_aftermath::operations)]
fun a_zero_target_is_rejected_as_an_invalid_order_size() {
    operations::order_sizes_for_testing(
        0,
        1,
        2_000_000_000,
        1_000_000_000,
        1,
    );
}

#[test]
#[expected_failure(abort_code = 32, location = blast_leverage_aftermath::operations)]
fun a_zero_order_cap_is_rejected_as_an_invalid_order_size() {
    operations::order_sizes_for_testing(
        1,
        0,
        2_000_000_000,
        1_000_000_000,
        1,
    );
}

#[test]
fun initialization_order_count_accepts_zero_remaining_and_the_fixed_maximum() {
    assert_eq!(operations::max_initialization_orders_for_testing(), 16);
    assert_eq!(operations::order_count_for_testing(0, 1), 0);
    assert_eq!(operations::order_count_for_testing(16, 1), 16);
}

#[test]
fun maximum_order_count_preserves_the_exact_total_and_per_order_cap() {
    let orders = operations::order_sizes_for_testing(
        16,
        1,
        1_000_000_000,
        1_000_000_000,
        1,
    );
    let mut total = 0;
    let mut index = 0;
    while (index < orders.length()) {
        let order = *orders.borrow(index);
        assert_eq!(order, 1_000);
        total = total + order;
        index = index + 1;
    };

    assert_eq!(orders.length(), 16);
    assert_eq!(total, 16_000);
}

#[test]
#[expected_failure(abort_code = 38, location = blast_leverage_aftermath::operations)]
fun initialization_order_count_rejects_the_first_value_above_the_maximum() {
    operations::order_count_for_testing(17, 1);
}

#[test]
fun initialization_order_count_ceil_does_not_add_before_dividing() {
    assert_eq!(
        operations::order_count_for_testing(
            std::u64::max_value!(),
            std::u64::max_value!() - 1,
        ),
        2,
    );
}

#[test]
#[expected_failure(abort_code = 32, location = blast_leverage_aftermath::operations)]
fun one_lot_above_the_order_cap_is_rejected() {
    operations::order_sizes_for_testing(
        2_000_000,
        1_999_999,
        2_000_000_000,
        1_000_000_000,
        1_000_000_000,
    );
}

#[test]
fun exact_long_and_short_full_fills_are_accepted() {
    operations::assert_session_result_for_testing(
        true,
        5_000_000_000,
        5_000_000_000_000_000_000,
        0,
        0,
        0,
        0,
    );
    operations::assert_session_result_for_testing(
        false,
        5_000_000_000,
        0,
        5_000_000_000_000_000_000,
        0,
        0,
        0,
    );
}

#[test]
fun series_side_maps_to_the_deployed_aftermath_order_side() {
    assert_eq!(operations::order_side_for_testing(policy::long()), false);
    assert_eq!(operations::order_side_for_testing(policy::short()), true);
}

#[test]
#[expected_failure(abort_code = 33, location = blast_leverage_aftermath::operations)]
fun a_partial_fill_is_rejected() {
    operations::assert_session_result_for_testing(
        true,
        5_000_000_000,
        4_999_999_999_000_000_000,
        0,
        0,
        0,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 33, location = blast_leverage_aftermath::operations)]
fun a_fill_on_the_wrong_side_is_rejected() {
    operations::assert_session_result_for_testing(
        true,
        5_000_000_000,
        0,
        5_000_000_000_000_000_000,
        0,
        0,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 34, location = blast_leverage_aftermath::operations)]
fun a_posted_order_is_rejected_before_fill_validation() {
    operations::assert_session_result_for_testing(
        true,
        5_000_000_000,
        0,
        0,
        1,
        0,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 35, location = blast_leverage_aftermath::operations)]
fun a_liquidation_is_rejected_before_fill_validation() {
    operations::assert_session_result_for_testing(
        true,
        5_000_000_000,
        0,
        0,
        0,
        1,
        0,
    );
}

#[test]
#[expected_failure(abort_code = 35, location = blast_leverage_aftermath::operations)]
fun bad_debt_is_rejected_before_fill_validation() {
    operations::assert_session_result_for_testing(
        true,
        5_000_000_000,
        0,
        0,
        0,
        0,
        1,
    );
}

#[test]
fun valid_local_initialization_inputs_are_accepted() {
    operations::assert_initialization_inputs_for_testing(false, 6, 100, 10, 0);
}

#[test]
#[expected_failure(abort_code = 19, location = blast_leverage_aftermath::vault)]
fun already_initialized_precedes_currency_and_seed_validation() {
    operations::assert_initialization_inputs_for_testing(true, 7, 0, 0, 1);
}

#[test]
#[expected_failure(abort_code = 28, location = blast_leverage_aftermath::operations)]
fun non_six_decimal_collateral_is_rejected_before_seed_validation() {
    operations::assert_initialization_inputs_for_testing(false, 7, 0, 0, 1);
}

#[test]
#[expected_failure(abort_code = 29, location = blast_leverage_aftermath::operations)]
fun a_zero_seed_is_rejected_before_reserve_validation() {
    operations::assert_initialization_inputs_for_testing(false, 6, 0, 1, 1);
}

#[test]
#[expected_failure(abort_code = 30, location = blast_leverage_aftermath::operations)]
fun a_reserve_equal_to_the_seed_is_rejected_before_supply_validation() {
    operations::assert_initialization_inputs_for_testing(false, 6, 100, 100, 1);
}

#[test]
#[expected_failure(abort_code = 31, location = blast_leverage_aftermath::operations)]
fun preexisting_share_supply_is_rejected() {
    operations::assert_initialization_inputs_for_testing(false, 6, 100, 10, 1);
}

#[test]
fun locked_share_scaling_accepts_the_largest_seed_nav() {
    assert_eq!(
        operations::locked_shares_for_testing(std::u64::max_value!() / 1_000),
        std::u64::max_value!() / 1_000 * 1_000,
    );
}

#[test]
#[expected_failure(abort_code = 37, location = blast_leverage_aftermath::operations)]
fun locked_share_scaling_rejects_the_first_overflow() {
    operations::locked_shares_for_testing(std::u64::max_value!() / 1_000 + 1);
}

#[test]
fun execution_price_rounds_against_the_vault() {
    assert_eq!(
        operations::execution_price_for_testing(2_000_000_000_000_000_001, true, false),
        2_000_000_001,
    );
    assert_eq!(
        operations::execution_price_for_testing(2_000_000_000_999_999_999, false, false),
        2_000_000_000,
    );
}

#[test]
#[expected_failure(abort_code = 26, location = blast_leverage_aftermath::operations)]
fun negative_execution_price_is_rejected() {
    operations::execution_price_for_testing(1, true, true);
}

#[test]
#[expected_failure(abort_code = 26, location = blast_leverage_aftermath::operations)]
fun unrepresentable_execution_price_is_rejected() {
    operations::execution_price_for_testing(std::u256::max_value!(), false, false);
}

#[test]
fun nonnegative_position_imr_is_accepted() {
    operations::assert_position_imr_for_testing(false);
}

#[test]
#[expected_failure(abort_code = 36, location = blast_leverage_aftermath::operations)]
fun negative_position_imr_is_rejected() {
    operations::assert_position_imr_for_testing(true);
}

#[test]
fun vault_initialized_event_records_every_activation_primitive() {
    let checkpoint = venue_account::checkpoint_for_testing(
        11,
        12,
        13,
        14,
        15,
        16,
        17,
        18,
        19,
        20,
        21,
        22,
        23,
        false,
        24,
        25,
        26,
    );
    events::vault_initialized<Product>(
        @0xA.to_id(),
        @0xB.to_id(),
        27,
        @0xC.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        @0xF.to_id(),
        type_name::with_original_ids<Collateral>(),
        28,
        29,
        30,
        31,
        32,
        33,
        34,
        35,
        policy::short(),
        36,
        checkpoint,
    );

    let event = events::collect_one<events::VaultInitialized<Product>>(0);
    let (
        vault_id,
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
        seed_amount,
        seed_venue_equity,
        seed_reserve,
        seed_shareholder_nav,
        locked_shares,
        absolute_base,
        absolute_notional,
        lot_size,
        side,
        position_imr,
        event_checkpoint,
    ) = event.vault_initialized_fields();

    assert_eq!(vault_id, @0xA.to_id());
    assert_eq!(account_object_id, @0xB.to_id());
    assert_eq!(account_number, 27);
    assert_eq!(registry_id, @0xC.to_id());
    assert_eq!(clearing_house_id, @0xD.to_id());
    assert_eq!(base_oracle_id, @0xE.to_id());
    assert_eq!(collateral_oracle_id, @0xF.to_id());
    assert_eq!(collateral_type, type_name::with_original_ids<Collateral>());
    assert_eq!(seed_amount, 28);
    assert_eq!(seed_venue_equity, 29);
    assert_eq!(seed_reserve, 30);
    assert_eq!(seed_shareholder_nav, 31);
    assert_eq!(locked_shares, 32);
    assert_eq!(absolute_base, 33);
    assert_eq!(absolute_notional, 34);
    assert_eq!(lot_size, 35);
    assert_eq!(side, policy::short());
    assert_eq!(position_imr, 36);
    assert_eq!(event_checkpoint, checkpoint);
}

#[test]
fun synchronization_classifies_no_change_and_replay_as_no_funding() {
    let before = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);

    let first = operations::classify_sync_change_for_testing(
        &before,
        &before,
        &before,
        false,
        0,
    );
    assert!(snapshot::is_unchanged_for_testing(first));

    let after = sync_checkpoint(1_000, 110_000_000_000_000, 11, 21, 11, 21, 0, 0, 0);
    let replay = operations::classify_sync_change_for_testing(
        &after,
        &after,
        &after,
        false,
        0,
    );
    assert!(snapshot::is_unchanged_for_testing(replay));
}

#[test]
fun synchronization_accepts_only_an_isolated_funding_credit() {
    let stored = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let after = sync_checkpoint(1_000, 110_000_000_000_000, 11, 21, 11, 21, 0, 0, 0);

    let change = operations::classify_sync_change_for_testing(
        &stored,
        &stored,
        &after,
        false,
        10_000_000_000_000,
    );
    let (has_funding, is_cost, raw_amount, amount, checkpoint_clean) =
        operations::funding_change_fields_for_testing(&change);

    assert!(has_funding);
    assert!(!is_cost);
    assert_eq!(raw_amount, 10_000_000_000_000);
    assert_eq!(amount, 10);
    assert!(checkpoint_clean);
    assert!(snapshot::is_credit_for_testing(change));
}

#[test]
fun synchronization_rounds_an_isolated_funding_cost_against_the_reserve() {
    let stored = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let after = sync_checkpoint(1_000, 99_000_000_000_001, 11, 21, 11, 21, 0, 0, 0);

    let change = operations::classify_sync_change_for_testing(
        &stored,
        &stored,
        &after,
        true,
        999_999_999_999,
    );
    let (has_funding, is_cost, raw_amount, amount, checkpoint_clean) =
        operations::funding_change_fields_for_testing(&change);

    assert!(has_funding);
    assert!(is_cost);
    assert_eq!(raw_amount, 999_999_999_999);
    assert_eq!(amount, 1);
    assert!(checkpoint_clean);
    assert!(snapshot::is_cost_for_testing(change));
}

#[test]
fun preexisting_pnl_collateral_or_liquidation_change_is_never_funding() {
    let stored = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let clean_after = sync_checkpoint(1_000, 110_000_000_000_000, 11, 21, 11, 21, 0, 0, 0);
    let pnl_before = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 1, 0, 0);
    let collateral_before = sync_checkpoint(999, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let liquidation_after = sync_checkpoint(1_000, 110_000_000_000_000, 11, 21, 11, 21, 0, 1, 0);

    assert_unexpected_sync_change(&stored, &pnl_before, &clean_after);
    assert_unexpected_sync_change(&stored, &collateral_before, &clean_after);
    assert_unexpected_sync_change(&stored, &stored, &liquidation_after);
}

#[test]
fun stored_drift_plus_an_exact_settlement_is_unexpected_and_not_funding() {
    let stored = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let before = sync_checkpoint(999, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let after = sync_checkpoint(999, 110_000_000_000_000, 11, 21, 11, 21, 0, 0, 0);

    assert_unexpected_sync_change(&stored, &before, &after);
}

#[test]
fun funding_event_records_exact_amount_reserve_effect_and_checkpoint() {
    let previous_checkpoint = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 0);
    let checkpoint = sync_checkpoint(1_000, 90_000_000_000_000, 11, 21, 11, 21, 0, 0, 0);

    events::funding_settled<Product>(
        @0xA.to_id(),
        true,
        10_000_000_000_000,
        10,
        10,
        0,
        90,
        previous_checkpoint,
        checkpoint,
    );
    let event = events::collect_one<events::FundingSettled<Product>>(0);
    let (
        vault_id,
        is_cost,
        raw_amount,
        amount,
        absorbed,
        uncovered,
        reserve_after,
        event_previous_checkpoint,
        event_checkpoint,
    ) = event.funding_settled_fields();

    assert_eq!(vault_id, @0xA.to_id());
    assert!(is_cost);
    assert_eq!(raw_amount, 10_000_000_000_000);
    assert_eq!(amount, 10);
    assert_eq!(absorbed, 10);
    assert_eq!(uncovered, 0);
    assert_eq!(reserve_after, 90);
    assert_eq!(event_previous_checkpoint, previous_checkpoint);
    assert_eq!(event_checkpoint, checkpoint);
}

#[test]
fun health_event_records_stable_reason_and_latest_checkpoint() {
    let checkpoint = sync_checkpoint(1_000, 100_000_000_000_000, 10, 20, 11, 21, 0, 0, 1);

    events::health_synchronized<Product>(
        @0xA.to_id(),
        events::unexpected_checkpoint_reason(),
        true,
        checkpoint,
    );
    let event = events::collect_one<events::HealthSynchronized<Product>>(0);
    let (vault_id, reason, lifecycle_changed, event_checkpoint) =
        event.health_synchronized_fields();

    assert_eq!(vault_id, @0xA.to_id());
    assert_eq!(reason, events::unexpected_checkpoint_reason());
    assert!(lifecycle_changed);
    assert_eq!(event_checkpoint, checkpoint);
}

#[test]
fun health_event_decision_is_quiet_when_healthy_and_stable_when_degraded() {
    let (emit_healthy, healthy_reason) =
        operations::health_event_decision_for_testing(false, true);
    let (emit_objective, objective_reason) =
        operations::health_event_decision_for_testing(true, true);
    let (emit_unexpected, unexpected_reason) =
        operations::health_event_decision_for_testing(false, false);

    assert!(!emit_healthy);
    assert_eq!(healthy_reason, events::objective_failure_reason());
    assert!(emit_objective);
    assert_eq!(objective_reason, events::objective_failure_reason());
    assert!(emit_unexpected);
    assert_eq!(unexpected_reason, events::unexpected_checkpoint_reason());
}

#[test]
fun reducer_reconstructs_every_canonical_vault_fact_from_the_event_stream() {
    let vault_id = @0xA.to_id();
    let initial_checkpoint = sync_checkpoint(
        1_000,
        100_000_000_000_000,
        10,
        20,
        11,
        21,
        0,
        0,
        0,
    );
    let funded_checkpoint = sync_checkpoint(
        1_000,
        90_000_000_000_000,
        11,
        21,
        11,
        21,
        0,
        0,
        0,
    );
    let final_checkpoint = sync_checkpoint(
        999,
        90_000_000_000_000,
        11,
        21,
        11,
        21,
        0,
        0,
        0,
    );

    events::vault_issued<Product>(
        vault_id,
        @0x1.to_id(),
        @0x2.to_id(),
        type_name::with_original_ids<RiskModule>(),
        standard_tier_policy(),
        100,
        250,
        1_000,
        0,
    );
    events::vault_initialized<Product>(
        vault_id,
        @0xB.to_id(),
        7,
        @0xC.to_id(),
        @0xD.to_id(),
        @0xE.to_id(),
        @0xF.to_id(),
        type_name::with_original_ids<Collateral>(),
        1_000,
        1_000,
        100,
        900,
        900_000,
        1_000,
        1_800,
        1,
        policy::long(),
        1,
        initial_checkpoint,
    );
    events::funding_settled<Product>(
        vault_id,
        true,
        10_000_000_000_000,
        10,
        10,
        0,
        90,
        initial_checkpoint,
        funded_checkpoint,
    );
    events::max_order_notional_updated<Product>(vault_id, 250, 300);
    events::risk_module_witness_rotated<Product>(
        vault_id,
        type_name::with_original_ids<RiskModule>(),
        type_name::with_original_ids<RiskModuleV2>(),
    );
    events::reduce_only_entered<Product>(vault_id);
    events::health_synchronized<Product>(
        vault_id,
        events::unexpected_checkpoint_reason(),
        false,
        final_checkpoint,
    );

    let mut replay = replay_issued(
        events::collect_one<events::VaultIssued<Product>>(0),
        initial_checkpoint,
    );
    replay_initialized(
        &mut replay,
        events::collect_one<events::VaultInitialized<Product>>(0),
    );
    replay_funding(
        &mut replay,
        events::collect_one<events::FundingSettled<Product>>(0),
    );
    replay_max_order_notional(
        &mut replay,
        events::collect_one<events::MaxOrderNotionalUpdated<Product>>(0),
    );
    replay_risk_rotation(
        &mut replay,
        events::collect_one<events::RiskModuleWitnessRotated<Product>>(0),
    );
    replay_reduce_only(
        &mut replay,
        events::collect_one<events::ReduceOnlyEntered<Product>>(0),
    );
    replay_health(
        &mut replay,
        events::collect_one<events::HealthSynchronized<Product>>(0),
    );

    assert_eq!(replay.vault_id, vault_id);
    assert_eq!(replay.account_object_id, @0xB.to_id());
    assert_eq!(replay.account_number, 7);
    assert_eq!(replay.registry_id, @0xC.to_id());
    assert_eq!(replay.clearing_house_id, @0xD.to_id());
    assert_eq!(replay.base_oracle_id, @0xE.to_id());
    assert_eq!(replay.collateral_oracle_id, @0xF.to_id());
    assert_eq!(replay.collateral_type, type_name::with_original_ids<Collateral>());
    assert_eq!(replay.maintenance_reserve, 90);
    assert_eq!(replay.lifecycle, 2);
    assert_eq!(replay.risk_module_witness, type_name::with_original_ids<RiskModuleV2>());
    assert_eq!(replay.max_order_notional, 300);
    assert_eq!(replay.checkpoint, final_checkpoint);
}

// === Test Helpers ===

fun sync_checkpoint(
    free_collateral: u64,
    allocated_collateral: u256,
    funding_snapshot_long: u256,
    funding_snapshot_short: u256,
    market_funding_long: u256,
    market_funding_short: u256,
    signed_quote_notional: u256,
    signed_base: u256,
    pending_order_count: u64,
): venue_account::Checkpoint {
    venue_account::checkpoint_for_testing(
        free_collateral,
        allocated_collateral,
        signed_base,
        signed_quote_notional,
        funding_snapshot_long,
        funding_snapshot_short,
        market_funding_long,
        market_funding_short,
        1,
        0,
        0,
        pending_order_count,
        0,
        false,
        1,
        1,
        1,
    )
}

fun assert_unexpected_sync_change(
    stored: &venue_account::Checkpoint,
    before: &venue_account::Checkpoint,
    after: &venue_account::Checkpoint,
) {
    let change = operations::classify_sync_change_for_testing(
        stored,
        before,
        after,
        false,
        10_000_000_000_000,
    );
    let (has_funding, _, _, _, checkpoint_clean) =
        operations::funding_change_fields_for_testing(&change);

    assert!(!has_funding);
    assert!(!checkpoint_clean);
    assert!(snapshot::is_unexpected_for_testing(change));
}

fun standard_tier_policy(): policy::TierPolicy {
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

fun replay_issued(
    event: events::VaultIssued<Product>,
    checkpoint: venue_account::Checkpoint,
): ReplayState {
    let (
        vault_id,
        _,
        _,
        risk_module_witness,
        _,
        _,
        max_order_notional,
        _,
        maintenance_reserve,
    ) = event.vault_issued_fields();

    ReplayState {
        vault_id,
        account_object_id: @0x0.to_id(),
        account_number: 0,
        registry_id: @0x0.to_id(),
        clearing_house_id: @0x0.to_id(),
        base_oracle_id: @0x0.to_id(),
        collateral_oracle_id: @0x0.to_id(),
        collateral_type: type_name::with_original_ids<u8>(),
        maintenance_reserve,
        lifecycle: 0,
        risk_module_witness,
        max_order_notional,
        checkpoint,
    }
}

fun replay_initialized(
    replay: &mut ReplayState,
    event: events::VaultInitialized<Product>,
) {
    let (
        vault_id,
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
        _,
        _,
        maintenance_reserve,
        _,
        _,
        _,
        _,
        _,
        _,
        _,
        checkpoint,
    ) = event.vault_initialized_fields();
    assert_eq!(vault_id, replay.vault_id);

    replay.account_object_id = account_object_id;
    replay.account_number = account_number;
    replay.registry_id = registry_id;
    replay.clearing_house_id = clearing_house_id;
    replay.base_oracle_id = base_oracle_id;
    replay.collateral_oracle_id = collateral_oracle_id;
    replay.collateral_type = collateral_type;
    replay.maintenance_reserve = maintenance_reserve;
    replay.lifecycle = 1;
    replay.checkpoint = checkpoint;
}

fun replay_funding(
    replay: &mut ReplayState,
    event: events::FundingSettled<Product>,
) {
    let (vault_id, _, _, _, absorbed, _, reserve_after, previous_checkpoint, checkpoint) =
        event.funding_settled_fields();
    assert_eq!(vault_id, replay.vault_id);
    assert_eq!(previous_checkpoint, replay.checkpoint);

    assert_eq!(reserve_after, replay.maintenance_reserve - absorbed);
    replay.maintenance_reserve = reserve_after;
    replay.checkpoint = checkpoint;
}

fun replay_max_order_notional(
    replay: &mut ReplayState,
    event: events::MaxOrderNotionalUpdated<Product>,
) {
    let (vault_id, previous, current) = event.max_order_notional_updated_fields();
    assert_eq!(vault_id, replay.vault_id);
    assert_eq!(previous, replay.max_order_notional);
    replay.max_order_notional = current;
}

fun replay_risk_rotation(
    replay: &mut ReplayState,
    event: events::RiskModuleWitnessRotated<Product>,
) {
    let (vault_id, previous, current) = event.risk_module_witness_rotated_fields();
    assert_eq!(vault_id, replay.vault_id);
    assert_eq!(previous, replay.risk_module_witness);
    replay.risk_module_witness = current;
}

fun replay_reduce_only(
    replay: &mut ReplayState,
    event: events::ReduceOnlyEntered<Product>,
) {
    assert_eq!(event.reduce_only_entered_vault_id(), replay.vault_id);
    replay.lifecycle = 2;
}

fun replay_health(
    replay: &mut ReplayState,
    event: events::HealthSynchronized<Product>,
) {
    let (vault_id, _, lifecycle_changed, checkpoint) =
        event.health_synchronized_fields();
    assert_eq!(vault_id, replay.vault_id);
    if (lifecycle_changed) {
        replay.lifecycle = 2;
    };
    replay.checkpoint = checkpoint;
}
