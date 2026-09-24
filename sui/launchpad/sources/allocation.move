// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// Package error macros preserve the allocation owner's abort location.
#[allow(lint(abort_without_constant))]
/// Migration allocation plans, LP-fee splits, and their exact apportionment.
module blast_fun::allocation;

// === Public Types ===

/// One address paid at migration, with its shares of the Meme supply and the final Quote reserve.
public struct Recipient has copy, drop, store {
    destination: address,
    meme_bps: Bps,
    quote_bps: Bps,
}

/// How migration divides the Meme supply and the final Quote reserve between the curve, the pool,
/// and the recipients. Each asset sums to 10,000 once Blast's allocation is added.
public struct AllocationPlan has copy, drop, store {
    curve_meme_bps: Bps,
    lp_meme_bps: Bps,
    lp_quote_bps: Bps,
    recipients: vector<Recipient>,
}

/// One LP-fee recipient and its share.
public struct Route has copy, drop, store {
    destination: address,
    bps: Bps,
}

/// The creator's split of every LP-fee collection after Blast's share, applied to both assets.
/// The burn part's Meme is burned at collection and its Quote buys Meme back to burn. The parts
/// sum to 10,000.
public struct FeeSplit has copy, drop, store {
    creator_bps: Bps,
    auto_lp_bps: Bps,
    rewards_bps: Bps,
    burn_bps: Bps,
    recipients: vector<Route>,
}

// === Public Functions ===

public fun recipient(destination: address, meme_bps: Bps, quote_bps: Bps): Recipient {
    assert!(destination != @0x0, blast_fun::errors::invalid_destination!());

    Recipient { destination, meme_bps, quote_bps }
}

/// The curve and the pool need positive Meme shares; Blast's allocation is added at finalization.
public fun plan(
    curve_meme_bps: Bps,
    lp_meme_bps: Bps,
    lp_quote_bps: Bps,
    recipients: vector<Recipient>,
): AllocationPlan {
    assert!(curve_meme_bps.value() > 0 && lp_meme_bps.value() > 0, blast_fun::errors::invalid_shares!());

    AllocationPlan { curve_meme_bps, lp_meme_bps, lp_quote_bps, recipients }
}

public fun route(destination: address, bps: Bps): Route {
    assert!(destination != @0x0, blast_fun::errors::invalid_destination!());

    Route { destination, bps }
}

public fun fee_split(
    creator_bps: Bps,
    auto_lp_bps: Bps,
    rewards_bps: Bps,
    burn_bps: Bps,
    recipients: vector<Route>,
): FeeSplit {
    assert!(
        recipients.length() <= constants::max_recipients!(),
        blast_fun::errors::recipient_capacity_reached!(),
    );
    recipients.do_ref!(|route| assert!(
        recipients.count!(|other| other.destination == route.destination) == 1,
        blast_fun::errors::duplicate_destination!(),
    ));
    assert!(
        recipients.fold!(
            creator_bps.value() + auto_lp_bps.value() + rewards_bps.value() + burn_bps.value(),
            |sum, route| sum + route.bps.value(),
        ) == constants::basis_points_denominator!(),
        blast_fun::errors::invalid_shares!(),
    );

    FeeSplit { creator_bps, auto_lp_bps, rewards_bps, burn_bps, recipients }
}

public fun recipients(self: &FeeSplit): &vector<Route> { &self.recipients }

public fun destination(self: &Route): address { self.destination }

/// Splits `total` into the creator, auto-LP, rewards, burn, and per-recipient amounts, exactly.
public fun apportion_fee_split(self: &FeeSplit, total: u64): (u64, u64, u64, u64, vector<u64>) {
    let mut bps = vector[self.creator_bps, self.auto_lp_bps, self.rewards_bps, self.burn_bps];
    self.recipients.do_ref!(|route| bps.push_back(route.bps));
    let amounts = apportion(bps, total, option::none());
    let recipients = vector::tabulate!(amounts.length() - 4, |i| amounts[i + 4]);

    (amounts[0], amounts[1], amounts[2], amounts[3], recipients)
}

// === Package Functions ===

/// Adds Blast's allocation as the first recipient and checks that each asset sums to 10,000.
public(package) fun add_protocol(mut self: AllocationPlan, protocol: Recipient): AllocationPlan {
    self.recipients.insert(protocol, 0);
    assert!(
        self.recipients.length() <= constants::max_recipients!(),
        blast_fun::errors::recipient_capacity_reached!(),
    );
    assert!(
        self.recipients.fold!(
            self.curve_meme_bps.value() + self.lp_meme_bps.value(),
            |sum, recipient| sum + recipient.meme_bps.value(),
        ) == constants::basis_points_denominator!()
            && self.recipients.fold!(
                self.lp_quote_bps.value(),
                |sum, recipient| sum + recipient.quote_bps.value(),
            ) == constants::basis_points_denominator!(),
        blast_fun::errors::invalid_shares!(),
    );

    self
}

/// Splits the Meme `supply` into the curve's, the pool's, and each recipient's amounts; Blast's
/// comes first and rounds up.
public(package) fun apportion_meme(self: &AllocationPlan, supply: u64): (u64, u64, vector<u64>) {
    let mut bps = vector[self.curve_meme_bps, self.lp_meme_bps];
    self.recipients.do_ref!(|recipient| bps.push_back(recipient.meme_bps));
    let amounts = apportion(bps, supply, option::some(2));
    let recipients = vector::tabulate!(amounts.length() - 2, |i| amounts[i + 2]);

    (amounts[0], amounts[1], recipients)
}

/// Splits the final Quote `reserve` into the pool's and each recipient's amounts; Blast's comes
/// first and rounds up.
public(package) fun apportion_quote(self: &AllocationPlan, reserve: u64): (u64, vector<u64>) {
    let mut bps = vector[self.lp_quote_bps];
    self.recipients.do_ref!(|recipient| bps.push_back(recipient.quote_bps));
    let amounts = apportion(bps, reserve, option::some(1));
    let recipients = vector::tabulate!(amounts.length() - 1, |i| amounts[i + 1]);

    (amounts[0], recipients)
}

public(package) fun destinations(self: &AllocationPlan): vector<address> {
    self.recipients.map_ref!(|recipient| recipient.destination)
}

// === Private Functions ===

/// Largest-remainder apportionment of `total` over shares summing to 10,000: the `rounded_up` part
/// takes its ceiling, every other part its floor, and the leftover units go one each to the largest
/// remaining remainders, earlier parts first.
fun apportion(bps: vector<Bps>, total: u64, rounded_up: Option<u64>): vector<u64> {
    let denominator = constants::basis_points_denominator!() as u128;
    let products = bps.map!(|share| (total as u128) * (share.value() as u128));
    let mut amounts = vector::tabulate!(products.length(), |i| {
        if (rounded_up.contains(&i)) products[i].div_ceil(denominator) as u64
        else (products[i] / denominator) as u64
    });
    let mut order = vector::tabulate!(products.length(), |i| i)
        .filter!(|i| !rounded_up.contains(i));
    order.insertion_sort_by!(|a, b| {
        let (remainder_a, remainder_b) = (products[*a] % denominator, products[*b] % denominator);
        remainder_a > remainder_b || (remainder_a == remainder_b && *a <= *b)
    });
    let leftover = total - amounts.fold!(0, |sum, amount| sum + amount);
    leftover.do!(|i| *&mut amounts[order[i]] = amounts[order[i]] + 1);

    amounts
}

// === Test-Only Functions ===

#[test_only]
public fun creator_bps_for_testing(self: &FeeSplit): Bps { self.creator_bps }

#[test_only]
public fun auto_lp_bps_for_testing(self: &FeeSplit): Bps { self.auto_lp_bps }

#[test_only]
public fun rewards_bps_for_testing(self: &FeeSplit): Bps { self.rewards_bps }

#[test_only]
public fun burn_bps_for_testing(self: &FeeSplit): Bps { self.burn_bps }

#[test_only]
public fun route_bps_for_testing(self: &Route): u64 { self.bps.value() }

// === Imports ===

use blast_fun::{bps::Bps, constants};
