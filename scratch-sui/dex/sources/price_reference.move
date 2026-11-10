// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// A pool-local time-weighted square-root price.
module blast_fun_dex::price_reference;

// === Constants ===

const WINDOW_MS: u64 = 600_000;

// === Public Types ===

/// The previous full window's integral and the current partial window's integral.
public struct PriceReference has drop, store {
    previous_total: u256,
    current_total: u256,
    window_start_ms: u64,
    observed_at_ms: u64,
}

// === Package Functions ===

public(package) fun new(initial_sqrt_price_x96: u256): PriceReference {
    PriceReference {
        previous_total: initial_sqrt_price_x96 * (WINDOW_MS as u256),
        current_total: 0,
        window_start_ms: 0,
        observed_at_ms: 0,
    }
}

/// Accumulates the spot that held since the last observation. The caller observes
/// before every price change. All swaps with the same Clock value share a reference.
public(package) fun observe(self: &mut PriceReference, spot_x96: u256, now_ms: u64): u256 {
    if (now_ms > self.observed_at_ms) {
        // Windows align to Unix time, including before the first observation.
        let start_ms = self.window_start_ms;
        let elapsed_ms = now_ms - start_ms;
        if (elapsed_ms < WINDOW_MS) {
            self.current_total = self.current_total + spot_x96 * ((now_ms - self.observed_at_ms) as u256);
        } else {
            // After two boundaries, the entire preceding window held at this spot.
            self.previous_total = if (elapsed_ms >= 2 * WINDOW_MS) {
                spot_x96 * (WINDOW_MS as u256)
            } else {
                let remaining_ms = WINDOW_MS - (self.observed_at_ms - start_ms);
                self.current_total + spot_x96 * (remaining_ms as u256)
            };
            let partial_ms = elapsed_ms % WINDOW_MS;
            self.current_total = spot_x96 * (partial_ms as u256);
            self.window_start_ms = now_ms - partial_ms;
        };
        self.observed_at_ms = now_ms;
    };

    self.value()
}

// === Private Functions ===

/// The current integral plus the unexpired fraction of the previous window's
/// integral. Divide once, rounding down. The numerator is bounded by a
/// square-root price below 2^161 times WINDOW_MS^2 (below 2^40).
fun value(self: &PriceReference): u256 {
    let elapsed_ms = self.observed_at_ms - self.window_start_ms;
    let window = WINDOW_MS as u256;
    let retained_ms = (WINDOW_MS - elapsed_ms) as u256;

    (self.previous_total * retained_ms + self.current_total * window) / (window * window)
}

// === Test-Only Functions ===

#[test_only]
public(package) fun observation_for_testing(self: &PriceReference): (u256, u64) {
    (self.value(), self.observed_at_ms)
}
