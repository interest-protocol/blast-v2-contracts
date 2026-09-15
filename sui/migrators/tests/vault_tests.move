#[test_only]
module blast_fun_migrators::vault_tests;

use blast_admin::acl::{Self, Authority, AdminCap, AdminWitness};
use blast_fun::{bps, launchpad_domain::{Self, LAUNCHPAD_DOMAIN}, package_version};
use blast_fun_migrators::{
    events,
    lp_fee_authority::{Self, LpFeeCap},
    lp_fee_policy::{Self, LpFeePolicy},
    package_version::{Self as migrators_version, PackageVersion as MigratorsVersion},
    vault::{Self, LpVault},
};
use std::{bcs, type_name, unit_test::{assert_eq, destroy}};
use sui::{balance, coin, test_scenario::{Self, Scenario}};

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;
const CREATOR: address = @0xC0FFEE;
const NEW_CREATOR: address = @0xC7;
const MAX_ADMINS: u64 = 16;
const ROOT_TRANSFER_DELAY_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

// === Test-Only Types ===

public struct MEME has drop {}
public struct QUOTE has drop {}
public struct OTHER_MEME has drop {}
public struct TestVenue() has drop;
public struct OtherVenue() has drop;
public struct TestPosition has key, store { id: UID }

/// Shared custody and LP-policy fee accounting through the vault seam.
public struct VaultFixture {
    scenario: Scenario,
    authority: Authority<LAUNCHPAD_DOMAIN>,
    admin_cap: AdminCap<LAUNCHPAD_DOMAIN>,
    package_version: package_version::PackageVersion,
    migrators_version: MigratorsVersion,
    lp_fee_policy: LpFeePolicy,
    vault: LpVault<MEME, QUOTE>,
    pool_id: ID,
    position_id: ID,
}

// === Tests ===

#[test]
fun prepared_vault_keeps_its_id_when_finished_and_shared() {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let position = TestPosition { id: object::new(scenario.ctx()) };
    let pool_uid = object::new(scenario.ctx());
    let pool_id = pool_uid.to_inner();
    pool_uid.delete();
    let pending_vault = vault::prepare<MEME, QUOTE>(
        lp_fee_authority::new_for_testing(),
        balance::zero(),
        balance::zero(),
        scenario.ctx(),
    );
    let pending_id = pending_vault.pending_id();
    let finished_id = pending_vault.finish(TestVenue(), pool_id, position);
    assert_eq!(finished_id, pending_id);

    scenario.next_tx(PUBLISHER);
    let shared = scenario.take_shared<LpVault<MEME, QUOTE>>();
    assert_eq!(object::id(&shared), pending_id);
    assert_eq!(shared.pool_id(), pool_id);
    test_scenario::return_shared(shared);
    scenario.end();
}

#[test]
fun accrues_with_the_lp_policy_share_and_never_resplits_prior_ownership() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.lp_fee_policy.set_protocol_fee_share(
            &f.migrators_version,
            &admin_witness,
            bps::new(2_000),
        );
        f.accrue!(10, 10);

        let (meme, quote) =
            f.vault.claim_protocol_fees(
                &f.migrators_version,
                &admin_witness,
                f.scenario.ctx(),
            );
        assert_eq!(meme.value(), 2);
        assert_eq!(quote.value(), 2);
        destroy(meme);
        destroy(quote);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.lp_fee_policy.set_protocol_fee_share(
            &f.migrators_version,
            &admin_witness,
            bps::new(10_000),
        );
        f.accrue!(10, 10);

        // Only the new accrual follows the raised share; the eight units the
        // creator already owns from the first accrual are never re-split.
        let (meme, quote) =
            f.vault.claim_protocol_fees(
                &f.migrators_version,
                &admin_witness,
                f.scenario.ctx(),
            );
        assert_eq!(meme.value(), 10);
        assert_eq!(quote.value(), 10);
        destroy(meme);
        destroy(quote);
    });

    fixture.end();
}

#[test]
fun project_share_overrides_the_default_and_is_the_emitted_split_input() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.lp_fee_policy.set_protocol_fee_share(
            &f.migrators_version,
            &admin_witness,
            bps::new(2_000),
        );
        f.lp_fee_policy.set_project_protocol_fee_share<OTHER_MEME>(
            &f.migrators_version,
            &admin_witness,
            bps::new(9_000),
        );
        f.accrue!(10, 10);

        // Another project's pin never reaches this vault.
        let (meme, quote) =
            f.vault.claim_protocol_fees(
                &f.migrators_version,
                &admin_witness,
                f.scenario.ctx(),
            );
        assert_eq!(meme.value(), 2);
        assert_eq!(quote.value(), 2);
        destroy(meme);
        destroy(quote);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.lp_fee_policy.set_project_protocol_fee_share<MEME>(
            &f.migrators_version,
            &admin_witness,
            bps::new(5_000),
        );
        f.accrue!(10, 10);

        let events = sui::event::events_by_type<blast_fun_migrators::events::LpFeesCollected>();
        let mut expected = bcs::to_bytes(&object::id(&f.vault));
        expected.append(bcs::to_bytes(&f.pool_id));
        expected.append(bcs::to_bytes(&f.position_id));
        expected.append(bcs::to_bytes(&type_name::with_original_ids<TestVenue>()));
        expected.append(bcs::to_bytes(&type_name::with_original_ids<MEME>()));
        expected.append(bcs::to_bytes(&type_name::with_original_ids<QUOTE>()));
        let collector = PROTOCOL_ADMIN;
        expected.append(bcs::to_bytes(&collector));
        vector[10u64, 10, 5_000, 5, 5, 5, 5].do!(|value| {
            expected.append(bcs::to_bytes(&value));
        });
        expected.append(bcs::to_bytes(&5u128));
        assert_eq!(events.length(), 1);
        assert_eq!(bcs::to_bytes(&events[0]), expected);

        let (meme, quote) =
            f.vault.claim_protocol_fees(
                &f.migrators_version,
                &admin_witness,
                f.scenario.ctx(),
            );
        assert_eq!(meme.value(), 5);
        assert_eq!(quote.value(), 5);
        destroy(meme);
        destroy(quote);
    });

    fixture.end();
}

#[test]
fun protocol_claim_drains_migration_residuals_without_accrued_fees() {
    let mut fixture = start_with_residuals(3, 4);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();
        let (meme, quote) =
            f.vault.claim_protocol_fees(
                &f.migrators_version,
                &admin_witness,
                f.scenario.ctx(),
            );

        assert_eq!(meme.value(), 3);
        assert_eq!(quote.value(), 4);
        destroy(meme);
        destroy(quote);
    });

    fixture.end();
}

#[test]
fun borrow_returns_the_attached_position() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let venue = TestVenue();
        let position = f.vault.position_mut<
            MEME,
            QUOTE,
            TestVenue,
            TestPosition,
        >(&venue);

        assert_eq!(object::id(position), f.position_id);
    });

    fixture.end();
}

#[test]
fun receives_and_merges_the_maximum_coin_batch() {
    let mut fixture = start();
    let vault_id = object::id(&fixture.vault);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut count: u64 = 0;
        while (count < 60) {
            let fee_coin =
                balance::create_for_testing<MEME>(1).into_coin(f.scenario.ctx());
            transfer::public_transfer(fee_coin, vault_id.to_address());
            count = count + 1;
        };
        while (count < 100) {
            let fee_coin =
                balance::create_for_testing<QUOTE>(1).into_coin(f.scenario.ctx());
            transfer::public_transfer(fee_coin, vault_id.to_address());
            count = count + 1;
        };
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut meme_coin_ids =
            test_scenario::receivable_object_ids_for_owner_id<coin::Coin<MEME>>(
                vault_id,
            );
        assert_eq!(meme_coin_ids.length(), 60);
        let mut meme_receivings = vector[];
        while (!meme_coin_ids.is_empty()) {
            meme_receivings.push_back(
                test_scenario::receiving_ticket_by_id<coin::Coin<MEME>>(
                    meme_coin_ids.pop_back(),
                ),
            );
        };
        let mut quote_coin_ids =
            test_scenario::receivable_object_ids_for_owner_id<coin::Coin<QUOTE>>(
                vault_id,
            );
        assert_eq!(quote_coin_ids.length(), 40);
        let mut quote_receivings = vector[];
        while (!quote_coin_ids.is_empty()) {
            quote_receivings.push_back(
                test_scenario::receiving_ticket_by_id<coin::Coin<QUOTE>>(
                    quote_coin_ids.pop_back(),
                ),
            );
        };
        let (meme, quote) = f.vault.receive_coins(
            &TestVenue(),
            meme_receivings,
            quote_receivings,
        );
        assert_eq!(meme.destroy_for_testing(), 60);
        assert_eq!(quote.destroy_for_testing(), 40);
    });

    fixture.end();
}

#[test]
fun receiving_coin_batch_accepts_each_one_sided_maximum() {
    vault::assert_valid_receiving_coin_batch_size_for_testing(100, 0);
    vault::assert_valid_receiving_coin_batch_size_for_testing(0, 100);
}

#[test]
#[expected_failure(
    abort_code = vault::EInvalidReceivingCoinBatch,
    location = blast_fun_migrators::vault,
)]
fun receiving_coin_batch_rejects_empty() {
    vault::assert_valid_receiving_coin_batch_size_for_testing(0, 0);
}

#[test]
#[expected_failure(
    abort_code = vault::EInvalidReceivingCoinBatch,
    location = blast_fun_migrators::vault,
)]
fun receiving_coin_batch_rejects_the_first_size_above_maximum() {
    vault::assert_valid_receiving_coin_batch_size_for_testing(60, 41);
}

#[test]
#[expected_failure(
    abort_code = vault::EWrongVenue,
    location = blast_fun_migrators::vault,
)]
fun wrong_venue_borrow_fails_closed() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let venue = OtherVenue();

        f.vault.position_mut<MEME, QUOTE, OtherVenue, TestPosition>(
            &venue,
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = vault::EWrongVenue,
    location = blast_fun_migrators::vault,
)]
fun wrong_venue_accrual_fails_closed() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let venue = OtherVenue();

        f.vault.accrue_fees(
            &venue,
            f.position_id,
            balance::create_for_testing<MEME>(1),
            balance::create_for_testing<QUOTE>(1),
            5,
            &f.lp_fee_policy,
            f.scenario.ctx(),
        );
    });

    fixture.end();
}


#[test]
fun live_lp_fee_cap_claims_only_creator_fees() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let lp_fee_cap = f.vault.issue_lp_fee_cap_for_testing(f.scenario.ctx());

        f.accrue!(10, 20);
        let (meme, quote) = f.vault.claim_creator_fees(
            &f.migrators_version,
            &lp_fee_cap,
            f.scenario.ctx(),
        );

        assert_eq!(meme.value(), 10);
        assert_eq!(quote.value(), 20);

        destroy(meme);
        destroy(quote);
        destroy(lp_fee_cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_authority::ELpFeeCapNotLive,
    location = blast_fun_migrators::lp_fee_authority,
)]
fun retired_lp_fee_cap_is_rejected_before_the_empty_ledger_check() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let retired = f.vault.issue_lp_fee_cap_for_testing(f.scenario.ctx());
        let live = f.vault.issue_lp_fee_cap_for_testing(f.scenario.ctx());
        let (meme, quote) = f.vault.claim_creator_fees(
            &f.migrators_version,
            &retired,
            f.scenario.ctx(),
        );

        destroy(meme);
        destroy(quote);
        destroy(retired);
        destroy(live);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_authority::ELpFeeCapNotLive,
    location = blast_fun_migrators::lp_fee_authority,
)]
fun pending_vault_honors_no_lp_fee_cap() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let lp_fee_cap = lp_fee_authority::new_lp_fee_cap_for_testing<MEME>(f.scenario.ctx());

        f.accrue!(10, 20);
        let (meme, quote) = f.vault.claim_creator_fees(
            &f.migrators_version,
            &lp_fee_cap,
            f.scenario.ctx(),
        );

        destroy(meme);
        destroy(quote);
        destroy(lp_fee_cap);
    });

    fixture.end();
}

#[test]
fun locked_lp_fees_are_claimed_only_by_the_bound_custodian() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let custodian = object::new(f.scenario.ctx());
        let lp_fee_cap = f.vault.issue_lp_fee_cap_for_testing(f.scenario.ctx());
        let lp_fee_cap_id = object::id(&lp_fee_cap);

        f.accrue!(10, 20);
        f.vault.lock_creator_fees(&f.migrators_version, lp_fee_cap, &custodian);

        let events = sui::event::events_by_type<events::LpFeesLocked>();
        let mut expected = bcs::to_bytes(&object::id(&f.vault));
        expected.append(bcs::to_bytes(&type_name::with_original_ids<MEME>()));
        expected.append(bcs::to_bytes(&type_name::with_original_ids<QUOTE>()));
        expected.append(bcs::to_bytes(&option::some(lp_fee_cap_id)));
        expected.append(bcs::to_bytes(&custodian.to_inner()));
        assert_eq!(events.length(), 1);
        assert_eq!(bcs::to_bytes(&events[0]), expected);
        assert_eq!(f.vault.custodian_id_for_testing(), option::some(custodian.to_inner()));

        let (meme, quote) = f.vault.claim_custodied_creator_fees(
            &f.migrators_version,
            &custodian,
            f.scenario.ctx(),
        );
        assert_eq!(meme.value(), 10);
        assert_eq!(quote.value(), 20);

        custodian.delete();
        destroy(meme);
        destroy(quote);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = lp_fee_authority::ELpFeeCustodianMismatch,
    location = blast_fun_migrators::lp_fee_authority,
)]
fun wrong_custodian_is_rejected_before_the_empty_lp_ledger_check() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let custodian = object::new(f.scenario.ctx());
        let impostor = object::new(f.scenario.ctx());
        let lp_fee_cap = f.vault.issue_lp_fee_cap_for_testing(f.scenario.ctx());

        f.vault.lock_creator_fees(&f.migrators_version, lp_fee_cap, &custodian);
        let (meme, quote) = f.vault.claim_custodied_creator_fees(
            &f.migrators_version,
            &impostor,
            f.scenario.ctx(),
        );

        custodian.delete();
        impostor.delete();
        destroy(meme);
        destroy(quote);
    });

    fixture.end();
}

// === Private Test Helpers ===

macro fun next_tx(
    $fixture: &mut VaultFixture,
    $sender: address,
    $fn: |&mut VaultFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun accrue($fixture: &mut VaultFixture, $meme: u64, $quote: u64) {
    let fixture = $fixture;
    let venue = TestVenue();

    fixture.vault.accrue_fees(
        &venue,
        fixture.position_id,
        balance::create_for_testing<MEME>($meme),
        balance::create_for_testing<QUOTE>($quote),
        5,
        &fixture.lp_fee_policy,
        fixture.scenario.ctx(),
    );
}

fun start(): VaultFixture {
    start_with_residuals(0, 0)
}

fun start_with_residuals(
    protocol_meme_residual: u64,
    protocol_quote_residual: u64,
): VaultFixture {
    let mut scenario = test_scenario::begin(PUBLISHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let migrators_version = migrators_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) = acl::new_for_testing<LAUNCHPAD_DOMAIN>(
        MAX_ADMINS,
        ROOT_TRANSFER_DELAY_MS,
        scenario.ctx(),
    );
    authority.grant_admin(
        &super_admin_cap,
        launchpad_domain::creator_admin_role(),
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );
    destroy(super_admin_cap);
    let lp_fee_policy = lp_fee_policy::new_for_testing(scenario.ctx());
    let position = TestPosition { id: object::new(scenario.ctx()) };
    let position_id = object::id(&position);
    let pool_uid = object::new(scenario.ctx());
    let pool_id = pool_uid.to_inner();
    pool_uid.delete();
    vault::new<MEME, QUOTE, TestVenue, TestPosition>(
        TestVenue(),
        lp_fee_authority::new_for_testing(),
        pool_id,
        position,
        balance::create_for_testing<MEME>(protocol_meme_residual),
        balance::create_for_testing<QUOTE>(protocol_quote_residual),
        scenario.ctx(),
    );

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<AdminCap<LAUNCHPAD_DOMAIN>>();
    let vault = scenario.take_shared<LpVault<MEME, QUOTE>>();

    VaultFixture {
        scenario,
        authority,
        admin_cap,
        package_version,
        migrators_version,
        lp_fee_policy,
        vault,
        pool_id,
        position_id,
    }
}

fun sign_in(self: &VaultFixture): AdminWitness<LAUNCHPAD_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun end(self: VaultFixture) {
    destroy(self);
}
