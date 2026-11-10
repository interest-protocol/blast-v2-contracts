// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[allow(unused_const)]
/// Package error registry.
module blast_fun_dex_example_hook::errors;

// === Errors ===

#[test_only]
/// Hook configuration is not at this package's version.
const EWrongVersion: u64 = 0;

#[test_only]
/// Hook fee must not exceed 1,000 bps.
const EFeeTooHigh: u64 = 1;

#[test_only]
/// Pool has collected no hook fees in this coin.
const ENoFeesCollected: u64 = 2;

macro public(package) fun wrong_version(): u64 { 0 }

macro public(package) fun fee_too_high(): u64 { 1 }

macro public(package) fun no_fees_collected(): u64 { 2 }
