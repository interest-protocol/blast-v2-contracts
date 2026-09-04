// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Venue-neutral state for one Series1 leveraged product.
///
/// The selected adapter stores this value inside its own shared Vault. Only
/// functions in this module can inspect or change the private Series1 fields.
/// Currency, venue custody, ACL routing, and versioning belong to the adapter.
module blast_leverage_series_one::state;

use blast_leverage_series_one::{
    accounting_math,
    acl::AdminWitness,
    bounded_value::{Self, BoundedValue},
    constants,
    lifecycle::{Self, Lifecycle},
    observation::{Self, FundingSettlement, PositionObservation},
    policy::TierPolicy,
};

// === Public Types ===

/// Sealed Series1 state stored inside one adapter-owned Vault.
///
/// The value can be stored but cannot be copied or dropped. `Product`
/// separates independent leveraged products at the type level.
public struct State<phantom Product> has store {
    tier_policy: TierPolicy,
    max_order_notional: BoundedValue,
    maintenance_reserve: u64,
    lifecycle: Lifecycle,
}

// === Public Functions ===

/// Creates one validated, uninitialized Series1 state value.
///
/// The adapter must store the returned value inside its Vault. The caller's
/// live admin witness must contain the Vault issuer role.
public fun new<Product>(
    admin_witness: &AdminWitness,
    tier_policy: TierPolicy,
    max_order_notional_minimum: u64,
    max_order_notional_current: u64,
    max_order_notional_maximum: u64,
): State<Product> {
    admin_witness.assert_role(constants::vault_issuer_role!());
    assert!(
        max_order_notional_minimum > 0,
        blast_leverage_series_one::errors::invalid_max_order_notional!(),
    );

    State {
        tier_policy,
        max_order_notional: bounded_value::new(
            max_order_notional_minimum,
            max_order_notional_current,
            max_order_notional_maximum,
        ),
        maintenance_reserve: 0,
        lifecycle: lifecycle::new(),
    }
}

/// Returns the seed position's target notional from reserve-excluded shareholder NAV.
///
/// Both inputs and the result use atomic collateral units. The target rounds
/// down so the planned opening order never exceeds the fixed target because of
/// integer remainder. This read is available only before activation and checks
/// reserve backing, positive NAV, and the immutable NAV cap before sizing.
public fun initialization_target_notional<Product>(
    self: &State<Product>,
    seed_venue_equity: u64,
    seed_reserve: u64,
): u64 {
    self.lifecycle.assert_can_activate();
    assert!(
        accounting_math::is_reserve_backed(seed_venue_equity, seed_reserve),
        blast_leverage_series_one::errors::maintenance_reserve_exceeds_equity!(),
    );
    assert!(
        accounting_math::is_shareholder_nav_positive(seed_venue_equity, seed_reserve),
        blast_leverage_series_one::errors::invalid_nav!(),
    );

    let seed_nav = accounting_math::shareholder_nav(seed_venue_equity, seed_reserve);
    self.tier_policy.assert_within_nav_cap(seed_nav);

    accounting_math::target_notional_from_equity_down(
        seed_venue_equity,
        seed_reserve,
        self.tier_policy.rebalance_policy().target_bps(),
    )
}

/// Rejects one adapter order above the live atomic-collateral notional limit.
public fun assert_order_notional_allowed<Product>(
    self: &State<Product>,
    order_notional: u64,
) {
    assert!(
        order_notional <= self.max_order_notional.current(),
        blast_leverage_series_one::errors::order_notional_exceeds_maximum!(),
    );
}

/// Activates one fully observed long or short seed.
///
/// Returns the seed's reserve-excluded shareholder NAV in atomic collateral
/// units. The adapter must authenticate the linear observation before calling
/// this function. Every lifecycle, accounting, valuation, position, venue,
/// capacity, leverage, and minimum-operation guard runs before reserve or
/// lifecycle mutation. No administrative witness is accepted after State
/// construction.
public fun initialize<Product>(
    self: &mut State<Product>,
    observation: PositionObservation,
    seed_reserve: u64,
    reference_time_ms: u64,
): u64 {
    self.lifecycle.assert_can_activate();

    let seed_nav = validated_initialization_nav(
        self,
        observation,
        seed_reserve,
        reference_time_ms,
    );

    self.lifecycle.activate();
    self.maintenance_reserve = seed_reserve;

    seed_nav
}

/// Applies one adapter-authenticated funding classification to the reserve.
///
/// Returns `(absorbed_by_reserve, uncovered_cost)` in atomic collateral units.
/// A credit or no-funding classification leaves the reserve unchanged. The
/// adapter owns exact-once funding checkpoint authentication; Series1 stores
/// no venue cursor and never infers funding from an equity delta.
public fun settle_funding<Product>(
    self: &mut State<Product>,
    settlement: FundingSettlement,
): (u64, u64) {
    let (_, is_cost, amount) = settlement.unpack_funding();

    if (is_cost) {
        let (reserve_after, absorbed, uncovered) = accounting_math::absorb_funding_cost(
            self.maintenance_reserve,
            amount,
        );
        self.maintenance_reserve = reserve_after;

        (absorbed, uncovered)
    } else {
        (0, 0)
    }
}

/// Synchronizes objective health without increasing risk or moving lifecycle backward.
///
/// Returns true only when this call changes `Active` to `ReduceOnly`. Every
/// observation is consumed once. Objective failures use non-aborting
/// predicates so degradation commits instead of rolling back. An uninitialized
/// State aborts; `ReduceOnly`, `ShutdownPending`, and `ShutdownSettled` can only
/// remain unchanged.
public fun sync_health<Product>(
    self: &mut State<Product>,
    observation: PositionObservation,
    share_supply: u64,
    reference_time_ms: u64,
): bool {
    self.lifecycle.assert_initialized();
    let was_active = self.lifecycle.is_active();

    let (
        venue_equity,
        absolute_base,
        absolute_notional,
        lot_size,
        observed_side,
        pending_order_count,
        margin_safe,
        venue_operational,
        checkpoint_clean,
        base_index,
        collateral_oracle,
        mark_price,
    ) = observation.unpack_position();
    let (base_index_price, base_confidence, base_publish_time_ms) =
        base_index.unpack_price();
    let (collateral_price, collateral_confidence, collateral_publish_time_ms) =
        collateral_oracle.unpack_price();
    let valuation_policy = self.tier_policy.valuation_policy();
    let rebalance_policy = self.tier_policy.rebalance_policy();
    let min_exposure_lots = self.tier_policy.min_exposure_lots();

    let is_healthy = accounting_math::is_reserve_backed(
        venue_equity,
        self.maintenance_reserve,
    ) && accounting_math::is_shareholder_nav_positive(
        venue_equity,
        self.maintenance_reserve,
    ) && valuation_policy.is_price_fresh(
        base_publish_time_ms,
        reference_time_ms,
    ) && valuation_policy.is_confidence_within_bound(
        base_confidence,
        base_index_price,
    ) && valuation_policy.is_price_fresh(
        collateral_publish_time_ms,
        reference_time_ms,
    ) && valuation_policy.is_confidence_within_bound(
        collateral_confidence,
        collateral_price,
    ) && valuation_policy.is_mark_within_index_divergence(
        mark_price,
        base_index_price,
    ) && observation::is_position_structurally_valid(
        absolute_base,
        absolute_notional,
        lot_size,
    ) && observed_side == self.tier_policy.side()
        && pending_order_count == 0
        && venue_operational
        && checkpoint_clean
        && margin_safe
        && accounting_math::is_accounting_leverage_below_limit(
            absolute_notional,
            venue_equity,
            self.maintenance_reserve,
            rebalance_policy.hard_cap_bps(),
        )
        && accounting_math::is_exposure_above_minimum_operation(
            absolute_base,
            lot_size,
            min_exposure_lots,
        )
        && accounting_math::is_redemption_possible(
            absolute_base,
            share_supply,
            lot_size,
            min_exposure_lots,
        );

    if (!is_healthy) {
        self.lifecycle.degrade_to_reduce_only();
    };

    was_active && !is_healthy
}

/// Updates the live per-call maximum order notional within its frozen bounds.
///
/// This value limits the absolute atomic-USDC notional of one adapter order.
/// It does not limit a user's deposit or the Vault's total open position.
/// Adapter custody of `State<Product>` determines who can present mutable
/// access. The adapter must authenticate its currently selected risk module
/// before calling this function. Updates are available in every lifecycle
/// state because they change only the size of later calls, not live exposure.
public fun set_max_order_notional<Product>(
    self: &mut State<Product>,
    current: u64,
): u64 {
    let previous = self.max_order_notional.current();
    assert!(
        current != previous,
        blast_leverage_series_one::errors::max_order_notional_unchanged!(),
    );

    self.max_order_notional.set_current(current);
    previous
}

/// Disables new risk for an active Series1 product.
///
/// The adapter that owns this State must authorize the operation before this
/// call. This transition cannot activate an uninitialized product, resume a
/// reduced product, or begin shutdown.
public fun enter_reduce_only<Product>(
    self: &mut State<Product>,
) {
    self.lifecycle.enter_reduce_only();
}

// === Private Functions ===

/// Consumes and validates a complete seed without mutable access to State.
fun validated_initialization_nav<Product>(
    self: &State<Product>,
    observation: PositionObservation,
    seed_reserve: u64,
    reference_time_ms: u64,
): u64 {
    let (
        venue_equity,
        absolute_base,
        absolute_notional,
        lot_size,
        observed_side,
        pending_order_count,
        margin_safe,
        venue_operational,
        checkpoint_clean,
        base_index,
        collateral_oracle,
        mark_price,
    ) = observation.unpack_position();
    let (base_index_price, base_confidence, base_publish_time_ms) =
        base_index.unpack_price();
    let (collateral_price, collateral_confidence, collateral_publish_time_ms) =
        collateral_oracle.unpack_price();

    assert!(
        accounting_math::is_reserve_backed(venue_equity, seed_reserve),
        blast_leverage_series_one::errors::maintenance_reserve_exceeds_equity!(),
    );
    assert!(
        accounting_math::is_shareholder_nav_positive(venue_equity, seed_reserve),
        blast_leverage_series_one::errors::invalid_nav!(),
    );

    let valuation_policy = self.tier_policy.valuation_policy();
    valuation_policy.assert_price_fresh(base_publish_time_ms, reference_time_ms);
    valuation_policy.assert_confidence_within_bound(base_confidence, base_index_price);
    valuation_policy.assert_price_fresh(collateral_publish_time_ms, reference_time_ms);
    valuation_policy.assert_confidence_within_bound(collateral_confidence, collateral_price);
    valuation_policy.assert_mark_within_index_divergence(mark_price, base_index_price);
    assert!(
        observed_side == self.tier_policy.side(),
        blast_leverage_series_one::errors::invalid_initialization_observation!(),
    );
    assert!(
        pending_order_count == 0,
        blast_leverage_series_one::errors::initialization_orders_not_empty!(),
    );
    assert!(
        venue_operational,
        blast_leverage_series_one::errors::initialization_venue_not_operational!(),
    );
    assert!(
        checkpoint_clean,
        blast_leverage_series_one::errors::initialization_checkpoint_dirty!(),
    );
    assert!(
        margin_safe,
        blast_leverage_series_one::errors::initialization_margin_unsafe!(),
    );

    let seed_nav = accounting_math::shareholder_nav(venue_equity, seed_reserve);
    self.tier_policy.assert_within_nav_cap(seed_nav);
    let rebalance_policy = self.tier_policy.rebalance_policy();
    let leverage_bps = accounting_math::accounting_leverage_bps_up(
        absolute_notional,
        venue_equity,
        seed_reserve,
    );
    assert!(
        rebalance_policy.is_healthy(leverage_bps),
        blast_leverage_series_one::errors::initialization_leverage_unhealthy!(),
    );
    assert!(
        observation::is_position_structurally_valid(
            absolute_base,
            absolute_notional,
            lot_size,
        ),
        blast_leverage_series_one::errors::invalid_position_observation!(),
    );
    assert!(
        accounting_math::is_exposure_above_minimum_operation(
            absolute_base,
            lot_size,
            self.tier_policy.min_exposure_lots(),
        ),
        blast_leverage_series_one::errors::initialization_exposure_below_minimum!(),
    );

    seed_nav
}

// === Test-Only Functions ===

#[test_only]
/// Returns whether the embedded lifecycle is uninitialized.
public fun is_uninitialized_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_uninitialized()
}

#[test_only]
/// Returns whether the embedded lifecycle is active.
public fun is_active_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_active()
}

#[test_only]
/// Returns the initial and live maintenance reserve.
public fun maintenance_reserve_for_testing<Product>(self: &State<Product>): u64 {
    self.maintenance_reserve
}

#[test_only]
/// Returns the immutable tier policy.
public fun tier_policy_for_testing<Product>(self: &State<Product>): TierPolicy {
    self.tier_policy
}

#[test_only]
/// Returns the complete maximum-order-notional tuple.
public fun max_order_notional_for_testing<Product>(self: &State<Product>): (u64, u64, u64) {
    (
        self.max_order_notional.minimum(),
        self.max_order_notional.current(),
        self.max_order_notional.maximum(),
    )
}

#[test_only]
/// Forces shutdown-pending state for focused adapter tests.
public fun set_shutdown_pending_for_testing<Product>(self: &mut State<Product>) {
    self.lifecycle.set_shutdown_pending_for_testing();
}

#[test_only]
/// Returns whether the lifecycle is shutdown-pending.
public fun is_shutdown_pending_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_shutdown_pending()
}

#[test_only]
/// Forces shutdown-settled state for focused monotonicity tests.
public fun set_shutdown_settled_for_testing<Product>(self: &mut State<Product>) {
    self.lifecycle = lifecycle::shutdown_settled_for_testing();
}

#[test_only]
/// Returns whether the lifecycle is shutdown-settled.
public fun is_shutdown_settled_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_shutdown_settled()
}

#[test_only]
/// Forces active state for focused transition and adapter tests.
public fun set_active_for_testing<Product>(self: &mut State<Product>) {
    self.lifecycle = lifecycle::active_for_testing();
}

#[test_only]
/// Returns whether the lifecycle is reduce-only.
public fun is_reduce_only_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_reduce_only()
}

#[test_only]
/// Consumes an isolated state value at the end of a unit test.
public fun destroy_for_testing<Product>(self: State<Product>) {
    let State {
        tier_policy: _,
        max_order_notional: _,
        maintenance_reserve: _,
        lifecycle: _,
    } = self;
}
