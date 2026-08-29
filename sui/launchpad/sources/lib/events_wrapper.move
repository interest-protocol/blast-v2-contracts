module blast_fun::events_wrapper;

// === Public Structs ===

/// Stable package-wide envelope for every Blast protocol event payload.
public struct Event<T: copy + drop>(T) has copy, drop;

// === Package Functions ===

public(package) fun emit_event<T: copy + drop>(event: T) {
    sui::event::emit(Event(event));
}

// === Test-Only Functions ===

/// Unwraps a payload collected from the generic protocol event envelope.
#[test_only]
public fun unwrap<T: copy + drop>(event: Event<T>): T {
    let Event(inner) = event;
    inner
}
