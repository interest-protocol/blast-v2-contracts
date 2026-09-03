module blast_leverage_series_one::events_wrapper;

// === Public Structs ===

/// Stable package-wide envelope for every Series1 event payload.
public struct Event<T: copy + drop>(T) has copy, drop;

// === Package Functions ===

/// Emits one Series1 payload through the stable package event envelope.
public(package) fun emit_event<T: copy + drop>(event: T) {
    sui::event::emit(Event(event));
}

// === Test-Only Functions ===

#[test_only]
/// Unwraps a payload collected from the generic Series1 event envelope.
public fun unwrap<T: copy + drop>(self: Event<T>): T {
    let Event(inner) = self;
    inner
}
