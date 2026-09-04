// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Adapter-owned Vault, leverage currency, and venue storage.
module blast_leverage_aftermath::vault;

use blast_leverage_aftermath::{
    aftermath::AFTERMATH,
    constants,
    events,
    protocol::Protocol,
};
use blast_leverage_series_one::{
    acl::{Self, AdminWitness},
    policy::TierPolicy,
    state::{Self as series_state, State},
};
use std::{string::String, type_name::{Self, TypeName}};
use sui::{
    coin::TreasuryCap,
    coin_registry::{CoinRegistry, MetadataCap},
    dynamic_object_field,
};

use fun dynamic_object_field::add as UID.add_dynamic_object_field;

// === Public Structs ===

/// Shared adapter custody for one Series1 leverage currency and product.
///
/// This adapter defines `Vault<Product>`, so it can issue the corresponding
/// non-OTW currency through Coin Registry. The nested Series1 state has private
/// fields and can change only through Series1 mutation functions.
public struct Vault<phantom Product> has key {
    id: UID,
    series_state: State<Product>,
    risk_module_witness: TypeName,
}

/// Dynamic-object-field key for one Vault's share mint authority.
public struct TreasuryKey<phantom Product>() has copy, drop, store;

/// Dynamic-object-field key for one Vault's metadata authority.
public struct MetadataKey<phantom Product>() has copy, drop, store;

// === Public Functions ===

/// Issues one owned adapter Vault and its unique leverage currency.
///
/// The adapter version and Series1 issuer role are checked before Coin Registry
/// mutation. The returned key-only Vault must pass to `share` in this package.
public fun issue<Product: drop, RiskModule: drop>(
    protocol: &Protocol,
    admin_witness: &AdminWitness,
    _: Product,
    registry: &mut CoinRegistry,
    tier_policy: TierPolicy,
    max_order_notional_minimum: u64,
    max_order_notional_current: u64,
    max_order_notional_maximum: u64,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    ctx: &mut TxContext,
): Vault<Product> {
    protocol.assert_current();
    let series_state = series_state::new<Product>(
        admin_witness,
        tier_policy,
        max_order_notional_minimum,
        max_order_notional_current,
        max_order_notional_maximum,
    );

    let product_witness = type_name::with_original_ids<Product>();
    assert!(
        !product_witness.is_primitive(),
        blast_leverage_aftermath::errors::invalid_product_witness_type!(),
    );
    assert!(
        type_name::original_id<Product>()
            == type_name::original_id<AFTERMATH>(),
        blast_leverage_aftermath::errors::product_witness_package_mismatch!(),
    );

    let risk_module_witness = type_name::with_original_ids<RiskModule>();
    assert!(
        !risk_module_witness.is_primitive(),
        blast_leverage_aftermath::errors::invalid_risk_module_witness_type!(),
    );

    let (initializer, treasury_cap) = registry.new_currency<Vault<Product>>(
        constants::share_decimals!(),
        symbol,
        name,
        description,
        icon_url,
        ctx,
    );
    let metadata_cap = initializer.finalize(ctx);
    let treasury_cap_id = object::id(&treasury_cap);
    let metadata_cap_id = object::id(&metadata_cap);
    let mut vault = Vault {
        id: object::new(ctx),
        series_state,
        risk_module_witness,
    };
    let vault_id = vault.id.to_inner();

    vault.add_treasury_cap(treasury_cap);
    vault.add_metadata_cap(metadata_cap);
    events::vault_issued<Product>(
        vault_id,
        treasury_cap_id,
        metadata_cap_id,
        risk_module_witness,
        tier_policy,
        max_order_notional_minimum,
        max_order_notional_current,
        max_order_notional_maximum,
        0,
    );

    vault
}

/// Shares one fully issued adapter Vault.
public fun share<Product>(self: Vault<Product>) {
    transfer::share_object(self);
}

/// Replaces the risk-module witness accepted by this adapter Vault.
///
/// Rotation is available in every Series1 lifecycle state. It changes no core
/// policy, accounting value, currency capability, or adapter version.
public fun rotate_risk_module<Product, RiskModule: drop>(
    self: &mut Vault<Product>,
    protocol: &Protocol,
    admin_witness: &AdminWitness,
) {
    protocol.assert_current();
    admin_witness.assert_risk_admin();

    let new_witness = type_name::with_original_ids<RiskModule>();
    assert!(
        !new_witness.is_primitive(),
        blast_leverage_aftermath::errors::invalid_risk_module_witness_type!(),
    );
    assert!(
        new_witness != self.risk_module_witness,
        blast_leverage_aftermath::errors::risk_module_witness_unchanged!(),
    );

    let previous_witness = self.risk_module_witness;
    self.risk_module_witness = new_witness;
    events::risk_module_witness_rotated<Product>(
        self.id.to_inner(),
        previous_witness,
        new_witness,
    );
}

/// Changes the live per-call maximum order notional within its frozen bounds.
///
/// This value limits the absolute atomic-USDC notional of one Aftermath order.
/// It does not limit a user's deposit or the Vault's total open position.
/// The selected risk module may raise or lower the current value without a
/// cooldown. This transition changes neither the immutable bounds nor live
/// position exposure and therefore remains available in every lifecycle state.
public fun set_max_order_notional<Product, RiskModule: drop>(
    self: &mut Vault<Product>,
    protocol: &Protocol,
    _: RiskModule,
    current: u64,
) {
    protocol.assert_current();
    let presented_witness = type_name::with_original_ids<RiskModule>();
    assert!(
        !presented_witness.is_primitive(),
        blast_leverage_aftermath::errors::invalid_risk_module_witness_type!(),
    );
    assert!(
        presented_witness == self.risk_module_witness,
        blast_leverage_aftermath::errors::risk_module_witness_mismatch!(),
    );

    let previous = self.series_state.set_max_order_notional(current);
    events::max_order_notional_updated<Product>(
        self.id.to_inner(),
        previous,
        current,
    );
}

/// Disables new risk through the Series1-wide risk administrator role.
public fun enter_reduce_only<Product>(
    self: &mut Vault<Product>,
    protocol: &Protocol,
    admin_witness: &AdminWitness,
) {
    protocol.assert_current();
    admin_witness.assert_risk_admin();

    self.series_state.enter_reduce_only();
    events::reduce_only_entered<Product>(self.id.to_inner());
}

// === Private Functions ===

fun add_treasury_cap<Product>(
    self: &mut Vault<Product>,
    treasury_cap: TreasuryCap<Vault<Product>>,
) {
    self.id.add_dynamic_object_field(TreasuryKey<Product>(), treasury_cap);
}

fun add_metadata_cap<Product>(
    self: &mut Vault<Product>,
    metadata_cap: MetadataCap<Vault<Product>>,
) {
    self.id.add_dynamic_object_field(MetadataKey<Product>(), metadata_cap);
}

// === Test-Only Functions ===

#[test_only]
fun treasury_cap<Product>(self: &Vault<Product>): &TreasuryCap<Vault<Product>> {
    dynamic_object_field::borrow(&self.id, TreasuryKey<Product>())
}

#[test_only]
fun metadata_cap<Product>(self: &Vault<Product>): &MetadataCap<Vault<Product>> {
    dynamic_object_field::borrow(&self.id, MetadataKey<Product>())
}

#[test_only]
public fun id_for_testing<Product>(self: &Vault<Product>): ID {
    self.id.to_inner()
}

#[test_only]
public fun is_uninitialized_for_testing<Product>(self: &Vault<Product>): bool {
    self.series_state.is_uninitialized_for_testing()
}

#[test_only]
public fun set_active_for_testing<Product>(self: &mut Vault<Product>) {
    self.series_state.set_active_for_testing();
}

#[test_only]
public fun is_reduce_only_for_testing<Product>(self: &Vault<Product>): bool {
    self.series_state.is_reduce_only_for_testing()
}

#[test_only]
public fun maintenance_reserve_for_testing<Product>(self: &Vault<Product>): u64 {
    self.series_state.maintenance_reserve_for_testing()
}

#[test_only]
public fun max_order_notional_for_testing<Product>(
    self: &Vault<Product>,
): (u64, u64, u64) {
    self.series_state.max_order_notional_for_testing()
}

#[test_only]
public fun tier_policy_for_testing<Product>(self: &Vault<Product>): TierPolicy {
    self.series_state.tier_policy_for_testing()
}

#[test_only]
public fun risk_module_witness_for_testing<Product>(
    self: &Vault<Product>,
): TypeName {
    self.risk_module_witness
}

#[test_only]
public fun treasury_cap_id_for_testing<Product>(self: &Vault<Product>): ID {
    object::id(self.treasury_cap())
}

#[test_only]
public fun metadata_cap_id_for_testing<Product>(self: &Vault<Product>): ID {
    object::id(self.metadata_cap())
}

#[test_only]
public fun share_supply_for_testing<Product>(self: &Vault<Product>): u64 {
    self.treasury_cap().total_supply()
}

#[test_only]
public fun set_shutdown_pending_for_testing<Product>(self: &mut Vault<Product>) {
    self.series_state.set_shutdown_pending_for_testing();
}

#[test_only]
public fun is_shutdown_pending_for_testing<Product>(self: &Vault<Product>): bool {
    self.series_state.is_shutdown_pending_for_testing()
}
