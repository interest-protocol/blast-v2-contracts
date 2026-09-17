/// Stable event envelope for the Aftermath adapter package.
module blast_boosts_aftermath::blast_events;

// === Public Structs ===

/// Stable package-wide envelope for every adapter event payload.
public struct Event<T: copy + drop>(T) has copy, drop;

// === Package Functions ===

/// Emits one adapter payload through the stable package event envelope.
public(package) fun emit_event<T: copy + drop>(event: T) {
    sui::event::emit(Event(event));
}

// === Test-Only Functions ===

#[test_only]
/// Unwraps one collected adapter event payload.
public fun unwrap<T: copy + drop>(self: Event<T>): T {
    let Event(inner) = self;
    inner
}
