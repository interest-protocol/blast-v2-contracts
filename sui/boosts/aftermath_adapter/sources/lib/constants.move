/// Package-wide immutable adapter constants.
module blast_boosts_aftermath::constants;

// === Package Constants ===

/// Fixed decimals for every Boost currency issued by this adapter.
macro public(package) fun share_decimals(): u8 {
    9
}

/// Decimals this adapter normalizes every venue base amount to.
macro public(package) fun base_decimals(): u8 {
    9
}

/// Decimals of the only collateral this adapter admits.
macro public(package) fun collateral_decimals(): u8 {
    6
}

/// One in IFixed: `10^18`.
macro public(package) fun ifixed_one(): u256 {
    1_000_000_000_000_000_000
}

/// One basis point in IFixed: `10^18 / 10_000`.
macro public(package) fun ifixed_per_basis_point(): u256 {
    100_000_000_000_000
}

/// Raw IFixed units in one base atom: `10^(18 - 9)`.
macro public(package) fun base_atom_to_ifixed_scale(): u256 {
    1_000_000_000
}

/// Raw IFixed units in one collateral atom: `10^(18 - 6)`.
macro public(package) fun collateral_atom_to_ifixed_scale(): u256 {
    1_000_000_000_000
}

/// Base atoms per collateral atom at a unit price: `10^(9 - 6)`.
macro public(package) fun collateral_to_base_scale(): u256 {
    1_000
}
