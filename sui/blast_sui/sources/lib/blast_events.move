// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

module blast_sui::blast_events;

// === Public Structs ===

/// Stable package-wide envelope for every Blast SUI protocol event payload.
public struct Event<T: copy + drop>(T) has copy, drop;

// === Package Functions ===

/// Emits one package payload through the stable Blast event envelope.
public(package) fun emit_event<T: copy + drop>(event: T) {
    sui::event::emit(Event(event));
}

// === Test-Only Functions ===

/// Unwraps a payload collected from the generic protocol event envelope.
#[test_only]
public fun unwrap<T: copy + drop>(self: Event<T>): T {
    let Event(inner) = self;
    inner
}
