// Package error macros keep stable codes in `errors.move`; the lint sees the expanded literal.
#[allow(lint(abort_without_constant))]
/// Irreversible lifecycle and operation permissions for one Vault.
module blast_boosts_core::lifecycle;

// === Public Types ===

/// Only activation and authenticated shutdown can move a Vault forward.
/// Field assignment and construction remain restricted by the source-boundary gate.
public enum Lifecycle has drop, store {
    Uninitialized,
    Active,
    Unwinding,
    Settled,
}

/// Administrator-declared operational reason, never an on-chain liquidation verdict.
public enum ShutdownReason has copy, drop, store {
    Emergency,
    ObservedVenueChange,
}

// === Public Functions ===

/// Declares an administrator's emergency decision, without an objective venue verdict.
public fun emergency_reason(): ShutdownReason { ShutdownReason::Emergency }

/// Declares an off-chain venue-change observation, including liquidation or ADL.
public fun observed_venue_change_reason(): ShutdownReason { ShutdownReason::ObservedVenueChange }

// === Package Functions ===

public(package) fun uninitialized(): Lifecycle { Lifecycle::Uninitialized }

public(package) fun is_uninitialized(self: &Lifecycle): bool {
    match (self) { Lifecycle::Uninitialized => true, _ => false }
}

public(package) fun assert_can_activate(self: &Lifecycle) {
    assert!(self.is_uninitialized(), blast_boosts_core::errors::invalid_lifecycle_transition!());
}

public(package) fun activate(self: &mut Lifecycle) {
    self.assert_can_activate();

    *self = Lifecycle::Active;
}

public(package) fun is_active(self: &Lifecycle): bool {
    match (self) { Lifecycle::Active => true, _ => false }
}

public(package) fun assert_active(self: &Lifecycle) {
    assert!(self.is_active(), blast_boosts_core::errors::operation_not_permitted_in_lifecycle!());
}

/// Settled cash has no remaining venue funding or health lifecycle.
public(package) fun assert_can_sync(self: &Lifecycle) {
    assert!(
        self.is_active() || self.is_unwinding(),
        blast_boosts_core::errors::operation_not_permitted_in_lifecycle!(),
    );
}

/// Only the owner with authenticated shutdown authority may call this transition.
public(package) fun begin_shutdown(self: &mut Lifecycle) {
    assert!(self.is_active(), blast_boosts_core::errors::invalid_lifecycle_transition!());

    *self = Lifecycle::Unwinding;
}

public(package) fun is_unwinding(self: &Lifecycle): bool {
    match (self) { Lifecycle::Unwinding => true, _ => false }
}

public(package) fun assert_shutdown_close_allowed(self: &Lifecycle) {
    assert!(self.is_unwinding(), blast_boosts_core::errors::operation_not_permitted_in_lifecycle!());
}

/// The owning adapter must first recover all cash and prove venue finality.
public(package) fun finalize_shutdown(self: &mut Lifecycle) {
    assert!(self.is_unwinding(), blast_boosts_core::errors::invalid_lifecycle_transition!());

    *self = Lifecycle::Settled;
}

public(package) fun is_settled(self: &Lifecycle): bool {
    match (self) { Lifecycle::Settled => true, _ => false }
}

public(package) fun assert_shutdown_redemption_allowed(self: &Lifecycle) {
    assert!(self.is_settled(), blast_boosts_core::errors::operation_not_permitted_in_lifecycle!());
}

// === Test-Only Functions ===

#[test_only]
public(package) fun active_for_testing(): Lifecycle { Lifecycle::Active }

#[test_only]
public(package) fun unwinding_for_testing(): Lifecycle { Lifecycle::Unwinding }

#[test_only]
public(package) fun settled_for_testing(): Lifecycle { Lifecycle::Settled }

#[test_only]
public(package) fun set_unwinding_for_testing(self: &mut Lifecycle) {
    *self = Lifecycle::Unwinding;
}
