// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast market maker roles in the shared Blast ACL. A sign-in witness grants exactly one role.
module blast_market_maker::blast_market_maker_domain;

// === Public Types ===

/// Sets bounded deductions from market maker liquidity-provider fees.
public struct FeeAdmin()

/// Configures Blast market maker treasury payouts and withdraws already-earned assets.
public struct TreasuryAdmin()

/// Publishes funded presale buyer allocations for checkpointed reward epochs.
public struct RewardsAdmin()

/// Authorizes native upgrades and activates a checked next operational generation.
public struct UpgradeAdmin()
