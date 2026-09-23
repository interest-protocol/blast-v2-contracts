// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the allocation owner's abort location.
#[allow(lint(abort_without_constant))]
/// Canonical bounded allocation tables and protected-first exact apportionment.
module blast_fun::allocation;

// === Public Types ===

/// Immutable migration identity role. Only Liquidity is handed to the launch's adapter.
public enum ChannelRole has copy, drop, store {
    Liquidity,
    Protocol,
    External,
}

/// Stable migration identity and the immutable destination its allocation is paid to.
public struct Channel has copy, drop, store {
    channel_id: u64,
    role: ChannelRole,
    destination: address,
}

/// Positive table entry. Channel zero denotes the curve and is valid only in the Meme table.
public struct Weight has copy, drop, store {
    channel_id: u64,
    bps: Bps,
}

/// Validated, immutable tables sharing at most sixteen migration identities.
public struct AllocationPlan has copy, drop, store {
    channels: vector<Channel>,
    meme: vector<Weight>,
    quote: vector<Weight>,
}

/// One recurring-fee destination and its positive share of one asset.
public struct Route has copy, drop, store {
    destination: address,
    bps: Bps,
}

/// Canonical positive per-asset route tables naming at most sixteen distinct destinations.
public struct Routes has copy, drop, store {
    meme: vector<Route>,
    quote: vector<Route>,
}

// === Public Functions ===

/// Creates a migration identity. Zero is reserved for the curve.
public fun channel(channel_id: u64, role: ChannelRole, destination: address): Channel {
    assert!(channel_id != 0, blast_fun::errors::unknown_migration_channel!());
    assert!(destination != @0x0, blast_fun::errors::unknown_migration_channel!());

    Channel { channel_id, role, destination }
}

/// Creates a positive allocation entry; omitted entries express zero allocation.
public fun weight(channel_id: u64, bps: Bps): Weight {
    assert!(bps.value() > 0, blast_fun::errors::allocation_sum_invalid!());

    Weight { channel_id, bps }
}

/// Constructs the unique LP role.
public fun liquidity_role(): ChannelRole { ChannelRole::Liquidity }

/// Constructs the named Blast protocol role.
public fun protocol_role(): ChannelRole { ChannelRole::Protocol }

/// Constructs a custom role paid to an external destination.
public fun external_role(): ChannelRole { ChannelRole::External }

/// Canonicalizes and validates both complete tables before any balance is partitioned.
public fun new(
    mut channels: vector<Channel>,
    mut meme: vector<Weight>,
    mut quote: vector<Weight>,
): AllocationPlan {
    // One-over inputs retain duplicate precedence without allowing unbounded sorting work.
    assert!(
        channels.length() <= constants::max_migration_channels!() + 1
            && meme.length() <= constants::max_migration_channels!() + 2
            && quote.length() <= constants::max_migration_channels!() + 1,
        blast_fun::errors::migration_channel_capacity_reached!(),
    );
    channels.insertion_sort_by!(|a, b| a.channel_id <= b.channel_id);
    meme.insertion_sort_by!(|a, b| a.channel_id <= b.channel_id);
    quote.insertion_sort_by!(|a, b| a.channel_id <= b.channel_id);
    let mut liquidity_count = 0u64;
    let mut protocol_count = 0u64;
    channels.length().do!(|i| {
        if (i > 0) {
            assert!(
                channels[i - 1].channel_id != channels[i].channel_id,
                blast_fun::errors::duplicate_migration_channel!(),
            );
        };
        if (channels[i].role == ChannelRole::Liquidity) liquidity_count = liquidity_count + 1;
        if (channels[i].role == ChannelRole::Protocol) protocol_count = protocol_count + 1;
    });
    assert_weights_unique(&meme);
    assert_weights_unique(&quote);
    assert!(
        channels.length() <= constants::max_migration_channels!(),
        blast_fun::errors::migration_channel_capacity_reached!(),
    );
    assert!(
        meme.length() <= constants::max_migration_channels!() + 1 && quote.length() <= constants::max_migration_channels!(),
        blast_fun::errors::migration_channel_capacity_reached!(),
    );
    assert!(liquidity_count == 1, blast_fun::errors::invalid_liquidity_channel!());
    assert!(protocol_count <= 1, blast_fun::errors::protocol_channel_mismatch!());
    validate_table(&meme, &channels, true);
    validate_table(&quote, &channels, false);
    channels.do_ref!(|channel| {
        let meme_bps = table_bps(&meme, channel.channel_id);
        let quote_bps = table_bps(&quote, channel.channel_id);
        assert!(meme_bps > 0 || quote_bps > 0, blast_fun::errors::unknown_migration_channel!());
        if (channel.role == ChannelRole::Liquidity) {
            assert!(meme_bps > 0 && quote_bps > 0, blast_fun::errors::invalid_liquidity_channel!());
        };
    });

    AllocationPlan { channels, meme, quote }
}

/// Returns immutable identity records in ascending stable ID order.
public fun channels(self: &AllocationPlan): &vector<Channel> { &self.channels }

/// Returns immutable Meme weights in ascending stable ID order, including the curve at zero.
public fun meme_weights(self: &AllocationPlan): &vector<Weight> { &self.meme }

/// Returns immutable terminal Quote weights in ascending stable ID order.
public fun quote_weights(self: &AllocationPlan): &vector<Weight> { &self.quote }

/// Returns the stable migration identity.
public fun channel_id(self: &Channel): u64 { self.channel_id }

/// Returns the immutable role; only the Liquidity channel is handed to the adapter.
public fun channel_role(self: &Channel): ChannelRole { self.role }

/// Returns the immutable destination this channel's allocation is paid to.
public fun channel_destination(self: &Channel): address { self.destination }

/// Returns the stable identity named by a table entry; zero means the curve.
public fun weight_channel_id(self: &Weight): u64 { self.channel_id }

/// Returns the positive basis-point weight.
public fun weight_bps(self: &Weight): u64 { self.bps.value() }

/// Creates a positive recurring route; omitted destinations receive nothing for that asset.
public fun route(destination: address, bps: Bps): Route {
    assert!(destination != @0x0, blast_fun::errors::route_invalid_destination!());
    assert!(bps.value() > 0, blast_fun::errors::route_sum_invalid!());

    Route { destination, bps }
}

/// Canonicalizes and validates both complete route tables before a router stores them.
public fun routes(mut meme: vector<Route>, mut quote: vector<Route>): Routes {
    // Permit one-over inputs for duplicate precedence, but never sort unbounded input.
    assert!(
        meme.length() <= constants::max_route_destinations!() + 1
            && quote.length() <= constants::max_route_destinations!() + 1,
        blast_fun::errors::route_capacity_reached!(),
    );
    meme.insertion_sort_by!(|a, b| address::to_u256(a.destination) <= address::to_u256(b.destination));
    quote.insertion_sort_by!(|a, b| address::to_u256(a.destination) <= address::to_u256(b.destination));
    assert_routes_unique(&meme);
    assert_routes_unique(&quote);
    let mut destinations = meme.map_ref!(|route| route.destination);
    quote.do_ref!(|route| {
        if (!destinations.contains(&route.destination)) destinations.push_back(route.destination);
    });
    assert!(
        destinations.length() <= constants::max_route_destinations!(),
        blast_fun::errors::route_capacity_reached!(),
    );
    assert!(
        meme.fold!(0, |sum, route| sum + route.bps.value()) == 10_000
            && quote.fold!(0, |sum, route| sum + route.bps.value()) == 10_000,
        blast_fun::errors::route_sum_invalid!(),
    );

    Routes { meme, quote }
}

/// Returns the canonical Meme route table.
public fun meme_routes(self: &Routes): &vector<Route> { &self.meme }

/// Returns the canonical Quote route table.
public fun quote_routes(self: &Routes): &vector<Route> { &self.quote }

/// Returns the address paid for this route.
public fun destination(self: &Route): address { self.destination }

/// Returns the route's positive basis-point share.
public fun route_bps(self: &Route): u64 { self.bps.value() }

/// Returns the sole LP identity for the migration handoff.
public fun liquidity_channel_id(self: &AllocationPlan): u64 {
    'found: {
        self.channels.do_ref!(|channel| {
            if (channel.role == ChannelRole::Liquidity) return 'found channel.channel_id;
        });
        abort blast_fun::errors::invalid_liquidity_channel!()
    }
}

// === Package Functions ===

/// Checks the named protected channel against the current cold policy before custody is created.
public(package) fun assert_protocol_policy(
    self: &AllocationPlan,
    channel_id: u64,
    meme_bps: Bps,
    quote_bps: Bps,
    destination: address,
) {
    let mut found = false;
    self.channels.do_ref!(|channel| {
        if (channel.role == ChannelRole::Protocol) {
            found = true;
            assert!(
                channel.channel_id == channel_id && channel.destination == destination
                    && table_bps(&self.meme, channel.channel_id) == meme_bps.value()
                    && table_bps(&self.quote, channel.channel_id) == quote_bps.value(),
                blast_fun::errors::protocol_channel_mismatch!(),
            );
        };
    });
    assert!(
        found == (meme_bps.value() > 0 || quote_bps.value() > 0),
        blast_fun::errors::protocol_channel_mismatch!(),
    );
}

/// Apportions Meme in table order. Protocol receives its ceiling; other dust follows remainder/ID.
public(package) fun apportion_meme(self: &AllocationPlan, total: u64): vector<u64> {
    apportion(&self.meme, self.protocol_channel_id(), total)
}

/// Apportions terminal Quote in table order using the same exact-conservation rule.
public(package) fun apportion_quote(self: &AllocationPlan, total: u64): vector<u64> {
    apportion(&self.quote, self.protocol_channel_id(), total)
}

/// Returns the apportioned amount of one channel, or zero when the table omits it.
public(package) fun amount_for(table: &vector<Weight>, amounts: &vector<u64>, channel_id: u64): u64 {
    'found: {
        table.length().do!(|i| if (table[i].channel_id == channel_id) return 'found amounts[i]);
        0
    }
}

/// Apportions the project remainder after the recurring protocol share has been removed.
/// No route is protected; dust follows descending remainder then canonical route order.
public(package) fun apportion_routes(table: &vector<Route>, total: u64): vector<u64> {
    apportion(
        &vector::tabulate!(table.length(), |i| Weight { channel_id: i, bps: table[i].bps }),
        option::none(),
        total,
    )
}

// === Private Functions ===

fun validate_table(table: &vector<Weight>, channels: &vector<Channel>, has_curve: bool) {
    let mut sum = 0;
    table.length().do!(|i| {
        assert!(
            (has_curve && table[i].channel_id == 0)
                || channels.any!(|channel| channel.channel_id == table[i].channel_id),
            blast_fun::errors::unknown_migration_channel!(),
        );
        sum = sum + table[i].bps.value();
    });
    assert!(sum == 10_000, blast_fun::errors::allocation_sum_invalid!());
    if (has_curve) assert!(table_bps(table, 0) > 0, blast_fun::errors::allocation_sum_invalid!());
}

fun assert_routes_unique(table: &vector<Route>) {
    table.length().do!(|i| {
        if (i > 0)
            assert!(
                table[i - 1].destination != table[i].destination,
                blast_fun::errors::route_duplicate_destination!(),
            );
    });
}

fun assert_weights_unique(table: &vector<Weight>) {
    table.length().do!(|i| {
        if (i > 0)
            assert!(
                table[i - 1].channel_id != table[i].channel_id,
                blast_fun::errors::duplicate_migration_channel!(),
            );
    });
}

fun table_bps(table: &vector<Weight>, channel_id: u64): u64 {
    'found: {
        table.do_ref!(|entry| if (entry.channel_id == channel_id) return 'found entry.bps.value());
        0
    }
}

fun protocol_channel_id(self: &AllocationPlan): Option<u64> {
    'found: {
        self.channels.do_ref!(|channel| {
            if (channel.role == ChannelRole::Protocol)
                return 'found option::some(channel.channel_id);
        });
        option::none()
    }
}

/// Products use u128; each result is bounded by total. Residue is awarded at most once per entry.
fun apportion(table: &vector<Weight>, protocol_id: Option<u64>, total: u64): vector<u64> {
    let mut amounts = vector[];
    let mut ranked = vector[];
    let mut allocated = 0u64;
    table.length().do!(|i| {
        let product = (total as u128) * (table[i].bps.value() as u128);
        let protected = protocol_id.contains(&table[i].channel_id);
        let amount = if (protected) product.div_ceil(10_000) else product / 10_000;
        amounts.push_back(amount as u64);
        allocated = allocated + (amount as u64);
        if (!protected) ranked.push_back(i);
    });
    ranked.insertion_sort_by!(|a, b| {
        let remainder_a = ((total as u128) * (table[*a].bps.value() as u128)) % 10_000;
        let remainder_b = ((total as u128) * (table[*b].bps.value() as u128)) % 10_000;
        remainder_a > remainder_b || (remainder_a == remainder_b && table[*a].channel_id <= table[*b].channel_id)
    });
    let residue = total - allocated;
    assert!(residue <= ranked.length(), blast_fun::errors::allocation_sum_invalid!());
    residue.do!(|i| *&mut amounts[ranked[i]] = amounts[ranked[i]] + 1);
    assert!(
        amounts.fold!(0, |sum, amount| sum + amount) == total,
        blast_fun::errors::allocation_sum_invalid!(),
    );

    amounts
}

// === Imports ===

use blast_fun::{bps::Bps, constants};
use sui::address;
