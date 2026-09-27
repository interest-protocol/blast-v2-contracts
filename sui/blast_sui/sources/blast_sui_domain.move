// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast SUI's administration roles in the shared Blast ACL.
///
/// A role is a type. The ACL's `AdminCap<Role>` signs in to `AdminWitness<Role>`,
/// and a function's witness parameter names the one role it accepts, so a role
/// from any other package is a different type and cannot reach these operations.
module blast_sui::blast_sui_domain;

// === Public Types ===

/// Attaches package capabilities and authorizes, cuts over, restricts, or seals an upgrade.
public struct UpgradeAdmin()

/// Sets the blastSUI redemption fee.
public struct FeeAdmin()
