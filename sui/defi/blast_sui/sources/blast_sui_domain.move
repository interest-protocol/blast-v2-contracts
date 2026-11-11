// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast SUI's administration roles in the shared Blast ACL.
///
/// A role is a type. An `AdminCap` holding `Role` signs in to `AdminWitness<Role>`,
/// and a function's witness parameter names the one role it accepts, so a role
/// from any other package is a different type and cannot reach these operations.
/// Upgrades and pausing use the generic `blast_admin::package_admin` roles typed
/// by `BLAST_SUI_PACKAGE`.
module blast_sui::blast_sui_domain;

// === Public Types ===

/// Schedules the blastSUI redemption fee and its delay.
public struct FeeAdmin()

/// Cancels a scheduled change to the vault's delayed values.
public struct CancelAdmin()

/// Admits and removes the validators users may pick.
public struct ValidatorAdmin()
