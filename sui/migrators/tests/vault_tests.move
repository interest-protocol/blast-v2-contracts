#[test_only]
module blast_fun_migrators::vault_tests;

use blast_fun::{acl, package_version, runtime_config};
use blast_fun_migrators::vault::{Self, LpVault};
use std::unit_test::{assert_eq, destroy};
use sui::{balance, test_scenario::{Self, Scenario}};

// === Constants ===

const PUBLISHER: address = @0xA11CE;
const PROTOCOL_ADMIN: address = @0xAD;

// === Test-Only Types ===

public struct MEME has drop {}
public struct QUOTE has drop {}
public struct TestVenue() has drop;
public struct OtherVenue() has drop;
public struct TestPosition has key, store { id: UID }

/// Shared custody and live-share fee accounting through the vault seam.
public struct VaultFixture {
    scenario: Scenario,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
    package_version: package_version::PackageVersion,
    runtime_config: runtime_config::RuntimeConfig,
    vault: LpVault<MEME, QUOTE>,
    pool_id: ID,
    position_id: ID,
}

// === Tests ===

#[test]
fun accrues_with_the_live_share_and_never_resplits_prior_ownership() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.runtime_config.set_protocol_fee_share(
            &f.package_version,
            &admin_witness,
            2_000,
        );
        f.accrue!(10, 10);

        let (meme, quote) =
            f.vault.claim_protocol_fees(&admin_witness, f.scenario.ctx());
        assert_eq!(meme.value(), 2);
        assert_eq!(quote.value(), 2);
        destroy(meme);
        destroy(quote);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.runtime_config.set_protocol_fee_share(
            &f.package_version,
            &admin_witness,
            10_000,
        );
        f.accrue!(10, 10);

        // Only the new accrual follows the raised share; the eight units the
        // creator already owns from the first accrual are never re-split.
        let (meme, quote) =
            f.vault.claim_protocol_fees(&admin_witness, f.scenario.ctx());
        assert_eq!(meme.value(), 10);
        assert_eq!(quote.value(), 10);
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
            f.vault.claim_protocol_fees(&admin_witness, f.scenario.ctx());

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
            5,
            &f.runtime_config,
            f.scenario.ctx(),
        );
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
        5,
        &fixture.runtime_config,
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
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(scenario.ctx());
    authority.grant_admin(
        &package_version,
        &super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );
    destroy(super_admin_cap);
    let runtime_config =
        runtime_config::new_disabled_for_testing(scenario.ctx());
    let position = TestPosition { id: object::new(scenario.ctx()) };
    let position_id = object::id(&position);
    let pool_uid = object::new(scenario.ctx());
    let pool_id = pool_uid.to_inner();
    pool_uid.delete();
    vault::new<MEME, QUOTE, TestVenue, TestPosition>(
        TestVenue(),
        pool_id,
        position,
        balance::create_for_testing<MEME>(protocol_meme_residual),
        balance::create_for_testing<QUOTE>(protocol_quote_residual),
        scenario.ctx(),
    );

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let vault = scenario.take_shared<LpVault<MEME, QUOTE>>();

    VaultFixture {
        scenario,
        authority,
        admin_cap,
        package_version,
        runtime_config,
        vault,
        pool_id,
        position_id,
    }
}

fun sign_in(self: &VaultFixture): acl::AdminWitness {
    self.authority.sign_in(&self.package_version, &self.admin_cap)
}

fun end(self: VaultFixture) {
    destroy(self);
}
