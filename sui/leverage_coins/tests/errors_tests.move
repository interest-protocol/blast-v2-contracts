#[test_only]
module blast_leverage_coins::errors_tests;

use std::unit_test::assert_eq;

// === Tests ===

/// Pins every published abort code so a later module cannot renumber the registry.
#[test]
fun package_error_registry_is_stable() {
    assert_eq!(blast_leverage_coins::errors::zero_amount!(), 0);
    assert_eq!(blast_leverage_coins::errors::invalid_fee_bps!(), 1);
    assert_eq!(blast_leverage_coins::errors::invalid_nav!(), 2);
    assert_eq!(blast_leverage_coins::errors::invalid_share_supply!(), 3);
    assert_eq!(blast_leverage_coins::errors::invalid_share_amount!(), 4);
    assert_eq!(blast_leverage_coins::errors::nonpositive_contribution!(), 5);
    assert_eq!(blast_leverage_coins::errors::zero_shares_out!(), 6);
    assert_eq!(blast_leverage_coins::errors::nonpositive_gross!(), 7);
    assert_eq!(blast_leverage_coins::errors::zero_net_payout!(), 8);
    assert_eq!(
        blast_leverage_coins::errors::invalid_target_leverage_bps!(),
        9,
    );
    assert_eq!(blast_leverage_coins::errors::invalid_lot_size!(), 10);
    assert_eq!(blast_leverage_coins::errors::invalid_base_exposure!(), 11);
    assert_eq!(blast_leverage_coins::errors::sub_lot_exposure_delta!(), 12);
    assert_eq!(
        blast_leverage_coins::errors::redemption_under_reduced!(),
        13,
    );
    assert_eq!(blast_leverage_coins::errors::redemption_over_reduced!(), 14);
    assert_eq!(blast_leverage_coins::errors::arithmetic_overflow!(), 15);
    assert_eq!(
        blast_leverage_coins::errors::maintenance_reserve_exceeds_equity!(),
        16,
    );
    assert_eq!(
        blast_leverage_coins::errors::invalid_lifecycle_transition!(),
        17,
    );
    assert_eq!(
        blast_leverage_coins::errors::operation_not_permitted_in_lifecycle!(),
        18,
    );
    assert_eq!(blast_leverage_coins::errors::mint_over_exposed!(), 19);
    assert_eq!(blast_leverage_coins::errors::mint_under_exposed!(), 20);
    assert_eq!(
        blast_leverage_coins::errors::invalid_min_exposure_lots!(),
        21,
    );
    assert_eq!(blast_leverage_coins::errors::invalid_leverage_bounds!(), 22);
    assert_eq!(blast_leverage_coins::errors::invalid_series_nav_cap!(), 23);
    assert_eq!(blast_leverage_coins::errors::invalid_max_price_age!(), 24);
    assert_eq!(
        blast_leverage_coins::errors::invalid_max_confidence_bps!(),
        25,
    );
    assert_eq!(
        blast_leverage_coins::errors::invalid_max_mark_divergence_bps!(),
        26,
    );
    assert_eq!(blast_leverage_coins::errors::stale_valuation!(), 27);
    assert_eq!(blast_leverage_coins::errors::future_valuation!(), 28);
    assert_eq!(blast_leverage_coins::errors::invalid_valuation_price!(), 29);
    assert_eq!(
        blast_leverage_coins::errors::confidence_exceeds_bound!(),
        30,
    );
    assert_eq!(
        blast_leverage_coins::errors::mark_index_divergence_exceeds_bound!(),
        31,
    );
    assert_eq!(
        blast_leverage_coins::errors::mint_contribution_exceeds_bound!(),
        32,
    );
    assert_eq!(
        blast_leverage_coins::errors::invalid_max_mint_contribution_divergence_bps!(),
        33,
    );
}
