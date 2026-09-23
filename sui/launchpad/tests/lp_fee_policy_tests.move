// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::lp_fee_policy_tests;

// === Constants ===

const PUBLISHER: address = @0xA11CE;

const PROTOCOL_ADMIN: address = @0xAD;

// === Test-Only Types ===

public struct MemeA has drop {}

public struct MemeB has drop {}

/// Publication-only setup; owns no administrator resources.
public struct InitFixture {
    scenario: Scenario,
    policy: LpFeePolicy,
}

/// Live policy administration through the production ACL sign-in seam.
public struct PolicyFixture {
    scenario: Scenario,
    authority: Authority<BLAST_FUN_DOMAIN>,
    root: SuperAdminCap<BLAST_FUN_DOMAIN>,
    admin_cap: AdminCap<BLAST_FUN_DOMAIN>,
    package_version: package_version::PackageVersion,
    policy: LpFeePolicy,
}

/// Independently encoded expectation for every policy event field in ABI order.
public struct ExpectedChange has copy, drop {
    override_meme: Option<TypeName>,
    old_meme_bps: Option<u64>,
    old_quote_bps: Option<u64>,
    new_meme_bps: Option<u64>,
    new_quote_bps: Option<u64>,
}

// === Tests ===

#[test]
fun publication_shares_one_eventless_zero_default_policy() {
    let mut fixture = start_init();

    fixture.next_tx!(PUBLISHER, |f| {
        assert_snapshot(f.policy.snapshot<MemeA>(), false, 0, 0);
        assert_snapshot(f.policy.snapshot<MemeB>(), false, 0, 0);
        assert_eq!(f.policy.partner_count_for_testing(), 0);
    });

    fixture.end();
}

#[test]
fun publisher_is_the_initial_protocol_destination_until_redirected() {
    let mut fixture = start_init();

    fixture.next_tx!(PUBLISHER, |f| {
        assert_eq!(f.policy.protocol_destination(), PUBLISHER);
    });

    fixture.end();
}

#[test]
fun admin_redirects_the_protocol_destination_and_emits_old_and_new() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.policy.set_protocol_destination(&f.package_version, &admin, @0xCAFE);

        assert_eq!(f.policy.protocol_destination(), @0xCAFE);
        let publisher = PUBLISHER;
        let mut expected = bcs::to_bytes(&publisher);
        expected.append(bcs::to_bytes(&@0xCAFE));
        assert_eq!(
            bcs::to_bytes(&events::collect_one<events::LpFeeDestinationChanged>(0)),
            expected,
        );
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EProtocolDestinationUnchanged,
        location = blast_fun::lp_fee_policy,
    ),
]
fun unchanged_protocol_destination_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.policy.set_protocol_destination(&f.package_version, &admin, PUBLISHER);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EProtocolDestinationUnchanged,
        location = blast_fun::lp_fee_policy,
    ),
]
fun zero_protocol_destination_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.policy.set_protocol_destination(&f.package_version, &admin, @0x0);
    });

    fixture.end();
}

#[test]
fun active_admin_changes_independent_defaults_and_all_event_fields() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.policy.set_default_shares(&f.package_version, &admin, bps::new(2_000), bps::new(7_000));

        assert_snapshot(f.policy.snapshot<MemeA>(), false, 2_000, 7_000);
        assert_snapshot(f.policy.snapshot<MemeB>(), false, 2_000, 7_000);
        assert_change(
            events::collect_one<events::LpFeePolicyChanged>(0),
            option::none(),
            option::some(0),
            option::some(0),
            option::some(2_000),
            option::some(7_000),
        );
        assert!(event::events_by_type<events::LpFeePolicyChanged>().is_empty());
    });

    fixture.end();
}

#[test]
fun changing_either_asset_alone_is_a_real_default_update() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.policy.set_default_shares(&f.package_version, &admin, bps::new(1), bps::new(0));
        f.policy.set_default_shares(&f.package_version, &admin, bps::new(1), bps::new(2));

        assert_snapshot(f.policy.snapshot<MemeA>(), false, 1, 2);
        let changes = events::collect<events::LpFeePolicyChanged>();
        assert_eq!(changes.length(), 2);
        assert_change(
            changes[0],
            option::none(),
            option::some(0),
            option::some(0),
            option::some(1),
            option::some(0),
        );
        assert_change(
            changes[1],
            option::none(),
            option::some(1),
            option::some(0),
            option::some(1),
            option::some(2),
        );
    });

    fixture.end();
}

#[test]
fun partner_create_update_clear_readd_preserves_original_type_keys_and_event_history() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.policy.set_default_shares(&f.package_version, &admin, bps::new(11), bps::new(22));
        f.policy.set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(33), bps::new(44));
        f.policy.set_partner_shares<MemeB>(&f.package_version, &admin, bps::new(55), bps::new(66));
        assert_snapshot(f.policy.snapshot<MemeA>(), true, 33, 44);
        assert_snapshot(f.policy.snapshot<MemeB>(), true, 55, 66);
        assert_eq!(f.policy.partner_count_for_testing(), 2);

        f.policy.set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(33), bps::new(77));
        assert_snapshot(f.policy.snapshot<MemeA>(), true, 33, 77);
        f.policy.set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(88), bps::new(77));
        assert_snapshot(f.policy.snapshot<MemeA>(), true, 88, 77);
        f.policy.clear_partner_shares<MemeA>(&f.package_version, &admin);
        assert_snapshot(f.policy.snapshot<MemeA>(), false, 11, 22);
        assert_snapshot(f.policy.snapshot<MemeB>(), true, 55, 66);
        assert_eq!(f.policy.partner_count_for_testing(), 1);

        f.policy.set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(99), bps::new(0));
        assert_snapshot(f.policy.snapshot<MemeA>(), true, 99, 0);
        assert_eq!(f.policy.partner_count_for_testing(), 2);

        let changes = events::collect<events::LpFeePolicyChanged>();
        let meme_a = option::some(type_name::with_original_ids<MemeA>());
        let meme_b = option::some(type_name::with_original_ids<MemeB>());
        assert_eq!(changes.length(), 7);
        assert_change(
            changes[0],
            option::none(),
            option::some(0),
            option::some(0),
            option::some(11),
            option::some(22),
        );
        assert_change(
            changes[1],
            meme_a,
            option::none(),
            option::none(),
            option::some(33),
            option::some(44),
        );
        assert_change(
            changes[2],
            meme_b,
            option::none(),
            option::none(),
            option::some(55),
            option::some(66),
        );
        assert_change(
            changes[3],
            meme_a,
            option::some(33),
            option::some(44),
            option::some(33),
            option::some(77),
        );
        assert_change(
            changes[4],
            meme_a,
            option::some(33),
            option::some(77),
            option::some(88),
            option::some(77),
        );
        assert_change(
            changes[5],
            meme_a,
            option::some(88),
            option::some(77),
            option::none(),
            option::none(),
        );
        assert_change(
            changes[6],
            meme_a,
            option::none(),
            option::none(),
            option::some(99),
            option::some(0),
        );
    });

    fixture.end();
}

#[test]
fun pinning_defaults_is_real_and_preserves_both_assets_against_later_defaults() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.policy.set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(0), bps::new(0));
        f.policy.set_default_shares(&f.package_version, &admin, bps::new(1_234), bps::new(9_876));

        assert_snapshot(f.policy.snapshot<MemeA>(), true, 0, 0);
        assert_snapshot(f.policy.snapshot<MemeB>(), false, 1_234, 9_876);
        let changes = events::collect<events::LpFeePolicyChanged>();
        assert_eq!(changes.length(), 2);
        assert_change(
            changes[0],
            option::some(type_name::with_original_ids<MemeA>()),
            option::none(),
            option::none(),
            option::some(0),
            option::some(0),
        );
    });

    fixture.end();
}

#[test]
fun default_shares_read_the_default_pair_whatever_partners_are_pinned() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.assert_default_shares(0, 0);

        f.policy.set_default_shares(&f.package_version, &admin, bps::new(1_234), bps::new(9_876));
        f.policy.set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(11), bps::new(22));
        f.assert_default_shares(1_234, 9_876);
        assert_snapshot(f.policy.snapshot<MemeA>(), true, 11, 22);

        f.policy.clear_partner_shares<MemeA>(&f.package_version, &admin);
        f.policy.set_default_shares(&f.package_version, &admin, bps::new(5), bps::new(6));
        f.assert_default_shares(5, 6);
        assert_snapshot(f.policy.snapshot<MemeA>(), false, 5, 6);
    });

    fixture.end();
}

#[test]
fun copied_default_and_partner_snapshots_survive_every_later_policy_transition() {
    let mut fixture = start_policy();

    let default_snapshot = fixture.policy.snapshot<MemeA>();
    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f
            .policy
            .set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(10_000), bps::new(1));
    });
    let partner_snapshot = fixture.policy.snapshot<MemeA>();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.policy.set_default_shares(&f.package_version, &admin, bps::new(2), bps::new(3));
        f.policy.set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(4), bps::new(5));
        f.policy.clear_partner_shares<MemeA>(&f.package_version, &admin);

        assert_snapshot(f.policy.snapshot<MemeA>(), false, 2, 3);
    });

    assert_snapshot(default_snapshot, false, 0, 0);
    assert_snapshot(partner_snapshot, true, 10_000, 1);
    fixture.end();
}

#[test]
fun both_assets_accept_zero_and_full_share_independently() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.policy.set_default_shares(&f.package_version, &admin, bps::new(10_000), bps::new(0));
        assert_snapshot(f.policy.snapshot<MemeA>(), false, 10_000, 0);
        f.policy.set_default_shares(&f.package_version, &admin, bps::new(0), bps::new(10_000));
        assert_snapshot(f.policy.snapshot<MemeA>(), false, 0, 10_000);
        f.policy.set_default_shares(&f.package_version, &admin, bps::new(10_000), bps::new(10_000));
        assert_snapshot(f.policy.snapshot<MemeA>(), false, 10_000, 10_000);
        f.policy.set_default_shares(&f.package_version, &admin, bps::new(0), bps::new(0));
        assert_snapshot(f.policy.snapshot<MemeA>(), false, 0, 0);

        f
            .policy
            .set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(10_000), bps::new(0));
        assert_snapshot(f.policy.snapshot<MemeA>(), true, 10_000, 0);
        f
            .policy
            .set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(0), bps::new(10_000));
        assert_snapshot(f.policy.snapshot<MemeA>(), true, 0, 10_000);
        f
            .policy
            .set_partner_shares<MemeA>(
                &f.package_version,
                &admin,
                bps::new(10_000),
                bps::new(10_000),
            );
        assert_snapshot(f.policy.snapshot<MemeA>(), true, 10_000, 10_000);
        f.policy.set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(0), bps::new(0));
        assert_snapshot(f.policy.snapshot<MemeA>(), true, 0, 0);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EProtocolFeeShareUnchanged,
        location = blast_fun::lp_fee_policy,
    ),
]
fun unchanged_default_pair_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.policy.set_default_shares(&f.package_version, &admin, bps::new(0), bps::new(0));
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EProtocolFeeShareUnchanged,
        location = blast_fun::lp_fee_policy,
    ),
]
fun unchanged_partner_pair_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.policy.set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(23), bps::new(45));
        f.policy.set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(23), bps::new(45));
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_fun::errors::EProtocolFeeShareUnchanged,
        location = blast_fun::lp_fee_policy,
    ),
]
fun clearing_absent_partner_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.policy.clear_partner_shares<MemeA>(&f.package_version, &admin);
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EOperationalVersionMismatch,
        location = blast_admin::operational_version,
    ),
]
fun stale_version_precedes_default_noop() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.package_version.set_for_testing(2);
        f.policy.set_default_shares(&f.package_version, &admin, bps::new(0), bps::new(0));
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EOperationalVersionMismatch,
        location = blast_admin::operational_version,
    ),
]
fun stale_version_precedes_partner_noop() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.policy.set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(0), bps::new(0));
        f.package_version.set_for_testing(2);
        f.policy.set_partner_shares<MemeA>(&f.package_version, &admin, bps::new(0), bps::new(0));
    });

    fixture.end();
}

#[test]
#[
    expected_failure(
        abort_code = blast_admin::errors::EOperationalVersionMismatch,
        location = blast_admin::operational_version,
    ),
]
fun stale_version_precedes_missing_partner_clear() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = f.sign_in();
        f.package_version.set_for_testing(2);
        f.policy.clear_partner_shares<MemeA>(&f.package_version, &admin);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = blast_admin::errors::EInvalidAdminCap, location = blast_admin::acl)]
fun revoked_admin_cannot_obtain_authority_to_mutate_policy() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.authority.revoke_admin(&f.root, object::id(&f.admin_cap));
        let admin = f.sign_in();
        f.policy.set_default_shares(&f.package_version, &admin, bps::new(1), bps::new(2));
    });

    fixture.end();
}

// === Test Helpers ===

macro fun init_next_tx($fixture: &mut InitFixture, $sender: address, $fn: |&mut InitFixture|) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun policy_next_tx(
    $fixture: &mut PolicyFixture,
    $sender: address,
    $fn: |&mut PolicyFixture|,
) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start_init(): InitFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    lp_fee_policy::init_for_testing(scenario.ctx());
    assert_eq!(event::num_events(), 0);
    scenario.next_tx(PUBLISHER);
    let policy = scenario.take_shared<LpFeePolicy>();

    InitFixture { scenario, policy }
}

fun start_policy(): PolicyFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (root, mut authority) = domain_fixture::new_authority(scenario.ctx());
    authority.grant_admin(&root, 0, PROTOCOL_ADMIN, scenario.ctx());
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());
    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();

    PolicyFixture { scenario, authority, root, admin_cap, package_version, policy }
}

fun sign_in(self: &PolicyFixture): AdminWitness<BLAST_FUN_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun assert_snapshot(snapshot: PolicySnapshot, partner: bool, meme_bps: u64, quote_bps: u64) {
    assert_eq!(snapshot.is_partner(), partner);
    assert_eq!(snapshot.meme_share().value(), meme_bps);
    assert_eq!(snapshot.quote_share().value(), quote_bps);
}

fun assert_default_shares(self: &PolicyFixture, meme_bps: u64, quote_bps: u64) {
    let (meme_share, quote_share) = self.policy.default_shares();

    assert_eq!(meme_share.value(), meme_bps);
    assert_eq!(quote_share.value(), quote_bps);
}

fun assert_change(
    change: events::LpFeePolicyChanged,
    override_meme: Option<TypeName>,
    old_meme_bps: Option<u64>,
    old_quote_bps: Option<u64>,
    new_meme_bps: Option<u64>,
    new_quote_bps: Option<u64>,
) {
    assert_eq!(
        bcs::to_bytes(&change),
        bcs::to_bytes(
            &ExpectedChange {
                override_meme,
                old_meme_bps,
                old_quote_bps,
                new_meme_bps,
                new_quote_bps,
            },
        ),
    );
}

fun init_end(self: InitFixture) {
    destroy(self);
}

fun policy_end(self: PolicyFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::{Authority, SuperAdminCap, AdminCap, AdminWitness};

use blast_fun::{
    blast_fun_domain::BLAST_FUN_DOMAIN,
    bps,
    domain_fixture,
    events,
    lp_fee_policy::{Self, LpFeePolicy, PolicySnapshot},
    package_version,
};

use std::{bcs, type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::{event, test_scenario::{Self, Scenario}};

use fun init_end as InitFixture.end;

use fun init_next_tx as InitFixture.next_tx;

use fun policy_end as PolicyFixture.end;

use fun policy_next_tx as PolicyFixture.next_tx;
