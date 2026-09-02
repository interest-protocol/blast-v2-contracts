// `blast_leverage_coins::errors` centralizes package abort codes through zero-cost macros. This
// narrow suppression preserves caller-local abort locations and the stable code map documented in
// this package's `README.md`.
#[allow(lint(abort_without_constant))]
/// Closed lifecycle and operation permissions for one leverage Series.
///
/// This module owns no Series object, asset, capability, venue fact, or event.
/// It permits only monotone degradation that depends on the current lifecycle
/// alone. The future `series` module owns authority and health proofs, stored
/// state mutation, and lifecycle event emission.
module blast_leverage_coins::series_lifecycle;

// === Public Types ===

/// Consensus lifecycle for one leverage Series.
public enum Lifecycle has drop, store {
    /// Normal mint, redemption, and risk management are available.
    Active,
    /// New risk is disabled while reduction and venue-permitted exits remain.
    ReduceOnly,
    /// Ordinary redemption is stopped while the venue position closes or settles.
    ShutdownPending,
    /// The position is gone and only pro-rata settled-cash redemption remains.
    ShutdownSettled,
}

// === Package Functions ===

/// Returns the lifecycle of a newly constructed Series.
public(package) fun new(): Lifecycle {
    Lifecycle::Active
}

/// Returns whether normal minting and risk increase are permitted.
public(package) fun is_active(self: &Lifecycle): bool {
    match (self) {
        Lifecycle::Active => true,
        _ => false,
    }
}

/// Returns whether new risk is disabled but ordinary exits remain possible.
public(package) fun is_reduce_only(self: &Lifecycle): bool {
    match (self) {
        Lifecycle::ReduceOnly => true,
        _ => false,
    }
}

/// Returns whether shutdown still requires venue close or settlement.
public(package) fun is_shutdown_pending(self: &Lifecycle): bool {
    match (self) {
        Lifecycle::ShutdownPending => true,
        _ => false,
    }
}

/// Returns whether shutdown cash is final and redeemable.
public(package) fun is_shutdown_settled(self: &Lifecycle): bool {
    match (self) {
        Lifecycle::ShutdownSettled => true,
        _ => false,
    }
}

/// Disables new risk from the active lifecycle.
public(package) fun enter_reduce_only(self: &mut Lifecycle) {
    assert!(
        self.is_active(),
        blast_leverage_coins::errors::invalid_lifecycle_transition!(),
    );

    *self = Lifecycle::ReduceOnly;
}

/// Starts terminal shutdown from either nonterminal operating lifecycle.
public(package) fun enter_shutdown_pending(self: &mut Lifecycle) {
    assert!(
        self.is_active() || self.is_reduce_only(),
        blast_leverage_coins::errors::invalid_lifecycle_transition!(),
    );

    *self = Lifecycle::ShutdownPending;
}

/// Permits a mint, risk increase, or ordinary active-only operation.
public(package) fun assert_active(self: &Lifecycle) {
    assert!(
        self.is_active(),
        blast_leverage_coins::errors::operation_not_permitted_in_lifecycle!(),
    );
}

/// Permits an ordinary redemption only before shutdown starts.
///
/// `ReduceOnly` admission is necessary but not sufficient: the later Series
/// and adapter must still prove that the venue can complete the exit safely.
public(package) fun assert_normal_redemption_allowed(self: &Lifecycle) {
    assert!(
        self.is_active() || self.is_reduce_only(),
        blast_leverage_coins::errors::operation_not_permitted_in_lifecycle!(),
    );
}

/// Permits ordinary risk reduction while the Series is still operating.
///
/// This guard intentionally remains separate from ordinary redemption even
/// while both admit the same states. Any future ReduceOnly redemption-policy
/// change must re-audit both guards against the lifecycle permission matrix.
public(package) fun assert_operating_risk_reduction_allowed(self: &Lifecycle) {
    assert!(
        self.is_active() || self.is_reduce_only(),
        blast_leverage_coins::errors::operation_not_permitted_in_lifecycle!(),
    );
}

/// Permits the close-or-settle operation only during pending shutdown.
public(package) fun assert_shutdown_close_allowed(self: &Lifecycle) {
    assert!(
        self.is_shutdown_pending(),
        blast_leverage_coins::errors::operation_not_permitted_in_lifecycle!(),
    );
}

/// Permits pro-rata cash redemption only after shutdown settlement is final.
public(package) fun assert_shutdown_redemption_allowed(self: &Lifecycle) {
    assert!(
        self.is_shutdown_settled(),
        blast_leverage_coins::errors::operation_not_permitted_in_lifecycle!(),
    );
}

// ponytail: Resume and settlement finalization stay absent until `series` can prove their
// authority, cooldown, venue-health, funding, custody, and reserve-reclassification conditions.

// === Test-Only Functions ===

#[test_only]
/// Creates ReduceOnly state for exhaustive transition and operation tests.
public(package) fun reduce_only_for_testing(): Lifecycle {
    Lifecycle::ReduceOnly
}

#[test_only]
/// Creates ShutdownPending state for exhaustive transition and operation tests.
public(package) fun shutdown_pending_for_testing(): Lifecycle {
    Lifecycle::ShutdownPending
}

#[test_only]
/// Creates ShutdownSettled state for exhaustive transition and operation tests.
public(package) fun shutdown_settled_for_testing(): Lifecycle {
    Lifecycle::ShutdownSettled
}
