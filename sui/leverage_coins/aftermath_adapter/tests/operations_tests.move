#[test_only]
/// Tests for atomic Aftermath Vault initialization seams.
module blast_leverage_aftermath::operations_tests;

use blast_leverage_aftermath::{events, operations, venue_account};
use blast_leverage_series_one::policy;
use std::type_name;
use std::unit_test::assert_eq;

// === Test-Only Types ===

public struct Product {}

public struct Collateral {}

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
