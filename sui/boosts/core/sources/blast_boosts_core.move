// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Boosts administration roles in the shared Blast ACL, used by every leverage adapter.
///
/// A role is a type. An `AdminCap` holding `Role` signs in to `AdminWitness<Role>`,
/// and a function's witness parameter names the one role it accepts, so a role
/// from any other package is a different type and cannot reach these operations.
///
/// The core package is published immutably, so `UpgradeAdmin` governs adapter
/// package custody rather than any transition in this package.
module blast_boosts_core::blast_boosts_core;

// === Public Types ===

/// Issues an adapter Vault and its share currency, and updates that currency's metadata.
public struct VaultIssuer()

/// Sets a Vault's fees, NAV cap and maximum order notional, and withdraws its admin fees.
public struct RiskAdmin()

/// Irreversibly begins a Vault's shutdown.
public struct ShutdownAdmin()

/// Authorizes, cuts over, restricts, or seals an adapter package upgrade.
public struct UpgradeAdmin()
