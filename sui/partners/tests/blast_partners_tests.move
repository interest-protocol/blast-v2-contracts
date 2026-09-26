// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_partners::blast_partners_tests;

// === Constants ===

const ROOT: address = @0x0;
const ADMIN: address = @0xA11CE;
const PARTNER: address = @0xB0B;
const RECIPIENT: address = @0xFEE;
const NEW_RECIPIENT: address = @0xFEE2;
const START_MS: u64 = 1_000;
const MAX_SHARE_BPS: u64 = 8_000;
const BASIS_POINTS: u64 = 10_000;

// === Test-Only Types ===

public struct Fixture {
    scenario: Scenario,
    authority: Authority<BLAST_PARTNERS>,
    super_admin_cap: SuperAdminCap<BLAST_PARTNERS>,
    admin_cap: AdminCap<BLAST_PARTNERS>,
    clock: Clock,
}

// === Tests ===

// --- Domain ---

#[test]
fun initialization_creates_the_partner_administration_domain() {
    let mut scenario = test_scenario::begin(ROOT);
    partners::init_for_testing(scenario.ctx());

    scenario.next_tx(ROOT);
    let authority = scenario.take_shared<Authority<BLAST_PARTNERS>>();
    assert_eq!(authority.max_admins_for_testing(), 16);
    assert_eq!(authority.root_transfer_delay_ms_for_testing(), 7 * 24 * 60 * 60 * 1_000);
    test_scenario::return_shared(authority);

    scenario.end();
}

// --- Registration ---

#[test]
/// The share starts at zero and switches only after the forced delay; the cap is live at once.
fun registration_shares_the_partner_and_delays_its_first_share() {
    let mut fixture = start();

    let cap = fixture.register(RECIPIENT, 2_500);
    let (id, recipient, share, live_cap) = fixture.last_update().partner_updated_fields();
    assert_eq!(recipient, RECIPIENT);
    assert_eq!(vector[share.value(&fixture.clock), share.scheduled()], vector[0, 2_500]);
    assert_eq!(share.scheduled_at_ms(), START_MS + delay());
    assert_eq!(vector[live_cap.value(&fixture.clock), live_cap.scheduled()], vector[object::id(&cap), object::id(&cap)]);

    fixture.next_tx!(ADMIN, |fixture| {
        let partner = fixture.take_partner();
        assert_eq!(object::id(&partner), id);
        let (_, share, live_cap) = partner.terms_for_testing(&fixture.clock);
        assert_eq!(share, 0);
        assert_eq!(live_cap, object::id(&cap));
        fixture.set_time(START_MS + delay() - 1);
        let (_, share, _) = partner.terms_for_testing(&fixture.clock);
        assert_eq!(share, 0);
        fixture.set_time(START_MS + delay());
        let (_, share, _) = partner.terms_for_testing(&fixture.clock);
        assert_eq!(share, 2_500);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

#[test]
fun registration_accepts_the_zero_share_house_partner_and_the_maximum_share() {
    let mut fixture = start();

    let house = fixture.register(RECIPIENT, 0);
    let top = fixture.register(RECIPIENT, MAX_SHARE_BPS);
    let updates = event::events_by_type<PartnerUpdated>();
    let (_, _, house_share, _) = updates[0].partner_updated_fields();
    let (_, _, top_share, _) = updates[1].partner_updated_fields();
    assert_eq!(vector[house_share.scheduled(), top_share.scheduled()], vector[0, MAX_SHARE_BPS]);

    partners::destroy_cap(house);
    partners::destroy_cap(top);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = partners::EShareAboveMax, location = blast_partners::blast_partners)]
fun registration_rejects_a_share_one_above_the_maximum() {
    let mut fixture = start();

    partners::destroy_cap(fixture.register(RECIPIENT, MAX_SHARE_BPS + 1));

    fixture.end();
}

#[test]
#[expected_failure(abort_code = partners::EInvalidRecipient, location = blast_partners::blast_partners)]
fun registration_rejects_a_zero_recipient() {
    let mut fixture = start();

    partners::destroy_cap(fixture.register(@0x0, 2_500));

    fixture.end();
}

#[test]
#[expected_failure(abort_code = partners::EInvalidRecipient, location = blast_partners::blast_partners)]
fun a_zero_recipient_precedes_a_share_above_the_maximum() {
    let mut fixture = start();

    partners::destroy_cap(fixture.register(@0x0, MAX_SHARE_BPS + 1));

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun the_missing_role_precedes_an_invalid_registration() {
    let mut fixture = start();
    fixture.revoke_partner_admin_role();

    partners::destroy_cap(fixture.register(@0x0, MAX_SHARE_BPS + 1));

    fixture.end();
}

// --- Share ---

#[test]
/// A cut waits the full delay; until then the partner keeps earning its share.
fun a_scheduled_share_takes_effect_exactly_after_the_delay() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);
    fixture.set_time(START_MS + delay());

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        let scheduled_at = fixture.now();
        fixture.schedule_share(&mut partner, 1_000);
        let (_, _, share, _) = fixture.last_update().partner_updated_fields();
        assert_eq!(vector[share.value(&fixture.clock), share.scheduled()], vector[2_500, 1_000]);
        assert_eq!(share.scheduled_at_ms(), scheduled_at + delay());
        fixture.set_time(scheduled_at + delay() - 1);
        assert_eq!(fixture.share_in_force(&partner), 2_500);
        fixture.set_time(scheduled_at + delay());
        assert_eq!(fixture.share_in_force(&partner), 1_000);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

#[test]
/// Rescheduling keeps the share in force and restarts the clock; nothing Blast
/// schedules takes effect sooner than the delay after it was last scheduled.
fun a_new_schedule_replaces_a_pending_one_and_restarts_the_delay() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);
    fixture.set_time(START_MS + delay());

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 0);
        fixture.advance(delay() - 1);
        let rescheduled_at = fixture.now();
        fixture.schedule_share(&mut partner, 5_000);
        fixture.set_time(rescheduled_at + delay() - 1);
        assert_eq!(fixture.share_in_force(&partner), 2_500);
        fixture.set_time(rescheduled_at + delay());
        assert_eq!(fixture.share_in_force(&partner), 5_000);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

#[test]
fun scheduling_the_share_in_force_cancels_a_pending_cut() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);
    fixture.set_time(START_MS + delay());

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 0);
        fixture.schedule_share(&mut partner, 2_500);
        fixture.advance(10 * delay());
        assert_eq!(fixture.share_in_force(&partner), 2_500);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = partners::EUnchanged, location = blast_partners::blast_partners)]
fun scheduling_the_pending_share_again_is_refused() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, 2_500);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = partners::EShareAboveMax, location = blast_partners::blast_partners)]
fun a_scheduled_share_one_above_the_maximum_is_refused() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, MAX_SHARE_BPS + 1);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun the_missing_role_precedes_an_invalid_share() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);
    fixture.revoke_partner_admin_role();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_share(&mut partner, MAX_SHARE_BPS + 1);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

// --- Cap ---

#[test]
/// The old cap keeps working until the switch and not after; the new one the reverse.
fun a_reissued_cap_goes_live_exactly_after_the_delay() {
    let mut fixture = start();
    let old_cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        let reissued_at = fixture.now();
        let new_cap = fixture.reissue_cap(&mut partner);
        let (_, _, _, live_cap) = fixture.last_update().partner_updated_fields();
        assert_eq!(vector[live_cap.value(&fixture.clock), live_cap.scheduled()], vector[object::id(&old_cap), object::id(&new_cap)]);
        assert_eq!(live_cap.scheduled_at_ms(), reissued_at + delay());
        fixture.set_time(reissued_at + delay() - 1);
        fixture.set_recipient(&mut partner, &old_cap, NEW_RECIPIENT);
        fixture.set_time(reissued_at + delay());
        fixture.set_recipient(&mut partner, &new_cap, RECIPIENT);
        let (recipient, _, live_cap) = partner.terms_for_testing(&fixture.clock);
        assert_eq!(recipient, RECIPIENT);
        assert_eq!(live_cap, object::id(&new_cap));
        partners::destroy_cap(new_cap);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(old_cap);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = partners::ENotLiveCap, location = blast_partners::blast_partners)]
fun the_replaced_cap_is_refused_once_the_reissue_takes_effect() {
    let mut fixture = start();
    let old_cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        let new_cap = fixture.reissue_cap(&mut partner);
        fixture.advance(delay());
        fixture.set_recipient(&mut partner, &old_cap, NEW_RECIPIENT);
        partners::destroy_cap(new_cap);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(old_cap);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = partners::ENotLiveCap, location = blast_partners::blast_partners)]
fun a_reissued_cap_is_refused_before_the_delay() {
    let mut fixture = start();
    let old_cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        let new_cap = fixture.reissue_cap(&mut partner);
        fixture.advance(delay() - 1);
        fixture.set_recipient(&mut partner, &new_cap, NEW_RECIPIENT);
        partners::destroy_cap(new_cap);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(old_cap);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = partners::ENotLiveCap, location = blast_partners::blast_partners)]
/// A newer reissue supersedes a pending one, whose cap never goes live.
fun a_superseded_reissue_never_goes_live() {
    let mut fixture = start();
    let old_cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        let superseded = fixture.reissue_cap(&mut partner);
        let latest = fixture.reissue_cap(&mut partner);
        fixture.advance(10 * delay());
        fixture.set_recipient(&mut partner, &superseded, NEW_RECIPIENT);
        partners::destroy_cap(superseded);
        partners::destroy_cap(latest);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(old_cap);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun reissuing_a_cap_requires_the_partner_admin_role() {
    let mut fixture = start();
    let old_cap = fixture.register(RECIPIENT, 2_500);
    fixture.revoke_partner_admin_role();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        partners::destroy_cap(fixture.reissue_cap(&mut partner));
        fixture.return_partner(partner);
    });

    partners::destroy_cap(old_cap);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = partners::EUnchanged, location = blast_partners::blast_partners)]
fun scheduling_the_pending_cap_again_is_refused() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_cap(&mut partner, object::id(&cap));
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EAdminRoleNotGranted, location = blast_admin::acl)]
fun the_missing_role_precedes_an_unchanged_cap() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);
    fixture.revoke_partner_admin_role();

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.schedule_cap(&mut partner, object::id(&cap));
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

#[test]
/// Scheduling the cap in force cancels a pending move: the original cap stays live and the new one never does.
fun scheduling_the_live_cap_cancels_a_pending_move() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(ADMIN, |fixture| {
        let mut partner = fixture.take_partner();
        let moved_to = fixture.reissue_cap(&mut partner);
        fixture.schedule_cap(&mut partner, object::id(&cap));
        fixture.advance(10 * delay());
        let (_, _, live_cap) = partner.terms_for_testing(&fixture.clock);
        assert_eq!(live_cap, object::id(&cap));
        fixture.set_recipient(&mut partner, &cap, NEW_RECIPIENT);
        partners::destroy_cap(moved_to);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

// --- One cap, many partners ---

#[test]
/// A company holds one cap for every deal: each partner has its own share and
/// recipient, and the one cap sets both recipients.
fun one_cap_manages_every_partner_of_a_company() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 5_000);
    let (boosts_id, _, _, _) = fixture.last_update().partner_updated_fields();
    fixture.register_under(&cap, RECIPIENT, 800);
    let (other_id, _, other_share, other_cap) = fixture.last_update().partner_updated_fields();
    assert_eq!(other_share.scheduled(), 800);
    assert_eq!(other_cap.value(&fixture.clock), object::id(&cap));
    fixture.set_time(START_MS + delay());

    fixture.next_tx!(PARTNER, |fixture| {
        let mut boosts = fixture.take_partner_by_id(boosts_id);
        let mut other = fixture.take_partner_by_id(other_id);
        fixture.set_recipient(&mut boosts, &cap, NEW_RECIPIENT);
        fixture.set_recipient(&mut other, &cap, NEW_RECIPIENT);
        let (boosts_recipient, boosts_share, _) = boosts.terms_for_testing(&fixture.clock);
        let (other_recipient, other_share, _) = other.terms_for_testing(&fixture.clock);
        assert_eq!(vector[boosts_recipient, other_recipient], vector[NEW_RECIPIENT, NEW_RECIPIENT]);
        assert_eq!(vector[boosts_share, other_share], vector[5_000, 800]);
        fixture.return_partner(boosts);
        fixture.return_partner(other);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

#[test]
/// A cap anyone mints controls nothing until Blast registers a partner under it.
fun a_cap_minted_by_anyone_controls_nothing_until_a_partner_is_registered_under_it() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(PARTNER, |fixture| {
        let own_cap = partners::new_cap(fixture.scenario.ctx());
        let partner = fixture.take_partner();
        let (_, _, live_cap) = partner.terms_for_testing(&fixture.clock);
        assert!(live_cap != object::id(&own_cap));
        fixture.return_partner(partner);
        partners::destroy_cap(own_cap);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

// --- Recipient ---

#[test]
fun the_live_cap_sets_the_recipient_at_once() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(PARTNER, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.set_recipient(&mut partner, &cap, NEW_RECIPIENT);
        let (_, recipient, _, _) = fixture.last_update().partner_updated_fields();
        assert_eq!(recipient, NEW_RECIPIENT);
        let (recipient, _, _) = partner.terms_for_testing(&fixture.clock);
        assert_eq!(recipient, NEW_RECIPIENT);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = partners::ENotLiveCap, location = blast_partners::blast_partners)]
fun another_partners_cap_precedes_an_invalid_recipient() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);
    let (partner_id, _, _, _) = fixture.last_update().partner_updated_fields();
    let other_cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(PARTNER, |fixture| {
        let mut partner = fixture.take_partner_by_id(partner_id);
        fixture.set_recipient(&mut partner, &other_cap, @0x0);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    partners::destroy_cap(other_cap);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = partners::EInvalidRecipient, location = blast_partners::blast_partners)]
fun a_zero_recipient_is_refused() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(PARTNER, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.set_recipient(&mut partner, &cap, @0x0);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = partners::EUnchanged, location = blast_partners::blast_partners)]
fun the_current_recipient_is_refused() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 2_500);

    fixture.next_tx!(PARTNER, |fixture| {
        let mut partner = fixture.take_partner();
        fixture.set_recipient(&mut partner, &cap, RECIPIENT);
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

// --- Payment ---

#[test]
/// Before its share takes effect a partner is sent nothing and the fee is untouched.
fun a_partner_is_paid_nothing_until_its_share_takes_effect() {
    let mut fixture = start();
    let cap = fixture.register(RECIPIENT, 5_000);

    fixture.next_tx!(ADMIN, |fixture| {
        let partner = fixture.take_partner();
        let mut fee = balance::create_for_testing<SUI>(1_000);
        fixture.set_time(START_MS + delay() - 1);
        assert_eq!(partner.pay(&mut fee, &fixture.clock), 0);
        assert_eq!(fee.value(), 1_000);
        fixture.set_time(START_MS + delay());
        assert_eq!(partner.pay(&mut fee, &fixture.clock), 500);
        assert_eq!(fee.value(), 500);
        fee.destroy_for_testing();
        fixture.return_partner(partner);
    });

    partners::destroy_cap(cap);
    fixture.end();
}

#[test]
/// Every fee from 0 to 200 atoms at every share boundary pays the rounded-down
/// reference; the fee keeps exactly the rest, so Blast keeps every remainder. (Each
/// payment emits an event, so the sweep stays under the per-transaction event limit.)
fun payment_matches_the_rounded_down_reference() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let shares = vector[0, 1, 3_333, 5_000, MAX_SHARE_BPS - 1, MAX_SHARE_BPS];

    shares.do_ref!(|share_bps| {
        let partner = partners::new_for_testing(RECIPIENT, *share_bps, &mut ctx);
        201u64.do!(|amount| {
            let mut fee = balance::create_for_testing<SUI>(amount);
            let expected = ((amount as u128) * (*share_bps as u128) / (BASIS_POINTS as u128)) as u64;
            assert_eq!(partner.pay(&mut fee, &clock), expected);
            assert_eq!(fee.value(), amount - expected);
            fee.destroy_for_testing();
        });
        destroy(partner);
    });

    clock.destroy_for_testing();
    destroy(ctx);
}

#[test]
fun payment_of_the_largest_fee_at_the_maximum_share_does_not_overflow() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let partner = partners::new_for_testing(RECIPIENT, MAX_SHARE_BPS, &mut ctx);
    let max = std::u64::max_value!();
    let mut fee = balance::create_for_testing<SUI>(max);

    let paid = partner.pay(&mut fee, &clock);

    assert_eq!(paid, ((max as u128) * (MAX_SHARE_BPS as u128) / (BASIS_POINTS as u128)) as u64);
    assert_eq!(fee.value(), max - paid);
    fee.destroy_for_testing();
    destroy(partner);
    clock.destroy_for_testing();
    destroy(ctx);
}

#[test]
/// Every payment emits what the partner received; a payment of nothing emits nothing.
fun every_payment_emits_what_the_partner_received() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let partner = partners::new_for_testing(RECIPIENT, 5_000, &mut ctx);
    let mut fee = balance::create_for_testing<SUI>(1_001);

    assert_eq!(partner.pay(&mut fee, &clock), 500);
    let mut dust = balance::create_for_testing<SUI>(1);
    assert_eq!(partner.pay(&mut dust, &clock), 0);

    let payments = event::events_by_type<PartnerPaid<SUI>>();
    assert_eq!(payments.length(), 1);
    let (partner_id, amount) = payments[0].partner_paid_fields();
    assert_eq!(partner_id, object::id(&partner));
    assert_eq!(amount, 500);
    fee.destroy_for_testing();
    dust.destroy_for_testing();
    destroy(partner);
    clock.destroy_for_testing();
    destroy(ctx);
}

#[test]
/// Each deal under one cap is paid and reported on its own, at its own share.
fun each_deal_is_paid_and_reported_at_its_own_share() {
    let mut ctx = tx_context::dummy();
    let clock = clock::create_for_testing(&mut ctx);
    let boosts = partners::new_for_testing(RECIPIENT, 5_000, &mut ctx);
    let other = partners::new_for_testing(RECIPIENT, 800, &mut ctx);
    let mut boosts_fee = balance::create_for_testing<SUI>(1_000);
    let mut other_fee = balance::create_for_testing<SUI>(1_000);

    assert_eq!(boosts.pay(&mut boosts_fee, &clock), 500);
    assert_eq!(other.pay(&mut other_fee, &clock), 80);

    let payments = event::events_by_type<PartnerPaid<SUI>>();
    let (first_id, first_amount) = payments[0].partner_paid_fields();
    let (second_id, second_amount) = payments[1].partner_paid_fields();
    assert_eq!(vector[first_id, second_id], vector[object::id(&boosts), object::id(&other)]);
    assert_eq!(vector[first_amount, second_amount], vector[500, 80]);
    boosts_fee.destroy_for_testing();
    other_fee.destroy_for_testing();
    destroy(boosts);
    destroy(other);
    clock.destroy_for_testing();
    destroy(ctx);
}

// === Test Helpers ===

fun start(): Fixture {
    let mut scenario = test_scenario::begin(ROOT);
    let (super_admin_cap, mut authority) = acl::new_for_testing<BLAST_PARTNERS>(16, delay(), scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        partners::partner_admin_role_for_testing(),
        ADMIN,
        scenario.ctx(),
    );
    scenario.next_tx(ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_PARTNERS>>();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(START_MS);

    Fixture { scenario, authority, super_admin_cap, admin_cap, clock }
}

fun end(self: Fixture) {
    let Fixture { scenario, authority, super_admin_cap, admin_cap, clock } = self;
    destroy(authority);
    destroy(super_admin_cap);
    destroy(admin_cap);
    clock.destroy_for_testing();
    scenario.end();
}

macro fun next_tx($self: &mut Fixture, $sender: address, $body: |&mut Fixture|) {
    let fixture = $self;
    fixture.scenario.next_tx($sender);
    $body(fixture);
}

fun delay(): u64 {
    partners::delay_ms_for_testing()
}

fun now(self: &Fixture): u64 {
    self.clock.timestamp_ms()
}

fun set_time(self: &mut Fixture, now_ms: u64) {
    self.clock.set_for_testing(now_ms);
}

fun advance(self: &mut Fixture, ms: u64) {
    self.clock.increment_for_testing(ms);
}

/// Mints a company's cap and registers its first partner under it; the partner
/// is shared from the next transaction on.
fun register(self: &mut Fixture, recipient: address, share_bps: u64): PartnerCap {
    let cap = partners::new_cap(self.scenario.ctx());
    self.register_under(&cap, recipient, share_bps);
    cap
}

/// Registers another partner under an existing cap.
fun register_under(self: &mut Fixture, cap: &PartnerCap, recipient: address, share_bps: u64) {
    let witness = self.authority.sign_in(&self.admin_cap);
    partners::register(&witness, object::id(cap), recipient, share_bps, &self.clock, self.scenario.ctx());
}

fun schedule_share(self: &Fixture, partner: &mut Partner, share_bps: u64) {
    let witness = self.authority.sign_in(&self.admin_cap);
    partner.schedule_share(&witness, share_bps, &self.clock);
}

/// Mints a new cap and schedules the partner to move to it.
fun reissue_cap(self: &mut Fixture, partner: &mut Partner): PartnerCap {
    let cap = partners::new_cap(self.scenario.ctx());
    self.schedule_cap(partner, object::id(&cap));
    cap
}

fun schedule_cap(self: &Fixture, partner: &mut Partner, cap_id: ID) {
    let witness = self.authority.sign_in(&self.admin_cap);
    partner.schedule_cap(&witness, cap_id, &self.clock);
}

fun set_recipient(self: &Fixture, partner: &mut Partner, cap: &PartnerCap, recipient: address) {
    partner.set_recipient(cap, recipient, &self.clock);
}

fun share_in_force(self: &Fixture, partner: &Partner): u64 {
    let (_, share, _) = partner.terms_for_testing(&self.clock);
    share
}

fun last_update(_self: &Fixture): PartnerUpdated {
    let updates = event::events_by_type<PartnerUpdated>();
    updates[updates.length() - 1]
}

fun take_partner(self: &Fixture): Partner {
    self.scenario.take_shared<Partner>()
}

/// One partner by ID, when several are shared.
fun take_partner_by_id(self: &Fixture, partner_id: ID): Partner {
    self.scenario.take_shared_by_id<Partner>(partner_id)
}

fun return_partner(_self: &mut Fixture, partner: Partner) {
    test_scenario::return_shared(partner);
}

fun revoke_partner_admin_role(self: &mut Fixture) {
    let Fixture { authority, super_admin_cap, admin_cap, .. } = self;
    authority.revoke_role(super_admin_cap, object::id(admin_cap), partners::partner_admin_role_for_testing());
}

// === Imports ===

use blast_admin::acl::{Self, Authority, AdminCap, SuperAdminCap};

use blast_partners::blast_partners::{Self as partners, BLAST_PARTNERS, Partner, PartnerCap, PartnerPaid, PartnerUpdated};

use std::unit_test::{assert_eq, destroy};

use sui::{balance, clock::{Self, Clock}, event, sui::SUI, test_scenario::{Self, Scenario}};
