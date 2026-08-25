#[test_only]
module blast_fun::graduation_tests;

use blast_fun::graduation;
use std::unit_test::{assert_eq, destroy};
use sui::balance;

// === Constants ===

const QUOTE_MIGRATION_FEE_BPS: u64 = 250;
const MEME_GRADUATION_ALLOCATION_BPS: u64 = 750;
const MEME_LIQUIDITY_PROVISION_BPS: u64 = 2_000;

// === Test-Only Types ===

public struct TEST_MEME() has drop;
public struct TEST_QUOTE() has drop;

// === Tests ===

#[test]
fun zero_protocol_lines_preserve_independent_asset_conservation() {
    assert_partition(
        10_001,
        0,
        MEME_LIQUIDITY_PROVISION_BPS,
        8_001,
        0,
        2_000,
    );
    assert_quote_partition(10_001, 0, 10_001, 0);
}

#[test]
fun meme_only_protocol_line_rounds_up_without_quote_revenue() {
    assert_partition(
        1_000_001,
        MEME_GRADUATION_ALLOCATION_BPS,
        MEME_LIQUIDITY_PROVISION_BPS,
        725_000,
        75_001,
        200_000,
    );
    assert_quote_partition(1_000_001, 0, 1_000_001, 0);
}

#[test]
fun quote_only_protocol_line_rounds_up_without_meme_revenue() {
    assert_partition(
        1_000_001,
        0,
        MEME_LIQUIDITY_PROVISION_BPS,
        800_001,
        0,
        200_000,
    );
    assert_quote_partition(
        1_000_001,
        QUOTE_MIGRATION_FEE_BPS,
        975_000,
        25_001,
    );
}

#[test]
fun both_protocol_lines_round_up_while_pool_provision_rounds_down() {
    assert_partition(
        1_000_001,
        MEME_GRADUATION_ALLOCATION_BPS,
        MEME_LIQUIDITY_PROVISION_BPS,
        725_000,
        75_001,
        200_000,
    );
    assert_quote_partition(
        1_000_001,
        QUOTE_MIGRATION_FEE_BPS,
        975_000,
        25_001,
    );
}

#[test]
fun maximum_u64_partitions_use_wide_intermediates_and_conserve() {
    assert_partition(
        std::u64::max_value!(),
        1_000,
        8_999,
        1_844_674_407_370_955,
        1_844_674_407_370_955_162,
        16_600_224_991_931_225_498,
    );
    assert_quote_partition(
        std::u64::max_value!(),
        500,
        17_524_406_870_024_074_034,
        922_337_203_685_477_581,
    );
}

#[test]
fun exact_division_has_no_rounding_transfer() {
    assert_partition(10_000, 1_000, 2_000, 7_000, 1_000, 2_000);
    assert_quote_partition(10_000, 500, 9_500, 500);
}

#[test]
fun larger_rates_never_reserve_fewer_atomic_units() {
    let (low_curve, low_allocation, low_provision) = graduation::partition_meme(
        balance::create_for_testing<TEST_MEME>(1_000_001),
        100,
        1_000,
    );
    let (high_curve, high_allocation, high_provision) = graduation::partition_meme(
        balance::create_for_testing<TEST_MEME>(1_000_001),
        200,
        2_000,
    );

    assert!(high_allocation.value() >= low_allocation.value());
    assert!(high_provision.value() >= low_provision.value());
    assert!(high_curve.value() <= low_curve.value());

    destroy(low_curve);
    destroy(low_allocation);
    destroy(low_provision);
    destroy(high_curve);
    destroy(high_allocation);
    destroy(high_provision);
}

#[random_test]
fun valid_random_meme_partitions_conserve(seed: u32) {
    let initial_supply = (seed as u64) + 10_000;
    let allocation_bps = (seed as u64) % 1_001;
    let (curve, allocation, provision) = graduation::partition_meme(
        balance::create_for_testing<TEST_MEME>(initial_supply),
        allocation_bps,
        1_000,
    );

    assert_eq!(
        curve.value() + allocation.value() + provision.value(),
        initial_supply,
    );

    destroy(curve);
    destroy(allocation);
    destroy(provision);
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMemeGraduationAllocationBps,
    location = blast_fun::graduation,
)]
fun meme_partition_rejects_invalid_allocation_before_invalid_provision() {
    let (curve, allocation, provision) = graduation::partition_meme(
        balance::create_for_testing<TEST_MEME>(10_000),
        1_001,
        0,
    );

    destroy(curve);
    destroy(allocation);
    destroy(provision);
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMemeLiquidityProvisionBps,
    location = blast_fun::graduation,
)]
fun meme_partition_rejects_zero_provision_rate() {
    let (curve, allocation, provision) = graduation::partition_meme(
        balance::create_for_testing<TEST_MEME>(10_000),
        0,
        0,
    );

    destroy(curve);
    destroy(allocation);
    destroy(provision);
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidMemeSupplyPartitionBps,
    location = blast_fun::graduation,
)]
fun meme_partition_rejects_rate_partition_without_curve_share() {
    let (curve, allocation, provision) = graduation::partition_meme(
        balance::create_for_testing<TEST_MEME>(10_000),
        1_000,
        9_000,
    );

    destroy(curve);
    destroy(allocation);
    destroy(provision);
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EZeroMemeLiquidityProvision,
    location = blast_fun::graduation,
)]
fun meme_partition_rejects_positive_rate_that_rounds_to_zero_provision() {
    let (curve, allocation, provision) = graduation::partition_meme(
        balance::create_for_testing<TEST_MEME>(9_999),
        0,
        1,
    );

    destroy(curve);
    destroy(allocation);
    destroy(provision);
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EZeroMemeCurveInventory,
    location = blast_fun::graduation,
)]
fun meme_partition_rejects_rounding_that_consumes_curve_inventory() {
    let (curve, allocation, provision) = graduation::partition_meme(
        balance::create_for_testing<TEST_MEME>(2),
        1,
        5_000,
    );

    destroy(curve);
    destroy(allocation);
    destroy(provision);
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidQuoteMigrationFeeBps,
    location = blast_fun::graduation,
)]
fun quote_partition_rejects_fee_above_ceiling() {
    let (net_quote, migration_fee) = graduation::partition_quote(
        balance::create_for_testing<TEST_QUOTE>(10_000),
        501,
    );

    destroy(net_quote);
    destroy(migration_fee);
}

// === Private Test Helpers ===

fun assert_partition(
    initial_supply: u64,
    allocation_bps: u64,
    provision_bps: u64,
    expected_curve: u64,
    expected_allocation: u64,
    expected_provision: u64,
) {
    let (curve, allocation, provision) = graduation::partition_meme(
        balance::create_for_testing<TEST_MEME>(initial_supply),
        allocation_bps,
        provision_bps,
    );

    assert_eq!(curve.value(), expected_curve);
    assert_eq!(allocation.value(), expected_allocation);
    assert_eq!(provision.value(), expected_provision);
    assert_eq!(
        curve.value() + allocation.value() + provision.value(),
        initial_supply,
    );

    destroy(curve);
    destroy(allocation);
    destroy(provision);
}

fun assert_quote_partition(
    gross_quote: u64,
    fee_bps: u64,
    expected_net_quote: u64,
    expected_fee: u64,
) {
    let (net_quote, migration_fee) = graduation::partition_quote(
        balance::create_for_testing<TEST_QUOTE>(gross_quote),
        fee_bps,
    );

    assert_eq!(net_quote.value(), expected_net_quote);
    assert_eq!(migration_fee.value(), expected_fee);
    assert_eq!(net_quote.value() + migration_fee.value(), gross_quote);

    destroy(net_quote);
    destroy(migration_fee);
}
