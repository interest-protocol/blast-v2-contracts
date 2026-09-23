// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[allow(unused_const)]
/// Package error registry: numeric macros and matching test-only constants.
module blast_admin::errors;

// === Errors ===

#[test_only]
const EInvalidDomainWitness: u64 = 0;

#[test_only]
const EInvalidMaxAdmins: u64 = 1;

#[test_only]
const EInvalidRootTransferDelay: u64 = 2;

#[test_only]
const EInvalidSuperAdminCap: u64 = 3;

#[test_only]
const EInvalidAdminCap: u64 = 4;

#[test_only]
const EInvalidAdminRecipient: u64 = 5;

#[test_only]
const EAdminCapacityReached: u64 = 6;

#[test_only]
const EInvalidRole: u64 = 7;

#[test_only]
const EAdminRoleAlreadyGranted: u64 = 8;

#[test_only]
const EAdminRoleNotGranted: u64 = 9;

#[test_only]
const EInvalidSuperAdminRecipient: u64 = 10;

#[test_only]
const ESuperAdminTransferUnchanged: u64 = 11;

#[test_only]
const ESuperAdminTransferTimeOverflow: u64 = 12;

#[test_only]
const ENoPendingSuperAdminTransfer: u64 = 13;

#[test_only]
const ENotPendingSuperAdminRecipient: u64 = 14;

#[test_only]
const ESuperAdminTransferNotReady: u64 = 15;

#[test_only]
const ESuperAdminCapStillActive: u64 = 16;

#[test_only]
const EOperationalVersionMismatch: u64 = 17;

#[test_only]
const EOperationalVersionOverflow: u64 = 18;

#[test_only]
const EInvalidPackagePublisher: u64 = 19;

#[test_only]
const EInvalidUpgradeCap: u64 = 20;

#[test_only]
const EInvalidPackageDigest: u64 = 21;

#[test_only]
const EUpgradeCapUnavailable: u64 = 22;

#[test_only]
const EUpgradePolicyNotMoreRestrictive: u64 = 23;

macro public(package) fun invalid_domain_witness(): u64 { 0 }

macro public(package) fun invalid_max_admins(): u64 { 1 }

macro public(package) fun invalid_root_transfer_delay(): u64 { 2 }

macro public(package) fun invalid_super_admin_cap(): u64 { 3 }

macro public(package) fun invalid_admin_cap(): u64 { 4 }

macro public(package) fun invalid_admin_recipient(): u64 { 5 }

macro public(package) fun admin_capacity_reached(): u64 { 6 }

macro public(package) fun invalid_role(): u64 { 7 }

macro public(package) fun admin_role_already_granted(): u64 { 8 }

macro public(package) fun admin_role_not_granted(): u64 { 9 }

macro public(package) fun invalid_super_admin_recipient(): u64 { 10 }

macro public(package) fun super_admin_transfer_unchanged(): u64 { 11 }

macro public(package) fun super_admin_transfer_time_overflow(): u64 { 12 }

macro public(package) fun no_pending_super_admin_transfer(): u64 { 13 }

macro public(package) fun not_pending_super_admin_recipient(): u64 { 14 }

macro public(package) fun super_admin_transfer_not_ready(): u64 { 15 }

macro public(package) fun super_admin_cap_still_active(): u64 { 16 }

macro public(package) fun operational_version_mismatch(): u64 { 17 }

macro public(package) fun operational_version_overflow(): u64 { 18 }

macro public(package) fun invalid_package_publisher(): u64 { 19 }

macro public(package) fun invalid_upgrade_cap(): u64 { 20 }

macro public(package) fun invalid_package_digest(): u64 { 21 }

macro public(package) fun upgrade_cap_unavailable(): u64 { 22 }

macro public(package) fun upgrade_policy_not_more_restrictive(): u64 { 23 }
