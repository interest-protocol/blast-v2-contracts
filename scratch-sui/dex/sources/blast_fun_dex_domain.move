// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// DEX product roles in the shared Blast ACL. Sign in with an `AdminCap` holding
/// the role to obtain the `AdminWitness<Role>` accepted by the DEX.
///
/// Package governance uses `UpgradeAdmin<BLAST_FUN_DEX>`, `CancelAdmin<BLAST_FUN_DEX>`,
/// `PauseAdmin<BLAST_FUN_DEX>`, and `UnpauseAdmin<BLAST_FUN_DEX>` from
/// `blast_admin::package_admin`. The cancellation role also cancels pending fee tiers.
module blast_fun_dex::blast_fun_dex_domain;

// === Public Types ===

/// Schedules new rates for the shared DEX fee tier registry.
public struct BlastDexFeeTierAdmin()
