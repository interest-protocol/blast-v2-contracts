// Package error macros keep stable codes in `errors.move`; the lint sees the expanded literal.
#[allow(lint(abort_without_constant))]
/// An issued product before its seed position exists.
///
/// The issuer's terms live here while the adapter opens the seed position on
/// the venue; `activate` then turns them and the seeded observation into the
/// core `State`. The value has no abilities, so an issuance that is not
/// activated cannot be stored: a product is either live or never existed.
module blast_boosts_core::issuance;

// === Public Types ===

/// The immutable policy and the two live knobs the issuer set.
public struct Issuance<phantom Product> {
    vault_policy: VaultPolicy,
    max_order_notional: u64,
    nav_cap: u64,
}

// === Public Functions ===

/// Issues one product. The caller's live admin witness must hold the Vault
/// issuer role; `nav_cap` must satisfy `RebalancePolicy::assert_nav_cap_valid`
/// and stays adjustable through `State::set_nav_cap`.
public fun issue<Product>(
    admin_witness: &AdminWitness<BLAST_BOOSTS_CORE>,
    vault_policy: VaultPolicy,
    max_order_notional: u64,
    nav_cap: u64,
): Issuance<Product> {
    admin_witness.assert_role(domain::vault_issuer_role());
    assert!(max_order_notional > 0, blast_boosts_core::errors::invalid_max_order_notional!());
    vault_policy.rebalance_policy().assert_nav_cap_valid(nav_cap);

    Issuance { vault_policy, max_order_notional, nav_cap }
}

/// The immutable direction every order of this product takes.
public fun side<Product>(self: &Issuance<Product>): PositionSide {
    self.vault_policy.side()
}

/// The per-order notional cap in atomic collateral units.
public fun max_order_notional<Product>(self: &Issuance<Product>): u64 {
    self.max_order_notional
}

/// Rejects one seed order above the per-order notional cap.
public fun assert_order_notional_allowed<Product>(self: &Issuance<Product>, order_notional: u64) {
    assert!(
        order_notional <= self.max_order_notional,
        blast_boosts_core::errors::order_notional_exceeds_maximum!(),
    );
}

/// Rejects a seed fill outside the ordinary slippage bound; opening a position
/// always increases risk, so the emergency bound never applies here.
public fun assert_execution<Product>(self: &Issuance<Product>, reference: u64, executed: u64) {
    self.vault_policy.rebalance_policy().assert_execution_within_max_slippage(reference, executed);
}

/// Sizes the opening position from a flat seed observation: the target notional
/// in atomic collateral units, and the priced flat seed whose pair and lot the
/// orders are placed under.
///
/// The NAV and reserve caps are checked here against the sized target and
/// again in `state::activate` against the position actually filled.
public fun seed_terms<Product>(
    self: &Issuance<Product>, observation: PositionObservation, seed_reserve: u64, now_ms: u64,
): (u64, ActivePosition) {
    let seed_nav = state::seed_nav(&self.vault_policy, &observation, seed_reserve, now_ms);
    assert!(observation.position_base() == 0, blast_boosts_core::errors::invalid_initialization_observation!());
    assert!(seed_nav <= self.nav_cap, blast_boosts_core::errors::nav_cap_exceeded!());

    let target_notional =
        accounting_math::target_notional_down(seed_nav, self.vault_policy.rebalance_policy().target_bps());
    assert!(
        seed_reserve <= self.vault_policy.reserve_cap(target_notional),
        blast_boosts_core::errors::seed_reserve_above_cap!(),
    );

    (target_notional, state::flat_position(observation))
}

/// Turns the issuance and the seeded observation into the live state.
///
/// Returns the state, the seed's reserve-excluded shareholder NAV in atomic
/// collateral units, and the priced seed position.
public fun activate<Product>(
    self: Issuance<Product>,
    observation: PositionObservation,
    seed_reserve: u64,
    base_decimals: u8,
    collateral_decimals: u8,
    now_ms: u64,
): (State<Product>, u64, ActivePosition) {
    let Issuance { vault_policy, max_order_notional, nav_cap } = self;

    state::activate(
        vault_policy, max_order_notional, nav_cap, observation, seed_reserve, base_decimals, collateral_decimals, now_ms,
    )
}

// === Imports ===

use blast_admin::acl::AdminWitness;

use blast_boosts_core::{
    accounting_math,
    observation::PositionObservation,
    policy::{PositionSide, VaultPolicy},
    state::{Self, ActivePosition, State},
    blast_boosts_core::{Self as domain, BLAST_BOOSTS_CORE},
};
