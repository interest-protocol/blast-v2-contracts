// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast SUI's administration roles in the shared Blast ACL.
///
/// A role is a type. An `AdminCap` holding `Role` signs in to `AdminWitness<Role>`,
/// and a function's witness parameter names the one role it accepts, so a role
/// from any other package is a different type and cannot reach these operations.
module blast_sui::blast_sui_domain;

// === Public Types ===

/// Schedules and runs upgrades and terminal immutability, and governs their notice.
public struct UpgradeAdmin()

/// Schedules blastSUI redemption-fee changes.
public struct FeeAdmin()

/// May cancel any scheduled upgrade, immutability, notice or fee change.
public struct CancelAdmin()

/// May set deposit pause flags, never clear them.
public struct PauseAdmin()

/// May clear deposit pause flags once every notice is guarded.
public struct UnpauseAdmin()
