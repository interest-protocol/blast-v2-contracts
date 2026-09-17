/// Irreversible lifecycle and operation permissions for one Series1 Vault.
module blast_boosts_core::lifecycle;

// === Errors ===

#[error(code = 17)]
const EInvalidLifecycleTransition: vector<u8> = b"The lifecycle cannot make the requested transition.";

#[error(code = 18)]
const EOperationNotPermittedInLifecycle: vector<u8> = b"The lifecycle does not permit the requested operation.";

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

public(package) fun new(): Lifecycle { Lifecycle::Uninitialized }

public(package) fun is_uninitialized(self: &Lifecycle): bool {
    match (self) { Lifecycle::Uninitialized => true, _ => false }
}

public(package) fun assert_can_activate(self: &Lifecycle) {
    assert!(self.is_uninitialized(), EInvalidLifecycleTransition);
}

public(package) fun activate(self: &mut Lifecycle) {
    self.assert_can_activate();
    *self = Lifecycle::Active;
}

public(package) fun is_active(self: &Lifecycle): bool {
    match (self) { Lifecycle::Active => true, _ => false }
}

public(package) fun assert_active(self: &Lifecycle) {
    assert!(self.is_active(), EOperationNotPermittedInLifecycle);
}

public(package) fun assert_normal_redemption_allowed(self: &Lifecycle) {
    self.assert_active();
}

public(package) fun assert_operating_risk_reduction_allowed(self: &Lifecycle) {
    self.assert_active();
}

/// Settled cash has no remaining venue funding or health lifecycle.
public(package) fun assert_can_sync(self: &Lifecycle) {
    assert!(self.is_active() || self.is_unwinding(),
        EOperationNotPermittedInLifecycle);
}

/// Only the owner with authenticated shutdown authority may call this transition.
public(package) fun begin_shutdown(self: &mut Lifecycle) {
    assert!(self.is_active(), EInvalidLifecycleTransition);
    *self = Lifecycle::Unwinding;
}

public(package) fun is_unwinding(self: &Lifecycle): bool {
    match (self) { Lifecycle::Unwinding => true, _ => false }
}

public(package) fun assert_shutdown_close_allowed(self: &Lifecycle) {
    assert!(self.is_unwinding(), EOperationNotPermittedInLifecycle);
}

/// The owning adapter must first recover all cash and prove venue finality.
public(package) fun finalize_shutdown(self: &mut Lifecycle) {
    assert!(self.is_unwinding(), EInvalidLifecycleTransition);
    *self = Lifecycle::Settled;
}

public(package) fun is_settled(self: &Lifecycle): bool {
    match (self) { Lifecycle::Settled => true, _ => false }
}

public(package) fun assert_shutdown_redemption_allowed(self: &Lifecycle) {
    assert!(self.is_settled(), EOperationNotPermittedInLifecycle);
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
