module blast_fun_vesting_linear::events_wrapper;

// === Public Structs ===

/// Stable package-wide envelope for every vesting event payload.
public struct Event<T: copy + drop>(T) has copy, drop;

// === Package Functions ===

public(package) fun emit_event<T: copy + drop>(event: T) {
    sui::event::emit(Event(event));
}

// === Test-Only Functions ===

#[test_only]
public fun unwrap<T: copy + drop>(event: Event<T>): T {
    let Event(inner) = event;
    inner
}
