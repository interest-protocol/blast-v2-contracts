#[test_only]
/// Exact terminal venue finality; no dust forgiveness or synthetic collateral.
module blast_leverage_aftermath::terminal_checkpoint_tests;

use blast_leverage_aftermath::venue_account::{Self, Checkpoint};
use std::unit_test::assert_eq;

// === Tests ===

#[test]
#[expected_failure(abort_code = 54, location = blast_leverage_aftermath::venue_account)]
fun terminal_cash_sum_overflow_is_not_a_partial_withdrawal() {
    checkpoint(0, 0, 1_000_000_000_000, 0, 9, std::u64::max_value!())
        .recoverable_cash_for_testing(false, 1_000_000_000_000);
}

#[test]
#[expected_failure(abort_code = 54, location = blast_leverage_aftermath::venue_account)]
fun one_remaining_atomic_coin_blocks_completed_withdrawal() {
    let before = checkpoint(0, 0, 0, 0, 9, 13);
    let after = checkpoint(0, 0, 0, 0, 9, 1);
    venue_account::assert_terminal_withdrawal(&before, &after, 13);
}

#[test]
#[expected_failure(abort_code = 54, location = blast_leverage_aftermath::venue_account)]
fun pending_bid_base_blocks_finality_even_when_order_count_is_zero() {
    venue_account::new_checkpoint(0, 0, 0, 0, 9, 10, 9, 10, 1_000,
        0, 1, 0, 0, false, 0, 0, 0).recoverable_terminal_cash();
}

#[test]
#[expected_failure(abort_code = 54, location = blast_leverage_aftermath::venue_account)]
fun short_funding_snapshot_must_be_exact_even_when_flat() {
    venue_account::new_checkpoint(0, 0, 0, 0, 9, 9, 9, 10, 1_000,
        0, 0, 0, 0, false, 0, 0, 0).recoverable_terminal_cash();
}

#[test]
fun direct_settlement_closes_raw_dust_without_creating_a_market_order() {
    let before = venue_account::new_checkpoint(0, 0, 1, 1, 9, 10, 9, 10, 1_000,
        0, 0, 0, 0, true, 0, 0, 0);
    let after = venue_account::new_checkpoint(5, 0, 0, 0, 9, 10, 9, 10, 1_000,
        0, 0, 0, 0, true, 0, 0, 0);
    venue_account::assert_direct_settlement_close(&before, &after);
}

#[test]
#[expected_failure(abort_code = 54, location = blast_leverage_aftermath::venue_account)]
fun direct_settlement_cannot_leave_one_raw_order_or_position_unit() {
    let before = venue_account::new_checkpoint(0, 0, 1, 1, 9, 10, 9, 10, 1_000,
        0, 0, 0, 0, true, 0, 0, 0);
    let after = venue_account::new_checkpoint(5, 0, 0, 0, 9, 10, 9, 10, 1_000,
        1, 0, 0, 0, true, 0, 0, 0);
    venue_account::assert_direct_settlement_close(&before, &after);
}

#[test]
fun flat_settled_checkpoint_recovers_every_integral_collateral_atom() {
    let checkpoint = checkpoint(0, 0, 7_000_000_000_000, 0, 9, 5);
    assert_eq!(checkpoint.recoverable_cash_for_testing(false, 7_000_000_000_000), 12);
}

// === Fixtures ===

#[test]
#[expected_failure(abort_code = 54, location = blast_leverage_aftermath::venue_account)]
fun one_raw_base_unit_prevents_terminal_finality() {
    checkpoint(1, 0, 0, 0, 9, 0).recoverable_terminal_cash();
}

#[test]
#[expected_failure(abort_code = 54, location = blast_leverage_aftermath::venue_account)]
fun unresolved_entry_quote_prevents_terminal_finality() {
    checkpoint(0, 1, 0, 0, 9, 0).recoverable_terminal_cash();
}

#[test]
#[expected_failure(abort_code = 54, location = blast_leverage_aftermath::venue_account)]
fun pending_order_prevents_terminal_finality() {
    checkpoint(0, 0, 0, 1, 9, 0).recoverable_terminal_cash();
}

#[test]
#[expected_failure(abort_code = 54, location = blast_leverage_aftermath::venue_account)]
fun unsettled_funding_prevents_terminal_finality_even_when_flat() {
    checkpoint(0, 0, 0, 0, 8, 0).recoverable_terminal_cash();
}

#[test]
#[expected_failure(abort_code = 54, location = blast_leverage_aftermath::venue_account)]
fun sub_atomic_collateral_is_not_forgiven_at_finalization() {
    checkpoint(0, 0, 1, 0, 9, 0).recoverable_cash_for_testing(false, 1);
}

#[test]
#[expected_failure(abort_code = 54, location = blast_leverage_aftermath::venue_account)]
fun signed_negative_liability_cannot_be_recovered_as_cash() {
    checkpoint(0, 0, 0xffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff,
        0, 9, 0).recoverable_cash_for_testing(true, 1);
}

fun checkpoint(base: u256, quote: u256, allocated: u256, pending: u64, funding: u256, free: u64): Checkpoint {
    venue_account::new_checkpoint(free, allocated, base, quote, funding, 10, 9, 10,
        1_000, 0, 0, pending, 0, false, 0, 0, 0)
}
