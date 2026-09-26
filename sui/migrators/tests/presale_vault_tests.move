// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// A presale's pool share through a sealed mock adapter into a presale vault, and the vault's fee
/// payments.
///
/// The adapter takes the presale's pool share under its own witness, locks a mock position holding
/// it in a presale vault, and returns one atom of each asset as the venue's residuals, as the Cetus
/// and Bluefin routes do. The venue interfaces are `abort 0` link stubs, so the real pool creation
/// is checked by the source gate and the PTB harness, not here.
module blast_fun_migrators::presale_vault_tests;

// === Constants ===

/// Publishes the LP-fee policy, so it is Blast's protocol destination.
const PROTOCOL: address = @0xB1A57;

const ADMIN: address = @0xAD;

const CREATOR: address = @0xC0FFEE;

const BUYER: address = @0xB0;

const KEEPER: address = @0xEE;

const POOL: address = @0x9001;

const START_MS: u64 = 1_000;

const END_MS: u64 = 2_000;

const CLAIM_MS: u64 = 3_000;

// === Test-Only Types ===

public struct TOKEN() has drop;

public struct QUOTE() has drop;

/// The mock adapter's presale witness, which is also its vault venue marker.
public struct Venue() has drop;

/// Venue position holding the liquidity the adapter adds.
public struct MockPosition has key, store {
    id: UID,
    token: Balance<TOKEN>,
    quote: Balance<QUOTE>,
}

/// A finalized presale whose whole raise, 300 Quote, buys 600 tokens for its pool at 1 Quote per
/// 2 tokens, with Blast's LP shares at 10% of tokens and 20% of Quote.
public struct PresaleVaultFixture {
    scenario: Scenario,
    presale_version: PresaleVersion,
    presale_config: BlastPresaleConfig,
    migrators_version: MigratorsVersion,
    policy: LpFeePolicy,
    clock: Clock,
}

// === Tests ===

#[test]
fun the_adapter_locks_the_pool_share_and_pays_the_residuals_to_the_creator() {
    let mut fixture = start();
    let (presale_id, vault_id) = fixture.open_pool(1);

    let mut created = sui::bcs::new(bcs::to_bytes(&only_event<PresaleVaultCreated>()));
    assert_eq!(created.peel_address(), vault_id.to_address());
    assert_eq!(created.peel_address(), presale_id.to_address());
    assert_eq!(created.peel_address(), POOL);
    created.peel_address();
    assert_eq!(created.peel_vec_u8(), type_bytes<Venue>());
    assert_eq!(created.peel_vec_u8(), type_bytes<TOKEN>());
    assert_eq!(created.peel_vec_u8(), type_bytes<QUOTE>());
    assert_eq!(created.peel_address(), CREATOR);
    assert_eq!(created.peel_u64(), 1);
    assert_eq!(created.peel_u64(), 1);
    assert_eq!(created.peel_u128(), 1);
    // The tranche sold out and the pool used its whole reserve, so the creator holds only the
    // residuals.
    assert_eq!(fixture.coin_total<TOKEN>(CREATOR), 1);
    assert_eq!(fixture.coin_total<QUOTE>(CREATOR), 1);
    fixture.next_tx!(KEEPER, |f| {
        let mut vault = f.take_vault();
        let position = vault.position_mut<_, _, _, MockPosition>(&Venue());

        assert_eq!(position.token.value(), 599);
        assert_eq!(position.quote.value(), 299);
        assert_eq!(vault.creator_for_testing(), CREATOR);
        assert_eq!(vault.pool_id(), object::id_from_address(POOL));
        test_scenario::return_shared(vault);
    });
    fixture.end();
}

#[test]
fun fees_pay_blasts_share_rounded_up_and_the_rest_to_the_creator() {
    let mut fixture = start();
    let (_, vault_id) = fixture.open_pool(1);

    fixture.pay_fees(1_001, 501);
    let protocol = PROTOCOL;
    let mut expected = bcs::to_bytes(&vault_id);
    expected.append(bcs::to_bytes(&1_001u64));
    expected.append(bcs::to_bytes(&501u64));
    expected.append(bcs::to_bytes(&protocol));
    expected.append(bcs::to_bytes(&101u64));
    expected.append(bcs::to_bytes(&101u64));
    assert_eq!(bcs::to_bytes(&only_event<PresaleFeesCollected>()), expected);
    assert_eq!(fixture.coin_total<TOKEN>(PROTOCOL), 101);
    assert_eq!(fixture.coin_total<QUOTE>(PROTOCOL), 101);
    // The creator also holds one residual atom of each asset.
    assert_eq!(fixture.coin_total<TOKEN>(CREATOR), 1 + 900);
    assert_eq!(fixture.coin_total<QUOTE>(CREATOR), 1 + 400);
    fixture.end();
}

#[test]
fun an_empty_collection_moves_nothing_and_emits_nothing() {
    let mut fixture = start();
    fixture.open_pool(1);

    fixture.pay_fees(0, 0);
    assert_eq!(event::events_by_type<PresaleFeesCollected>().length(), 0);
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun_migrators::presale_vault::EZeroLiquidity, location = blast_fun_migrators::presale_vault)]
fun a_position_without_liquidity_is_rejected() {
    let mut fixture = start();

    fixture.open_pool(0);
    fixture.end();
}

// === Test Helpers ===

macro fun presale_vault_next_tx(
    $fixture: &mut PresaleVaultFixture,
    $sender: address,
    $fn: |&mut PresaleVaultFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

/// Admits the mock adapter, sets Blast's LP shares, creates the presale, fills it, and finalizes it
/// at the tranche's end.
fun start(): PresaleVaultFixture {
    let mut scenario = test_scenario::begin(PROTOCOL);
    let presale_version = blast_presale::package_version::new_for_testing(scenario.ctx());
    let migrators_version = migrators_version::new_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(START_MS);
    let policy = lp_fee_policy::new_for_testing(scenario.ctx());
    presale_config::init_for_testing(scenario.ctx());
    let (root, mut presale_authority) = acl::new_for_testing<BLAST_PRESALE_DOMAIN>(
        16,
        1,
        scenario.ctx(),
    );
    presale_authority.grant_admin(
        &root,
        blast_presale_domain::adapter_admin_role_for_testing(),
        ADMIN,
        scenario.ctx(),
    );
    destroy(root);
    let (root, mut blast_authority) = acl::new_for_testing<BLAST_FUN_DOMAIN>(16, 1, scenario.ctx());
    blast_authority.grant_admin(&root, blast_fun_domain::fee_admin_role(), ADMIN, scenario.ctx());
    destroy(root);

    scenario.next_tx(ADMIN);
    let mut presale_config = scenario.take_shared<BlastPresaleConfig>();
    let mut policy = policy;
    let admin_caps = test_scenario::ids_for_sender<AdminCap<BLAST_PRESALE_DOMAIN>>(&scenario);
    let presale_cap = scenario
        .take_from_sender_by_id<AdminCap<BLAST_PRESALE_DOMAIN>>(admin_caps[0]);
    let blast_cap = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    presale_config.set_adapter_allowed<Venue>(
        &presale_version,
        &presale_authority.sign_in(&presale_cap),
        true,
    );
    policy.set_default_shares(
        &migrators_version,
        &blast_authority.sign_in(&blast_cap),
        bps::new(1_000),
        bps::new(2_000),
    );
    destroy(presale_cap);
    destroy(blast_cap);
    destroy(presale_authority);
    destroy(blast_authority);

    scenario.next_tx(CREATOR);
    let sale = tranche::new(
        1_000,
        300,
        START_MS,
        END_MS,
        tranche::first_come(),
        tranche::public_access(0),
        0,
    );
    let liquidity = payout::liquidity<TOKEN, QUOTE, _>(Venue(), 60, 2_500, 10_000, 1, 2);
    let presale = presale::new<TOKEN, QUOTE>(
        &presale_version,
        &presale_config,
        coin::mint_for_testing(1_600, scenario.ctx()),
        vector[sale],
        0,
        CLAIM_MS,
        vector[],
        option::some(liquidity),
        &clock,
        scenario.ctx(),
    );
    presale.share();

    scenario.next_tx(BUYER);
    let mut presale = scenario.take_shared<BlastPresale<TOKEN, QUOTE>>();
    let unaccepted = presale.commit(
        &presale_version,
        0,
        coin::mint_for_testing(300, scenario.ctx()),
        &clock,
        scenario.ctx(),
    );
    unaccepted.destroy_zero();
    clock.set_for_testing(END_MS);
    presale.finalize(&presale_version, &presale_config, &clock, scenario.ctx());
    test_scenario::return_shared(presale);

    PresaleVaultFixture {
        scenario,
        presale_version,
        presale_config,
        migrators_version,
        policy,
        clock,
    }
}

/// At the claim time, takes the pool share as the mock adapter, locks a position holding it less
/// one atom of each asset, which returns as the venue's residuals, and reports `liquidity`.
/// Returns the presale's and the new vault's IDs.
fun presale_vault_open_pool(self: &mut PresaleVaultFixture, liquidity: u128): (ID, ID) {
    self.clock.set_for_testing(CLAIM_MS);
    self.scenario.next_tx(KEEPER);
    let mut presale = self.scenario.take_shared<BlastPresale<TOKEN, QUOTE>>();
    let presale_id = object::id(&presale);
    let (mut token, mut quote, _) = presale.take_liquidity(
        &self.presale_version,
        Venue(),
        &self.clock,
    );
    let residual_token = token.split(1);
    let residual_quote = quote.split(1);
    let position = MockPosition { id: object::new(self.scenario.ctx()), token, quote };
    presale_vault::create(
        &presale,
        &Venue(),
        object::id_from_address(POOL),
        position,
        liquidity,
        residual_token,
        residual_quote,
        self.scenario.ctx(),
    );
    test_scenario::return_shared(presale);
    let vault_id = event::events_by_type<PresaleVaultCreated>().map!(|created| {
        let mut fields = sui::bcs::new(bcs::to_bytes(&created));
        object::id_from_address(fields.peel_address())
    });

    (presale_id, vault_id[0])
}

/// Pays one collection of `token` and `quote` fees through the vault.
fun presale_vault_pay_fees(self: &mut PresaleVaultFixture, token: u64, quote: u64) {
    self.scenario.next_tx(KEEPER);
    let vault = self.take_vault();

    vault.pay_fees(
        &self.policy,
        balance::create_for_testing(token),
        balance::create_for_testing(quote),
        self.scenario.ctx(),
    );
    test_scenario::return_shared(vault);
}

fun presale_vault_take_vault(self: &PresaleVaultFixture): BlastPresaleVault<TOKEN, QUOTE> {
    self.scenario.take_shared()
}

/// Sums every `Coin<T>` `owner` holds, in a new transaction.
fun presale_vault_coin_total<T>(self: &mut PresaleVaultFixture, owner: address): u64 {
    self.scenario.next_tx(KEEPER);

    test_scenario::ids_for_address<Coin<T>>(owner).fold!(0, |sum, id| {
        let coin = self.scenario.take_from_address_by_id<Coin<T>>(owner, id);
        let value = coin.value();
        test_scenario::return_to_address(owner, coin);
        sum + value
    })
}

fun type_bytes<T>(): vector<u8> {
    type_name::with_original_ids<T>().into_string().into_bytes()
}

/// This transaction's only event of type `T`, which migrators emit directly.
fun only_event<T: copy + drop>(): T {
    let mut events = event::events_by_type<T>();
    assert_eq!(events.length(), 1);

    events.pop_back()
}

fun presale_vault_end(self: PresaleVaultFixture) {
    destroy(self);
}

// === Imports ===

use blast_admin::acl::{Self, AdminCap};

use blast_fun::{blast_fun_domain::{Self, BLAST_FUN_DOMAIN}, bps};

use blast_fun_migrators::{
    blast_events::{PresaleFeesCollected, PresaleVaultCreated},
    lp_fee_policy::{Self, LpFeePolicy},
    package_version::{Self as migrators_version, PackageVersion as MigratorsVersion},
    presale_vault::{Self, BlastPresaleVault},
};

use blast_presale::{
    blast_presale_domain::{Self, BLAST_PRESALE_DOMAIN},
    package_version::PackageVersion as PresaleVersion,
    payout,
    presale::{Self, BlastPresale},
    presale_config::{Self, BlastPresaleConfig},
    tranche,
};

use std::{bcs, type_name, unit_test::{assert_eq, destroy}};

use sui::{
    balance::{Self, Balance},
    clock::{Self, Clock},
    coin::{Self, Coin},
    event,
    test_scenario::{Self, Scenario},
};

use fun presale_vault_coin_total as PresaleVaultFixture.coin_total;

use fun presale_vault_end as PresaleVaultFixture.end;

use fun presale_vault_next_tx as PresaleVaultFixture.next_tx;

use fun presale_vault_open_pool as PresaleVaultFixture.open_pool;

use fun presale_vault_pay_fees as PresaleVaultFixture.pay_fees;

use fun presale_vault_take_vault as PresaleVaultFixture.take_vault;
