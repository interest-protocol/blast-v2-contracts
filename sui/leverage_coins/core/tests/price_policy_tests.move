#[test_only]
/// Validation and gate tests for the immutable Series valuation policy.
module blast_leverage_core::price_policy_tests;

use std::unit_test::assert_eq;

use blast_leverage_core::{policy};

// === Tests ===

#[test]
fun the_strictest_valid_policy_is_accepted_and_preserved() {
    let policy = policy::new_price_policy(1, 0, 0, 0);

    assert_eq!(policy.max_price_age_ms(), 1);
    assert_eq!(policy.max_price_ahead_ms(), 0);
    assert_eq!(policy.max_confidence_bps(), 0);
    assert_eq!(policy.max_mark_divergence_bps(), 0);
}

#[test]
fun the_largest_locally_valid_policy_is_accepted_and_preserved() {
    let max = std::u64::max_value!();
    let policy = policy::new_price_policy(max, max, 9_999, 9_999);

    assert_eq!(policy.max_price_age_ms(), max);
    assert_eq!(policy.max_price_ahead_ms(), max);
    assert_eq!(policy.max_confidence_bps(), 9_999);
    assert_eq!(policy.max_mark_divergence_bps(), 9_999);
}

#[test]
fun every_small_valid_policy_tuple_is_accepted_and_preserved() {
    1u64.range_do!(4, |max_price_age_ms| {
        0u64.range_do!(max_price_age_ms + 1, |max_price_ahead_ms| {
            0u64.range_do!(4, |max_confidence_bps| {
                0u64.range_do!(4, |max_mark_divergence_bps| {
                    let policy = policy::new_price_policy(
                        max_price_age_ms,
                        max_price_ahead_ms,
                        max_confidence_bps,
                        max_mark_divergence_bps,
                    );

                    assert_eq!(policy.max_price_age_ms(), max_price_age_ms);
                    assert_eq!(policy.max_price_ahead_ms(), max_price_ahead_ms);
                    assert_eq!(policy.max_confidence_bps(), max_confidence_bps);
                    assert_eq!(
                        policy.max_mark_divergence_bps(),
                        max_mark_divergence_bps,
                    );
                });
            });
        });
    });
}

#[test]
fun a_policy_is_a_copyable_immutable_value() {
    let policy = policy::new_price_policy(2, 1, 3, 4);
    let copied_policy = policy;

    assert_eq!(policy.max_price_age_ms(), 2);
    assert_eq!(policy.max_price_age_ms(), copied_policy.max_price_age_ms());
    assert_eq!(policy.max_price_ahead_ms(), copied_policy.max_price_ahead_ms());
    assert_eq!(policy.max_confidence_bps(), copied_policy.max_confidence_bps());
    assert_eq!(
        policy.max_mark_divergence_bps(),
        copied_policy.max_mark_divergence_bps(),
    );
}

#[test]
#[expected_failure(
    abort_code = policy::EInvalidMaxPriceAge, location = blast_leverage_core::policy,
)]
fun a_zero_freshness_budget_is_rejected() {
    policy::new_price_policy(0, 0, 0, 0);
}

#[test]
fun an_equal_skew_and_age_budget_is_accepted() {
    let policy = policy::new_price_policy(30_000, 30_000, 0, 0);

    assert_eq!(policy.max_price_ahead_ms(), policy.max_price_age_ms());
}

/// A transposed `(age, ahead)` pair would reject aged updates and admit future ones.
#[test]
#[expected_failure(
    abort_code = policy::EInvalidFreshnessWindow, location = blast_leverage_core::policy,
)]
fun a_skew_budget_above_the_age_budget_is_rejected() {
    policy::new_price_policy(2_000, 30_000, 0, 0);
}

#[test]
#[expected_failure(
    abort_code = policy::EInvalidMaxPriceAge, location = blast_leverage_core::policy,
)]
fun freshness_budget_validation_precedes_window_validation() {
    policy::new_price_policy(0, 1, 0, 0);
}

#[test]
#[expected_failure(
    abort_code = policy::EInvalidFreshnessWindow, location = blast_leverage_core::policy,
)]
fun window_validation_precedes_both_relative_bound_validations() {
    policy::new_price_policy(1, 2, 10_000, 10_000);
}

#[test]
#[expected_failure(
    abort_code = policy::EInvalidMaxConfidenceBps, location = blast_leverage_core::policy,
)]
fun a_confidence_bound_at_the_denominator_is_rejected() {
    policy::new_price_policy(1, 0, 10_000, 0);
}

#[test]
#[expected_failure(
    abort_code = policy::EInvalidMaxConfidenceBps, location = blast_leverage_core::policy,
)]
fun a_confidence_bound_above_the_denominator_is_rejected() {
    policy::new_price_policy(1, 0, std::u64::max_value!(), 0);
}

#[test]
#[expected_failure(
    abort_code = policy::EInvalidMaxMarkDivergenceBps, location = blast_leverage_core::policy,
)]
fun a_mark_divergence_bound_at_the_denominator_is_rejected() {
    policy::new_price_policy(1, 0, 0, 10_000);
}

#[test]
#[expected_failure(
    abort_code = policy::EInvalidMaxMarkDivergenceBps, location = blast_leverage_core::policy,
)]
fun a_mark_divergence_bound_above_the_denominator_is_rejected() {
    policy::new_price_policy(1, 0, 0, std::u64::max_value!());
}

#[test]
#[expected_failure(
    abort_code = policy::EInvalidMaxPriceAge, location = blast_leverage_core::policy,
)]
fun freshness_validation_precedes_both_relative_bound_validations() {
    policy::new_price_policy(0, 0, 10_000, 10_000);
}

#[test]
#[expected_failure(
    abort_code = policy::EInvalidMaxConfidenceBps, location = blast_leverage_core::policy,
)]
fun confidence_validation_precedes_mark_divergence_validation() {
    policy::new_price_policy(1, 0, 10_000, 10_000);
}

#[test]
fun the_freshness_window_matches_the_saturating_interval_model() {
    1u64.range_do!(4, |max_price_age_ms| {
        0u64.range_do!(max_price_age_ms + 1, |max_price_ahead_ms| {
            let policy = freshness_policy(max_price_age_ms, max_price_ahead_ms);

            0u64.range_do!(9, |reference_time_ms| {
                0u64.range_do!(9, |published_at_ms| {
                    let window_start = reference_time_ms.saturating_sub(
                        max_price_age_ms,
                    );
                    let window_end = reference_time_ms.saturating_add(
                        max_price_ahead_ms,
                    );
                    let is_fresh =
                        published_at_ms >= window_start
                            && published_at_ms <= window_end;

                    assert_eq!(
                        policy.is_price_fresh(published_at_ms, reference_time_ms),
                        is_fresh,
                    );
                    if (is_fresh) {
                        policy.assert_price_fresh(
                            published_at_ms,
                            reference_time_ms,
                        );
                    };
                });
            });
        });
    });
}

#[test]
fun an_update_stamped_at_the_reference_time_is_fresh() {
    let policy = freshness_policy(1, 0);

    assert!(policy.is_price_fresh(1_000, 1_000));
    policy.assert_price_fresh(1_000, 1_000);
}

#[test]
fun an_update_at_the_exact_age_bound_is_fresh() {
    let policy = freshness_policy(30_000, 0);

    assert!(policy.is_price_fresh(970_000, 1_000_000));
    policy.assert_price_fresh(970_000, 1_000_000);
}

#[test]
#[expected_failure(
    abort_code = policy::EStaleValuation, location = blast_leverage_core::policy,
)]
fun an_update_one_millisecond_past_the_age_bound_is_stale() {
    freshness_policy(30_000, 0).assert_price_fresh(969_999, 1_000_000);
}

#[test]
fun an_update_at_the_exact_skew_bound_is_fresh() {
    let policy = freshness_policy(30_000, 2_000);

    assert!(policy.is_price_fresh(1_002_000, 1_000_000));
    policy.assert_price_fresh(1_002_000, 1_000_000);
}

#[test]
#[expected_failure(
    abort_code = policy::EFutureValuation, location = blast_leverage_core::policy,
)]
fun an_update_one_millisecond_past_the_skew_bound_is_future_dated() {
    freshness_policy(30_000, 2_000).assert_price_fresh(1_002_001, 1_000_000);
}

#[test]
#[expected_failure(
    abort_code = policy::EFutureValuation, location = blast_leverage_core::policy,
)]
fun a_zero_skew_budget_rejects_the_first_future_millisecond() {
    freshness_policy(30_000, 0).assert_price_fresh(1_000_001, 1_000_000);
}

#[test]
fun the_freshness_window_saturates_instead_of_wrapping_at_the_width_boundary() {
    let max = std::u64::max_value!();
    let widest = freshness_policy(max, max);
    let narrowest = freshness_policy(1, 0);

    assert!(widest.is_price_fresh(0, max));
    assert!(widest.is_price_fresh(max, 0));
    widest.assert_price_fresh(0, max);
    widest.assert_price_fresh(max, 0);

    assert!(!narrowest.is_price_fresh(0, max));
    assert!(!narrowest.is_price_fresh(max, 0));
    assert!(narrowest.is_price_fresh(max - 1, max));
    assert!(narrowest.is_price_fresh(max, max));
    assert!(!narrowest.is_price_fresh(max, max - 1));
}

#[test]
fun confidence_predicate_matches_the_reference_across_the_small_domain() {
    vector[0u64, 1, 2, 5_000, 9_999].do!(|max_confidence_bps| {
        let policy = confidence_policy(max_confidence_bps);

        0u64.range_do!(41, |price| {
            0u64.range_do!(41, |confidence| {
                let expected = price > 0
                    && (confidence as u128) * 10_000
                        <= (max_confidence_bps as u128) * (price as u128);

                assert_eq!(
                    policy.is_confidence_within_bound(confidence, price),
                    expected,
                );
            });
        });
    });
}

#[test]
fun a_zero_confidence_is_admitted_by_the_strictest_bound() {
    confidence_policy(0).assert_confidence_within_bound(
        0,
        std::u64::max_value!(),
    );
}

#[test]
fun a_confidence_at_the_exact_threshold_is_admitted() {
    confidence_policy(250).assert_confidence_within_bound(250, 10_000);
}

#[test]
#[expected_failure(
    abort_code = policy::EConfidenceExceedsBound, location = blast_leverage_core::policy,
)]
fun a_confidence_one_unit_above_the_exact_threshold_is_rejected() {
    confidence_policy(250).assert_confidence_within_bound(251, 10_000);
}

#[test]
#[expected_failure(
    abort_code = policy::EConfidenceExceedsBound, location = blast_leverage_core::policy,
)]
fun the_strictest_confidence_bound_rejects_the_first_atomic_interval() {
    confidence_policy(0).assert_confidence_within_bound(
        1,
        std::u64::max_value!(),
    );
}

#[test]
#[expected_failure(
    abort_code = policy::EConfidenceExceedsBound, location = blast_leverage_core::policy,
)]
fun a_confidence_equal_to_the_price_is_always_rejected() {
    confidence_policy(9_999).assert_confidence_within_bound(1, 1);
}

#[test]
fun a_maximum_width_confidence_at_the_threshold_is_admitted() {
    let price = std::u64::max_value!();
    let threshold = ((9_999u128 * (price as u128)) / 10_000) as u64;

    confidence_policy(9_999).assert_confidence_within_bound(threshold, price);
}

#[test]
#[expected_failure(
    abort_code = policy::EConfidenceExceedsBound, location = blast_leverage_core::policy,
)]
fun a_maximum_width_confidence_one_unit_past_the_threshold_is_rejected() {
    let price = std::u64::max_value!();
    let threshold = ((9_999u128 * (price as u128)) / 10_000) as u64;

    confidence_policy(9_999).assert_confidence_within_bound(
        threshold + 1,
        price,
    );
}

#[test]
#[expected_failure(
    abort_code = policy::EConfidenceExceedsBound, location = blast_leverage_core::policy,
)]
fun a_maximum_width_confidence_and_price_do_not_wrap() {
    let max = std::u64::max_value!();

    confidence_policy(9_999).assert_confidence_within_bound(max, max);
}

#[test]
#[expected_failure(
    abort_code = policy::EInvalidValuationPrice, location = blast_leverage_core::policy,
)]
fun a_zero_price_is_rejected_even_when_the_confidence_bound_holds() {
    confidence_policy(9_999).assert_confidence_within_bound(0, 0);
}

#[test]
#[expected_failure(
    abort_code = policy::EInvalidValuationPrice, location = blast_leverage_core::policy,
)]
fun price_validation_precedes_the_confidence_bound() {
    confidence_policy(0).assert_confidence_within_bound(1, 0);
}

#[test]
fun mark_divergence_predicate_matches_the_reference_across_the_small_domain() {
    vector[0u64, 1, 2, 5_000, 9_999].do!(|max_mark_divergence_bps| {
        let policy = divergence_policy(max_mark_divergence_bps);

        0u64.range_do!(41, |index| {
            0u64.range_do!(41, |mark| {
                let difference = if (mark > index) {
                    mark - index
                } else {
                    index - mark
                };
                let expected = index > 0
                    && (difference as u128) * 10_000
                        <= (max_mark_divergence_bps as u128) * (index as u128);

                assert_eq!(
                    policy.is_mark_within_index_divergence(mark, index),
                    expected,
                );
            });
        });
    });
}

#[test]
fun a_mark_equal_to_the_index_is_admitted_by_the_strictest_bound() {
    let max = std::u64::max_value!();

    divergence_policy(0).assert_mark_within_index_divergence(max, max);
}

#[test]
fun a_mark_at_either_exact_divergence_bound_is_admitted() {
    let policy = divergence_policy(250);

    policy.assert_mark_within_index_divergence(10_250, 10_000);
    policy.assert_mark_within_index_divergence(9_750, 10_000);
}

#[test]
#[expected_failure(
    abort_code = policy::EMarkIndexDivergenceExceedsBound, location = blast_leverage_core::policy,
)]
fun a_mark_one_unit_above_the_upper_divergence_bound_is_rejected() {
    divergence_policy(250).assert_mark_within_index_divergence(10_251, 10_000);
}

#[test]
#[expected_failure(
    abort_code = policy::EMarkIndexDivergenceExceedsBound, location = blast_leverage_core::policy,
)]
fun a_mark_one_unit_below_the_lower_divergence_bound_is_rejected() {
    divergence_policy(250).assert_mark_within_index_divergence(9_749, 10_000);
}

#[test]
#[expected_failure(
    abort_code = policy::EMarkIndexDivergenceExceedsBound, location = blast_leverage_core::policy,
)]
fun a_zero_mark_against_a_positive_index_is_always_rejected() {
    divergence_policy(9_999).assert_mark_within_index_divergence(0, 10_000);
}

#[test]
fun a_maximum_width_mark_divergence_at_the_threshold_is_admitted() {
    let index = std::u64::max_value!();
    let threshold = ((9_999u128 * (index as u128)) / 10_000) as u64;

    divergence_policy(9_999).assert_mark_within_index_divergence(
        index - threshold,
        index,
    );
}

#[test]
#[expected_failure(
    abort_code = policy::EMarkIndexDivergenceExceedsBound, location = blast_leverage_core::policy,
)]
fun a_maximum_width_mark_divergence_one_unit_past_the_threshold_is_rejected() {
    let index = std::u64::max_value!();
    let threshold = ((9_999u128 * (index as u128)) / 10_000) as u64;

    divergence_policy(9_999).assert_mark_within_index_divergence(
        index - threshold - 1,
        index,
    );
}

#[test]
#[expected_failure(
    abort_code = policy::EMarkIndexDivergenceExceedsBound, location = blast_leverage_core::policy,
)]
fun a_maximum_width_mark_and_index_do_not_wrap() {
    divergence_policy(9_999).assert_mark_within_index_divergence(
        0,
        std::u64::max_value!(),
    );
}

#[test]
#[expected_failure(
    abort_code = policy::EInvalidValuationPrice, location = blast_leverage_core::policy,
)]
fun a_zero_index_is_rejected_even_when_the_mark_matches() {
    divergence_policy(9_999).assert_mark_within_index_divergence(0, 0);
}

#[test]
#[expected_failure(
    abort_code = policy::EInvalidValuationPrice, location = blast_leverage_core::policy,
)]
fun index_validation_precedes_the_mark_divergence_bound() {
    divergence_policy(0).assert_mark_within_index_divergence(
        std::u64::max_value!(),
        0,
    );
}

// === Private Functions ===

/// Builds a policy whose two-sided freshness window is the bound under test.
fun freshness_policy(
    max_price_age_ms: u64,
    max_price_ahead_ms: u64,
): policy::PricePolicy {
    policy::new_price_policy(max_price_age_ms, max_price_ahead_ms, 0, 0)
}

/// Builds a policy whose confidence bound is the bound under test.
fun confidence_policy(
    max_confidence_bps: u64,
): policy::PricePolicy {
    policy::new_price_policy(1, 0, max_confidence_bps, 0)
}

/// Builds a policy whose mark divergence bound is the bound under test.
fun divergence_policy(
    max_mark_divergence_bps: u64,
): policy::PricePolicy {
    policy::new_price_policy(1, 0, 0, max_mark_divergence_bps)
}
