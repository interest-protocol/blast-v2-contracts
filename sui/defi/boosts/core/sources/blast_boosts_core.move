// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Boosts administration roles in the shared Blast ACL, used by every leverage adapter.
///
/// A role is a type. An `AdminCap` holding `Role` signs in to `AdminWitness<Role>`,
/// and a function's witness parameter names the one role it accepts, so a role
/// from any other package is a different type and cannot reach these operations.
///
/// Package administration uses the shared ACL roles scoped to each adapter witness.
module blast_boosts_core::blast_boosts_core;

// === Public Types ===

/// Issues an adapter Vault and its share currency, and updates that currency's metadata.
public struct VaultIssuer()

/// Schedules changes to a Vault's NAV and order caps and reviews venue recovery.
public struct RiskAdmin()

/// Irreversibly begins a Vault's shutdown.
public struct ShutdownAdmin()
