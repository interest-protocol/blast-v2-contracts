// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// blast.fun's administration roles in the shared Blast ACL, shared with the migrators.
///
/// A role is a type. The ACL's `AdminCap<Role>` signs in to `AdminWitness<Role>`, and a
/// function's witness parameter names the one role it accepts, so no role authorizes another's
/// actions and a role from any other package cannot reach these operations.
module blast_fun::blast_fun_domain;

// === Public Types ===

/// Authorizes and commits package upgrades, and makes a package immutable.
public struct UpgradeAdmin()

/// Revokes and reissues a launch's creator capabilities.
public struct CreatorAdmin()

/// Swaps a vault's burn Quote for Meme to burn.
public struct BuybackAdmin()

/// Claims Blast's fees and chooses where Blast is paid.
public struct TreasuryAdmin()

/// Sets Blast's creation and trade fees, its fee share, and the partners new launches may name.
public struct FeeAdmin()

/// Admits or removes the Quotes and Meme decimals new launches may use.
public struct ListingAdmin()

/// Admits or removes migration adapters.
public struct AdapterAdmin()

/// Replaces the key that signs account claims.
public struct ClaimSignerAdmin()

/// Publishes holder-reward rounds.
public struct RewardsAdmin()
