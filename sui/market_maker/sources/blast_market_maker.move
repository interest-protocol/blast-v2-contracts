// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Publication orchestrator. The package remains unusable until native upgrade custody wraps.
module blast_market_maker::blast_market_maker;

// === Public Types ===

public struct BLAST_MARKET_MAKER() has drop;

// === Private Initialization ===

fun init(otw: BLAST_MARKET_MAKER, ctx: &mut TxContext) {
    let initial_generation = package_version::initial_generation(&otw);
    let treasury = protocol_treasury::new(ctx);
    let treasury_id = object::id(&treasury);
    let policy = market_maker_fee_policy::new(treasury_id, ctx);
    let policy_id = object::id(&policy);

    treasury.share();
    policy.share();
    package_version::new_bootstrap(
        sui::package::claim(otw, ctx),
        initial_generation,
        treasury_id,
        policy_id,
        ctx,
    );
}

// === Imports ===

use blast_market_maker::{market_maker_fee_policy, package_version, protocol_treasury};
