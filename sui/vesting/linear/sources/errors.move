#[allow(unused_const)]
module blast_fun_vesting_linear::errors;

// === Constants ===

#[test_only]
const EInvalidBeneficiary: u64 = 0;

#[test_only]
const EInvalidRefundRecipient: u64 = 1;

#[test_only]
const EZeroAllocation: u64 = 2;

#[test_only]
const EZeroPeriod: u64 = 3;

#[test_only]
const EZeroPeriods: u64 = 4;

#[test_only]
const EInvalidCliff: u64 = 5;

#[test_only]
const EScheduleOverflow: u64 = 6;

#[test_only]
const ENothingClaimable: u64 = 7;

#[test_only]
const EInvalidCancelCap: u64 = 8;

#[test_only]
const EScheduleNotEnded: u64 = 9;

#[test_only]
const EScheduleNotEmpty: u64 = 10;

#[test_only]
const ECancelCapRequired: u64 = 11;

// === Package Functions ===

public(package) macro fun invalid_beneficiary(): u64 { 0 }

public(package) macro fun invalid_refund_recipient(): u64 { 1 }

public(package) macro fun zero_allocation(): u64 { 2 }

public(package) macro fun zero_period(): u64 { 3 }

public(package) macro fun zero_periods(): u64 { 4 }

public(package) macro fun invalid_cliff(): u64 { 5 }

public(package) macro fun schedule_overflow(): u64 { 6 }

public(package) macro fun nothing_claimable(): u64 { 7 }

public(package) macro fun invalid_cancel_cap(): u64 { 8 }

public(package) macro fun schedule_not_ended(): u64 { 9 }

public(package) macro fun schedule_not_empty(): u64 { 10 }

public(package) macro fun cancel_cap_required(): u64 { 11 }
