// `blast_leverage_series_one::errors` centralizes package abort codes through zero-cost macros.
// This narrow suppression preserves caller-local abort locations and stable codes pinned by tests.
#[allow(lint(abort_without_constant))]
/// Closed lifecycle and operation permissions for one future Series1 Vault.
module blast_leverage_series_one::lifecycle;

// === Public Types ===

/// Consensus lifecycle for one Series1 Vault.
///
/// The value is non-copyable. New Vaults start uninitialized. Activation is
/// available only to `State` after it proves the complete seed
/// observation. Resume and settlement finalization remain absent because they
/// require later authority, venue, and custody proofs.
///
/// The value is droppable so transitions can assign through `&mut`, which means
/// the type system alone cannot stop an in-package module from overwriting a
/// stored lifecycle with `new()`. The source-boundary gate therefore
/// rejects any assignment to a `lifecycle` field and permits exactly one
/// production call of `new()` outside this module, the Vault
/// constructor. Every other state change must go through a transition here.
public enum Lifecycle has drop, store {
    /// No financial operation is available before risk initialization.
    Uninitialized,
    /// Normal mint, redemption, and risk management are available.
    Active,
    /// New risk is disabled while reduction and venue-permitted exits remain.
    ReduceOnly,
    /// Ordinary redemption is stopped while the venue position closes.
    ShutdownPending,
    /// The position is flat and only pro-rata settled-cash redemption remains.
    ShutdownSettled,
}

// === Package Functions ===

/// Returns the lifecycle of a newly issued Vault.
public(package) fun new(): Lifecycle {
    Lifecycle::Uninitialized
}

public(package) fun is_uninitialized(self: &Lifecycle): bool {
    match (self) {
        Lifecycle::Uninitialized => true,
        _ => false,
    }
}

public(package) fun is_active(self: &Lifecycle): bool {
    match (self) {
        Lifecycle::Active => true,
        _ => false,
    }
}

public(package) fun is_reduce_only(self: &Lifecycle): bool {
    match (self) {
        Lifecycle::ReduceOnly => true,
        _ => false,
    }
}

public(package) fun is_shutdown_pending(self: &Lifecycle): bool {
    match (self) {
        Lifecycle::ShutdownPending => true,
        _ => false,
    }
}

public(package) fun is_shutdown_settled(self: &Lifecycle): bool {
    match (self) {
        Lifecycle::ShutdownSettled => true,
        _ => false,
    }
}

/// Rejects any lifecycle that cannot begin the one-time activation proof.
public(package) fun assert_can_activate(self: &Lifecycle) {
    assert!(
        self.is_uninitialized(),
        blast_leverage_series_one::errors::invalid_lifecycle_transition!(),
    );
}

/// Rejects health synchronization before the product has activated.
public(package) fun assert_initialized(self: &Lifecycle) {
    assert!(
        !self.is_uninitialized(),
        blast_leverage_series_one::errors::invalid_lifecycle_transition!(),
    );
}

/// Activates a fully proved seed exactly once.
public(package) fun activate(self: &mut Lifecycle) {
    self.assert_can_activate();

    *self = Lifecycle::Active;
}

/// Disables new risk from the active lifecycle.
public(package) fun enter_reduce_only(self: &mut Lifecycle) {
    assert!(
        self.is_active(),
        blast_leverage_series_one::errors::invalid_lifecycle_transition!(),
    );

    *self = Lifecycle::ReduceOnly;
}

/// Irreversibly starts shutdown from an operating lifecycle.
public(package) fun enter_shutdown_pending(self: &mut Lifecycle) {
    assert!(
        self.is_active() || self.is_reduce_only(),
        blast_leverage_series_one::errors::invalid_lifecycle_transition!(),
    );

    *self = Lifecycle::ShutdownPending;
}

/// Disables new risk if the Vault is still active; otherwise leaves it as is.
///
/// This is the idempotent form for the objective health transition. A keeper
/// that observes a stale source or a leverage breach must persist degradation
/// even when an earlier transition already degraded the Vault, so a lifecycle
/// at or past `ReduceOnly` is left unchanged instead of aborting. Only an
/// uninitialized Vault aborts, because it holds no risk to disable.
public(package) fun degrade_to_reduce_only(self: &mut Lifecycle) {
    assert!(
        !self.is_uninitialized(),
        blast_leverage_series_one::errors::invalid_lifecycle_transition!(),
    );

    if (self.is_active()) {
        *self = Lifecycle::ReduceOnly;
    };
}

/// Starts shutdown if the Vault is still operating; otherwise leaves it as is.
///
/// Same idempotent contract as `degrade_to_reduce_only`: a Vault already in
/// `ShutdownPending` or `ShutdownSettled` is unchanged, and only an
/// uninitialized Vault aborts.
public(package) fun degrade_to_shutdown_pending(self: &mut Lifecycle) {
    assert!(
        !self.is_uninitialized(),
        blast_leverage_series_one::errors::invalid_lifecycle_transition!(),
    );

    if (self.is_active() || self.is_reduce_only()) {
        *self = Lifecycle::ShutdownPending;
    };
}

/// Permits minting, risk increase, or another active-only operation.
public(package) fun assert_active(self: &Lifecycle) {
    assert!(
        self.is_active(),
        blast_leverage_series_one::errors::operation_not_permitted_in_lifecycle!(),
    );
}

/// Permits ordinary redemption before shutdown starts.
public(package) fun assert_normal_redemption_allowed(self: &Lifecycle) {
    assert!(
        self.is_active() || self.is_reduce_only(),
        blast_leverage_series_one::errors::operation_not_permitted_in_lifecycle!(),
    );
}

/// Permits ordinary risk reduction while the Vault is operating.
public(package) fun assert_operating_risk_reduction_allowed(self: &Lifecycle) {
    assert!(
        self.is_active() || self.is_reduce_only(),
        blast_leverage_series_one::errors::operation_not_permitted_in_lifecycle!(),
    );
}

/// Permits close-only shutdown execution while settlement is pending.
public(package) fun assert_shutdown_close_allowed(self: &Lifecycle) {
    assert!(
        self.is_shutdown_pending(),
        blast_leverage_series_one::errors::operation_not_permitted_in_lifecycle!(),
    );
}

/// Permits pro-rata cash redemption only after shutdown settlement is final.
public(package) fun assert_shutdown_redemption_allowed(self: &Lifecycle) {
    assert!(
        self.is_shutdown_settled(),
        blast_leverage_series_one::errors::operation_not_permitted_in_lifecycle!(),
    );
}

// ponytail: Resume and settlement finalization stay absent until the adapter can prove their
// complete authority, valuation, venue-health, and custody conditions.

// === Test-Only Functions ===

#[test_only]
public(package) fun active_for_testing(): Lifecycle {
    Lifecycle::Active
}

#[test_only]
public(package) fun reduce_only_for_testing(): Lifecycle {
    Lifecycle::ReduceOnly
}

#[test_only]
public(package) fun shutdown_pending_for_testing(): Lifecycle {
    Lifecycle::ShutdownPending
}

#[test_only]
public(package) fun shutdown_settled_for_testing(): Lifecycle {
    Lifecycle::ShutdownSettled
}

#[test_only]
public(package) fun set_shutdown_pending_for_testing(self: &mut Lifecycle) {
    *self = Lifecycle::ShutdownPending;
}
