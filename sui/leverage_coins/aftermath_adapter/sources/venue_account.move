// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Exact Aftermath account custody and immutable venue binding.
module blast_leverage_aftermath::venue_account;

use authority_cap::authority::{Self, ADMIN, AuthorityCap};
use perpetuals::authority::ACCOUNT;
use std::type_name::TypeName;

// === Public Types ===

/// Immutable external object graph for one Aftermath leverage account.
public struct Binding has copy, drop, store {
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
    collateral_type: TypeName,
}

/// Raw Aftermath state captured at one authenticated mutation boundary.
public struct Checkpoint has copy, drop, store {
    free_collateral: u64,
    allocated_collateral: u256,
    signed_base: u256,
    signed_quote_notional: u256,
    funding_snapshot_long: u256,
    funding_snapshot_short: u256,
    market_funding_long: u256,
    market_funding_short: u256,
    lot_size: u64,
    pending_ask_base: u256,
    pending_bid_base: u256,
    pending_order_count: u64,
    market_pause_mode: u8,
    market_frozen: bool,
    position_initial_margin_ratio: u256,
    market_initial_margin_ratio: u256,
    market_maintenance_margin_ratio: u256,
}

/// Store-only custody for the sole admin authority of one bound Aftermath account.
public struct VenueAccount has store {
    admin_cap: Option<AuthorityCap<ACCOUNT, ADMIN>>,
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
    collateral_type: TypeName,
    checkpoint: Checkpoint,
}

// === Package Functions ===

/// Creates a value used to authenticate one complete external object graph.
public(package) fun new_binding(
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
    collateral_type: TypeName,
): Binding {
    Binding {
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
    }
}

/// Creates one raw checkpoint after the caller authenticates every source.
public(package) fun new_checkpoint(
    free_collateral: u64,
    allocated_collateral: u256,
    signed_base: u256,
    signed_quote_notional: u256,
    funding_snapshot_long: u256,
    funding_snapshot_short: u256,
    market_funding_long: u256,
    market_funding_short: u256,
    lot_size: u64,
    pending_ask_base: u256,
    pending_bid_base: u256,
    pending_order_count: u64,
    market_pause_mode: u8,
    market_frozen: bool,
    position_initial_margin_ratio: u256,
    market_initial_margin_ratio: u256,
    market_maintenance_margin_ratio: u256,
): Checkpoint {
    Checkpoint {
        free_collateral,
        allocated_collateral,
        signed_base,
        signed_quote_notional,
        funding_snapshot_long,
        funding_snapshot_short,
        market_funding_long,
        market_funding_short,
        lot_size,
        pending_ask_base,
        pending_bid_base,
        pending_order_count,
        market_pause_mode,
        market_frozen,
        position_initial_margin_ratio,
        market_initial_margin_ratio,
        market_maintenance_margin_ratio,
    }
}

/// Rejects the first external component that differs from this binding.
public(package) fun assert_exact(
    self: &Binding,
    account_object_id: ID,
    account_number: u64,
    registry_id: ID,
    clearing_house_id: ID,
    base_oracle_id: ID,
    collateral_oracle_id: ID,
    collateral_type: TypeName,
) {
    assert!(
        self.account_object_id == account_object_id,
        blast_leverage_aftermath::errors::account_object_mismatch!(),
    );
    assert!(
        self.account_number == account_number,
        blast_leverage_aftermath::errors::account_number_mismatch!(),
    );
    assert!(
        self.registry_id == registry_id,
        blast_leverage_aftermath::errors::registry_mismatch!(),
    );
    assert!(
        self.clearing_house_id == clearing_house_id,
        blast_leverage_aftermath::errors::clearing_house_mismatch!(),
    );
    assert!(
        self.base_oracle_id == base_oracle_id,
        blast_leverage_aftermath::errors::base_oracle_mismatch!(),
    );
    assert!(
        self.collateral_oracle_id == collateral_oracle_id,
        blast_leverage_aftermath::errors::collateral_oracle_mismatch!(),
    );
    assert!(
        self.collateral_type == collateral_type,
        blast_leverage_aftermath::errors::collateral_type_mismatch!(),
    );
}

/// Seals the exact account admin authority into its authenticated binding.
public(package) fun new(
    admin_cap: AuthorityCap<ACCOUNT, ADMIN>,
    binding: Binding,
    checkpoint: Checkpoint,
): VenueAccount {
    let Binding {
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
    } = binding;
    assert_admin_cap_binding(authority::`for`(&admin_cap), account_object_id);
    let admin_cap = option::some(admin_cap);
    VenueAccount {
        admin_cap,
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
        checkpoint,
    }
}

/// Rejects an admin cap that does not belong to the created account object.
public(package) fun assert_admin_cap_binding(
    cap_account_object_id: ID,
    account_object_id: ID,
) {
    assert!(
        cap_account_object_id == account_object_id,
        blast_leverage_aftermath::errors::admin_cap_account_mismatch!(),
    );
}

/// Copies the immutable binding without exposing venue custody.
public(package) fun binding(self: &VenueAccount): Binding {
    Binding {
        account_object_id: self.account_object_id,
        account_number: self.account_number,
        registry_id: self.registry_id,
        clearing_house_id: self.clearing_house_id,
        base_oracle_id: self.base_oracle_id,
        collateral_oracle_id: self.collateral_oracle_id,
        collateral_type: self.collateral_type,
    }
}

/// Unpacks a copied immutable binding for replay-complete adapter events.
public(package) fun unpack_binding(
    self: Binding,
): (ID, u64, ID, ID, ID, ID, TypeName) {
    let Binding {
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
    } = self;

    (
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
    )
}

/// Borrows the latest authenticated raw checkpoint immutably.
public(package) fun checkpoint(self: &VenueAccount): &Checkpoint {
    &self.checkpoint
}

/// Revalidates that retained admin authority still names the bound account.
public(package) fun assert_custody_binding(self: &VenueAccount) {
    assert!(
        self.admin_cap.is_some(),
        blast_leverage_aftermath::errors::admin_cap_account_mismatch!(),
    );
    assert_admin_cap_binding(
        authority::`for`(self.admin_cap.borrow()),
        self.account_object_id,
    );
}

/// Unpacks a copied checkpoint for normalization and change classification.
public(package) fun unpack(
    self: Checkpoint,
): (
    u64,
    u256,
    u256,
    u256,
    u256,
    u256,
    u256,
    u256,
    u64,
    u256,
    u256,
    u64,
    u8,
    bool,
    u256,
    u256,
    u256,
) {
    let Checkpoint {
        free_collateral,
        allocated_collateral,
        signed_base,
        signed_quote_notional,
        funding_snapshot_long,
        funding_snapshot_short,
        market_funding_long,
        market_funding_short,
        lot_size,
        pending_ask_base,
        pending_bid_base,
        pending_order_count,
        market_pause_mode,
        market_frozen,
        position_initial_margin_ratio,
        market_initial_margin_ratio,
        market_maintenance_margin_ratio,
    } = self;

    (
        free_collateral,
        allocated_collateral,
        signed_base,
        signed_quote_notional,
        funding_snapshot_long,
        funding_snapshot_short,
        market_funding_long,
        market_funding_short,
        lot_size,
        pending_ask_base,
        pending_bid_base,
        pending_order_count,
        market_pause_mode,
        market_frozen,
        position_initial_margin_ratio,
        market_initial_margin_ratio,
        market_maintenance_margin_ratio,
    )
}

/// Replaces the raw checkpoint after one fully authenticated observation.
public(package) fun replace_checkpoint(
    self: &mut VenueAccount,
    checkpoint: Checkpoint,
) {
    self.checkpoint = checkpoint;
}

// === Test-Only Functions ===

/// Builds real binding/checkpoint custody around the unavailable local cap.
///
/// The authoritative external AuthorityCap constructor is an aborting ABI
/// stub in local tests. Published code has no path that can create `none`.
#[test_only]
public fun new_for_testing(
    binding: Binding,
    checkpoint: Checkpoint,
): VenueAccount {
    let Binding {
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
    } = binding;

    VenueAccount {
        admin_cap: option::none(),
        account_object_id,
        account_number,
        registry_id,
        clearing_house_id,
        base_oracle_id,
        collateral_oracle_id,
        collateral_type,
        checkpoint,
    }
}

#[test_only]
public fun assert_admin_cap_binding_for_testing(
    cap_account_object_id: ID,
    account_object_id: ID,
) {
    assert_admin_cap_binding(cap_account_object_id, account_object_id);
}

#[test_only]
public fun checkpoint_for_testing(
    free_collateral: u64,
    allocated_collateral: u256,
    signed_base: u256,
    signed_quote_notional: u256,
    funding_snapshot_long: u256,
    funding_snapshot_short: u256,
    market_funding_long: u256,
    market_funding_short: u256,
    lot_size: u64,
    pending_ask_base: u256,
    pending_bid_base: u256,
    pending_order_count: u64,
    market_pause_mode: u8,
    market_frozen: bool,
    position_initial_margin_ratio: u256,
    market_initial_margin_ratio: u256,
    market_maintenance_margin_ratio: u256,
): Checkpoint {
    new_checkpoint(
        free_collateral,
        allocated_collateral,
        signed_base,
        signed_quote_notional,
        funding_snapshot_long,
        funding_snapshot_short,
        market_funding_long,
        market_funding_short,
        lot_size,
        pending_ask_base,
        pending_bid_base,
        pending_order_count,
        market_pause_mode,
        market_frozen,
        position_initial_margin_ratio,
        market_initial_margin_ratio,
        market_maintenance_margin_ratio,
    )
}
