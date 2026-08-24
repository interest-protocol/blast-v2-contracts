// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations and the stable code map documented in `docs/error-codes.md`.
#[allow(lint(abort_without_constant))]
module blast_fun::trade_fee_config;

use blast_fun::{acl::AdminWitness, constants, events};

// === Public Structs ===

/// Shared singleton whose live percentage applies to every subsequent trade-fee accrual.
public struct TradeFeeConfig has key {
    id: UID,
    protocol_fee_share_bps: u64,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    let config = new(ctx);
    let config_id = config.id.to_inner();
    let protocol_fee_share_bps = config.protocol_fee_share_bps;

    transfer::share_object(config);

    events::trade_fee_config_created(config_id, protocol_fee_share_bps);
}

// === Public Functions ===

/// Updates the live protocol share used by every subsequent trade-fee accrual.
public fun set_protocol_fee_share(
    self: &mut TradeFeeConfig,
    _: &AdminWitness,
    protocol_fee_share_bps: u64,
) {
    assert!(
        protocol_fee_share_bps <= constants::basis_points_denominator!(),
        blast_fun::errors::invalid_protocol_fee_share_bps!(),
    );
    assert!(
        protocol_fee_share_bps != self.protocol_fee_share_bps,
        blast_fun::errors::protocol_fee_share_unchanged!(),
    );

    let old_protocol_fee_share_bps = self.protocol_fee_share_bps;

    self.protocol_fee_share_bps = protocol_fee_share_bps;

    events::protocol_fee_share_changed(
        self.id.to_inner(),
        old_protocol_fee_share_bps,
        protocol_fee_share_bps,
    );
}

// === Package Functions ===

/// Returns the current global protocol share in basis points for the next fee accrual.
public(package) fun protocol_fee_share_bps(self: &TradeFeeConfig): u64 {
    self.protocol_fee_share_bps
}

// === Private Functions ===

/// Starts with zero protocol share so publication cannot silently take protocol revenue.
fun new(ctx: &mut TxContext): TradeFeeConfig {
    TradeFeeConfig {
        id: object::new(ctx),
        protocol_fee_share_bps: 0,
    }
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Deletes trade-fee configuration state after a test.
public fun destroy_for_testing(self: TradeFeeConfig) {
    let TradeFeeConfig { id, protocol_fee_share_bps: _ } = self;
    id.delete();
}
