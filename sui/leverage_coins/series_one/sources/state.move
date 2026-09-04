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
    acl::AdminWitness,
    bounded_value::{Self, BoundedValue},
    constants,
    lifecycle::{Self, Lifecycle},
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

// === Test-Only Functions ===

#[test_only]
/// Returns whether the embedded lifecycle is uninitialized.
public fun is_uninitialized_for_testing<Product>(self: &State<Product>): bool {
    self.lifecycle.is_uninitialized()
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
