/// Interface sketch only. LP fee mode and rate validation.
/// All function bodies abort; do not publish.
module blast_fun_dex::swap_fee;

// === Errors ===

#[error(code = 0)]
const EInterfaceOnly: vector<u8> = b"Scratch interface only; implementation is not provided.";

// === Public Types ===

/// LP swap fee in ppm (1,000,000 = 100%). The mode is fixed at construction;
/// only Dynamic permits authorized current-rate updates.
public enum SwapFee has copy, drop, store {
    Fixed { fee_ppm: u32 },
    Dynamic { current_fee_ppm: u32 },
}

// === Public Functions ===

/// Intended fixed-fee constructor; validate <= 1,000,000 ppm.
public fun new_fixed(
    _fee_ppm: u32,
): SwapFee {
    abort EInterfaceOnly
}

/// Intended dynamic-fee constructor; validate initial current rate <= 1,000,000 ppm.
public fun new_dynamic(
    _current_fee_ppm: u32,
): SwapFee {
    abort EInterfaceOnly
}

/// Intended current rate projection from either variant.
public fun rate_ppm(_self: &SwapFee): u32 {
    abort EInterfaceOnly
}

/// Intended mode predicate for stored-rate update authorization.
public fun is_dynamic(_self: &SwapFee): bool {
    abort EInterfaceOnly
}

// === Package Functions ===

/// Intended rate-only update: reject Fixed and rates above 1,000,000 ppm.
public(package) fun update_dynamic(_self: &mut SwapFee, _fee_ppm: u32) {
    abort EInterfaceOnly
}
