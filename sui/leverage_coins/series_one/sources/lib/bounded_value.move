// `blast_leverage_series_one::errors` centralizes package abort codes through zero-cost macros. This
// narrow suppression preserves caller-local abort locations and the stable code map documented in
// this package's `README.md`.
#[allow(lint(abort_without_constant))]
/// A reusable value whose current setting cannot leave immutable inclusive bounds.
module blast_leverage_series_one::bounded_value;

// === Public Structs ===

/// An inclusive minimum, current value, and maximum, in that tuple order.
///
/// This type assigns no unit or authority to the value. The consuming domain
/// owns those rules. The defining module seals the fields and exposes no bound
/// mutation.
public struct BoundedValue(u64, u64, u64) has copy, drop, store;

// === Package Functions ===

/// Creates a bounded value satisfying `minimum <= current <= maximum`.
public(package) fun new(minimum: u64, current: u64, maximum: u64): BoundedValue {
    assert!(
        minimum <= current && current <= maximum,
        blast_leverage_series_one::errors::invalid_bounded_value!(),
    );

    BoundedValue(minimum, current, maximum)
}

/// Returns the immutable inclusive minimum.
public(package) fun minimum(self: &BoundedValue): u64 {
    self.0
}

/// Returns the current value.
public(package) fun current(self: &BoundedValue): u64 {
    self.1
}

/// Returns the immutable inclusive maximum.
public(package) fun maximum(self: &BoundedValue): u64 {
    self.2
}

/// Updates the current value without changing either bound.
public(package) fun set_current(self: &mut BoundedValue, current: u64) {
    assert!(
        self.0 <= current && current <= self.2,
        blast_leverage_series_one::errors::invalid_bounded_value!(),
    );

    self.1 = current;
}
