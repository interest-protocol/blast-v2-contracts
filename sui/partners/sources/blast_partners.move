// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

/// Blast partner codes, shared by every Blast product.
///
/// A partner is paid a share of the fee Blast charges on every trade that
/// names it, in the same transaction. Blast's partner administrator registers
/// partners, sets each one's share, and can reissue its cap; the holder of the
/// live `PartnerCap` sets where the partner is paid. Everything Blast changes
/// takes effect only `DELAY_MS` after it is scheduled, and this package is
/// published immutable, so no one can shorten that delay. The recipient the
/// cap holder sets applies at once.
///
/// Products call `pay` with Blast's own fee on a trade and record what it paid
/// in their own trade event; `pay` emits nothing, so a payment can only be
/// attributed by the product that made the trade.
module blast_partners::blast_partners;

// === Constants ===

/// Maximum number of simultaneously registered partner administrators.
const MAX_ADMINS: u64 = 16;

/// Fixed delay before a proposed super administrator may accept root custody.
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

/// The one administrator role: register partners, schedule shares, reissue caps.
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

// === Public Types ===

/// One-time witness naming the partner administration domain.
public struct BLAST_PARTNERS() has drop;

/// A value that is `before` until `at_ms` and `after` from then on.
public struct Delayed<T: copy + drop + store> has copy, drop, store {
    before: T,
    after: T,
    at_ms: u64,
}

/// One Blast partner. Shared, and read by immutable reference on every trade that names it.
public struct Partner has key {
    id: UID,
    /// Where the partner's share is sent; set by the live cap's holder.
    recipient: address,
    /// The partner's share of Blast's fee on each trade, in basis points.
    share_bps: Delayed<u64>,
    /// The only cap that may set `recipient`.
    cap_id: Delayed<ID>,
}

/// The partner's own authority over its recipient. Only the partner's live cap is accepted.
public struct PartnerCap has key, store {
    id: UID,
}

/// Emitted after every change to a partner, registration included: its complete terms.
public struct PartnerUpdated has copy, drop {
    partner_id: ID,
    recipient: address,
    share_bps: Delayed<u64>,
    cap_id: Delayed<ID>,
}

// === Private Initialization ===

fun init(otw: BLAST_PARTNERS, ctx: &mut TxContext) {
    acl::new(otw, MAX_ADMINS, ROOT_TRANSFER_DELAY_MS, ctx);
}

// === Public Functions ===

/// Registers and shares a partner and returns its cap. The partner earns
/// nothing until its share takes effect `DELAY_MS` from now.
public fun register(
    admin_witness: &AdminWitness<BLAST_PARTNERS>,
    recipient: address,
    share_bps: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): PartnerCap {
    admin_witness.assert_role(PARTNER_ADMIN_ROLE);
    assert!(recipient != @0x0, EInvalidRecipient);
    assert!(share_bps <= MAX_SHARE_BPS, EShareAboveMax);

    let now_ms = clock.timestamp_ms();
    let cap = PartnerCap { id: object::new(ctx) };
    let cap_id = object::id(&cap);
    let partner = Partner {
        id: object::new(ctx),
        recipient,
        share_bps: Delayed { before: 0, after: share_bps, at_ms: now_ms + DELAY_MS },
        cap_id: Delayed { before: cap_id, after: cap_id, at_ms: now_ms },
    };

    partner.emit_updated();
    transfer::share_object(partner);

    cap
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
    assert!(share_bps != self.share_bps.after, EUnchanged);

    self.share_bps.schedule(share_bps, clock.timestamp_ms());

    self.emit_updated();
}

/// Issues a new cap that replaces the live one `DELAY_MS` from now. Until
/// then the current cap keeps working; a newer reissue supersedes this one.
public fun reissue_cap(
    self: &mut Partner,
    admin_witness: &AdminWitness<BLAST_PARTNERS>,
    clock: &Clock,
    ctx: &mut TxContext,
): PartnerCap {
    admin_witness.assert_role(PARTNER_ADMIN_ROLE);

    let cap = PartnerCap { id: object::new(ctx) };
    self.cap_id.schedule(object::id(&cap), clock.timestamp_ms());

    self.emit_updated();

    cap
}

/// Sets where the partner is paid, at once. Only the live cap may.
public fun set_recipient(self: &mut Partner, cap: &PartnerCap, recipient: address, clock: &Clock) {
    assert!(object::id(cap) == self.cap_id.read(clock.timestamp_ms()), ENotLiveCap);
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
/// down so Blast keeps the remainder, and returns the amount sent. Nothing is
/// sent while the share is zero. `fee` keeps the rest.
public fun pay<T>(self: &Partner, fee: &mut Balance<T>, clock: &Clock): u64 {
    let amount = fee.value().mul_div(self.share_bps.read(clock.timestamp_ms()), BASIS_POINTS);

    if (amount > 0) balance::send_funds(fee.split(amount), self.recipient);

    amount
}

// === Private Functions ===

fun read<T: copy + drop + store>(self: &Delayed<T>, now_ms: u64): T {
    if (now_ms >= self.at_ms) self.after else self.before
}

/// Keeps the value in force now until `DELAY_MS` from now, then `after`.
fun schedule<T: copy + drop + store>(self: &mut Delayed<T>, after: T, now_ms: u64) {
    self.before = self.read(now_ms);
    self.after = after;
    self.at_ms = now_ms + DELAY_MS;
}

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
    let cap_id = object::id_from_address(@0x0);
    Partner {
        id: object::new(ctx),
        recipient,
        share_bps: Delayed { before: share_bps, after: share_bps, at_ms: 0 },
        cap_id: Delayed { before: cap_id, after: cap_id, at_ms: 0 },
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
    let now_ms = clock.timestamp_ms();
    (self.recipient, self.share_bps.read(now_ms), self.cap_id.read(now_ms))
}

#[test_only]
public fun partner_updated_fields(self: &PartnerUpdated): (ID, address, u64, u64, u64, ID, ID, u64) {
    (
        self.partner_id,
        self.recipient,
        self.share_bps.before,
        self.share_bps.after,
        self.share_bps.at_ms,
        self.cap_id.before,
        self.cap_id.after,
        self.cap_id.at_ms,
    )
}

// === Imports ===

use blast_admin::acl::{Self, AdminWitness};

use sui::{balance::{Self, Balance}, clock::Clock, event};
