// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
/// Consumer-only launch/vesting composition through the production package interfaces.
module blast_boosts_composition_tests::launch_vesting_composition_tests;

// === Constants ===

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

const ADMIN: address = @0xAD;

const LAUNCHER: address = @0xA11CE;

const CREATOR: address = @0xC0FFEE;

const BENEFICIARY: address = @0xB;

const REFUND_RECIPIENT: address = @0xD;

const SHARE_MS: u64 = 2_000;

const SIX_DECIMAL_SUPPLY: u64 = 1_000_000_000_000_000;

const NINE_DECIMAL_SUPPLY: u64 = 1_000_000_000_000_000_000;

const POOL_TICK_SPACING: u32 = 200;

const POOL_FEE_RATE: u64 = 10_000;

// === Test-Only Types ===

/// Six-decimal fixture currency named by this module's one-time witness; the nine-decimal
/// path uses the actual template.
public struct LAUNCH_VESTING_COMPOSITION_TESTS has drop {}

public struct QUOTE has drop {}

public struct Migration has drop {}

public struct CompositionFixture {
    scenario: Scenario,
    version: PackageVersion,
    config: LaunchConfig,
    runtime: RuntimeConfig,
    clock: Clock,
}

public struct CompositionResult has copy, drop {
    launch_id: ID,
    vesting_id: ID,
    cancel_cap_id: Option<ID>,
    meme_out: u64,
}

public struct ExpectedPreShareBought has copy, drop {
    launch_id: ID,
    quote_in: u64,
    meme_out_gross: u64,
    protocol_meme_fee_delta: u64,
    creator_meme_fee_delta: u64,
    protocol_quote_fee_delta: u64,
    creator_quote_fee_delta: u64,
    post_meme_reserve: u64,
    post_real_quote_reserve: u64,
    meme_out_net: u64,
    quote_refund: u64,
}

public struct ExpectedLaunchShared has copy, drop {
    launch_id: ID,
    public_start_ms: u64,
    pre_share_buy_completed: bool,
}

public struct ExpectedVestingCreated has copy, drop {
    vesting_id: ID,
    coin_type: TypeName,
    funder: address,
    beneficiary: address,
    refund_recipient: Option<address>,
    cancel_cap_id: Option<ID>,
    total_amount: u64,
    start_ms: u64,
    cliff_ms: u64,
    period_ms: u64,
    periods: u64,
}

// === Tests ===

#[test]
fun six_decimal_address_ticket_uses_the_public_generated_currency_constructor() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| f.create_six_decimal_ticket());
    fixture.next_tx!(LAUNCHER, |f| {
        f.assert_ticket_and_currency<LAUNCH_VESTING_COMPOSITION_TESTS>(6);
    });
    fixture.end();
}

#[test]
fun actual_nine_decimal_template_creates_its_account_ticket_and_currency() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| f.create_template_ticket());
    fixture.next_tx!(LAUNCHER, |f| {
        f.assert_ticket_and_currency<TemplateProject>(9);
    });
    fixture.end();
}

#[test]
fun six_decimal_pre_buy_vests_atomically_while_a_distinct_address_creator_claims_caps_later() {
    let mut fixture = start();
    let result;
    fixture.next_tx!(LAUNCHER, |f| f.create_six_decimal_ticket());
    fixture.next_tx!(LAUNCHER, |f| {
        result = f.compose_and_share<LAUNCH_VESTING_COMPOSITION_TESTS>(SIX_DECIMAL_SUPPLY, false);
    });
    fixture.next_tx!(CREATOR, |f| {
        f.claim_creator_caps<LAUNCH_VESTING_COMPOSITION_TESTS>(result, option::none());
    });
    fixture.next_tx!(CREATOR, |f| {
        f.assert_delivered_caps<LAUNCH_VESTING_COMPOSITION_TESTS>(result);
        f.complete_irrevocable<LAUNCH_VESTING_COMPOSITION_TESTS>(result);
    });
    fixture.next_tx!(BENEFICIARY, |f| {
        f.assert_payment<LAUNCH_VESTING_COMPOSITION_TESTS>(result.meme_out);
    });
    fixture.end();
}

#[test]
fun actual_template_account_creator_claims_exact_escrowed_cap_after_irrevocable_composition() {
    let mut fixture = start();
    let result;
    fixture.next_tx!(LAUNCHER, |f| f.create_template_ticket());
    fixture.next_tx!(LAUNCHER, |f| {
        result = f.compose_and_share<TemplateProject>(NINE_DECIMAL_SUPPLY, false);
    });
    fixture.next_tx!(CREATOR, |f| {
        f.claim_creator_caps<TemplateProject>(result, option::some(account_attestation()));
    });
    fixture.next_tx!(CREATOR, |f| {
        f.assert_delivered_caps<TemplateProject>(result);
        f.complete_irrevocable<TemplateProject>(result);
    });
    fixture.next_tx!(
        BENEFICIARY,
        |f| f.assert_payment<TemplateProject>(result.meme_out),
    );
    fixture.end();
}

#[test]
fun cancelable_composition_delivers_cancel_cap_and_preserves_beneficiary_refund_split() {
    let mut fixture = start();
    let result;
    fixture.next_tx!(LAUNCHER, |f| f.create_six_decimal_ticket());
    fixture.next_tx!(LAUNCHER, |f| {
        result = f.compose_and_share<LAUNCH_VESTING_COMPOSITION_TESTS>(SIX_DECIMAL_SUPPLY, true);
    });
    fixture.next_tx!(CREATOR, |f| {
        f.claim_creator_caps<LAUNCH_VESTING_COMPOSITION_TESTS>(result, option::none());
    });
    fixture.next_tx!(CREATOR, |f| {
        f.assert_delivered_caps<LAUNCH_VESTING_COMPOSITION_TESTS>(result);
        f.cancel_half_vested<LAUNCH_VESTING_COMPOSITION_TESTS>(result);
    });
    fixture.next_tx!(BENEFICIARY, |f| {
        f.assert_payment<LAUNCH_VESTING_COMPOSITION_TESTS>(result.meme_out / 2);
    });
    fixture.next_tx!(REFUND_RECIPIENT, |f| {
        f.assert_payment<LAUNCH_VESTING_COMPOSITION_TESTS>(result.meme_out - result.meme_out / 2);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = 9, location = blast_fun::creator_authority)]
fun launcher_cannot_claim_a_distinct_address_creators_escrowed_caps() {
    let mut fixture = start();
    let result;
    fixture.next_tx!(LAUNCHER, |f| f.create_six_decimal_ticket());
    fixture.next_tx!(LAUNCHER, |f| {
        result = f.compose_and_share<LAUNCH_VESTING_COMPOSITION_TESTS>(SIX_DECIMAL_SUPPLY, false);
    });
    fixture.next_tx!(LAUNCHER, |f| {
        f.claim_creator_caps<LAUNCH_VESTING_COMPOSITION_TESTS>(result, option::none());
    });
    fixture.end();
}

#[test, expected_failure(abort_code = 2, location = blast_fun::runtime_config)]
fun launcher_cannot_reuse_an_account_attestation_bound_to_the_creator_wallet() {
    let mut fixture = start();
    let result;
    fixture.next_tx!(LAUNCHER, |f| f.create_template_ticket());
    fixture.next_tx!(LAUNCHER, |f| {
        result = f.compose_and_share<TemplateProject>(NINE_DECIMAL_SUPPLY, false);
    });
    fixture.next_tx!(LAUNCHER, |f| {
        f.claim_creator_caps<TemplateProject>(result, option::some(account_attestation()));
    });
    fixture.end();
}

// === Test Helpers ===

macro fun next_tx(
    $fixture: &mut CompositionFixture,
    $sender: address,
    $fn: |&mut CompositionFixture|,
) {
    let fixture = $fixture;
    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

fun start(): CompositionFixture {
    let mut scenario = test_scenario::begin(@0x0);
    let version = package_version::new_for_testing(scenario.ctx());
    let mut config = launch_config::new_for_testing(scenario.ctx());
    let mut runtime = runtime_config::new_disabled_for_testing(scenario.ctx());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000);
    let (root, mut authority) = acl::new_for_testing<BLAST_FUN_DOMAIN>(
        16,
        604_800_000,
        scenario.ctx(),
    );
    authority.grant_admin(&root, 0, ADMIN, scenario.ctx());
    scenario.next_tx(ADMIN);
    let admin = scenario.take_from_sender<AdminCap<BLAST_FUN_DOMAIN>>();
    let witness = authority.sign_in(&admin);
    config.allow_quote<QUOTE>(&version, &witness, 5_000_000);
    config.allow_migration_witness<Migration>(&version, &witness);
    config.set_protocol_allocation(&version, &witness, 1, CREATOR, bps::new(0), bps::new(0));
    config.set_trade_fees(&version, &witness, bps::new(100), bps::new(200));
    runtime.set_protocol_fee_share(&version, &witness, bps::new(1_000));
    runtime.set_creator_claim_signer(&version, &witness, signer_public_key());
    destroy(admin);
    destroy(authority);
    destroy(root);
    CompositionFixture { scenario, version, config, runtime, clock }
}

fun end(self: CompositionFixture) {
    let CompositionFixture { scenario, version, config, runtime, clock } = self;
    destroy(version);
    destroy(config);
    destroy(runtime);
    clock.destroy_for_testing();
    scenario.end();
}

fun create_six_decimal_ticket(self: &mut CompositionFixture) {
    let ticket = launch_ticket::new(
        test_utils::create_one_time_witness<LAUNCH_VESTING_COMPOSITION_TESTS>(),
        6,
        b"SIX".to_string(),
        b"Six decimal fixture".to_string(),
        b"Public launch and vesting composition".to_string(),
        b"".to_string(),
        creator_authority::new_address(CREATOR),
        false,
        0,
        self.scenario.ctx(),
    );
    transfer::public_transfer(ticket, LAUNCHER);
}

/// The template's initializer delivers its ticket to the publishing sender.
fun create_template_ticket(self: &mut CompositionFixture) {
    meme::init_for_testing(self.scenario.ctx());
}

fun compose_and_share<Meme>(
    self: &mut CompositionFixture,
    supply: u64,
    cancelable: bool,
): CompositionResult {
    self.clock.set_for_testing(SHARE_MS);
    let ticket = self.scenario.take_from_sender<LaunchTicket<Meme>>();
    let mut currency = self.scenario.take_from_address<Currency<Meme>>(COIN_REGISTRY);
    let mut initializer = launch::new<_, QUOTE, _>(
        ticket,
        &self.version,
        &self.config,
        Migration {},
        POOL_TICK_SPACING,
        POOL_FEE_RATE,
    );
    initializer.set_graduation_target(25_000_000);
    initializer.set_allocation_plan(allocation_plan());
    initializer.set_lp_fee_split(fee_split());
    let mut launch = initializer.finalize(
        &self.version,
        &mut currency,
        &self.config,
        self.scenario.ctx(),
    );
    assert!(currency.is_supply_fixed());
    assert_eq!(currency.total_supply().destroy_some(), supply);
    test_scenario::return_to_address(COIN_REGISTRY, currency);
    assert!(launch.public_start_ms_for_testing().is_none());
    assert!(!launch.pre_share_buy_completed_for_testing());
    assert_eq!(launch.lp_fee_split(), fee_split());
    let (tick_spacing, fee_rate) = launch.pool_tier();
    assert_eq!(tick_spacing, POOL_TICK_SPACING);
    assert_eq!(fee_rate, POOL_FEE_RATE);
    let launch_id = object::id(&launch);
    let quote = coin::mint_for_testing<QUOTE>(1_000_000, self.scenario.ctx());
    let (meme, refund) = launch.pre_share_buy(
        &self.version,
        &self.runtime,
        quote,
        1,
        self.scenario.ctx(),
    );
    assert_eq!(refund.value(), 0);
    refund.destroy_zero();
    let meme_out = meme.value();
    assert_buy(launch_id, supply, meme_out);
    assert!(launch.public_start_ms_for_testing().is_none());
    assert!(launch.pre_share_buy_completed_for_testing());
    let (vesting, cancel_cap_id) = if (cancelable) {
        let (vesting, cap) = linear_vesting::new_cancelable(
            meme,
            BENEFICIARY,
            REFUND_RECIPIENT,
            SHARE_MS,
            0,
            1_000,
            2,
            &self.clock,
            self.scenario.ctx(),
        );
        let cap_id = object::id(&cap);
        transfer::public_transfer(cap, CREATOR);
        (vesting, option::some(cap_id))
    } else {
        (
            linear_vesting::new_irrevocable(
                meme,
                BENEFICIARY,
                SHARE_MS,
                0,
                1_000,
                2,
                &self.clock,
                self.scenario.ctx(),
            ),
            option::none(),
        )
    };
    let vesting_id = object::id(&vesting);
    let mut created = sui::event::events_by_type<linear_vesting::VestingCreated>();
    assert_eq!(created.length(), 1);
    assert_eq!(
        bcs::to_bytes(&created.pop_back()),
        bcs::to_bytes(
            &ExpectedVestingCreated {
                vesting_id,
                coin_type: type_name::with_original_ids<Meme>(),
                funder: LAUNCHER,
                beneficiary: BENEFICIARY,
                refund_recipient: if (cancelable) option::some(REFUND_RECIPIENT)
                else option::none(),
                cancel_cap_id,
                total_amount: meme_out,
                start_ms: SHARE_MS,
                cliff_ms: 0,
                period_ms: 1_000,
                periods: 2,
            },
        ),
    );
    vesting.share();
    launch.share(&self.version, &self.clock);
    assert_eq!(
        bcs::to_bytes(&events::collect_one<events::LaunchShared>(0)),
        bcs::to_bytes(
            &ExpectedLaunchShared {
                launch_id,
                public_start_ms: SHARE_MS,
                pre_share_buy_completed: true,
            },
        ),
    );
    CompositionResult {
        launch_id,
        vesting_id,
        cancel_cap_id,
        meme_out,
    }
}

fun claim_creator_caps<Meme>(
    self: &mut CompositionFixture,
    result: CompositionResult,
    attestation: Option<vector<u8>>,
) {
    let mut launch = self.scenario.take_shared<Launch<Meme, QUOTE>>();
    assert_eq!(object::id(&launch), result.launch_id);
    assert_eq!(launch.public_start_ms_for_testing(), option::some(SHARE_MS));
    assert!(launch.pre_share_buy_completed_for_testing());
    let (curve, metadata) = launch.claim_creator_caps(
        &self.version,
        &self.runtime,
        attestation,
        &self.clock,
        self.scenario.ctx(),
    );
    transfer::public_transfer(curve, CREATOR);
    transfer::public_transfer(metadata, CREATOR);
    test_scenario::return_shared(launch);
}

/// The delivered curve-fee cap is the one the launch honors, including for LP-fee route updates.
fun assert_delivered_caps<Meme>(self: &CompositionFixture, result: CompositionResult) {
    let curve = self.scenario.take_from_sender<CurveFeeCap<Meme>>();
    let metadata = self.scenario.take_from_sender<BlastMetadataCap<Meme>>();
    let launch = self.scenario.take_shared<Launch<Meme, QUOTE>>();
    assert_eq!(object::id(&launch), result.launch_id);
    launch.assert_curve_fee_cap(&curve);
    assert_eq!(launch.blast_metadata_cap_id_for_testing(), option::some(object::id(&metadata)));
    test_scenario::return_shared(launch);
    test_scenario::return_to_sender(&self.scenario, curve);
    test_scenario::return_to_sender(&self.scenario, metadata);
}

fun complete_irrevocable<Meme>(self: &mut CompositionFixture, result: CompositionResult) {
    self.clock.set_for_testing(SHARE_MS + 2_000);
    let mut vesting = self.scenario.take_shared<Vesting<Meme>>();
    assert_eq!(object::id(&vesting), result.vesting_id);
    vesting.claim(&self.clock, self.scenario.ctx());
    vesting.close_irrevocable(&self.clock, self.scenario.ctx());
}

fun cancel_half_vested<Meme>(self: &mut CompositionFixture, result: CompositionResult) {
    self.clock.set_for_testing(SHARE_MS + 1_000);
    let vesting = self.scenario.take_shared<Vesting<Meme>>();
    let cap = self.scenario.take_from_sender<CancelCap<Meme>>();
    assert_eq!(object::id(&vesting), result.vesting_id);
    assert_eq!(option::some(object::id(&cap)), result.cancel_cap_id);
    vesting.cancel(cap, &self.clock, self.scenario.ctx());
}

fun assert_payment<Meme>(self: &CompositionFixture, amount: u64) {
    let funds = self.scenario.take_from_sender<Coin<Meme>>();
    assert_eq!(funds.value(), amount);
    coin::burn_for_testing(funds);
}

fun assert_buy(launch_id: ID, supply: u64, meme_out: u64) {
    let curve = supply * 8 / 10;
    let meme_out_gross = ((curve as u128) * 990_000 / 5_990_000) as u64;
    let meme_fee = (((meme_out_gross as u128) * 200 + 9_999) / 10_000) as u64;
    let protocol_meme = (((meme_fee as u128) * 1_000 + 9_999) / 10_000) as u64;
    assert_eq!(meme_out, meme_out_gross - meme_fee);
    assert_eq!(
        bcs::to_bytes(&events::collect_one<events::PreShareBought>(0)),
        bcs::to_bytes(
            &ExpectedPreShareBought {
                launch_id,
                quote_in: 1_000_000,
                meme_out_gross,
                protocol_meme_fee_delta: protocol_meme,
                creator_meme_fee_delta: meme_fee - protocol_meme,
                protocol_quote_fee_delta: 1_000,
                creator_quote_fee_delta: 9_000,
                post_meme_reserve: curve - meme_out_gross,
                post_real_quote_reserve: 990_000,
                meme_out_net: meme_out,
                quote_refund: 0,
            },
        ),
    );
}

fun allocation_plan(): AllocationPlan {
    allocation::new(
        vector[
            allocation::channel(2, allocation::liquidity_role(), CREATOR),
            allocation::channel(3, allocation::external_role(), CREATOR),
        ],
        vector[
            allocation::weight(0, bps::new(8_000)),
            allocation::weight(2, bps::new(1_000)),
            allocation::weight(3, bps::new(1_000)),
        ],
        vector[allocation::weight(2, bps::new(9_000)), allocation::weight(3, bps::new(1_000))],
    )
}

fun fee_split(): allocation::FeeSplit {
    allocation::fee_split(
        bps::new(5_000),
        bps::new(0),
        bps::new(0),
        vector[allocation::route(CREATOR, bps::new(5_000))],
    )
}

/// Independently signed canonical BCS for the actual template's account, its `MEME` type,
/// CREATOR claimant, and expiry 10_000, using the public fixture seed [42; 32].
/// The resolver assigns distinct original IDs to dependency packages in unit tests;
/// pin the template identity explicitly so a dependency-address change requires a new vector.
fun account_attestation(): vector<u8> {
    assert_eq!(type_name::original_id<TemplateProject>(), @0xcd80);
    let mut attestation = bcs::to_bytes(&10_000u64);
    attestation.push_back(64);
    attestation.append(
        x"bd6c2e787da3bbcfbebf50f8c3039d565b33667957f1f0576721bf2c6be87c7ffd9b010f8d09f056ebaf347dfdd82adb32bee54a81cefcadeac2d0f00bba2e07",
    );
    attestation
}

/// The supply mode stays open until launch intake, where `compose_and_share` checks it.
fun assert_ticket_and_currency<Meme>(self: &CompositionFixture, decimals: u8) {
    let ticket = self.scenario.take_from_sender<LaunchTicket<Meme>>();
    test_scenario::return_to_sender(&self.scenario, ticket);
    let currency = self.scenario.take_from_address<Currency<Meme>>(COIN_REGISTRY);
    assert_eq!(currency.decimals(), decimals);
    assert!(currency.total_supply().is_none());
    test_scenario::return_to_address(COIN_REGISTRY, currency);
}

/// Public test vector derived from the documented, non-secret Ed25519 seed [42; 32].
fun signer_public_key(): vector<u8> {
    x"197f6b23e16c8532c6abc838facd5ea789be0c76b2920334039bfa8b3d368d61"
}

// === Imports ===

use blast_admin::acl::{Self, AdminCap};

use blast_fun::{
    allocation::{Self, AllocationPlan},
    blast_fun_domain::BLAST_FUN_DOMAIN,
    bps,
    creator_authority::{Self, BlastMetadataCap, CurveFeeCap},
    events,
    launch::{Self, Launch},
    launch_config::{Self, LaunchConfig},
    launch_ticket::{Self, LaunchTicket},
    package_version::{Self, PackageVersion},
    runtime_config::{Self, RuntimeConfig}
};

use blast_fun_vesting::blast_fun_linear_vesting::{Self as linear_vesting, CancelCap, Vesting};

use meme_template::meme::{Self, MEME as TemplateProject};

use std::{bcs, type_name::{Self, TypeName}, unit_test::{assert_eq, destroy}};

use sui::{
    clock::{Self, Clock},
    coin::{Self, Coin},
    coin_registry::Currency,
    test_scenario::{Self, Scenario},
    test_utils
};
