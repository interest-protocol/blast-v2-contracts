// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros retain abort ownership at the router's invariant boundary.
#[allow(lint(abort_without_constant))]
/// Frozen recurring LP-fee policy and exactly conserved fee routing paid at collection.
module blast_fun::fee_router;

// === Public Types ===

/// Immutable identity of the adapter and permanent position that settle collections.
public struct SettlementBinding has copy, drop, store {
    settlement_witness: TypeName,
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
}

/// Activation freezes the policy snapshot and the settlement binding; there is no live-policy read.
public enum Lifecycle has copy, drop, store {
    Pending,
    Active { policy: PolicySnapshot, binding: SettlementBinding },
}

/// Sole transferable configuration authority; loss is terminal with no recovery or reissue.
///
/// Launch mints exactly one per one-time-witness Meme type, so holding it is the authority.
public struct RouterConfigCap<phantom Meme, phantom Quote> has key, store { id: UID }

/// Key-only recurring-fee router, permanently bound to one same-pair launch.
///
/// The router custodies nothing: every collection is split by the frozen routes and each share
/// is transferred to its destination in the same transaction.
public struct FeeRouter<phantom Meme, phantom Quote> has key {
    id: UID,
    launch_id: ID,
    lifecycle: Lifecycle,
    generation: u64,
    routes: Routes,
}

// === Public Functions ===

/// Returns the launch that created this router.
public fun launch_id<Meme, Quote>(self: &FeeRouter<Meme, Quote>): ID { self.launch_id }

/// Returns whether successful migration activated collection.
public fun is_active<Meme, Quote>(self: &FeeRouter<Meme, Quote>): bool {
    self.lifecycle != Lifecycle::Pending
}

/// Returns the immutable default-or-partner pair after activation, or none while Pending.
public fun policy<Meme, Quote>(self: &FeeRouter<Meme, Quote>): Option<PolicySnapshot> {
    match (self.lifecycle) {
        Lifecycle::Pending => option::none(),
        Lifecycle::Active { policy, .. } => option::some(policy),
    }
}

/// Returns the immutable active settlement binding, or none while Pending.
public fun settlement_binding<Meme, Quote>(
    self: &FeeRouter<Meme, Quote>,
): Option<SettlementBinding> {
    match (self.lifecycle) {
        Lifecycle::Pending => option::none(),
        Lifecycle::Active { binding, .. } => option::some(binding),
    }
}

/// Returns the adapter witness and exact permanent-position identities in one binding.
public fun settlement_binding_fields(self: SettlementBinding): (TypeName, ID, ID, ID) {
    let SettlementBinding { settlement_witness, vault_id, pool_id, position_id } = self;
    (settlement_witness, vault_id, pool_id, position_id)
}

/// Returns the exact routing generation stamped on every collection.
public fun generation<Meme, Quote>(self: &FeeRouter<Meme, Quote>): u64 { self.generation }

/// Returns the complete canonical routes both assets are split by.
public fun routes<Meme, Quote>(self: &FeeRouter<Meme, Quote>): &Routes { &self.routes }

/// Replaces the complete routes while Pending; no fee can have been collected yet.
public fun configure<Meme, Quote>(
    self: &mut FeeRouter<Meme, Quote>,
    package_version: &PackageVersion,
    _: &RouterConfigCap<Meme, Quote>,
    proposed: Routes,
) {
    package_version.assert_current();
    assert!(!self.is_active(), blast_fun::errors::router_already_active!());
    assert!(proposed != self.routes, blast_fun::errors::route_unchanged!());

    self.commit_routes(proposed);
}

/// Splits one exact position collection by the frozen routes and pays every destination.
///
/// The adapter constructs its private witness only after collecting this exact position and
/// passes the objects' actual IDs, which must match the binding frozen at activation.
public fun collect<Meme, Quote, SettlementWitness: drop>(
    self: &mut FeeRouter<Meme, Quote>,
    package_version: &PackageVersion,
    policy: &LpFeePolicy,
    _: SettlementWitness,
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
    self.assert_settlement<_, _, SettlementWitness>(vault_id, pool_id, position_id);

    self.distribute(policy, meme, quote, ctx);
}

/// Pays the exact position collection under the current routes, then commits the next routes.
///
/// Fees that accrued before the change therefore always follow the old generation; only later
/// venue accrual can use the new routes.
public fun settle_and_update_routes<Meme, Quote, SettlementWitness: drop>(
    self: &mut FeeRouter<Meme, Quote>,
    package_version: &PackageVersion,
    policy: &LpFeePolicy,
    _: &RouterConfigCap<Meme, Quote>,
    _: SettlementWitness,
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
    meme: Balance<Meme>,
    quote: Balance<Quote>,
    proposed: Routes,
    ctx: &mut TxContext,
) {
    package_version.assert_current();
    self.assert_settlement<_, _, SettlementWitness>(vault_id, pool_id, position_id);
    assert!(proposed != self.routes, blast_fun::errors::route_unchanged!());

    self.distribute(policy, meme, quote, ctx);
    self.commit_routes(proposed);
}

// === Package Functions ===

/// Only Launch creates a router, once, and records its ID in the same transition.
public(package) fun new<Meme, Quote>(
    launch_id: ID,
    routes: Routes,
    ctx: &mut TxContext,
): (FeeRouter<Meme, Quote>, RouterConfigCap<Meme, Quote>) {
    let router = FeeRouter {
        id: object::new(ctx),
        launch_id,
        lifecycle: Lifecycle::Pending,
        generation: 0,
        routes,
    };

    (router, RouterConfigCap { id: object::new(ctx) })
}

/// Launch owns the only public terminal sink and shares both objects in one transaction.
public(package) fun share<Meme, Quote>(self: FeeRouter<Meme, Quote>) {
    transfer::share_object(self);
}

/// Successful migration completion alone freezes policy and activates collection, once.
public(package) fun activate<Meme, Quote, SettlementWitness: drop>(
    self: &mut FeeRouter<Meme, Quote>,
    policy: &LpFeePolicy,
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
) {
    let snapshot = policy.snapshot<Meme>();
    let binding = SettlementBinding {
        settlement_witness: type_name::with_original_ids<SettlementWitness>(),
        vault_id,
        pool_id,
        position_id,
    };

    self.lifecycle = Lifecycle::Active { policy: snapshot, binding };

    events::router_activated(
        self.id.to_inner(),
        self.launch_id,
        snapshot.is_partner(),
        snapshot.meme_share().value(),
        snapshot.quote_share().value(),
        binding.settlement_witness,
        vault_id,
        pool_id,
        position_id,
        self.generation,
        self.routes,
    );
}

// === Private Functions ===

/// Aborts unless the router is active and the collector is its exact bound adapter and position.
fun assert_settlement<Meme, Quote, SettlementWitness>(
    self: &FeeRouter<Meme, Quote>,
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
) {
    assert!(self.is_active(), blast_fun::errors::router_not_active!());
    let settlement = SettlementBinding {
        settlement_witness: type_name::with_original_ids<SettlementWitness>(),
        vault_id,
        pool_id,
        position_id,
    };
    assert!(
        self.settlement_binding().contains(&settlement),
        blast_fun::errors::settlement_binding_mismatch!(),
    );
}

/// Pays the protected protocol share to the live protocol destination, then every route.
/// A zero collection is valid, moves nothing, and emits nothing.
fun distribute<Meme, Quote>(
    self: &FeeRouter<Meme, Quote>,
    policy: &LpFeePolicy,
    mut meme: Balance<Meme>,
    mut quote: Balance<Quote>,
    ctx: &mut TxContext,
) {
    let snapshot = self.policy().destroy_some();
    let gross_meme = meme.value();
    let gross_quote = quote.value();
    let protocol_meme = snapshot.meme_share().apply_up(gross_meme);
    let protocol_quote = snapshot.quote_share().apply_up(gross_quote);
    let meme_routes = self.routes.meme_routes();
    let quote_routes = self.routes.quote_routes();
    let meme_amounts = allocation::apportion_routes(meme_routes, gross_meme - protocol_meme);
    let quote_amounts = allocation::apportion_routes(quote_routes, gross_quote - protocol_quote);
    let protocol_destination = policy.protocol_destination();

    meme.pay(protocol_meme, protocol_destination, ctx);
    quote.pay(protocol_quote, protocol_destination, ctx);
    meme_amounts.length().do!(|i| meme.pay(meme_amounts[i], meme_routes[i].destination(), ctx));
    quote_amounts.length().do!(|i| quote.pay(quote_amounts[i], quote_routes[i].destination(), ctx));
    meme.destroy_zero();
    quote.destroy_zero();

    if (gross_meme == 0 && gross_quote == 0) return;
    events::fees_collected(
        self.id.to_inner(),
        self.launch_id,
        self.generation,
        gross_meme,
        gross_quote,
        protocol_destination,
        protocol_meme,
        protocol_quote,
        meme_amounts,
        quote_amounts,
    );
}

fun pay<T>(balance: &mut Balance<T>, amount: u64, destination: address, ctx: &mut TxContext) {
    if (amount > 0) transfer::public_transfer(balance.split(amount).into_coin(ctx), destination);
}

/// Installs complete new routes as the next generation.
fun commit_routes<Meme, Quote>(self: &mut FeeRouter<Meme, Quote>, proposed: Routes) {
    let old_generation = self.generation;
    let old_routes = self.routes;

    self.routes = proposed;
    self.generation = old_generation + 1;

    events::routes_changed(
        self.id.to_inner(),
        old_generation,
        self.generation,
        old_routes,
        self.routes,
    );
}

// === Test-Only Functions ===

#[test_only]
/// Creates pending custody without generated-currency choreography for arithmetic tests.
public fun new_for_testing<Meme, Quote>(
    launch_id: ID,
    routes: Routes,
    ctx: &mut TxContext,
): (FeeRouter<Meme, Quote>, RouterConfigCap<Meme, Quote>) {
    new(launch_id, routes, ctx)
}

#[test_only]
/// Exercises the same package-only activation used by the migration completion owner.
public fun activate_for_testing<Meme, Quote, SettlementWitness: drop>(
    self: &mut FeeRouter<Meme, Quote>,
    policy: &LpFeePolicy,
    vault_id: ID,
    pool_id: ID,
    position_id: ID,
) {
    self.activate<_, _, SettlementWitness>(policy, vault_id, pool_id, position_id);
}

// === Imports ===

use blast_fun::{
    allocation::{Self, Routes},
    events,
    lp_fee_policy::{LpFeePolicy, PolicySnapshot},
    package_version::PackageVersion,
};
use std::type_name::{Self, TypeName};
use sui::balance::Balance;

use fun pay as Balance.pay;
