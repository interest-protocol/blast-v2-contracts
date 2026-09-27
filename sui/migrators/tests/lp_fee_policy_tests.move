// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// LP-fee policy administration: the default pair, original-type per-coin pairs, the live protocol
/// destination, and the shares every collection reads live from them.
module blast_fun_migrators::lp_fee_policy_tests;

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

/// Live policy administration under each setter's own role.
public struct PolicyFixture {
    scenario: Scenario,
    migrators_version: MigratorsVersion,
    policy: LpFeePolicy,
}

/// Independently encoded expectation for every policy event field in ABI order.
public struct ExpectedChange has copy, drop {
    meme: Option<TypeName>,
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
        let (meme_share, quote_share) = f.policy.shares<MemeA>();
        assert_eq!(meme_share.value(), 0);
        assert_eq!(quote_share.value(), 0);
        let (default_meme_share, default_quote_share) = f.policy.default_shares_for_testing();
        assert_eq!(default_meme_share.value(), 0);
        assert_eq!(default_quote_share.value(), 0);
        assert_eq!(f.policy.coin_count_for_testing(), 0);
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
        let admin = treasury_admin();
        f.policy.set_protocol_destination(&f.migrators_version, &admin, @0xCAFE);

        assert_eq!(f.policy.protocol_destination(), @0xCAFE);
        let events = event::events_by_type<blast_events::LpFeeDestinationChanged>();
        let publisher = PUBLISHER;
        let mut expected = bcs::to_bytes(&publisher);
        expected.append(bcs::to_bytes(&@0xCAFE));
        assert_eq!(events.length(), 1);
        assert_eq!(bcs::to_bytes(&events[0]), expected);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_policy::EProtocolDestinationUnchanged,
    location = blast_fun_migrators::lp_fee_policy,
)]
fun unchanged_protocol_destination_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = treasury_admin();
        f.policy.set_protocol_destination(&f.migrators_version, &admin, PUBLISHER);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_policy::EProtocolDestinationUnchanged,
    location = blast_fun_migrators::lp_fee_policy,
)]
fun zero_protocol_destination_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = treasury_admin();
        f.policy.set_protocol_destination(&f.migrators_version, &admin, @0x0);
    });

    fixture.end();
}

#[test]
fun active_admin_changes_independent_defaults_and_all_event_fields() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f.policy.set_default_shares(&f.migrators_version, &admin, bps::new(2_000), bps::new(7_000));

        f.assert_shares<MemeA>(2_000, 7_000);
        f.assert_shares<MemeB>(2_000, 7_000);
        let changes = policy_changes();
        assert_eq!(changes.length(), 1);
        assert_change(
            changes[0],
            option::none(),
            option::some(0),
            option::some(0),
            option::some(2_000),
            option::some(7_000),
        );
    });

    fixture.end();
}

#[test]
fun changing_either_asset_alone_is_a_real_default_update() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f.policy.set_default_shares(&f.migrators_version, &admin, bps::new(1), bps::new(0));
        f.policy.set_default_shares(&f.migrators_version, &admin, bps::new(1), bps::new(2));

        f.assert_shares<MemeA>(1, 2);
        let changes = policy_changes();
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
fun coin_pair_create_update_clear_readd_preserves_original_type_keys_and_event_history() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        let version = &f.migrators_version;
        f.policy.set_default_shares(version, &admin, bps::new(11), bps::new(22));
        f.policy.set_coin_shares<MemeA>(version, &admin, bps::new(33), bps::new(44));
        f.policy.set_coin_shares<MemeB>(version, &admin, bps::new(55), bps::new(66));
        f.assert_shares<MemeA>(33, 44);
        f.assert_shares<MemeB>(55, 66);
        assert_eq!(f.policy.coin_count_for_testing(), 2);

        f.policy.set_coin_shares<MemeA>(version, &admin, bps::new(33), bps::new(77));
        f.assert_shares<MemeA>(33, 77);
        f.policy.set_coin_shares<MemeA>(version, &admin, bps::new(88), bps::new(77));
        f.assert_shares<MemeA>(88, 77);
        f.policy.clear_coin_shares<MemeA>(version, &admin);
        f.assert_shares<MemeA>(11, 22);
        f.assert_shares<MemeB>(55, 66);
        assert_eq!(f.policy.coin_count_for_testing(), 1);

        f.policy.set_coin_shares<MemeA>(version, &admin, bps::new(99), bps::new(0));
        f.assert_shares<MemeA>(99, 0);
        assert_eq!(f.policy.coin_count_for_testing(), 2);

        let changes = policy_changes();
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
fun a_coin_pair_equal_to_the_defaults_is_real_and_skips_later_default_changes() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        let version = &f.migrators_version;
        f.policy.set_coin_shares<MemeA>(version, &admin, bps::new(0), bps::new(0));
        f.policy.set_default_shares(version, &admin, bps::new(1_234), bps::new(9_876));

        f.assert_shares<MemeA>(0, 0);
        f.assert_shares<MemeB>(1_234, 9_876);
        let changes = policy_changes();
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
fun default_shares_read_the_default_pair_whatever_coin_pairs_are_set() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f.assert_default_shares(0, 0);

        f.policy.set_default_shares(&f.migrators_version, &admin, bps::new(1_234), bps::new(9_876));
        let version = &f.migrators_version;
        f.policy.set_coin_shares<MemeA>(version, &admin, bps::new(11), bps::new(22));
        f.assert_default_shares(1_234, 9_876);
        f.assert_shares<MemeA>(11, 22);

        f.policy.clear_coin_shares<MemeA>(&f.migrators_version, &admin);
        f.policy.set_default_shares(&f.migrators_version, &admin, bps::new(5), bps::new(6));
        f.assert_default_shares(5, 6);
        f.assert_shares<MemeA>(5, 6);
    });

    fixture.end();
}

#[test]
fun a_coin_pair_and_every_default_change_apply_to_the_very_next_read() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        let version = &f.migrators_version;
        f.policy.set_coin_shares<MemeA>(version, &admin, bps::new(10_000), bps::new(1));
        f.assert_shares<MemeA>(10_000, 1);
        f.assert_shares<MemeB>(0, 0);

        // A default change reaches every coin without its own pair at once, and no other.
        f.policy.set_default_shares(version, &admin, bps::new(2), bps::new(3));
        f.assert_shares<MemeA>(10_000, 1);
        f.assert_shares<MemeB>(2, 3);

        f.policy.set_coin_shares<MemeA>(version, &admin, bps::new(4), bps::new(5));
        f.assert_shares<MemeA>(4, 5);

        // Clearing falls back to the defaults current at the clear, not those at the set.
        f.policy.clear_coin_shares<MemeA>(version, &admin);
        f.assert_shares<MemeA>(2, 3);
        f.policy.set_default_shares(version, &admin, bps::new(6), bps::new(7));
        f.assert_shares<MemeA>(6, 7);
        f.assert_shares<MemeB>(6, 7);
        assert_eq!(f.policy.coin_count_for_testing(), 0);
    });

    fixture.end();
}

#[test]
fun both_assets_accept_zero_and_full_share_independently() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        let version = &f.migrators_version;
        f.policy.set_default_shares(version, &admin, bps::new(10_000), bps::new(0));
        f.assert_shares<MemeA>(10_000, 0);
        f.policy.set_default_shares(version, &admin, bps::new(0), bps::new(10_000));
        f.assert_shares<MemeA>(0, 10_000);
        f.policy.set_default_shares(version, &admin, bps::new(10_000), bps::new(10_000));
        f.assert_shares<MemeA>(10_000, 10_000);
        f.policy.set_default_shares(version, &admin, bps::new(0), bps::new(0));
        f.assert_shares<MemeA>(0, 0);

        f.policy.set_coin_shares<MemeA>(version, &admin, bps::new(10_000), bps::new(0));
        f.assert_shares<MemeA>(10_000, 0);
        f.policy.set_coin_shares<MemeA>(version, &admin, bps::new(0), bps::new(10_000));
        f.assert_shares<MemeA>(0, 10_000);
        f.policy.set_coin_shares<MemeA>(version, &admin, bps::new(10_000), bps::new(10_000));
        f.assert_shares<MemeA>(10_000, 10_000);
        f.policy.set_coin_shares<MemeA>(version, &admin, bps::new(0), bps::new(0));
        f.assert_shares<MemeA>(0, 0);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_policy::EProtocolFeeSharesUnchanged,
    location = blast_fun_migrators::lp_fee_policy,
)]
fun unchanged_default_pair_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f.policy.set_default_shares(&f.migrators_version, &admin, bps::new(0), bps::new(0));
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_policy::EProtocolFeeSharesUnchanged,
    location = blast_fun_migrators::lp_fee_policy,
)]
fun unchanged_coin_pair_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        let version = &f.migrators_version;
        f.policy.set_coin_shares<MemeA>(version, &admin, bps::new(23), bps::new(45));
        f.policy.set_coin_shares<MemeA>(version, &admin, bps::new(23), bps::new(45));
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = dynamic_field::EFieldDoesNotExist, location = sui::dynamic_field)]
fun clearing_an_absent_coin_pair_is_rejected() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f.policy.clear_coin_shares<MemeA>(&f.migrators_version, &admin);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_precedes_destination_noop() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = treasury_admin();
        f.migrators_version.set_for_testing(2);
        f.policy.set_protocol_destination(&f.migrators_version, &admin, PUBLISHER);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_precedes_default_noop() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f.migrators_version.set_for_testing(2);
        f.policy.set_default_shares(&f.migrators_version, &admin, bps::new(0), bps::new(0));
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_precedes_coin_noop() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f.policy.set_coin_shares<MemeA>(&f.migrators_version, &admin, bps::new(0), bps::new(0));
        f.migrators_version.set_for_testing(2);
        f.policy.set_coin_shares<MemeA>(&f.migrators_version, &admin, bps::new(0), bps::new(0));
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_admin::errors::EOperationalVersionMismatch,
    location = blast_admin::operational_version,
)]
fun stale_version_precedes_missing_coin_clear() {
    let mut fixture = start_policy();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin = fee_admin();
        f.migrators_version.set_for_testing(2);
        f.policy.clear_coin_shares<MemeA>(&f.migrators_version, &admin);
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

/// A fresh policy.
fun start_policy(): PolicyFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let migrators_version = migrators_version::new_for_testing(scenario.ctx());
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());

    PolicyFixture { scenario, migrators_version, policy }
}

fun treasury_admin(): AdminWitness<TreasuryAdmin> {
    blast_acl::witness_for_testing()
}

fun fee_admin(): AdminWitness<FeeAdmin> {
    blast_acl::witness_for_testing()
}

fun policy_changes(): vector<blast_events::LpFeePolicyChanged> {
    event::events_by_type<blast_events::LpFeePolicyChanged>()
}

/// Asserts the pair a collection for `Meme` pays Blast right now.
fun assert_shares<Meme>(self: &PolicyFixture, meme_bps: u64, quote_bps: u64) {
    let (meme_share, quote_share) = self.policy.shares<Meme>();

    assert_eq!(meme_share.value(), meme_bps);
    assert_eq!(quote_share.value(), quote_bps);
}

fun assert_default_shares(self: &PolicyFixture, meme_bps: u64, quote_bps: u64) {
    let (meme_share, quote_share) = self.policy.default_shares_for_testing();

    assert_eq!(meme_share.value(), meme_bps);
    assert_eq!(quote_share.value(), quote_bps);
}

fun assert_change(
    change: blast_events::LpFeePolicyChanged,
    meme: Option<TypeName>,
    old_meme_bps: Option<u64>,
    old_quote_bps: Option<u64>,
    new_meme_bps: Option<u64>,
    new_quote_bps: Option<u64>,
) {
    assert_eq!(
        bcs::to_bytes(&change),
        bcs::to_bytes(
            &ExpectedChange {
                meme,
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

use blast_admin::blast_acl::{Self, AdminWitness};

use blast_fun::{blast_fun_domain::{FeeAdmin, TreasuryAdmin}, bps};

use blast_fun_migrators::{
    blast_events,
    lp_fee_policy::{Self, LpFeePolicy},
    package_version::{Self as migrators_version, PackageVersion as MigratorsVersion},
};

use std::{bcs, type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::{dynamic_field, event, test_scenario::{Self, Scenario}};

use fun init_end as InitFixture.end;

use fun init_next_tx as InitFixture.next_tx;

use fun policy_end as PolicyFixture.end;

use fun policy_next_tx as PolicyFixture.next_tx;
