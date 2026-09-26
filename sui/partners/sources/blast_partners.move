// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast partner codes, shared by every Blast product.
///
/// A partner is one deal: it is paid a share of the fee Blast charges on every
/// trade that names it, in the same transaction. A company holds one
/// `PartnerCap` for all its deals, each a separate partner with its own share.
/// Blast's partner administrator registers partners under a cap, sets each
/// one's share, and can move a partner to another cap; the cap's holder sets
/// where each of its partners is paid. Everything Blast changes takes effect
/// only `DELAY_MS` after it is scheduled, and this package is published
/// immutable, so no one can shorten that delay. The recipient the cap holder
/// sets applies at once.
///
/// Products call `pay` with Blast's own fee on a trade. `pay` emits
/// `PartnerPaid` for what the partner received; the product records the trade
/// and the amount in its own event.
module blast_partners::blast_partners;

// === Public Types ===

/// One-time witness naming the partner administration domain.
public struct BLAST_PARTNERS() has drop;

/// One Blast partner. Shared, and read by immutable reference on every trade that names it.
public struct Partner has key {
    id: UID,
    /// Where the partner's share is sent; set by the live cap's holder.
    recipient: address,
    /// The partner's share of Blast's fee on each trade, in basis points.
    share_bps: Timelocked<u64>,
    /// The only cap that may set `recipient`; one cap may manage many partners.
    cap_id: Timelocked<ID>,
}

/// A company's authority over the recipient of every partner bound to it.
public struct PartnerCap has key, store {
    id: UID,
}

/// Emitted after every change to a partner, registration included: its complete terms.
public struct PartnerUpdated has copy, drop {
    partner_id: ID,
    recipient: address,
    share_bps: Timelocked<u64>,
    cap_id: Timelocked<ID>,
}

/// Emitted whenever a partner is paid: `amount` of `T` sent to its recipient.
public struct PartnerPaid<phantom T> has copy, drop {
    partner_id: ID,
    amount: u64,
}

// === Private Initialization ===

fun init(otw: BLAST_PARTNERS, ctx: &mut TxContext) {
    acl::new(otw, MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx);
}

// === Public Functions ===

/// Mints a cap. It controls nothing until Blast registers a partner under it,
/// so anyone may mint one, a company included.
public fun new_cap(ctx: &mut TxContext): PartnerCap {
    PartnerCap { id: object::new(ctx) }
}

/// Registers and shares a partner managed by the cap `cap_id`, with its share
/// and cap in force at once. Every later change to either waits `DELAY_MS`.
public fun register(
    admin_witness: &AdminWitness<BLAST_PARTNERS>,
    cap_id: ID,
    recipient: address,
    share_bps: u64,
    ctx: &mut TxContext,
) {
    admin_witness.assert_role(PARTNER_ADMIN_ROLE);
    assert!(recipient != @0x0, EInvalidRecipient);
    assert!(share_bps <= MAX_SHARE_BPS, EShareAboveMax);

    let partner = Partner {
        id: object::new(ctx),
        recipient,
        share_bps: timelock::new(share_bps, DELAY_MS),
        cap_id: timelock::new(cap_id, DELAY_MS),
    };

    partner.emit_updated();
    transfer::share_object(partner);
}

/// Schedules the partner's share to become `share_bps` `DELAY_MS` from now.
/// A new schedule replaces a pending one; scheduling the share in force
/// cancels a pending change.
public fun schedule_share(
    self: &mut Partner,
    admin_witness: &AdminWitness<BLAST_PARTNERS>,
    share_bps: u64,
    clock: &Clock,
) {
    admin_witness.assert_role(PARTNER_ADMIN_ROLE);
    assert!(share_bps <= MAX_SHARE_BPS, EShareAboveMax);
    assert!(share_bps != self.share_bps.scheduled(), EUnchanged);

    self.share_bps.schedule(share_bps, clock);

    self.emit_updated();
}

/// Schedules the partner to be managed by the cap `cap_id` `DELAY_MS` from
/// now, to replace a lost or stolen cap. Until then the current cap keeps
/// working; a new schedule replaces a pending one, and scheduling the cap in
/// force cancels a pending change.
public fun schedule_cap(
    self: &mut Partner,
    admin_witness: &AdminWitness<BLAST_PARTNERS>,
    cap_id: ID,
    clock: &Clock,
) {
    admin_witness.assert_role(PARTNER_ADMIN_ROLE);
    assert!(cap_id != self.cap_id.scheduled(), EUnchanged);

    self.cap_id.schedule(cap_id, clock);

    self.emit_updated();
}

/// Sets where the partner is paid, at once. Only the live cap may.
public fun set_recipient(self: &mut Partner, cap: &PartnerCap, recipient: address, clock: &Clock) {
    assert!(cap.id.to_inner() == self.cap_id.value(clock), ENotLiveCap);
    assert!(recipient != @0x0, EInvalidRecipient);
    assert!(recipient != self.recipient, EUnchanged);

    self.recipient = recipient;

    self.emit_updated();
}

/// Destroys a cap, live or not.
public fun destroy_cap(cap: PartnerCap) {
    let PartnerCap { id } = cap;
    id.delete();
}

/// Sends the partner its share of `fee`, Blast's fee on one trade, rounded
/// down so Blast keeps the remainder, emits `PartnerPaid`, and returns the
/// amount sent. Nothing is sent or emitted while the share is zero. `fee`
/// keeps the rest. Anyone calling it pays the partner from their own balance.
public fun pay<T>(self: &Partner, fee: &mut Balance<T>, clock: &Clock): u64 {
    let amount = fee.value().mul_div(self.share_bps.value(clock), BASIS_POINTS);

    if (amount > 0) {
        fee.split(amount).send_funds(self.recipient);
        event::emit(PartnerPaid<T> { partner_id: self.id.to_inner(), amount });
    };

    amount
}

// === Private Functions ===

fun emit_updated(self: &Partner) {
    event::emit(PartnerUpdated {
        partner_id: self.id.to_inner(),
        recipient: self.recipient,
        share_bps: self.share_bps,
        cap_id: self.cap_id,
    });
}

// === Test-Only Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<BLAST_PARTNERS>(), ctx);
}

#[test_only]
/// A partner whose share is already in force, for products' own tests.
public fun new_for_testing(recipient: address, share_bps: u64, ctx: &mut TxContext): Partner {
    Partner {
        id: object::new(ctx),
        recipient,
        share_bps: timelock::new(share_bps, DELAY_MS),
        cap_id: timelock::new(object::id_from_address(@0x0), DELAY_MS),
    }
}

#[test_only]
/// A partner whose share is `before` until `at_ms` and `after` from then on, for products' own tests.
public fun new_scheduled_for_testing(
    recipient: address,
    before: u64,
    after: u64,
    at_ms: u64,
    ctx: &mut TxContext,
): Partner {
    Partner {
        id: object::new(ctx),
        recipient,
        share_bps: timelock::new_scheduled_for_testing(before, after, at_ms, DELAY_MS),
        cap_id: timelock::new(object::id_from_address(@0x0), DELAY_MS),
    }
}

#[test_only]
public fun partner_admin_role_for_testing(): u64 {
    PARTNER_ADMIN_ROLE
}

#[test_only]
public fun delay_ms_for_testing(): u64 {
    DELAY_MS
}

#[test_only]
/// The partner's recipient, share in force and live cap at `clock`.
public fun terms_for_testing(self: &Partner, clock: &Clock): (address, u64, ID) {
    (self.recipient, self.share_bps.value(clock), self.cap_id.value(clock))
}

#[test_only]
public fun partner_paid_fields<T>(self: &PartnerPaid<T>): (ID, u64) {
    (self.partner_id, self.amount)
}

#[test_only]
public fun partner_updated_fields(self: &PartnerUpdated): (ID, address, Timelocked<u64>, Timelocked<ID>) {
    (self.partner_id, self.recipient, self.share_bps, self.cap_id)
}

// === Constants ===

/// Maximum number of simultaneously registered partner administrators.
const MAX_ADMINS: u64 = 16;

/// Fixed delay before a proposed super administrator may accept root custody.
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

/// The one administrator role: register partners, schedule shares, move partners between caps.
const PARTNER_ADMIN_ROLE: u64 = 1;

/// The forced delay before a share or a cap Blast schedules takes effect.
const DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

/// The largest share of Blast's fee one partner may earn: 80%.
const MAX_SHARE_BPS: u64 = 8_000;

/// Basis points in one whole.
const BASIS_POINTS: u64 = 10_000;

// === Errors ===

#[error(code = 0)]
const EInvalidRecipient: vector<u8> = b"A partner's recipient must not be the zero address.";

#[error(code = 1)]
const EShareAboveMax: vector<u8> = b"A partner's share must be at most 80% of Blast's fee.";

#[error(code = 2)]
const EUnchanged: vector<u8> = b"An update must change the value it sets.";

#[error(code = 3)]
const ENotLiveCap: vector<u8> = b"Only the partner's live cap may set its recipient.";

// === Imports ===

use blast_admin::acl::{Self, AdminWitness};

use blast_fun_timelock::blast_fun_timelock::{Self as timelock, Timelocked};

use sui::{balance::Balance, clock::Clock, event};
