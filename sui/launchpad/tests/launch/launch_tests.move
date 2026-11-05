// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

#[test_only]
module blast_fun::launch_tests;

// === Constants ===

/// `sui::object::sui_coin_registry_address()`, where one-time-witness currencies are delivered.
const COIN_REGISTRY: address = @0xc;

const LAUNCHER: address = @0xB1A57;

const CREATOR: address = @0xC0FFEE;

const PROTOCOL_ADMIN: address = @0xAD;

/// Where the fixture partner is paid.
const PARTNER: address = @0x9A27;

/// Where the fixture pays Blast's fees.
const TREASURY: address = @0x7EA5;

/// The fixture partner's share of Blast's fees: 40%.
const PARTNER_SHARE_BPS: u64 = 4_000;

/// A creation fee whose partner share rounds down: 40% of it is 400.4 MIST.
const CREATION_FEE: u64 = 1_001;

const ALICE: address = @0xA11CE;

const BOB: address = @0xB0B;

const NEW_CREATOR: address = @0xC7;

const MEME_DECIMALS: u8 = 9;

const INITIAL_MEME_SUPPLY: u64 = 1_000_000_000__000_000_000;

const VIRTUAL_QUOTE: u64 = 5_000_000;

const MIGRATION_QUOTE_TARGET: u64 = 25_000_000;


const QUOTE_FEE_BPS: u64 = 100;

const MEME_FEE_BPS: u64 = 250;

const SELL_BURN_BPS: u64 = 1_000;

/// Blast's allocation in the launch configuration.
const PROTOCOL_MEME_BPS: u64 = 750;

const PROTOCOL_QUOTE_BPS: u64 = 250;

/// The default creator plan: the curve and the pool take everything Blast does not.
const CURVE_MEME_BPS: u64 = 7_250;

const LP_MEME_BPS: u64 = 2_000;

const LP_QUOTE_BPS: u64 = 9_750;

const EXPECTED_CURVE_MEME: u64 = 725_000_000__000_000_000;

const EXPECTED_PROTOCOL_MEME: u64 = 75_000_000__000_000_000;

const EXPECTED_POOL_MEME: u64 = 200_000_000__000_000_000;

/// Blast's share of `MIGRATION_QUOTE_TARGET`.
const EXPECTED_PROTOCOL_QUOTE: u64 = 625_000;

/// The core treasury's applied delay for a destination change.
const TREASURY_DELAY_MS: u64 = 48 * 60 * 60 * 1_000;

// === Test-Only Types ===

/// This module's one-time witness stands in for a generated package's.
public struct LAUNCH_TESTS has drop {}

public struct TEST_QUOTE() has drop;

public struct OTHER_QUOTE() has drop;

/// The venue every fixture launch migrates to.
public struct TestVenue() has drop;

/// A venue the fixture configuration never admits.
public struct OtherVenue() has drop;

/// Launch construction through configured cold policy and creator custody.
/// One creator-cap proposal as the primitive records it; no recipient means a delay change.
public struct CapProposal has copy, drop {
    owner: ID,
    recipient: Option<address>,
    delay_ms: u64,
    ready_at_ms: u64,
}

public struct LaunchFixture {
    scenario: Scenario,
    package_version: PackageVersion<BLAST_FUN>,
    registry: LaunchRegistry,
    config: LaunchConfig,
    runtime_config: RuntimeConfig,
    treasury: Treasury,
    clock: Clock,
}

// === Tests ===

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun security_curve_fee_cap_early() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_233);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun security_curve_fee_cap_replacement() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            BOB,
            &f.clock
        );
        f.clock.set_for_testing(345_601_233);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun security_curve_fee_cap_replacement_exact_ready() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            BOB,
            &f.clock
        );
        f.clock.set_for_testing(345_601_234);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        let cap_id = launch.curve_fee_cap_id_for_testing().destroy_some();
        assert_eq!(
            bcs::to_bytes(&collect_one<CurveFeeCapReassigned<LAUNCH_TESTS, TEST_QUOTE>>()),
            cap_reassigned_bytes(object::id(&launch), cap_id, BOB)
        );
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_action)]
fun security_curve_fee_cap_cancelled() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        launch.cancel_curve_fee_cap_reassignment(
            &f.package_version,
            &blast_acl::witness_for_testing<CancelAdmin>()
        );
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_action)]
fun security_curve_fee_cap_replay() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun security_curve_fee_cap_stale_schedule() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        f.package_version.set_version_for_testing(2);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun security_curve_fee_cap_stale_apply() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        f.package_version.set_version_for_testing(2);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun security_curve_fee_cap_stale_cancel() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        f.package_version.set_version_for_testing(2);
        launch.cancel_curve_fee_cap_reassignment(
            &f.package_version,
            &blast_acl::witness_for_testing<CancelAdmin>()
        );
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun security_curve_fee_cap_exact_ready() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        let cap_id = launch.curve_fee_cap_id_for_testing().destroy_some();
        assert_eq!(
            bcs::to_bytes(&collect_one<CurveFeeCapReassigned<LAUNCH_TESTS, TEST_QUOTE>>()),
            cap_reassigned_bytes(object::id(&launch), cap_id, NEW_CREATOR)
        );
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun security_curve_fee_cap_after_ready() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_235);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        let cap_id = launch.curve_fee_cap_id_for_testing().destroy_some();
        assert_eq!(
            bcs::to_bytes(&collect_one<CurveFeeCapReassigned<LAUNCH_TESTS, TEST_QUOTE>>()),
            cap_reassigned_bytes(object::id(&launch), cap_id, NEW_CREATOR)
        );
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun security_curve_fee_cap_cancel_reschedule() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        launch.cancel_curve_fee_cap_reassignment(
            &f.package_version,
            &blast_acl::witness_for_testing<CancelAdmin>()
        );
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            BOB,
            &f.clock
        );
        f.clock.set_for_testing(345_601_234);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        let cap_id = launch.curve_fee_cap_id_for_testing().destroy_some();
        assert_eq!(
            bcs::to_bytes(&collect_one<CurveFeeCapReassigned<LAUNCH_TESTS, TEST_QUOTE>>()),
            cap_reassigned_bytes(object::id(&launch), cap_id, BOB)
        );
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun security_creator_metadata_cap_early() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_233);
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun security_creator_metadata_cap_replacement() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            BOB,
            &f.clock
        );
        f.clock.set_for_testing(345_601_233);
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun security_creator_metadata_cap_replacement_exact_ready() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            BOB,
            &f.clock
        );
        f.clock.set_for_testing(345_601_234);
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        let cap_id = launch.creator_metadata_cap_id_for_testing().destroy_some();
        assert_eq!(
            bcs::to_bytes(&collect_one<CreatorMetadataCapReassigned<LAUNCH_TESTS, TEST_QUOTE>>()),
            cap_reassigned_bytes(object::id(&launch), cap_id, BOB)
        );
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_action)]
fun security_creator_metadata_cap_cancelled() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        launch.cancel_creator_metadata_cap_reassignment(
            &f.package_version,
            &blast_acl::witness_for_testing<CancelAdmin>()
        );
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENoPending, location = blast_admin::delayed_action)]
fun security_creator_metadata_cap_replay() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun security_creator_metadata_cap_stale_schedule() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        f.package_version.set_version_for_testing(2);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun security_creator_metadata_cap_stale_apply() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        f.package_version.set_version_for_testing(2);
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun security_creator_metadata_cap_stale_cancel() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        f.package_version.set_version_for_testing(2);
        launch.cancel_creator_metadata_cap_reassignment(
            &f.package_version,
            &blast_acl::witness_for_testing<CancelAdmin>()
        );
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun security_creator_metadata_cap_exact_ready() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        let cap_id = launch.creator_metadata_cap_id_for_testing().destroy_some();
        assert_eq!(
            bcs::to_bytes(&collect_one<CreatorMetadataCapReassigned<LAUNCH_TESTS, TEST_QUOTE>>()),
            cap_reassigned_bytes(object::id(&launch), cap_id, NEW_CREATOR)
        );
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun security_creator_metadata_cap_after_ready() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_235);
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        let cap_id = launch.creator_metadata_cap_id_for_testing().destroy_some();
        assert_eq!(
            bcs::to_bytes(&collect_one<CreatorMetadataCapReassigned<LAUNCH_TESTS, TEST_QUOTE>>()),
            cap_reassigned_bytes(object::id(&launch), cap_id, NEW_CREATOR)
        );
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun security_creator_metadata_cap_cancel_reschedule() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.clock.set_for_testing(1234);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_801_234);
        launch.cancel_creator_metadata_cap_reassignment(
            &f.package_version,
            &blast_acl::witness_for_testing<CancelAdmin>()
        );
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            BOB,
            &f.clock
        );
        f.clock.set_for_testing(345_601_234);
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        let cap_id = launch.creator_metadata_cap_id_for_testing().destroy_some();
        assert_eq!(
            bcs::to_bytes(&collect_one<CreatorMetadataCapReassigned<LAUNCH_TESTS, TEST_QUOTE>>()),
            cap_reassigned_bytes(object::id(&launch), cap_id, BOB)
        );
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun security_pause_blocks_new() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        f.pause(1);
        destroy(f.start_launch<TEST_QUOTE, _>(ticket, TestVenue()));
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun security_partial_unpause_keeps_new_paused() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        f.pause(7);
        f.clear_pause_bits(2);
        destroy(f.start_launch<TEST_QUOTE, _>(ticket, TestVenue()));
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun security_pause_blocks_finalize() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let ticket = f.new_ticket(CREATOR);
        let initializer = f.configured_initializer(ticket);
        f.pause(1);
        destroy(f.finalize_launch(initializer));
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun security_pause_blocks_share() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        f.pause(1);
        f.share_launch(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun security_pause_blocks_migrate() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.graduate(&mut launch);
        f.pause(4);
        f.migrate(&mut launch);
        launch.put_back();
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun security_partial_unpause_keeps_migrate_paused() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.graduate(&mut launch);
        f.pause(7);
        f.clear_pause_bits(2);
        f.migrate(&mut launch);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun security_old_creator_claims_during_delay_and_new_cap_gets_only_remaining_fees() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (old_cap, metadata) = f.claim(&mut launch);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        let (meme, refund) = f.buy(&mut launch, 1_000_000, 1);
        destroy(meme);
        destroy(refund);
        let (_, expected_meme, _, expected_quote) = launch.fee_totals_for_testing();
        assert!(expected_meme > 0 && expected_quote > 0);
        let (meme, quote) = launch.claim_creator_fees(&f.package_version, &old_cap, f.ctx!());
        assert_eq!(meme.value(), expected_meme);
        assert_eq!(quote.value(), expected_quote);
        destroy(meme);
        destroy(quote);
        let (_, remaining_meme, _, remaining_quote) = launch.fee_totals_for_testing();
        assert_eq!(vector[remaining_meme, remaining_quote], vector[0, 0]);
        let (meme, refund) = f.buy(&mut launch, 2_000_000, 1);
        destroy(meme);
        destroy(refund);
        f.clock.set_for_testing(172_800_000);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        destroy(old_cap);
        destroy(metadata);
        launch.put_back();
    });
    fixture.next_tx!(NEW_CREATOR, |f| {
        let mut launch = f.take_launch();
        let cap = f.take_curve_fee_cap();
        let (_, expected_meme, _, expected_quote) = launch.fee_totals_for_testing();
        assert!(expected_meme > 0 && expected_quote > 0);
        // The exit remains usable even with every pause bit set.
        f.pause(7);
        let (meme, quote) = launch.claim_creator_fees(&f.package_version, &cap, f.ctx!());
        assert_eq!(meme.value(), expected_meme);
        assert_eq!(quote.value(), expected_quote);
        let (_, remaining_meme, _, remaining_quote) = launch.fee_totals_for_testing();
        assert_eq!(vector[remaining_meme, remaining_quote], vector[0, 0]);
        destroy(meme);
        destroy(quote);
        destroy(cap);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun security_fully_paused_creator_caps_can_still_be_claimed() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.pause(7);
        let (fee, metadata) = f.claim(&mut launch);
        assert_eq!(launch.curve_fee_cap_id_for_testing(), option::some(object::id(&fee)));
        assert_eq!(launch.creator_metadata_cap_id_for_testing(), option::some(object::id(&metadata)));
        destroy(fee);
        destroy(metadata);
        launch.put_back();
    });
    fixture.end();
}

#[test]
fun security_metadata_authority_stays_live_until_reassignment() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (fee, old_metadata) = f.claim(&mut launch);
        let mut currency = f.take_currency();
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_799_999);
        launch.set_name(
            &f.package_version,
            &old_metadata,
            &mut currency,
            b"During delay".to_string()
        );
        assert_eq!(currency.name(), b"During delay".to_string());
        f.clock.set_for_testing(172_800_000);
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        assert!(
            launch.creator_metadata_cap_id_for_testing().destroy_some() != object::id(&old_metadata)
        );
        destroy(fee);
        destroy(old_metadata);
        f.return_currency(currency);
        launch.put_back();
    });
    fixture.next_tx!(NEW_CREATOR, |f| {
        let launch = f.take_launch();
        let metadata = f.take_creator_metadata_cap();
        let mut currency = f.take_currency();
        launch.set_name(&f.package_version, &metadata, &mut currency, b"After delay".to_string());
        assert_eq!(currency.name(), b"After delay".to_string());
        destroy(metadata);
        destroy(currency);
        launch.put_back();
    });
    fixture.end();
}


#[test]
#[expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun trading_pause_blocks_buy_before_coin_validation() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.pause(constants::trading_pause_bit!());
        let (meme, refund) = f.buy(&mut launch, 0, 0);
        destroy(meme);
        destroy(refund);
        destroy(launch);
    });
    fixture.end();
}


#[test]
#[expected_failure(abort_code = blast_admin::errors::EPaused, location = blast_admin::package_version)]
fun trading_pause_blocks_sell_before_lifecycle_and_coin_validation() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.pause(constants::trading_pause_bit!());
        let meme = coin::zero<LAUNCH_TESTS>(f.ctx!());
        let quote = launch.sell(&f.package_version, &f.runtime_config, meme, 0, f.ctx!());
        destroy(quote);
        destroy(launch);
    });
    fixture.end();
}

#[test]
fun clearing_trading_restores_buy_and_sell_while_migration_stays_paused() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.pause(constants::trading_pause_bit!() | constants::migration_pause_bit!());
        f.clear_pause_bits(constants::trading_pause_bit!());

        let (meme, refund) = f.buy(&mut launch, 1_000_000, 1);
        assert!(meme.value() > 0);
        let quote = launch.sell(&f.package_version, &f.runtime_config, meme, 1, f.ctx!());
        assert!(quote.value() > 0);

        destroy(refund);
        destroy(quote);
        destroy(launch);
    });
    fixture.end();
}

// --- Construction ---

#[test]
fun finalize_snapshots_the_config_and_emits_launch_created() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let ticket_id = object::id(&ticket);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TestVenue(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        assert_eq!(
            bcs::to_bytes(&collect_one<LaunchCreated<LAUNCH_TESTS, TEST_QUOTE>>()),
            launch_created_bytes(object::id(&launch), ticket_id),
        );
        assert_eq!(launch.sell_burn_bps_for_testing(), SELL_BURN_BPS);
        assert_eq!(launch.atomic_supply_for_testing(), INITIAL_MEME_SUPPLY);
        launch.assert_lifecycle(true, false, false);
        launch.assert_snapshot();

        destroy(launch);
    });

    fixture.end();
}

#[test]
fun a_launch_id_derives_from_the_registry_and_its_coin_type() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);

        let key = launch::launch_key_for_testing<LAUNCH_TESTS>();
        let derived = derived_object::derive_address(object::id(&f.registry), key);
        assert_eq!(object::id(&launch), object::id_from_address(derived));
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = sui::derived_object::EObjectAlreadyExists, location = sui::derived_object)]
fun a_second_launch_of_the_same_coin_type_is_rejected() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let first = f.new_default_launch(CREATOR);

        let second = f.new_default_launch(CREATOR);

        destroy(first);
        destroy(second);
    });

    fixture.end();
}

#[test]
fun burn_only_ticket_keeps_supply_mode_authoritative_in_coin_registry() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, true);
        let ticket_id = object::id(&ticket);
        let metadata_cap_id = ticket.metadata_cap_id_for_testing();
        let ticket_created = collect_one<LaunchTicketCreated<LAUNCH_TESTS>>();
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TestVenue(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        assert_eq!(launch.metadata_cap_id_for_testing(), metadata_cap_id);
        assert_eq!(
            bcs::to_bytes(&ticket_created),
            ticket_created_bytes(ticket_id, metadata_cap_id, true),
        );
        launch.assert_snapshot();

        destroy(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let currency = f.take_currency();

        assert!(!currency.is_supply_fixed());
        assert!(currency.is_supply_burn_only());

        destroy(currency);
    });

    fixture.end();
}

#[test]
fun launch_snapshot_does_not_follow_later_config_updates() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let launch = f.new_default_launch(CREATOR);
        f.config.set_quote_allowed<TEST_QUOTE>(&f.package_version, &listing_admin(), false);
        f.config.set_trade_fees_for_testing(&f.package_version, &fee_admin(), bps::new(0), bps::new(0), f.ctx!());

        launch.assert_snapshot();

        destroy(launch);
    });

    fixture.end();
}

#[test]
fun launch_stores_the_venue_that_issued_its_ticket() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);

        assert_eq!(launch.venue_for_testing(), type_name::with_original_ids<TestVenue>());

        destroy(launch);
    });

    fixture.end();
}

#[test]
fun later_setter_calls_replace_earlier_settings() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TestVenue());
        let routes = launcher_fee_split();
        initializer.set_virtual_quote(&f.package_version, VIRTUAL_QUOTE);
        initializer.set_graduation_target(&f.package_version, MIGRATION_QUOTE_TARGET * 2);
        initializer.set_graduation_target(&f.package_version, MIGRATION_QUOTE_TARGET);
        initializer.set_allocation_plan(&f.package_version, external_plan());
        initializer.set_allocation_plan(&f.package_version, default_plan());
        initializer.set_lp_fee_split(&f.package_version, default_fee_split());
        initializer.set_lp_fee_split(&f.package_version, routes);
        let launch = f.finalize_launch(initializer);

        launch.assert_snapshot();

        let mut launch = f.open_launch(launch);
        f.graduate(&mut launch);

        assert_eq!(f.migrate(&mut launch).fee_split(), routes);

        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun finalize_requires_a_graduation_target() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TestVenue());
        initializer.set_virtual_quote(&f.package_version, VIRTUAL_QUOTE);
        initializer.set_allocation_plan(&f.package_version, default_plan());
        initializer.set_lp_fee_split(&f.package_version, default_fee_split());

        destroy(f.finalize_launch(initializer));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun finalize_requires_a_virtual_quote() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TestVenue());
        initializer.set_graduation_target(&f.package_version, MIGRATION_QUOTE_TARGET);
        initializer.set_allocation_plan(&f.package_version, default_plan());
        initializer.set_lp_fee_split(&f.package_version, default_fee_split());

        destroy(f.finalize_launch(initializer));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidVirtualQuote, location = blast_fun::launch)]
fun finalize_rejects_a_zero_virtual_quote() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TestVenue());
        initializer.set_virtual_quote(&f.package_version, 0);
        initializer.set_graduation_target(&f.package_version, MIGRATION_QUOTE_TARGET);
        initializer.set_allocation_plan(&f.package_version, default_plan());
        initializer.set_lp_fee_split(&f.package_version, default_fee_split());

        destroy(f.finalize_launch(initializer));
    });

    fixture.end();
}

#[test]
fun the_creator_picks_the_virtual_quote() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TestVenue());
        initializer.set_virtual_quote(&f.package_version, 1);
        initializer.set_graduation_target(&f.package_version, MIGRATION_QUOTE_TARGET);
        initializer.set_allocation_plan(&f.package_version, default_plan());
        initializer.set_lp_fee_split(&f.package_version, default_fee_split());
        let launch = f.finalize_launch(initializer);

        assert_eq!(launch.virtual_quote_for_testing(), 1);

        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun finalize_requires_an_allocation_plan() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TestVenue());
        initializer.set_virtual_quote(&f.package_version, VIRTUAL_QUOTE);
        initializer.set_graduation_target(&f.package_version, MIGRATION_QUOTE_TARGET);
        initializer.set_lp_fee_split(&f.package_version, default_fee_split());

        destroy(f.finalize_launch(initializer));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun finalize_requires_lp_fee_split() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.start_launch<TEST_QUOTE, _>(ticket, TestVenue());
        initializer.set_virtual_quote(&f.package_version, VIRTUAL_QUOTE);
        initializer.set_graduation_target(&f.package_version, MIGRATION_QUOTE_TARGET);
        initializer.set_allocation_plan(&f.package_version, default_plan());

        destroy(f.finalize_launch(initializer));
    });

    fixture.end();
}

#[test]
fun finalize_accepts_the_default_zero_protocol_allocation() {
    let mut fixture = start_with_zero_protocol_allocation();

    fixture.next_tx!(LAUNCHER, |f| {
        let plan = allocation::plan(
            bps::new(8_000),
            bps::new(2_000),
            bps::new(10_000),
            vector[],
        );

        destroy(f.new_launch_with(MIGRATION_QUOTE_TARGET, plan));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
/// The creator's Meme shares sum to 10,000 on their own, so Blast's share overflows them.
fun finalize_adds_blast_before_checking_the_meme_shares() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let plan = allocation::plan(
            bps::new(8_000),
            bps::new(LP_MEME_BPS),
            bps::new(LP_QUOTE_BPS),
            vector[],
        );

        destroy(f.new_launch_with(MIGRATION_QUOTE_TARGET, plan));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidShares, location = blast_fun::allocation)]
/// The creator's Quote shares sum to 10,000 on their own, so Blast's share overflows them.
fun finalize_adds_blast_before_checking_the_quote_shares() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let plan = allocation::plan(
            bps::new(CURVE_MEME_BPS),
            bps::new(LP_MEME_BPS),
            bps::new(10_000),
            vector[],
        );

        destroy(f.new_launch_with(MIGRATION_QUOTE_TARGET, plan));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ERecipientCapacityReached, location = blast_fun::allocation)]
/// Seventeen creator recipients exceed the sixteen-recipient bound; Blast is tracked separately.
fun finalize_rejects_a_seventeenth_recipient() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        destroy(f.new_launch_with(MIGRATION_QUOTE_TARGET, recipients_plan(17)));
    });

    fixture.end();
}

#[test]
fun launches_choose_their_own_graduation_target() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_launch_with(MIGRATION_QUOTE_TARGET * 3, default_plan());

        assert_eq!(launch.graduation_target_for_testing(), MIGRATION_QUOTE_TARGET * 3);

        destroy(launch);
    });

    fixture.end();
}

#[test]
/// Blast takes ceil(2 * 250 / 10,000) = 1 and the pool keeps 1.
fun smallest_target_that_leaves_the_pool_quote_is_accepted() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_launch_with(2, default_plan());

        assert_eq!(launch.graduation_target_for_testing(), 2);

        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidGraduationTarget, location = blast_fun::launch)]
/// Blast's rounded-up share takes the only atomic unit.
fun target_that_leaves_the_pool_no_quote_is_rejected() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| destroy(f.new_launch_with(1, default_plan())));

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EDecimalsNotAllowed, location = blast_fun::launch_config)]
fun intake_rejects_a_ticket_whose_decimals_are_no_longer_allowed() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let ticket = f.new_ticket_with_decimals(CREATOR, false, 6);
        let admin_witness = listing_admin();

        f.config.set_meme_decimals_allowed(&f.package_version, &admin_witness, 6, false);

        destroy(f.intake<TEST_QUOTE, _>(
            ticket,
            TestVenue(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun set_virtual_quote_rejects_a_stale_version() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.configured_initializer(ticket);
        f.package_version.set_version_for_testing(2);

        initializer.set_virtual_quote(&f.package_version, 0);
        destroy(initializer);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun set_graduation_target_rejects_a_stale_version() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.configured_initializer(ticket);
        f.package_version.set_version_for_testing(2);

        initializer.set_graduation_target(&f.package_version, 0);
        destroy(initializer);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun set_allocation_plan_rejects_a_stale_version() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.configured_initializer(ticket);
        f.package_version.set_version_for_testing(2);

        initializer.set_allocation_plan(&f.package_version, default_plan());
        destroy(initializer);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun set_lp_fee_split_rejects_a_stale_version() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.configured_initializer(ticket);
        f.package_version.set_version_for_testing(2);

        initializer.set_lp_fee_split(&f.package_version, default_fee_split());
        destroy(initializer);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun set_opening_round_rejects_a_stale_version() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.configured_initializer(ticket);
        f.package_version.set_version_for_testing(2);

        initializer.set_opening_round(&f.package_version, 1);
        destroy(initializer);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun set_partner_checks_the_version_before_partner_admission() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let partner = partners::new_for_testing(PARTNER, PARTNER_SHARE_BPS, f.ctx!());
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.configured_initializer(ticket);
        f.package_version.set_version_for_testing(2);

        initializer.set_partner(&f.package_version, &f.config, &partner, &f.clock);
        destroy(initializer);
        destroy(partner);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun finalize_checks_the_version_before_missing_settings() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let initializer = f.start_launch<TEST_QUOTE, _>(ticket, TestVenue());
        f.package_version.set_version_for_testing(2);

        destroy(f.finalize_launch(initializer));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun share_checks_the_version_before_already_shared_lifecycle() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_launch_with(MIGRATION_QUOTE_TARGET, default_plan());
        let launch = f.open_launch(launch);
        f.package_version.set_version_for_testing(2);

        launch.share(&f.package_version, &f.clock);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EQuoteNotAllowed, location = blast_fun::launch_config)]
fun launch_delegates_quote_admission_to_launch_config() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);

        destroy(f.intake<OTHER_QUOTE, _>(
            ticket,
            TestVenue(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidMemeQuotePair, location = blast_fun::launch)]
fun launch_rejects_using_the_meme_type_as_quote_before_config_lookup() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);

        destroy(f.intake<LAUNCH_TESTS, _>(
            ticket,
            TestVenue(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidSellBurnBps, location = blast_fun::launch_ticket)]
fun launch_rejects_a_ticket_whose_sell_burn_exceeds_this_versions_ceiling() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut ticket = f.new_ticket(CREATOR);
        ticket.set_sell_burn_bps_for_testing(5_001);

        destroy(f.intake<TEST_QUOTE, _>(
            ticket,
            TestVenue(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidInitialMemeSupply, location = blast_fun::launch_ticket)]
fun launch_rejects_a_ticket_without_the_canonical_supply() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut ticket = f.new_ticket(CREATOR);
        ticket.burn_meme_for_testing(1);

        destroy(f.intake<TEST_QUOTE, _>(
            ticket,
            TestVenue(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        ));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidInitialMemeSupply, location = blast_fun::launch_ticket)]
fun launch_rejects_supply_minted_with_the_treasury_cap_before_finalize() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        f.mint_extra_supply_and_finalize(ticket);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidInitialMemeSupply, location = blast_fun::launch_ticket)]
fun launch_rejects_supply_minted_with_the_treasury_cap_on_a_burn_only_ticket() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, true);
        f.mint_extra_supply_and_finalize(ticket);
    });

    fixture.end();
}

// A ticket issued for another Meme or Quote is a compile-time type error: `VenueTicket` is
// generic in the pair, so no runtime test can hand one to `launch::new`.

#[test, expected_failure(abort_code = blast_fun::errors::EVenueNotAllowed, location = blast_fun::launch_config)]
fun a_ticket_from_an_unadmitted_venue_cannot_start_a_launch() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);

        destroy(f.start_launch<TEST_QUOTE, _>(ticket, OtherVenue()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EQuoteNotAllowed, location = blast_fun::launch_config)]
fun a_quote_that_is_not_allowed_is_reported_before_an_unadmitted_venue() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);

        destroy(f.start_launch<OTHER_QUOTE, _>(ticket, OtherVenue()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EVenueNotAllowed, location = blast_fun::launch_config)]
fun an_unadmitted_venue_is_reported_before_disallowed_decimals() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let ticket = f.new_ticket_with_decimals(CREATOR, false, 6);
        f.config.set_meme_decimals_allowed(&f.package_version, &listing_admin(), 6, false);

        destroy(f.start_launch<TEST_QUOTE, _>(ticket, OtherVenue()));
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EVenueNotAllowed, location = blast_fun::launch_config)]
fun a_removed_venue_cannot_start_a_launch() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let ticket = f.new_ticket(CREATOR);
        f
            .config
            .remove_venue<TestVenue>(&f.package_version, &blast_acl::witness_for_testing<VenueAdmin>());

        destroy(f.start_launch<TEST_QUOTE, _>(ticket, TestVenue()));
    });

    fixture.end();
}

// --- Buys before sharing, and sharing ---

#[test]
fun buy_before_share_emits_bought() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let (quote_fee, gross, meme_fee, net) = curve::quote_buy(
            EXPECTED_CURVE_MEME,
            0,
            VIRTUAL_QUOTE,
            10_000_000,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
        );
        let (meme, refund) = f.buy(&mut launch, 10_000_000, net);

        assert_eq!(meme.value(), net);
        assert_eq!(refund.value(), 0);
        assert!(launch.public_start_ms_for_testing().is_none());
        launch.assert_lifecycle(true, false, false);
        assert_eq!(
            bcs::to_bytes(&collect_one<Bought<LAUNCH_TESTS, TEST_QUOTE>>()),
            u64_payload(
                object::id(&launch),
                vector[
                    10_000_000,
                    gross,
                    net,
                    0,
                    0,
                    meme_fee,
                    0,
                    quote_fee,
                    EXPECTED_CURVE_MEME - gross,
                    10_000_000 - quote_fee,
                ],
            ),
        );

        destroy(meme);
        destroy(refund);
        f.share_launch(launch);
    });

    fixture.end();
}

#[test]
/// Two buys before sharing stay below the target; the third reaches it, refunds the excess, and closes
/// the curve before the launch is shared. The shared launch then migrates.
fun buys_before_share_repeat_until_one_graduates_the_launch() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let (first, first_refund) = f.buy(&mut launch, 10_000_000, 1);
        let (second, second_refund) = f.buy(&mut launch, 10_000_000, 1);
        let (_, real_quote, _, _) = launch.balances_for_testing();

        assert_eq!(real_quote, 19_800_000);
        launch.assert_lifecycle(true, false, false);

        let (third, third_refund) = f.buy(&mut launch, 10_000_000, 1);
        let (_, real_quote, _, _) = launch.balances_for_testing();

        assert_eq!(collect<Bought<LAUNCH_TESTS, TEST_QUOTE>>().length(), 3);
        assert_eq!(real_quote, MIGRATION_QUOTE_TARGET);
        assert_eq!(third_refund.value(), 10_000_000 - 5_252_526);
        launch.assert_lifecycle(false, true, false);

        destroy(vector[first, second, third]);
        destroy(vector[first_refund, second_refund, third_refund]);
        f.share_launch(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        f.migrate(&mut launch);

        launch.assert_lifecycle(false, false, true);

        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun buy_before_share_after_graduation_is_rejected() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let (meme, refund) = f.buy(&mut launch, 30_000_000, 1);
        destroy(meme);
        destroy(refund);
        let (meme, refund) = f.buy(&mut launch, 1_000_000, 0);

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EZeroTradeOutput, location = blast_fun::launch)]
fun buy_before_share_rejects_zero_input() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let (meme, refund) = f.buy(&mut launch, 0, 0);

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ESlippageExceeded, location = blast_fun::launch)]
fun buy_before_share_enforces_the_minimum_output() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let (meme, refund) = f.buy(&mut launch, 1_000_000, INITIAL_MEME_SUPPLY);

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun share_starts_public_trading_and_emits_launch_shared() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let launch_id = object::id(&launch);
        f.clock.set_for_testing(250_000);
        f.share_launch(launch);

        assert_eq!(
            bcs::to_bytes(&collect_one<LaunchShared<LAUNCH_TESTS, TEST_QUOTE>>()),
            u64_payload(launch_id, vector[250_000]),
        );
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        assert_eq!(launch.public_start_ms_for_testing(), option::some(250_000));

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun share_rejects_a_second_share() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let launch = f.open_launch(launch);

        f.share_launch(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun owned_launch_rejects_public_sell_before_zero_input() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let meme = coin::zero<LAUNCH_TESTS>(f.ctx!());
        let quote = launch.sell(&f.package_version, &f.runtime_config, meme, 0, f.ctx!());

        destroy(quote);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun buy_checks_the_version_first() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.package_version.set_version_for_testing(2);
        let (meme, refund) = f.buy(&mut launch, 1_000, 0);

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

// --- Creator caps ---

#[test]
fun cap_delay_and_recipient_proposals_are_recorded_by_the_primitive() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let cancel_witness = blast_acl::witness_for_testing<CancelAdmin>();
        let launch_id = object::id(&launch);
        f.clock.set_for_testing(10);
        launch.schedule_curve_fee_cap_delay(&f.package_version, &creator_admin(), 25, &f.clock);
        launch.schedule_creator_metadata_cap_delay(&f.package_version, &creator_admin(), 50, &f.clock);

        assert_eq!(
            last_cap_proposal<CurveFeeCapReassignment>(),
            CapProposal { owner: launch_id, recipient: option::none(), delay_ms: 25, ready_at_ms: 172_800_010 },
        );
        assert_eq!(
            last_cap_proposal<CreatorMetadataCapReassignment>(),
            CapProposal { owner: launch_id, recipient: option::none(), delay_ms: 50, ready_at_ms: 172_800_010 },
        );

        // Cancelling a delay change keeps each applied delay.
        launch.cancel_curve_fee_cap_reassignment(&f.package_version, &cancel_witness);
        launch.cancel_creator_metadata_cap_reassignment(&f.package_version, &cancel_witness);
        assert_eq!(cancelled_cap_recipients<CurveFeeCapReassignment>(), vector[option::none()]);
        assert_eq!(cancelled_cap_recipients<CreatorMetadataCapReassignment>(), vector[option::none()]);
        assert_eq!(launch.curve_fee_cap_reassignment_for_testing().delay_ms(), 172_800_000);
        assert_eq!(launch.creator_metadata_cap_reassignment_for_testing().delay_ms(), 172_800_000);

        launch.schedule_curve_fee_cap_reassignment(&f.package_version, &creator_admin(), NEW_CREATOR, &f.clock);
        launch.schedule_creator_metadata_cap_reassignment(&f.package_version, &creator_admin(), NEW_CREATOR, &f.clock);
        let expected = CapProposal {
            owner: launch_id,
            recipient: option::some(NEW_CREATOR),
            delay_ms: 172_800_000,
            ready_at_ms: 172_800_010,
        };
        assert_eq!(last_cap_proposal<CurveFeeCapReassignment>(), expected);
        assert_eq!(last_cap_proposal<CreatorMetadataCapReassignment>(), expected);

        launch.cancel_curve_fee_cap_reassignment(&f.package_version, &cancel_witness);
        launch.cancel_creator_metadata_cap_reassignment(&f.package_version, &cancel_witness);
        assert_eq!(
            cancelled_cap_recipients<CurveFeeCapReassignment>(),
            vector[option::none(), option::some(NEW_CREATOR)],
        );
        assert_eq!(
            cancelled_cap_recipients<CreatorMetadataCapReassignment>(),
            vector[option::none(), option::some(NEW_CREATOR)],
        );
        assert!(applied_cap_recipients<CurveFeeCapReassignment>().is_empty());
        assert!(applied_cap_recipients<CreatorMetadataCapReassignment>().is_empty());
        destroy(launch);
    });
    fixture.end();
}

#[test]
fun cap_delay_change_preserves_creator_and_existing_caps() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let curve = launch.curve_fee_cap_id_for_testing();
        let metadata = launch.creator_metadata_cap_id_for_testing();
        launch.schedule_curve_fee_cap_delay(&f.package_version, &creator_admin(), 25, &f.clock);
        launch.schedule_creator_metadata_cap_delay(&f.package_version, &creator_admin(), 50, &f.clock);
        f.clock.set_for_testing(172_800_000);
        launch.apply_curve_fee_cap_delay(&f.package_version, &f.clock);
        launch.apply_creator_metadata_cap_delay(&f.package_version, &f.clock);
        assert_eq!(launch.curve_fee_cap_id_for_testing(), curve);
        assert_eq!(launch.creator_metadata_cap_id_for_testing(), metadata);
        assert_eq!(launch.curve_fee_cap_reassignment_for_testing().delay_ms(), 25);
        assert_eq!(launch.creator_metadata_cap_reassignment_for_testing().delay_ms(), 50);
        assert_eq!(applied_cap_recipients<CurveFeeCapReassignment>(), vector[option::none()]);
        assert_eq!(applied_cap_recipients<CreatorMetadataCapReassignment>(), vector[option::none()]);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_800_025);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        assert!(launch.curve_fee_cap_id_for_testing().is_some());
        f.clock.set_for_testing(172_800_050);
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        assert!(launch.creator_metadata_cap_id_for_testing().is_some());
        assert_eq!(
            applied_cap_recipients<CurveFeeCapReassignment>(),
            vector[option::none(), option::some(NEW_CREATOR)],
        );
        assert_eq!(
            applied_cap_recipients<CreatorMetadataCapReassignment>(),
            vector[option::none(), option::some(NEW_CREATOR)],
        );
        assert_eq!(launch.curve_fee_cap_reassignment_for_testing().delay_ms(), 25);
        assert_eq!(launch.creator_metadata_cap_reassignment_for_testing().delay_ms(), 50);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EWrongChange, location = blast_admin::delayed_action)]
fun a_cap_delay_change_cannot_be_applied_as_a_reassignment() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        launch.schedule_curve_fee_cap_delay(&f.package_version, &creator_admin(), 25, &f.clock);
        f.clock.set_for_testing(172_800_000);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EWrongChange, location = blast_admin::delayed_action)]
fun a_cap_reassignment_cannot_be_applied_as_a_delay_change() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        launch.schedule_creator_metadata_cap_reassignment(&f.package_version, &creator_admin(), NEW_CREATOR, &f.clock);
        f.clock.set_for_testing(172_800_000);
        launch.apply_creator_metadata_cap_delay(&f.package_version, &f.clock);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun curve_fee_cap_reassignment_preserves_the_wait_for_the_next_recipient() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        launch.schedule_curve_fee_cap_delay(&f.package_version, &creator_admin(), 25, &f.clock);
        f.clock.set_for_testing(172_800_000);
        launch.apply_curve_fee_cap_delay(&f.package_version, &f.clock);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_800_025);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            BOB,
            &f.clock
        );
        f.clock.set_for_testing(172_800_049);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun creator_metadata_cap_reassignment_preserves_the_wait_for_the_next_recipient() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        launch.schedule_creator_metadata_cap_delay(&f.package_version, &creator_admin(), 50, &f.clock);
        f.clock.set_for_testing(172_800_000);
        launch.apply_creator_metadata_cap_delay(&f.package_version, &f.clock);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(172_800_050);
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            BOB,
            &f.clock
        );
        f.clock.set_for_testing(172_800_099);
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        destroy(launch);
    });
    fixture.end();
}

#[test]
fun recipient_schedules_replace_pending_policy_without_adopting_its_delay() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        launch.schedule_curve_fee_cap_delay(&f.package_version, &creator_admin(), 0, &f.clock);
        launch.schedule_creator_metadata_cap_delay(&f.package_version, &creator_admin(), 0, &f.clock);
        f.clock.set_for_testing(10);
        launch.schedule_curve_fee_cap_reassignment(&f.package_version, &creator_admin(), NEW_CREATOR, &f.clock);
        launch.schedule_creator_metadata_cap_reassignment(&f.package_version, &creator_admin(), NEW_CREATOR, &f.clock);

        let expected = CapProposal {
            owner: object::id(&launch),
            recipient: option::some(NEW_CREATOR),
            delay_ms: 172_800_000,
            ready_at_ms: 172_800_010,
        };
        assert_eq!(last_cap_proposal<CurveFeeCapReassignment>(), expected);
        assert_eq!(last_cap_proposal<CreatorMetadataCapReassignment>(), expected);
        assert_eq!(cancelled_cap_recipients<CurveFeeCapReassignment>(), vector[option::none()]);
        assert_eq!(cancelled_cap_recipients<CreatorMetadataCapReassignment>(), vector[option::none()]);

        f.clock.set_for_testing(172_800_010);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        assert!(launch.curve_fee_cap_id_for_testing().is_some());
        assert!(launch.creator_metadata_cap_id_for_testing().is_some());
        destroy(launch);
    });
    fixture.end();
}

#[test]
fun policy_only_schedules_replace_recipients_and_preserve_the_creator_claim() {
    let mut fixture = start();
    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        launch.schedule_curve_fee_cap_reassignment(&f.package_version, &creator_admin(), NEW_CREATOR, &f.clock);
        launch.schedule_creator_metadata_cap_reassignment(&f.package_version, &creator_admin(), NEW_CREATOR, &f.clock);
        launch.schedule_curve_fee_cap_delay(&f.package_version, &creator_admin(), 0, &f.clock);
        launch.schedule_creator_metadata_cap_delay(&f.package_version, &creator_admin(), 0, &f.clock);
        f.clock.set_for_testing(172_800_000);
        launch.apply_curve_fee_cap_delay(&f.package_version, &f.clock);
        launch.apply_creator_metadata_cap_delay(&f.package_version, &f.clock);

        assert!(launch.curve_fee_cap_id_for_testing().is_none());
        assert!(launch.creator_metadata_cap_id_for_testing().is_none());
        assert!(collect<CurveFeeCapReassigned<LAUNCH_TESTS, TEST_QUOTE>>().is_empty());
        assert!(collect<CreatorMetadataCapReassigned<LAUNCH_TESTS, TEST_QUOTE>>().is_empty());
        let (curve, metadata) = f.claim(&mut launch);
        assert_eq!(launch.curve_fee_cap_id_for_testing(), option::some(object::id(&curve)));
        assert_eq!(launch.creator_metadata_cap_id_for_testing(), option::some(object::id(&metadata)));
        destroy(curve);
        destroy(metadata);
        destroy(launch);
    });
    fixture.end();
}

#[test]
fun recipient_schedules_preserve_zero_delay_across_repeated_reassignments() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        launch.schedule_curve_fee_cap_delay(&f.package_version, &creator_admin(), 0, &f.clock);
        launch.schedule_creator_metadata_cap_delay(&f.package_version, &creator_admin(), 0, &f.clock);
        f.clock.set_for_testing(172_800_000);
        launch.apply_curve_fee_cap_delay(&f.package_version, &f.clock);
        launch.apply_creator_metadata_cap_delay(&f.package_version, &f.clock);
        launch.schedule_curve_fee_cap_reassignment(&f.package_version, &creator_admin(), NEW_CREATOR, &f.clock);
        launch.schedule_creator_metadata_cap_reassignment(&f.package_version, &creator_admin(), NEW_CREATOR, &f.clock);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        let curve = launch.curve_fee_cap_id_for_testing();
        let metadata = launch.creator_metadata_cap_id_for_testing();

        launch.schedule_curve_fee_cap_reassignment(&f.package_version, &creator_admin(), BOB, &f.clock);
        launch.schedule_creator_metadata_cap_reassignment(&f.package_version, &creator_admin(), BOB, &f.clock);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        assert!(launch.curve_fee_cap_id_for_testing() != curve);
        assert!(launch.creator_metadata_cap_id_for_testing() != metadata);
        assert_eq!(f.clock.timestamp_ms(), 172_800_000);
        destroy(launch);
    });
    fixture.end();
}

#[test]
fun recipient_schedules_allow_the_last_representable_application_with_their_delay() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.clock.set_for_testing(std::u64::max_value!() - 345_600_000);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        f.clock.set_for_testing(std::u64::max_value!() - 172_800_000);
        launch.apply_curve_fee_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        launch.apply_creator_metadata_cap_reassignment(&f.package_version, &f.clock, f.ctx!());
        assert!(launch.curve_fee_cap_id_for_testing().is_some());
        assert!(launch.creator_metadata_cap_id_for_testing().is_some());
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorRecipient, location = blast_fun::launch)]
fun metadata_recipient_schedule_rejects_zero() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            @0x0,
            &f.clock
        );
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun curve_fee_cap_schedule_checks_version_before_zero_recipient() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.package_version.set_version_for_testing(2);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            @0x0,
            &f.clock
        );
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EInvalidDelay, location = blast_admin::delayed)]
fun curve_fee_cap_schedule_rejects_delay_overflow_at_its_deadline() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.clock.set_for_testing(std::u64::max_value!() - 172_800_000);
        launch.schedule_curve_fee_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun curve_fee_cap_delay_reduction_to_zero_waits_the_old_delay() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        launch.schedule_curve_fee_cap_delay(&f.package_version, &creator_admin(), 0, &f.clock);
        f.clock.set_for_testing(172_799_999);
        launch.apply_curve_fee_cap_delay(&f.package_version, &f.clock);
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun creator_metadata_cap_schedule_checks_version_before_zero_recipient() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.package_version.set_version_for_testing(2);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            @0x0,
            &f.clock
        );
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EInvalidDelay, location = blast_admin::delayed)]
fun creator_metadata_cap_schedule_rejects_delay_overflow_at_its_deadline() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        f.clock.set_for_testing(std::u64::max_value!() - 172_800_000);
        launch.schedule_creator_metadata_cap_reassignment(
            &f.package_version,
            &creator_admin(),
            NEW_CREATOR,
            &f.clock
        );
        destroy(launch);
    });
    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::ENotReady, location = blast_admin::delayed)]
fun creator_metadata_cap_delay_reduction_to_zero_waits_the_old_delay() {
    let mut fixture = start();
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        launch.schedule_creator_metadata_cap_delay(&f.package_version, &creator_admin(), 0, &f.clock);
        f.clock.set_for_testing(172_799_999);
        launch.apply_creator_metadata_cap_delay(&f.package_version, &f.clock);
        destroy(launch);
    });
    fixture.end();
}

#[test]
fun creator_cap_reassignment_schedules_and_cancellations_record_each_recipient() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let launch_id = object::id(&launch);
        let admin_witness = creator_admin();
        let cancel_witness = blast_acl::witness_for_testing<CancelAdmin>();
        f.clock.set_for_testing(1_234);

        launch.schedule_curve_fee_cap_reassignment(&f.package_version, &admin_witness, NEW_CREATOR, &f.clock);
        launch.schedule_creator_metadata_cap_reassignment(&f.package_version, &admin_witness, CREATOR, &f.clock);

        assert_eq!(
            last_cap_proposal<CurveFeeCapReassignment>(),
            CapProposal {
                owner: launch_id,
                recipient: option::some(NEW_CREATOR),
                delay_ms: 172_800_000,
                ready_at_ms: 172_801_234,
            },
        );
        assert_eq!(
            last_cap_proposal<CreatorMetadataCapReassignment>(),
            CapProposal {
                owner: launch_id,
                recipient: option::some(CREATOR),
                delay_ms: 172_800_000,
                ready_at_ms: 172_801_234,
            },
        );

        launch.cancel_curve_fee_cap_reassignment(&f.package_version, &cancel_witness);
        launch.cancel_creator_metadata_cap_reassignment(&f.package_version, &cancel_witness);
        assert_eq!(
            cancelled_cap_recipients<CurveFeeCapReassignment>(),
            vector[option::some(NEW_CREATOR)],
        );
        assert_eq!(cancelled_cap_recipients<CreatorMetadataCapReassignment>(), vector[option::some(CREATOR)]);

        destroy(launch);
    });

    fixture.end();
}

#[test]
/// The launcher designates `CREATOR`, who claims both caps; the launch keeps the native cap.
fun designated_creator_claims_both_caps() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        f.share_launch(launch);
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let native_metadata_cap_id = launch.metadata_cap_id_for_testing();
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        let mut expected = bcs::to_bytes(&object::id(&curve_fee_cap));
        expected.append(bcs::to_bytes(&object::id(&metadata_cap)));

        assert_eq!(bcs::to_bytes(&collect_one<CreatorCapsClaimed<LAUNCH_TESTS, TEST_QUOTE>>()), expected);
        assert_eq!(launch.metadata_cap_id_for_testing(), native_metadata_cap_id);
        assert!(object::id(&metadata_cap) != native_metadata_cap_id);
        assert!(!launch.has_creator_authority_for_testing());
        assert_eq!(launch.curve_fee_cap_id_for_testing(), option::some(object::id(&curve_fee_cap)));
        assert_eq!(
            launch.creator_metadata_cap_id_for_testing(),
            option::some(object::id(&metadata_cap)),
        );

        let admin_witness = creator_admin();
        launch.reassign_creator_metadata_cap_for_testing(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());
        let reassigned_id = launch.creator_metadata_cap_id_for_testing().destroy_some();
        assert!(reassigned_id != object::id(&metadata_cap));
        assert!(reassigned_id != native_metadata_cap_id);
        assert_eq!(launch.metadata_cap_id_for_testing(), native_metadata_cap_id);
        assert_eq!(
            bcs::to_bytes(&collect_one<CreatorMetadataCapReassigned<LAUNCH_TESTS, TEST_QUOTE>>()),
            cap_reassigned_bytes(object::id(&launch), reassigned_id, NEW_CREATOR),
        );

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun creator_claim_cannot_be_repeated() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        destroy(curve_fee_cap);
        destroy(metadata_cap);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun creator_claim_waits_for_the_share() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.new_default_launch(CREATOR);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECreatorNotSender, location = blast_fun::creator_authority)]
fun launcher_cannot_claim_another_address_creators_caps() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun creator_claim_checks_the_version_before_the_sender() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.package_version.set_version_for_testing(2);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun admin_reassigns_claimed_creator_and_the_new_cap_claims_prior_fees() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        let (meme, refund) = f.buy(&mut launch, 10_000_000, 1);

        transfer::public_transfer(curve_fee_cap, CREATOR);
        destroy(metadata_cap);
        destroy(meme);
        destroy(refund);
        launch.put_back();
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let mut launch = f.take_launch();
        let admin_witness = creator_admin();
        let retired_cap_id = launch.curve_fee_cap_id_for_testing().destroy_some();

        launch.reassign_curve_fee_cap_for_testing(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());

        let cap_id = launch.curve_fee_cap_id_for_testing().destroy_some();
        assert!(cap_id != retired_cap_id);
        assert_eq!(
            bcs::to_bytes(&collect_one<CurveFeeCapReassigned<LAUNCH_TESTS, TEST_QUOTE>>()),
            cap_reassigned_bytes(object::id(&launch), cap_id, NEW_CREATOR),
        );

        launch.put_back();
    });

    fixture.next_tx!(NEW_CREATOR, |f| {
        let mut launch = f.take_launch();
        let curve_fee_cap = f.take_curve_fee_cap();
        let (_, creator_meme, _, creator_quote) = launch.fee_totals_for_testing();
        let (meme_fees, quote_fees) = launch.claim_creator_fees(
            &f.package_version,
            &curve_fee_cap,
            f.ctx!(),
        );

        assert!(creator_meme > 0 && creator_quote > 0);
        assert_eq!(meme_fees.value(), creator_meme);
        assert_eq!(quote_fees.value(), creator_quote);

        destroy(curve_fee_cap);
        destroy(meme_fees);
        destroy(quote_fees);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECreatorCapNotLive, location = blast_fun::launch)]
fun retired_creator_cap_is_rejected_before_the_empty_fee_ledger_check() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        let admin_witness = creator_admin();

        launch.reassign_curve_fee_cap_for_testing(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());
        let (meme_fees, quote_fees) = launch.claim_creator_fees(
            &f.package_version,
            &curve_fee_cap,
            f.ctx!(),
        );

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(meme_fees);
        destroy(quote_fees);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun admin_reassigns_an_unclaimed_creator_and_removes_the_pending_claim() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let admin_witness = creator_admin();

        launch.reassign_curve_fee_cap_for_testing(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());

        let cap_id = launch.curve_fee_cap_id_for_testing().destroy_some();
        assert!(!launch.has_creator_authority_for_testing());
        assert_eq!(
            bcs::to_bytes(&collect_one<CurveFeeCapReassigned<LAUNCH_TESTS, TEST_QUOTE>>()),
            cap_reassigned_bytes(object::id(&launch), cap_id, NEW_CREATOR),
        );

        launch.put_back();
    });

    fixture.next_tx!(NEW_CREATOR, |f| assert!(f.has_curve_fee_cap()));

    fixture.end();
}

#[test, expected_failure(abort_code = std::option::EOPTION_NOT_SET, location = std::option)]
fun reassignment_prevents_the_original_recipient_from_claiming() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let admin_witness = creator_admin();

        launch.reassign_curve_fee_cap_for_testing(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreatorRecipient, location = blast_fun::launch)]
fun reassignment_rejects_the_zero_recipient() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let admin_witness = creator_admin();

        launch.reassign_curve_fee_cap_for_testing(&f.package_version, &admin_witness, @0x0, f.ctx!());

        destroy(launch);
    });

    fixture.end();
}

#[test]
fun creator_metadata_cap_holder_updates_coin_metadata_through_the_launch() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        f.share_launch(launch);
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let native_metadata_cap_id = launch.metadata_cap_id_for_testing();
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        launch.set_name(
            &f.package_version,
            &metadata_cap,
            &mut currency,
            b"Renamed Launch".to_string(),
        );

        let mut expected = bcs::to_bytes(&object::id(&launch));
        expected.append(bcs::to_bytes(&b"Renamed Launch".to_string()));
        expected.append(bcs::to_bytes(&b"Normalized launch state".to_string()));
        expected.append(bcs::to_bytes(&b"".to_string()));
        assert_eq!(bcs::to_bytes(&collect_one<MemeMetadataUpdated<LAUNCH_TESTS, TEST_QUOTE>>()), expected);

        launch.set_description(
            &f.package_version,
            &metadata_cap,
            &mut currency,
            b"Community owned".to_string(),
        );
        launch.set_icon_url(
            &f.package_version,
            &metadata_cap,
            &mut currency,
            b"https://blast.fun/icon.png".to_string(),
        );

        assert_eq!(currency.name(), b"Renamed Launch".to_string());
        assert_eq!(currency.description(), b"Community owned".to_string());
        assert_eq!(currency.icon_url(), b"https://blast.fun/icon.png".to_string());
        assert_eq!(launch.metadata_cap_id_for_testing(), native_metadata_cap_id);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(currency);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EUnchanged, location = blast_fun::launch)]
fun metadata_update_rejects_the_current_value() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        f.share_launch(launch);
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        launch.set_name(
            &f.package_version,
            &metadata_cap,
            &mut currency,
            b"Launch Test".to_string(),
        );

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(currency);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EUnchanged, location = blast_fun::launch)]
fun metadata_update_rejects_the_current_description() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        f.share_launch(launch);
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        let current = currency.description();
        launch.set_description(
            &f.package_version,
            &metadata_cap,
            &mut currency,
            current,
        );

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(currency);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EUnchanged, location = blast_fun::launch)]
fun metadata_update_rejects_the_current_icon_url() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        f.share_launch(launch);
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        let current = currency.icon_url();
        launch.set_icon_url(
            &f.package_version,
            &metadata_cap,
            &mut currency,
            current,
        );

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(currency);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECreatorCapNotLive, location = blast_fun::launch)]
fun retired_creator_metadata_cap_is_rejected_before_unchanged_metadata() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        f.share_launch(launch);
    });

    fixture.next_tx!(CREATOR, |f| {
        let mut launch = f.take_launch();
        let mut currency = f.take_currency();
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        let admin_witness = creator_admin();

        launch.reassign_creator_metadata_cap_for_testing(&f.package_version, &admin_witness, NEW_CREATOR, f.ctx!());
        launch.set_name(
            &f.package_version,
            &metadata_cap,
            &mut currency,
            b"Launch Test".to_string(),
        );

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(currency);
        launch.put_back();
    });

    fixture.end();
}

#[test]
fun holders_destroy_curve_fee_and_metadata_capabilities() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        curve_fee_cap.destroy_curve_fee_cap();
        metadata_cap.destroy_creator_metadata_cap();

        destroy(launch);
    });

    fixture.end();
}

// --- Trading and fees ---

#[test]
fun buy_and_sell_move_exact_coins_accounting_and_payloads() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(LAUNCHER);
        let mut launch = f.open_launch(launch);
        let launch_id = object::id(&launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        let (quote_fee, meme_out_gross, meme_fee, meme_out_net) = curve::quote_buy(
            EXPECTED_CURVE_MEME,
            0,
            VIRTUAL_QUOTE,
            10_000_000,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
        );
        let (meme, refund) = f.buy(&mut launch, 10_000_000, meme_out_net);
        let meme_reserve = EXPECTED_CURVE_MEME - meme_out_gross;
        let real_quote = 10_000_000 - quote_fee;

        assert_eq!(meme.value(), meme_out_net);
        assert_eq!(refund.value(), 0);
        assert_eq!(
            bcs::to_bytes(&collect_one<Bought<LAUNCH_TESTS, TEST_QUOTE>>()),
            u64_payload(
                launch_id,
                vector[
                    10_000_000,
                    meme_out_gross,
                    meme_out_net,
                    0,
                    0,
                    meme_fee,
                    0,
                    quote_fee,
                    meme_reserve,
                    real_quote,
                ],
            ),
        );

        let meme_in = meme.value();
        let (
            sell_meme_fee,
            pending_burn,
            quote_out_gross,
            sell_quote_fee,
            quote_out_net,
        ) = curve::quote_sell(
            meme_reserve,
            real_quote,
            VIRTUAL_QUOTE,
            meme_in,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
            bps::new(SELL_BURN_BPS),
        );
        let quote_out = launch.sell(
            &f.package_version,
            &f.runtime_config,
            meme,
            quote_out_net,
            f.ctx!(),
        );
        let meme_reserve = meme_reserve + meme_in - sell_meme_fee - pending_burn;
        let real_quote = real_quote - quote_out_gross;

        assert_eq!(quote_out.value(), quote_out_net);
        assert_eq!(
            bcs::to_bytes(&collect_one<Sold<LAUNCH_TESTS, TEST_QUOTE>>()),
            u64_payload(
                launch_id,
                vector[
                    meme_in,
                    pending_burn,
                    quote_out_gross,
                    0,
                    sell_meme_fee,
                    0,
                    sell_quote_fee,
                    meme_reserve,
                    real_quote,
                ],
            ),
        );
        let (reserve, quote_reserve, burn, _) = launch.balances_for_testing();
        assert_eq!(reserve, meme_reserve);
        assert_eq!(quote_reserve, real_quote);
        assert_eq!(burn, pending_burn);

        let (meme_fees, quote_fees) = launch.claim_creator_fees(
            &f.package_version,
            &curve_fee_cap,
            f.ctx!(),
        );

        assert_eq!(meme_fees.value(), meme_fee + sell_meme_fee);
        assert_eq!(quote_fees.value(), quote_fee + sell_quote_fee);
        assert_eq!(
            bcs::to_bytes(&collect_one<CreatorFeesClaimed<LAUNCH_TESTS, TEST_QUOTE>>()),
            u64_payload(launch_id, vector[meme_fee + sell_meme_fee, quote_fee + sell_quote_fee]),
        );
        let (protocol_meme, creator_meme, protocol_quote, creator_quote) = launch
            .fee_totals_for_testing();
        assert_eq!(protocol_meme + creator_meme + protocol_quote + creator_quote, 0);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(refund);
        destroy(quote_out);
        destroy(meme_fees);
        destroy(quote_fees);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun graduating_buy_refunds_the_excess_and_closes_the_curve() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (meme, refund) = f.buy(&mut launch, 30_000_000, 1);
        let quote_in = 30_000_000 - refund.value();
        let (quote_fee, meme_out_gross, meme_fee, meme_out_net) = curve::quote_buy(
            EXPECTED_CURVE_MEME,
            0,
            VIRTUAL_QUOTE,
            quote_in,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
        );
        let (meme_reserve, real_quote, _, _) = launch.balances_for_testing();

        assert_eq!(quote_in - quote_fee, MIGRATION_QUOTE_TARGET);
        assert_eq!(real_quote, MIGRATION_QUOTE_TARGET);
        assert_eq!(meme.value(), meme_out_net);
        assert_eq!(meme_reserve, EXPECTED_CURVE_MEME - meme_out_gross);
        launch.assert_lifecycle(false, true, false);
        assert_eq!(
            bcs::to_bytes(&collect_one<Bought<LAUNCH_TESTS, TEST_QUOTE>>()),
            u64_payload(
                object::id(&launch),
                vector[
                    quote_in,
                    meme_out_gross,
                    meme_out_net,
                    refund.value(),
                    0,
                    meme_fee,
                    0,
                    quote_fee,
                    meme_reserve,
                    real_quote,
                ],
            ),
        );

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun terminal_dust_buy_graduates_without_meme_output() {
    assert_terminal_dust_buy(1_000_000_000_000_000_000, 0);
}

#[test]
fun terminal_dust_buy_graduates_when_the_meme_fee_takes_the_entire_output() {
    assert_terminal_dust_buy(100_000_000_000_000_000, 1);
}

#[test, expected_failure(abort_code = blast_fun::errors::ESlippageExceeded, location = blast_fun::launch)]
fun terminal_dust_buy_preserves_positive_minimum_output() {
    let mut fixture = start();
    fixture.prepare_terminal_gap(1_000_000_000_000_000_000, 1);

    fixture.next_tx!(ALICE, |f| {
        let mut launch = f.take_launch();
        let (meme, refund) = f.buy(&mut launch, 100, 1);
        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EZeroTradeOutput, location = blast_fun::launch)]
fun nonterminal_dust_buy_still_rejects_positive_net_quote() {
    let mut fixture = start();
    fixture.prepare_terminal_gap(1_000_000_000_000_000_000, 2);

    fixture.next_tx!(ALICE, |f| {
        let mut launch = f.take_launch();
        let (meme, refund) = f.buy(&mut launch, 2, 0);
        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EZeroTradeOutput, location = blast_fun::launch)]
fun terminal_gap_does_not_allow_input_consumed_entirely_by_quote_fees() {
    let mut fixture = start();
    fixture.prepare_terminal_gap(1_000_000_000_000_000_000, 1);

    fixture.next_tx!(ALICE, |f| {
        let mut launch = f.take_launch();
        let (meme, refund) = f.buy(&mut launch, 1, 0);
        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

#[test]
fun zero_launch_trade_fees_sell_all_bought_meme_without_fee_balances() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = fee_admin();
        f.config.set_trade_fees_for_testing(&f.package_version, &admin_witness, bps::new(0), bps::new(0), f.ctx!());
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (meme, refund) = f.buy(&mut launch, 10_000_000, 1);
        let quote_out = launch.sell(&f.package_version, &f.runtime_config, meme, 1, f.ctx!());
        let (protocol_meme, creator_meme, protocol_quote, creator_quote) = launch
            .fee_totals_for_testing();

        assert!(quote_out.value() > 0);
        assert_eq!(protocol_meme + creator_meme + protocol_quote + creator_quote, 0);

        destroy(refund);
        destroy(quote_out);
        destroy(launch);
    });

    fixture.end();
}

#[test]
/// Anyone may claim Blast's trade fees: they go to the treasury, never to the sender, and the
/// empty SUI balance sends nothing.
fun anyone_claims_blasts_trade_fees_for_the_treasury() {
    let mut fixture = start();
    let (treasury_meme, treasury_quote);

    fixture.next_tx!(BOB, |f| {
        f
            .runtime_config
            .set_protocol_fee_share_for_testing(
                &f.package_version,
                &fee_admin(),
                bps::new(2_500),
                f.ctx!()
            );
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (meme, refund) = f.buy(&mut launch, 10_000_000, 1);
        let (
            protocol_meme,
            creator_meme,
            protocol_quote,
            creator_quote
        ) = launch
            .fee_totals_for_testing();

        assert!(protocol_meme > 0);
        assert!(creator_meme > protocol_meme);
        assert!(protocol_quote > 0);
        assert!(creator_quote > protocol_quote);

        f.pause(constants::valid_pause_bits!());
        launch.claim_protocol_fees(&f.package_version, &f.treasury, f.ctx!());

        let (
            protocol_meme_left,
            creator_meme_left,
            protocol_quote_left,
            creator_quote_left
        ) = launch
            .fee_totals_for_testing();
        assert_eq!(protocol_meme_left, 0);
        assert_eq!(creator_meme_left, creator_meme);
        assert_eq!(protocol_quote_left, 0);
        assert_eq!(creator_quote_left, creator_quote);
        assert_eq!(
            bcs::to_bytes(&collect_one<ProtocolFeesPaid<LAUNCH_TESTS, TEST_QUOTE>>()),
            protocol_fees_paid_bytes(
                object::id(&launch),
                TREASURY,
                option::none(),
                vector[protocol_meme, protocol_quote, 0, 0, 0, 0],
            ),
        );
        (treasury_meme, treasury_quote) = (protocol_meme, protocol_quote);

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.next_tx!(BOB, |f| {
        f.burn_paid(TREASURY, treasury_meme, treasury_quote, 0);
        f.burn_paid(BOB, 0, 0, 0);
    });

    fixture.end();
}

#[test]
/// A treasury administrator redirects every later claim; the old treasury keeps what it was paid
/// and receives nothing more.
fun a_rotated_treasury_receives_every_later_claim() {
    let mut fixture = start();
    let (treasury_meme, treasury_quote);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f
            .runtime_config
            .set_protocol_fee_share_for_testing(&f.package_version, &fee_admin(), bps::new(2_500), f.ctx!());
        f.set_creation_fee_for_testing(CREATION_FEE);
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let launch_id = object::id(&launch);

        launch.claim_protocol_fees(&f.package_version, &f.treasury, f.ctx!());
        f.rotate_treasury(ALICE);
        let (meme, refund) = f.buy(&mut launch, 10_000_000, 1);
        let (protocol_meme, _, protocol_quote, _) = launch.fee_totals_for_testing();
        launch.claim_protocol_fees(&f.package_version, &f.treasury, f.ctx!());

        let claims = collect<ProtocolFeesPaid<LAUNCH_TESTS, TEST_QUOTE>>();
        assert_eq!(claims.length(), 2);
        assert_eq!(
            bcs::to_bytes(&claims[0]),
            protocol_fees_paid_bytes(launch_id, TREASURY, option::none(), vector[0, 0, CREATION_FEE, 0, 0, 0]),
        );
        assert_eq!(
            bcs::to_bytes(&claims[1]),
            protocol_fees_paid_bytes(
                launch_id,
                ALICE,
                option::none(),
                vector[protocol_meme, protocol_quote, 0, 0, 0, 0],
            ),
        );
        (treasury_meme, treasury_quote) = (protocol_meme, protocol_quote);

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.burn_paid(TREASURY, 0, 0, CREATION_FEE);
        f.burn_paid(ALICE, treasury_meme, treasury_quote, 0);
    });

    fixture.end();
}

// --- Creation fee and partner ---

#[test]
/// The creation fee joins Blast's fees on the launch, and the treasury is paid it before any trade.
fun finalize_holds_the_creation_fee_for_blasts_claim() {
    let mut fixture = start();

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.set_creation_fee_for_testing(CREATION_FEE);
        let ticket = f.new_ticket(CREATOR);
        let ticket_id = object::id(&ticket);
        let mut launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TestVenue(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );

        assert_eq!(launch.protocol_sui_for_testing(), CREATION_FEE);
        assert_eq!(
            bcs::to_bytes(&collect_one<LaunchCreated<LAUNCH_TESTS, TEST_QUOTE>>()),
            launch_created_bytes_with(object::id(&launch), ticket_id, CREATION_FEE, option::none()),
        );

        launch.claim_protocol_fees(&f.package_version, &f.treasury, f.ctx!());

        assert_eq!(launch.protocol_sui_for_testing(), 0);
        assert_eq!(
            bcs::to_bytes(&collect_one<ProtocolFeesPaid<LAUNCH_TESTS, TEST_QUOTE>>()),
            protocol_fees_paid_bytes(
                object::id(&launch),
                TREASURY,
                option::none(),
                vector[0, 0, CREATION_FEE, 0, 0, 0],
            ),
        );

        destroy(launch);
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.burn_paid(TREASURY, 0, 0, CREATION_FEE);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidCreationFee, location = blast_fun::launch)]
fun finalize_rejects_a_creation_fee_other_than_the_configured_one() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        f.set_creation_fee_for_testing(CREATION_FEE);
        let ticket = f.new_ticket(CREATOR);
        let initializer = f.configured_initializer(ticket);
        let mut currency = f.take_currency();
        let creation_fee = coin::mint_for_testing<SUI>(CREATION_FEE - 1, f.ctx!());

        destroy(initializer.finalize(&f.package_version, &mut f.registry, &mut currency, &f.config, creation_fee));
        destroy(currency);
    });

    fixture.end();
}

#[test]
/// Naming a partner at creation binds it for good and pays it nothing yet: the creation fee waits
/// with Blast's other fees for the claim.
fun set_partner_binds_the_partner_at_creation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        f.set_creation_fee_for_testing(CREATION_FEE);
        let partner = f.accepted_partner();
        let partner_id = object::id(&partner);
        let ticket = f.new_ticket(CREATOR);
        let ticket_id = object::id(&ticket);
        let launch = f.intake_with_partner(ticket, &partner);

        assert_eq!(launch.protocol_sui_for_testing(), CREATION_FEE);
        assert_eq!(
            bcs::to_bytes(&collect_one<LaunchCreated<LAUNCH_TESTS, TEST_QUOTE>>()),
            launch_created_bytes_with(
                object::id(&launch),
                ticket_id,
                CREATION_FEE,
                option::some(partner_id),
            ),
        );
        assert!(event::events_by_type<PartnerPaid<SUI>>().is_empty());

        destroy(partner);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_partners::errors::EPartnerNotAccepted, location = blast_partners::partner_list)]
fun set_partner_rejects_a_partner_launches_may_not_name() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let partner = partners::new_for_testing(PARTNER, PARTNER_SHARE_BPS, f.ctx!());
        let ticket = f.new_ticket(CREATOR);

        destroy(f.intake_with_partner(ticket, &partner));
        destroy(partner);
    });

    fixture.end();
}

#[test]
/// The partner itself can claim: it is paid its share of the creation fee and of Blast's trade fees
/// in both assets, each rounded down, and the treasury the rest; the creator's fees are untouched.
fun claim_protocol_fees_with_partner_pays_the_partner_its_share() {
    let mut fixture = start();
    let (treasury_meme, treasury_quote);

    fixture.next_tx!(PARTNER, |f| {
        f
            .runtime_config
            .set_protocol_fee_share_for_testing(&f.package_version, &fee_admin(), bps::new(2_500), f.ctx!());
        f.set_creation_fee_for_testing(CREATION_FEE);
        let partner = f.accepted_partner();
        let partner_id = object::id(&partner);
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake_with_partner(ticket, &partner);
        let mut launch = f.open_launch(launch);
        let (meme, refund) = f.buy(&mut launch, 10_000_000, 1);
        let (protocol_meme, creator_meme, protocol_quote, creator_quote) = launch
            .fee_totals_for_testing();
        let partner_meme = (
            (protocol_meme as u128) * (PARTNER_SHARE_BPS as u128) / 10_000
        ) as u64;
        let partner_quote = (
            (protocol_quote as u128) * (PARTNER_SHARE_BPS as u128) / 10_000
        ) as u64;

        launch.claim_protocol_fees_with_partner(
            &f.package_version,
            &f.treasury,
            &partner,
            f.ctx!(),
        );

        assert!(partner_meme > 0 && partner_quote > 0);
        let (protocol_meme_left, creator_meme_left, protocol_quote_left, creator_quote_left) = launch
            .fee_totals_for_testing();
        assert_eq!(protocol_meme_left, 0);
        assert_eq!(creator_meme_left, creator_meme);
        assert_eq!(protocol_quote_left, 0);
        assert_eq!(creator_quote_left, creator_quote);
        assert_eq!(
            bcs::to_bytes(&collect_one<ProtocolFeesPaid<LAUNCH_TESTS, TEST_QUOTE>>()),
            protocol_fees_paid_bytes(
                object::id(&launch),
                TREASURY,
                option::some(partner_id),
                vector[
                    protocol_meme - partner_meme,
                    protocol_quote - partner_quote,
                    CREATION_FEE - 400,
                    partner_meme,
                    partner_quote,
                    400,
                ],
            ),
        );
        let (meme_partner_id, paid_meme) = event::events_by_type<PartnerPaid<LAUNCH_TESTS>>()[0]
            .partner_paid_fields();
        let (quote_partner_id, paid_quote) = event::events_by_type<PartnerPaid<TEST_QUOTE>>()[0]
            .partner_paid_fields();
        let (sui_partner_id, paid_sui) = event::events_by_type<PartnerPaid<SUI>>()[0]
            .partner_paid_fields();
        assert_eq!(meme_partner_id, partner_id);
        assert_eq!(paid_meme, partner_meme);
        assert_eq!(quote_partner_id, partner_id);
        assert_eq!(paid_quote, partner_quote);
        assert_eq!(sui_partner_id, partner_id);
        assert_eq!(paid_sui, 400);
        (treasury_meme, treasury_quote) =
            (protocol_meme - partner_meme, protocol_quote - partner_quote);

        destroy(partner);
        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.next_tx!(PARTNER, |f| {
        f.burn_paid(TREASURY, treasury_meme, treasury_quote, CREATION_FEE - 400);
    });

    fixture.end();
}

#[test]
/// Blast's one-time migration Meme and Quote fees enter the launch ledger, so the launch's partner
/// receives its configured share of them at the claim and the treasury the rest.
fun claim_protocol_fees_with_partner_includes_migration_fees() {
    let mut fixture = start();
    let (treasury_meme, treasury_quote);

    fixture.next_tx!(BOB, |f| {
        f
            .runtime_config
            .set_protocol_fee_share_for_testing(&f.package_version, &fee_admin(), bps::new(2_500), f.ctx!());
        f.set_creation_fee_for_testing(CREATION_FEE);
        let partner = f.accepted_partner();
        let partner_id = object::id(&partner);
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake_with_partner(ticket, &partner);
        let mut launch = f.open_launch(launch);
        f.graduate(&mut launch);

        let mut currency = f.take_currency();
        let (pool_meme, pool_quote, terms) = launch
            .migrate(&f.package_version, &f.config, &mut currency, &f.clock, f.ctx!())
            .redeem(TestVenue());
        assert_eq!(terms.partner_id(), option::some(partner_id));

        let (protocol_meme, creator_meme, protocol_quote, creator_quote) = launch
            .fee_totals_for_testing();
        let partner_meme = (
            (protocol_meme as u128) * (PARTNER_SHARE_BPS as u128) / 10_000
        ) as u64;
        let partner_quote = (
            (protocol_quote as u128) * (PARTNER_SHARE_BPS as u128) / 10_000
        ) as u64;
        launch.claim_protocol_fees_with_partner(
            &f.package_version,
            &f.treasury,
            &partner,
            f.ctx!(),
        );

        assert!(protocol_meme >= EXPECTED_PROTOCOL_MEME);
        assert!(protocol_quote >= EXPECTED_PROTOCOL_QUOTE);
        let (protocol_meme_left, creator_meme_left, protocol_quote_left, creator_quote_left) = launch
            .fee_totals_for_testing();
        assert_eq!(protocol_meme_left, 0);
        assert_eq!(creator_meme_left, creator_meme);
        assert_eq!(protocol_quote_left, 0);
        assert_eq!(creator_quote_left, creator_quote);
        let (meme_partner_id, paid_meme) = event::events_by_type<PartnerPaid<LAUNCH_TESTS>>()[0]
            .partner_paid_fields();
        let (quote_partner_id, paid_quote) = event::events_by_type<PartnerPaid<TEST_QUOTE>>()[0]
            .partner_paid_fields();
        assert_eq!(meme_partner_id, partner_id);
        assert_eq!(paid_meme, partner_meme);
        assert_eq!(quote_partner_id, partner_id);
        assert_eq!(paid_quote, partner_quote);
        (treasury_meme, treasury_quote) =
            (protocol_meme - partner_meme, protocol_quote - partner_quote);

        destroy(partner);
        destroy(pool_meme);
        destroy(pool_quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.next_tx!(BOB, |f| {
        f.burn_paid(TREASURY, treasury_meme, treasury_quote, CREATION_FEE - 400);
    });

    fixture.end();
}

#[test]
/// A partner whose share is zero is paid nothing and emits no `PartnerPaid`; the claim still
/// records it, and the treasury receives Blast's whole fee.
fun claim_protocol_fees_with_a_zero_share_partner_pays_nothing() {
    let mut fixture = start();
    let (treasury_meme, treasury_quote);

    fixture.next_tx!(BOB, |f| {
        f
            .runtime_config
            .set_protocol_fee_share_for_testing(&f.package_version, &fee_admin(), bps::new(2_500), f.ctx!());
        f.set_creation_fee_for_testing(CREATION_FEE);
        let partner = partners::new_for_testing(PARTNER, 0, f.ctx!());
        f.config.add_partner(&f.package_version, &fee_admin(), &partner);
        let ticket = f.new_ticket(CREATOR);
        let launch = f.intake_with_partner(ticket, &partner);
        let mut launch = f.open_launch(launch);
        let (meme, refund) = f.buy(&mut launch, 10_000_000, 1);
        let (protocol_meme, _, protocol_quote, _) = launch.fee_totals_for_testing();

        launch.claim_protocol_fees_with_partner(
            &f.package_version,
            &f.treasury,
            &partner,
            f.ctx!(),
        );

        assert_eq!(
            bcs::to_bytes(&collect_one<ProtocolFeesPaid<LAUNCH_TESTS, TEST_QUOTE>>()),
            protocol_fees_paid_bytes(
                object::id(&launch),
                TREASURY,
                option::some(object::id(&partner)),
                vector[protocol_meme, protocol_quote, CREATION_FEE, 0, 0, 0],
            ),
        );
        assert!(event::events_by_type<PartnerPaid<LAUNCH_TESTS>>().is_empty());
        assert!(event::events_by_type<PartnerPaid<TEST_QUOTE>>().is_empty());
        assert!(event::events_by_type<PartnerPaid<SUI>>().is_empty());
        (treasury_meme, treasury_quote) = (protocol_meme, protocol_quote);

        destroy(partner);
        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.next_tx!(BOB, |f| {
        f.burn_paid(TREASURY, treasury_meme, treasury_quote, CREATION_FEE);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
/// A stale package is refused before the partner check, so old bytecode cannot claim.
fun claim_protocol_fees_checks_the_version_before_the_partner() {
    let mut fixture = start();

    fixture.next_tx!(BOB, |f| {
        f.set_creation_fee_for_testing(CREATION_FEE);
        let partner = f.accepted_partner();
        let ticket = f.new_ticket(CREATOR);
        let mut launch = f.intake_with_partner(ticket, &partner);
        f.package_version.set_version_for_testing(2);

        launch.claim_protocol_fees(&f.package_version, &f.treasury, f.ctx!());

        destroy(partner);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
/// A stale package is refused before the partner check, so old bytecode cannot pay a partner.
fun claim_protocol_fees_with_partner_checks_the_version_before_the_partner() {
    let mut fixture = start();

    fixture.next_tx!(BOB, |f| {
        f.set_creation_fee_for_testing(CREATION_FEE);
        let partner = f.accepted_partner();
        let other = f.accepted_partner();
        let ticket = f.new_ticket(CREATOR);
        let mut launch = f.intake_with_partner(ticket, &partner);
        f.package_version.set_version_for_testing(2);

        launch.claim_protocol_fees_with_partner(
            &f.package_version,
            &f.treasury,
            &other,
            f.ctx!(),
        );

        destroy(partner);
        destroy(other);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_core::errors::EPartnerMismatch, location = blast_core::protocol_fees)]
/// Naming the wrong partner is refused before the empty ledger is.
fun claim_protocol_fees_with_partner_checks_the_partner_before_the_fees() {
    let mut fixture = start();

    fixture.next_tx!(BOB, |f| {
        let partner = f.accepted_partner();
        let other = f.accepted_partner();
        let ticket = f.new_ticket(CREATOR);
        let mut launch = f.intake_with_partner(ticket, &partner);

        launch.claim_protocol_fees_with_partner(
            &f.package_version,
            &f.treasury,
            &other,
            f.ctx!(),
        );

        destroy(partner);
        destroy(other);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_core::errors::EPartnerMismatch, location = blast_core::protocol_fees)]
/// No one can claim a partnered launch's fees without paying its partner.
fun claim_protocol_fees_rejects_a_launch_that_names_a_partner() {
    let mut fixture = start();

    fixture.next_tx!(BOB, |f| {
        f.set_creation_fee_for_testing(CREATION_FEE);
        let partner = f.accepted_partner();
        let ticket = f.new_ticket(CREATOR);
        let mut launch = f.intake_with_partner(ticket, &partner);

        launch.claim_protocol_fees(&f.package_version, &f.treasury, f.ctx!());

        destroy(partner);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_core::errors::EPartnerMismatch, location = blast_core::protocol_fees)]
fun claim_protocol_fees_with_partner_rejects_another_partner() {
    let mut fixture = start();

    fixture.next_tx!(BOB, |f| {
        f.set_creation_fee_for_testing(CREATION_FEE);
        let partner = f.accepted_partner();
        let other = f.accepted_partner();
        let ticket = f.new_ticket(CREATOR);
        let mut launch = f.intake_with_partner(ticket, &partner);

        launch.claim_protocol_fees_with_partner(
            &f.package_version,
            &f.treasury,
            &other,
            f.ctx!(),
        );

        destroy(partner);
        destroy(other);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_core::errors::EPartnerMismatch, location = blast_core::protocol_fees)]
fun claim_protocol_fees_with_partner_rejects_a_launch_without_one() {
    let mut fixture = start();

    fixture.next_tx!(BOB, |f| {
        f.set_creation_fee_for_testing(CREATION_FEE);
        let partner = f.accepted_partner();
        let mut launch = f.new_default_launch(CREATOR);

        launch.claim_protocol_fees_with_partner(
            &f.package_version,
            &f.treasury,
            &partner,
            f.ctx!(),
        );

        destroy(partner);
        destroy(launch);
    });

    fixture.end();
}

#[test]
/// Blast's fee claim on an empty ledger pays and emits nothing, so a keeper's claim never aborts.
fun claim_protocol_fees_on_an_empty_ledger_pays_nothing() {
    let mut fixture = start();

    fixture.next_tx!(BOB, |f| {
        let mut launch = f.new_default_launch(CREATOR);

        launch.claim_protocol_fees(&f.package_version, &f.treasury, f.ctx!());

        assert!(event::events_by_type<ProtocolFeesPaid<LAUNCH_TESTS, TEST_QUOTE>>().is_empty());
        destroy(launch);
    });

    fixture.next_tx!(BOB, |f| {
        f.burn_paid(TREASURY, 0, 0, 0);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ENothingAccrued, location = blast_fun::launch)]
fun claim_creator_fees_rejects_an_empty_creator_balance() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        let (meme, quote) = launch.claim_creator_fees(&f.package_version, &curve_fee_cap, f.ctx!());

        destroy(meme);
        destroy(quote);
        destroy(curve_fee_cap);
        destroy(metadata_cap);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ESlippageExceeded, location = blast_fun::launch)]
fun buy_rejects_minimum_above_exact_returned_coin() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (_, _, _, meme_out_net) = curve::quote_buy(
            EXPECTED_CURVE_MEME,
            0,
            VIRTUAL_QUOTE,
            10_000_000,
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
        );
        let (meme, refund) = f.buy(&mut launch, 10_000_000, meme_out_net + 1);

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ESlippageExceeded, location = blast_fun::launch)]
fun sell_rejects_minimum_above_exact_returned_coin() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (meme, refund) = f.buy(&mut launch, 10_000_000, 1);
        let (meme_reserve, real_quote, _, _) = launch.balances_for_testing();
        let (_, _, _, _, quote_out_net) = curve::quote_sell(
            meme_reserve,
            real_quote,
            VIRTUAL_QUOTE,
            meme.value(),
            bps::new(QUOTE_FEE_BPS),
            bps::new(MEME_FEE_BPS),
            bps::new(SELL_BURN_BPS),
        );
        let quote = launch.sell(
            &f.package_version,
            &f.runtime_config,
            meme,
            quote_out_net + 1,
            f.ctx!(),
        );

        destroy(refund);
        destroy(quote);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EZeroTradeOutput, location = blast_fun::launch)]
fun public_buy_checks_zero_output_before_slippage() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (meme, refund) = f.buy(&mut launch, 0, std::u64::max_value!());

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun threshold_crossing_buy_closes_sell_before_curve_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (meme, refund) = f.buy(&mut launch, 30_000_000, 1);
        let quote = launch.sell(&f.package_version, &f.runtime_config, meme, 0, f.ctx!());

        destroy(refund);
        destroy(quote);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun threshold_crossing_buy_closes_another_buy_before_curve_validation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.graduate(&mut launch);
        let (meme, refund) = f.buy(&mut launch, 0, 0);

        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

// --- Migration ---

#[test]
/// Creator recipients are paid in plan order; a zero share is reported but transfers nothing.
/// Blast's allocation enters the fee ledger and the pool's share goes to the stored venue.
fun migration_pays_recipients_and_accrues_blast_allocation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_launch_with(MIGRATION_QUOTE_TARGET, external_plan());
        let (curve, _, _, allocated) = launch.balances_for_testing();

        assert_eq!(curve, 700_000_000__000_000_000);
        assert_eq!(allocated, INITIAL_MEME_SUPPLY - curve);

        f.share_launch(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let launch_id = object::id(&launch);
        f.graduate(&mut launch);
        let (protocol_meme_before, _, protocol_quote_before, _) = launch
            .fee_totals_for_testing();
        let mut currency = f.take_currency();
        let (meme, quote, _) = launch
            .migrate(&f.package_version, &f.config, &mut currency, &f.clock, f.ctx!())
            .redeem(TestVenue());
        let paid = collect<MigrationAllocationPaid<LAUNCH_TESTS, TEST_QUOTE>>();
        let (curve, real_quote, pending_burn, allocated) = launch.balances_for_testing();
        let (protocol_meme, _, protocol_quote, _) = launch.fee_totals_for_testing();

        assert_eq!(meme.value(), EXPECTED_POOL_MEME);
        assert_eq!(quote.value(), 22_500_000);
        assert_eq!(paid.length(), 2);
        assert_eq!(
            bcs::to_bytes(&paid[0]),
            allocation_paid_bytes(launch_id, CREATOR, 0, 1_875_000, option::none(), option::none()),
        );
        assert_eq!(
            bcs::to_bytes(&paid[1]),
            allocation_paid_bytes(
                launch_id,
                ALICE,
                25_000_000__000_000_000,
                0,
                option::none(),
                option::none(),
            ),
        );
        assert_eq!(protocol_meme, protocol_meme_before + EXPECTED_PROTOCOL_MEME);
        assert_eq!(protocol_quote, protocol_quote_before + EXPECTED_PROTOCOL_QUOTE);
        assert_eq!(
            bcs::to_bytes(&collect_one<ProtocolFeesAccrued<LAUNCH_TESTS, TEST_QUOTE>>()),
            u64_payload(launch_id, vector[EXPECTED_PROTOCOL_MEME, EXPECTED_PROTOCOL_QUOTE]),
        );
        assert_eq!(curve + real_quote + pending_burn + allocated, 0);
        launch.assert_lifecycle(false, false, true);

        destroy(meme);
        destroy(quote);
        destroy(currency);
        launch.put_back();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        assert_eq!(f.take_coin<TEST_QUOTE>(CREATOR).burn_for_testing(), 1_875_000);
        assert_eq!(f.take_coin<LAUNCH_TESTS>(ALICE).burn_for_testing(), 25_000_000__000_000_000);
        assert!(!f.has_coin<LAUNCH_TESTS>(CREATOR));
        assert!(!f.has_coin<TEST_QUOTE>(ALICE));
    });

    fixture.end();
}

#[test]
/// A vesting recipient's allocation is locked in one schedule per asset, starting at migration,
/// instead of being sent outright; the payout event still reports its amounts.
fun migration_vests_a_vesting_recipients_allocation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let vesting = option::some(blast_core::payout::vesting_terms(0, 1_000, 10));
        let plan = allocation::plan(
            bps::new(7_000),
            bps::new(LP_MEME_BPS),
            bps::new(9_000),
            vector[
                allocation::recipient_share(
                    blast_core::payout::recipient(CREATOR, option::none()),
                    bps::new(0),
                    bps::new(750),
                ),
                allocation::recipient_share(
                    blast_core::payout::recipient(ALICE, vesting),
                    bps::new(250),
                    bps::new(0),
                ),
            ],
        );
        let launch = f.new_launch_with(MIGRATION_QUOTE_TARGET, plan);
        f.share_launch(launch);
    });

    let alice_paid;
    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        f.graduate(&mut launch);
        f.migrate(&mut launch);

        alice_paid = bcs::to_bytes(&collect<MigrationAllocationPaid<LAUNCH_TESTS, TEST_QUOTE>>()[1]);
        launch.put_back();
    });

    // The event names the Meme schedule shared by migration and no Quote schedule.
    fixture.next_tx!(LAUNCHER, |f| {
        assert_eq!(f.take_coin<TEST_QUOTE>(CREATOR).burn_for_testing(), 1_875_000);
        assert!(!f.has_coin<LAUNCH_TESTS>(ALICE));
        assert!(f.has_vesting<LAUNCH_TESTS>());
        assert!(!f.has_vesting<TEST_QUOTE>());
        let launch = f.take_launch();
        assert_eq!(
            alice_paid,
            allocation_paid_bytes(
                object::id(&launch),
                ALICE,
                25_000_000__000_000_000,
                0,
                f.vesting_id<LAUNCH_TESTS>(),
                option::none(),
            ),
        );
        launch.put_back();
    });

    fixture.end();
}

#[test]
/// Odd shares of an odd target: Blast's Quote rounds up, the one leftover Quote unit goes to the
/// largest remaining remainder (ALICE 7,777 over BOB 6,034 and the pool's 4,439), and every Meme
/// and Quote unit is accounted for.
fun migration_apportions_by_largest_remainder_and_conserves_both_assets() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let plan = allocation::plan(
            bps::new(6_001),
            bps::new(2_333),
            bps::new(7_777),
            vector[
                allocation::recipient_share(
                    blast_core::payout::recipient(ALICE, option::none()),
                    bps::new(333),
                    bps::new(1_111),
                ),
                allocation::recipient_share(
                    blast_core::payout::recipient(BOB, option::none()),
                    bps::new(583),
                    bps::new(862),
                ),
            ],
        );
        let launch = f.new_launch_with(25_000_007, plan);
        f.share_launch(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let launch_id = object::id(&launch);
        let (bought, refund) = f.buy(&mut launch, 30_000_000, 1);
        let (curve, real_quote, pending_burn, allocated) = launch.balances_for_testing();
        let (protocol_fee, creator_fee, protocol_quote_fee, _) = launch
            .fee_totals_for_testing();

        assert_eq!(real_quote, 25_000_007);
        assert_eq!(
            curve + pending_burn + allocated + bought.value() + protocol_fee + creator_fee,
            INITIAL_MEME_SUPPLY,
        );

        let mut currency = f.take_currency();
        let (meme, quote, _) = launch
            .migrate(&f.package_version, &f.config, &mut currency, &f.clock, f.ctx!())
            .redeem(TestVenue());
        let paid = collect<MigrationAllocationPaid<LAUNCH_TESTS, TEST_QUOTE>>();
        let (protocol_meme, _, protocol_quote, _) = launch.fee_totals_for_testing();

        assert_eq!(
            bcs::to_bytes(&paid[0]),
            allocation_paid_bytes(
                launch_id,
                ALICE,
                33_300_000__000_000_000,
                2_777_501,
                option::none(),
                option::none(),
            ),
        );
        assert_eq!(
            bcs::to_bytes(&paid[1]),
            allocation_paid_bytes(
                launch_id,
                BOB,
                58_300_000__000_000_000,
                2_155_000,
                option::none(),
                option::none(),
            ),
        );
        assert_eq!(protocol_meme, protocol_fee + EXPECTED_PROTOCOL_MEME);
        assert_eq!(protocol_quote, protocol_quote_fee + 625_001);
        assert_eq!(meme.value(), 233_300_000__000_000_000);
        assert_eq!(quote.value(), 19_442_505);
        assert_eq!(
            meme.value() + EXPECTED_PROTOCOL_MEME + 33_300_000__000_000_000
                + 58_300_000__000_000_000,
            allocated,
        );
        assert_eq!(quote.value() + 625_001 + 2_777_501 + 2_155_000, real_quote);

        destroy(bought);
        destroy(refund);
        destroy(meme);
        destroy(quote);
        destroy(currency);
        launch.put_back();
    });

    fixture.end();
}

#[test]
fun migration_pays_sixteen_project_recipients() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_launch_with(MIGRATION_QUOTE_TARGET, recipients_plan(16));
        f.share_launch(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        f.graduate(&mut launch);
        f.migrate(&mut launch);
        let (_, real_quote, _, allocated) = launch.balances_for_testing();

        assert_eq!(collect<MigrationAllocationPaid<LAUNCH_TESTS, TEST_QUOTE>>().length(), 16);
        assert_eq!(real_quote + allocated, 0);

        launch.put_back();
    });

    fixture.end();
}

#[test]
fun fixed_supply_migration_sends_the_disposal_to_zero() {
    let mut fixture = start();
    let disposed_meme;

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        f.share_launch(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        disposed_meme = f.reach_migration_after_sell(&mut launch);
        let mut currency = f.take_currency();
        let supply = currency.total_supply().destroy_some();
        let (meme, quote, _) = launch
            .migrate(&f.package_version, &f.config, &mut currency, &f.clock, f.ctx!())
            .redeem(TestVenue());

        assert_eq!(meme.value(), EXPECTED_POOL_MEME);
        assert_eq!(currency.total_supply().destroy_some(), supply);
        assert_eq!(
            bcs::to_bytes(&collect_one<Migrated<LAUNCH_TESTS, TEST_QUOTE>>()),
            migrated_bytes(
                object::id(&launch),
                meme.value(),
                quote.value(),
                disposed_meme,
                supply,
            ),
        );

        destroy(meme);
        destroy(quote);
        destroy(currency);
        launch.put_back();
    });

    fixture.next_tx!(LAUNCHER, |f| {
        assert_eq!(f.take_coin<LAUNCH_TESTS>(@0x0).burn_for_testing(), disposed_meme);
    });

    fixture.end();
}

#[test]
fun burn_only_migration_burns_the_disposal_from_native_supply() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket_with_mode(CREATOR, true);
        let launch = f.intake<TEST_QUOTE, _>(
            ticket,
            TestVenue(),
            MIGRATION_QUOTE_TARGET,
            default_plan(),
        );
        f.share_launch(launch);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let mut launch = f.take_launch();
        let disposed_meme = f.reach_migration_after_sell(&mut launch);
        let mut currency = f.take_currency();
        let supply = currency.total_supply().destroy_some();
        let (meme, quote, _) = launch
            .migrate(&f.package_version, &f.config, &mut currency, &f.clock, f.ctx!())
            .redeem(TestVenue());

        assert_eq!(currency.total_supply().destroy_some(), supply - disposed_meme);
        assert_eq!(
            bcs::to_bytes(&collect_one<Migrated<LAUNCH_TESTS, TEST_QUOTE>>()),
            migrated_bytes(
                object::id(&launch),
                meme.value(),
                quote.value(),
                disposed_meme,
                supply - disposed_meme,
            ),
        );

        destroy(meme);
        destroy(quote);
        destroy(currency);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun migration_rejects_a_live_launch() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let mut currency = f.take_currency();
        let migration = launch.migrate(&f.package_version, &f.config, &mut currency, &f.clock, f.ctx!());

        destroy(migration);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::EInvalidLaunchLifecycle, location = blast_fun::launch)]
fun migration_cannot_be_repeated() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.graduate(&mut launch);
        let mut currency = f.take_currency();
        let (meme, quote, _) = launch
            .migrate(&f.package_version, &f.config, &mut currency, &f.clock, f.ctx!())
            .redeem(TestVenue());
        destroy(meme);
        destroy(quote);
        let migration = launch.migrate(&f.package_version, &f.config, &mut currency, &f.clock, f.ctx!());

        destroy(migration);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_core::errors::EWrongVenue, location = blast_core::migration)]
fun only_the_stored_venue_redeems_the_migration() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.graduate(&mut launch);
        let mut currency = f.take_currency();
        let (meme, quote, _) = launch
            .migrate(&f.package_version, &f.config, &mut currency, &f.clock, f.ctx!())
            .redeem(OtherVenue());

        destroy(meme);
        destroy(quote);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun stale_package_version_aborts_migration_before_its_lifecycle_check() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.package_version.set_version_for_testing(2);
        let mut currency = f.take_currency();
        let migration = launch.migrate(&f.package_version, &f.config, &mut currency, &f.clock, f.ctx!());

        destroy(migration);
        destroy(currency);
        destroy(launch);
    });

    fixture.end();
}

// --- Migration hand-off and owner proof ---

#[test]
fun migration_hands_the_stored_venue_the_pool_share_and_the_vault_terms() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        f.set_protocol_lp_fees(1_200, 900);
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.graduate(&mut launch);
        let mut currency = f.take_currency();
        let (meme, quote, terms) = launch
            .migrate(&f.package_version, &f.config, &mut currency, &f.clock, f.ctx!())
            .redeem(TestVenue());
        let (protocol_meme_bps, protocol_quote_bps) = terms.protocol_bps();

        assert_eq!(meme.value(), EXPECTED_POOL_MEME);
        assert_eq!(quote.value(), MIGRATION_QUOTE_TARGET - EXPECTED_PROTOCOL_QUOTE);
        assert_eq!(terms.origin(), object::id(&launch));
        assert_eq!(terms.package_witness(), type_name::with_original_ids<PackageWitness>());
        assert_eq!(terms.fee_split(), default_fee_split());
        assert_eq!(protocol_meme_bps.value(), 1_200);
        assert_eq!(protocol_quote_bps.value(), 900);
        assert_eq!(terms.partner_id(), option::none());
        assert!(terms.residuals().is_protocol());

        destroy(meme);
        destroy(quote);
        destroy(currency);
        launch.put_back();
    });

    fixture.end();
}

#[test]
fun migration_terms_carry_the_lp_share_applied_at_migration_not_at_creation() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.graduate(&mut launch);
        f.set_protocol_lp_fees(3_000, 3_000);
        let (protocol_meme_bps, protocol_quote_bps) = f.migrate(&mut launch).protocol_bps();

        assert_eq!(protocol_meme_bps.value(), 3_000);
        assert_eq!(protocol_quote_bps.value(), 3_000);

        launch.put_back();
    });

    fixture.end();
}

#[test]
fun migration_terms_keep_the_creators_fee_split() {
    let mut fixture = start();

    fixture.next_tx!(LAUNCHER, |f| {
        let ticket = f.new_ticket(CREATOR);
        let mut initializer = f.configured_initializer(ticket);
        initializer.set_lp_fee_split(&f.package_version, launcher_fee_split());
        let launch = f.finalize_launch(initializer);
        let mut launch = f.open_launch(launch);
        f.graduate(&mut launch);

        assert_eq!(f.migrate(&mut launch).fee_split(), launcher_fee_split());

        launch.put_back();
    });

    fixture.end();
}

#[test]
fun the_curve_fee_cap_holder_proves_ownership_of_the_launchs_vault() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        f.graduate(&mut launch);
        let terms = f.migrate(&mut launch);

        launch.prove_owner(&f.package_version, &curve_fee_cap).assert_terms(&terms);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        launch.put_back();
    });

    fixture.end();
}

#[test]
fun the_reassigned_curve_fee_cap_proves_ownership() {
    let mut fixture = start();
    let terms_for_new_creator;

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        launch.reassign_curve_fee_cap_for_testing(&f.package_version, &creator_admin(), NEW_CREATOR, f.ctx!());
        f.graduate(&mut launch);
        terms_for_new_creator = f.migrate(&mut launch);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        launch.put_back();
    });

    fixture.next_tx!(NEW_CREATOR, |f| {
        let launch = f.take_launch();
        let curve_fee_cap = f.take_curve_fee_cap();

        launch.prove_owner(&f.package_version, &curve_fee_cap).assert_terms(&terms_for_new_creator);

        destroy(curve_fee_cap);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_fun::errors::ECreatorCapNotLive, location = blast_fun::launch)]
fun a_retired_curve_fee_cap_cannot_prove_ownership() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        launch.reassign_curve_fee_cap_for_testing(&f.package_version, &creator_admin(), NEW_CREATOR, f.ctx!());

        let proof = launch.prove_owner(&f.package_version, &curve_fee_cap);

        destroy(proof);
        destroy(curve_fee_cap);
        destroy(metadata_cap);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_admin::errors::EVersionMismatch, location = blast_admin::package_version)]
fun prove_owner_checks_the_version_before_the_cap() {
    let mut fixture = start();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);
        launch.reassign_curve_fee_cap_for_testing(&f.package_version, &creator_admin(), NEW_CREATOR, f.ctx!());
        f.package_version.set_version_for_testing(2);

        let proof = launch.prove_owner(&f.package_version, &curve_fee_cap);

        destroy(proof);
        destroy(curve_fee_cap);
        destroy(metadata_cap);
        launch.put_back();
    });

    fixture.end();
}

#[test, expected_failure(abort_code = blast_core::errors::EWrongOwner, location = blast_core::owner_proof)]
fun an_owner_proof_for_one_launch_does_not_open_another_launchs_vault() {
    let mut fixture = start();
    let other_terms;

    fixture.next_tx!(LAUNCHER, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        f.graduate(&mut launch);
        other_terms = f.migrate(&mut launch);
        launch.put_back();
    });
    let mut fixture = fixture.with_fresh_registry();

    fixture.next_tx!(CREATOR, |f| {
        let launch = f.new_default_launch(CREATOR);
        let mut launch = f.open_launch(launch);
        let (curve_fee_cap, metadata_cap) = f.claim(&mut launch);

        assert!(object::id(&launch) != other_terms.origin());
        launch.prove_owner(&f.package_version, &curve_fee_cap).assert_terms(&other_terms);

        destroy(curve_fee_cap);
        destroy(metadata_cap);
        launch.put_back();
    });

    fixture.end();
}

// === Test Helpers ===

// --- Fixture ---

/// The fixture with Blast's protocol allocation set.
fun start(): LaunchFixture {
    let mut fixture = start_with_zero_protocol_allocation();
    let f = &mut fixture;

    f
        .config
        .set_protocol_allocation_for_testing(
            &f.package_version,
            &treasury_admin(),
            bps::new(PROTOCOL_MEME_BPS),
            bps::new(PROTOCOL_QUOTE_BPS),
         &mut sui::tx_context::dummy());

    fixture
}

/// Configured launch policy with Blast's default zero protocol allocation, paying `TREASURY`.
fun start_with_zero_protocol_allocation(): LaunchFixture {
    let mut scenario = test_scenario::begin(@0x0);
    let package_version = package_version::version_for_testing(scenario.ctx());
    let registry = launch::registry_for_testing(scenario.ctx());
    launch_config::init_zero_fees_for_testing(scenario.ctx());
    let runtime_config = runtime_config::new_zero_fee_share_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let mut config = scenario.take_shared<LaunchConfig>();

    let treasury = blast_treasury::new_for_testing(TREASURY, scenario.ctx());

    config.set_quote_allowed<TEST_QUOTE>(&package_version, &listing_admin(), true);
    config.set_venue_allowed_for_testing<TestVenue>(
        &package_version,
        &blast_acl::witness_for_testing<VenueAdmin>(),
        true,
     scenario.ctx());
    config.set_trade_fees_for_testing(
        &package_version,
        &fee_admin(),
        bps::new(QUOTE_FEE_BPS),
        bps::new(MEME_FEE_BPS),
     scenario.ctx());

    LaunchFixture {
        scenario,
        package_version,
        registry,
        config,
        runtime_config,
        treasury,
        clock,
    }
}

macro fun launch_next_tx(
    $fixture: &mut LaunchFixture,
    $sender: address,
    $fn: |&mut LaunchFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun launch_ctx($fixture: &mut LaunchFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun creator_admin(): AdminWitness<CreatorAdmin> {
    blast_acl::witness_for_testing()
}

fun treasury_admin(): AdminWitness<TreasuryAdmin> {
    blast_acl::witness_for_testing()
}

fun fee_admin(): AdminWitness<FeeAdmin> {
    blast_acl::witness_for_testing()
}

fun listing_admin(): AdminWitness<ListingAdmin> {
    blast_acl::witness_for_testing()
}

fun launch_end(self: LaunchFixture) {
    destroy(self);
}

/// Replaces the launch registry with a new one, as another publication would hold, so the same
/// coin type can launch again under a different derived ID.
fun launch_with_fresh_registry(self: LaunchFixture): LaunchFixture {
    let LaunchFixture {
        mut scenario,
        package_version,
        registry,
        config,
        runtime_config,
        treasury,
        clock,
    } = self;
    destroy(registry);
    let registry = launch::registry_for_testing(scenario.ctx());

    LaunchFixture { scenario, package_version, registry, config, runtime_config, treasury, clock }
}

// --- Plans ---

/// Blast's allocation added to the default creator plan, as `finalize` stores it.
fun default_plan_with_blast(): AllocationPlan {
    allocation::plan(
        bps::new(CURVE_MEME_BPS),
        bps::new(LP_MEME_BPS),
        bps::new(LP_QUOTE_BPS),
        vector[],
    ).add_protocol(
        allocation::protocol_allocation(
            bps::new(PROTOCOL_MEME_BPS),
            bps::new(PROTOCOL_QUOTE_BPS),
        ),
    )
}

fun default_plan(): AllocationPlan {
    allocation::plan(
        bps::new(CURVE_MEME_BPS),
        bps::new(LP_MEME_BPS),
        bps::new(LP_QUOTE_BPS),
        vector[],
    )
}

/// A Quote-only recipient and a Meme-only recipient beside Blast.
fun external_plan(): AllocationPlan {
    allocation::plan(
        bps::new(7_000),
        bps::new(LP_MEME_BPS),
        bps::new(9_000),
        vector[
            allocation::recipient_share(
                blast_core::payout::recipient(CREATOR, option::none()),
                bps::new(0),
                bps::new(750),
            ),
            allocation::recipient_share(
                blast_core::payout::recipient(ALICE, option::none()),
                bps::new(250),
                bps::new(0),
            ),
        ],
    )
}

/// `count` one-BPS creator recipients carved from the curve's and the pool's default shares.
fun recipients_plan(count: u64): AllocationPlan {
    allocation::plan(
        bps::new(CURVE_MEME_BPS - count),
        bps::new(LP_MEME_BPS),
        bps::new(LP_QUOTE_BPS - count),
        vector::tabulate!(count, |_| allocation::recipient_share(
            blast_core::payout::recipient(CREATOR, option::none()),
            bps::new(1),
            bps::new(1),
        )),
    )
}

/// Every LP-fee collection after Blast's share goes to the vault's owner.
fun default_fee_split(): FeeSplit {
    fee_split::new(vector[fee_split::route(fee_split::owner_destination(), bps::new(10_000))])
}

/// The owner, an address, auto-LP, holder rewards, and burn each take a part.
fun launcher_fee_split(): FeeSplit {
    fee_split::new(vector[
        fee_split::route(fee_split::owner_destination(), bps::new(4_000)),
        fee_split::route(fee_split::address_destination(LAUNCHER), bps::new(3_000)),
        fee_split::route(fee_split::auto_lp_destination(), bps::new(1_500)),
        fee_split::route(fee_split::holder_rewards_destination(), bps::new(1_000)),
        fee_split::route(fee_split::burn_destination(), bps::new(500)),
    ])
}

// --- Construction ---

fun launch_new_ticket(self: &mut LaunchFixture, creator: address): LaunchTicket<LAUNCH_TESTS> {
    self.new_ticket_with_mode(creator, false)
}

fun launch_new_ticket_with_mode(
    self: &mut LaunchFixture,
    creator: address,
    burnable: bool,
): LaunchTicket<LAUNCH_TESTS> {
    self.new_ticket_with_decimals(creator, burnable, MEME_DECIMALS)
}

fun launch_new_ticket_with_decimals(
    self: &mut LaunchFixture,
    creator: address,
    burnable: bool,
    decimals: u8,
): LaunchTicket<LAUNCH_TESTS> {
    self.new_ticket_with(creator, burnable, decimals, b"LAUNCH")
}

fun launch_new_ticket_with(
    self: &mut LaunchFixture,
    creator: address,
    burnable: bool,
    decimals: u8,
    symbol: vector<u8>,
): LaunchTicket<LAUNCH_TESTS> {
    let (ticket, treasury_cap) = launch_ticket::new(
        test_utils::create_one_time_witness<LAUNCH_TESTS>(),
        decimals,
        symbol.to_string(),
        b"Launch Test".to_string(),
        b"Normalized launch state".to_string(),
        b"".to_string(),
        creator_authority::new_address(creator),
        burnable,
        SELL_BURN_BPS,
        self.ctx!(),
    );
    // The sender holds the cap as a venue would while preparing the coin; `start_launch` takes it.
    transfer::public_transfer(treasury_cap, self.ctx!().sender());

    ticket
}

/// Starts the launch with a ticket from `venue`, sets the target, plan, and default fee split, and
/// finalizes it without an opening round.
fun launch_intake<Quote, Venue: drop>(
    self: &mut LaunchFixture,
    ticket: LaunchTicket<LAUNCH_TESTS>,
    venue: Venue,
    target: u64,
    plan: AllocationPlan,
): Launch<LAUNCH_TESTS, Quote> {
    let mut initializer = self.start_launch<Quote, _>(ticket, venue);
    initializer.set_virtual_quote(&self.package_version, VIRTUAL_QUOTE);
    initializer.set_graduation_target(&self.package_version, target);
    initializer.set_allocation_plan(&self.package_version, plan);
    initializer.set_lp_fee_split(&self.package_version, default_fee_split());
    self.finalize_launch(initializer)
}

/// An unshared launch for `creator` with the default target and plan.
fun new_default_launch(
    self: &mut LaunchFixture,
    creator: address,
): Launch<LAUNCH_TESTS, TEST_QUOTE> {
    let ticket = self.new_ticket(creator);
    self.intake(ticket, TestVenue(), MIGRATION_QUOTE_TARGET, default_plan())
}

/// An unshared launch for `CREATOR` with this target and plan.
fun launch_new_launch_with(
    self: &mut LaunchFixture,
    target: u64,
    plan: AllocationPlan,
): Launch<LAUNCH_TESTS, TEST_QUOTE> {
    let ticket = self.new_ticket(CREATOR);
    self.intake(ticket, TestVenue(), target, plan)
}

/// Starts construction with a ticket `venue` issues in the next transaction, once the Coin Registry
/// holds the ticket's currency and the sender its `TreasuryCap`.
fun launch_start<Quote, Venue: drop>(
    self: &mut LaunchFixture,
    ticket: LaunchTicket<LAUNCH_TESTS>,
    venue: Venue,
): LaunchInitializer<LAUNCH_TESTS, Quote> {
    let sender = self.scenario.sender();
    self.scenario.next_tx(sender);
    let treasury_cap = self.scenario.take_from_sender<TreasuryCap<LAUNCH_TESTS>>();

    launch::new(
        ticket,
        treasury_cap,
        &self.package_version,
        &self.config,
        migration::issue_ticket<_, Quote, _>(venue),
    )
}

/// Finalizes construction against the registered currency, paying the configured creation fee.
fun launch_finalize<Quote>(
    self: &mut LaunchFixture,
    initializer: LaunchInitializer<LAUNCH_TESTS, Quote>,
): Launch<LAUNCH_TESTS, Quote> {
    let mut currency = self.take_currency();
    let creation_fee = coin::mint_for_testing<SUI>(self.config.creation_fee(), self.ctx!());
    let launch = initializer.finalize(
        &self.package_version,
        &mut self.registry,
        &mut currency,
        &self.config,
        creation_fee,
    );
    test_scenario::return_to_address(COIN_REGISTRY, currency);

    launch
}

/// Starts a default launch in `TEST_QUOTE` and sets the default target, plan, and fee split.
fun launch_configured_initializer(
    self: &mut LaunchFixture,
    ticket: LaunchTicket<LAUNCH_TESTS>,
): LaunchInitializer<LAUNCH_TESTS, TEST_QUOTE> {
    let mut initializer = self.start_launch<TEST_QUOTE, _>(ticket, TestVenue());
    initializer.set_virtual_quote(&self.package_version, VIRTUAL_QUOTE);
    initializer.set_graduation_target(&self.package_version, MIGRATION_QUOTE_TARGET);
    initializer.set_allocation_plan(&self.package_version, default_plan());
    initializer.set_lp_fee_split(&self.package_version, default_fee_split());
    initializer
}

/// A default launch naming `partner`, paying the configured creation fee.
fun launch_intake_with_partner(
    self: &mut LaunchFixture,
    ticket: LaunchTicket<LAUNCH_TESTS>,
    partner: &Partner,
): Launch<LAUNCH_TESTS, TEST_QUOTE> {
    let mut initializer = self.configured_initializer(ticket);
    initializer.set_partner(&self.package_version, &self.config, partner, &self.clock);
    self.finalize_launch(initializer)
}

/// A partner paid `PARTNER_SHARE_BPS` of Blast's fees, which new launches may name.
fun launch_accepted_partner(self: &mut LaunchFixture): Partner {
    let partner = partners::new_for_testing(PARTNER, PARTNER_SHARE_BPS, self.ctx!());
    self.config.add_partner(&self.package_version, &fee_admin(), &partner);
    partner
}

/// Sets Blast's LP-fee share for vaults created from now on.
fun launch_set_protocol_lp_fees(self: &mut LaunchFixture, meme_bps: u64, quote_bps: u64) {
    self
        .config
        .set_protocol_lp_fees_for_testing(
            &self.package_version,
            &fee_admin(),
            bps::new(meme_bps),
            bps::new(quote_bps),
            self.ctx!(),
        );
}

fun launch_set_creation_fee(self: &mut LaunchFixture, creation_fee: u64) {
    self.config.set_creation_fee_for_testing(&self.package_version, &fee_admin(), creation_fee, self.ctx!());
}

/// Mints one extra atom with the coin's `TreasuryCap` between the ticket and the launch, as a
/// preparing venue could, then finalizes.
fun launch_mint_extra_supply_and_finalize(
    self: &mut LaunchFixture,
    ticket: LaunchTicket<LAUNCH_TESTS>,
) {
    let sender = self.scenario.sender();
    self.scenario.next_tx(sender);
    let mut treasury_cap = self.scenario.take_from_sender<TreasuryCap<LAUNCH_TESTS>>();
    destroy(treasury_cap.mint_balance(1));
    let mut initializer = launch::new(
        ticket,
        treasury_cap,
        &self.package_version,
        &self.config,
        migration::issue_ticket<_, TEST_QUOTE, _>(TestVenue()),
    );
    initializer.set_virtual_quote(&self.package_version, VIRTUAL_QUOTE);
    initializer.set_graduation_target(&self.package_version, MIGRATION_QUOTE_TARGET);
    initializer.set_allocation_plan(&self.package_version, default_plan());
    initializer.set_lp_fee_split(&self.package_version, default_fee_split());
    destroy(self.finalize_launch(initializer));
}

fun share_launch(self: &LaunchFixture, launch: Launch<LAUNCH_TESTS, TEST_QUOTE>) {
    launch.share(&self.package_version, &self.clock);
}

/// Shares the launch and takes it back in the next transaction from the same sender.
fun open_launch(
    self: &mut LaunchFixture,
    launch: Launch<LAUNCH_TESTS, TEST_QUOTE>,
): Launch<LAUNCH_TESTS, TEST_QUOTE> {
    let sender = self.ctx!().sender();
    self.share_launch(launch);
    self.scenario.next_tx(sender);
    self.take_launch()
}

// --- Trading ---

/// Reaches the specified target gap through a real public buy, with no reserve mutation or sell.
fun prepare_terminal_gap(self: &mut LaunchFixture, target: u64, gap: u64) {
    let ticket = self.new_ticket(CREATOR);
    let mut initializer = self.configured_initializer(ticket);
    initializer.set_virtual_quote(&self.package_version, target);
    initializer.set_graduation_target(&self.package_version, target);
    let launch = self.finalize_launch(initializer);
    let mut launch = self.open_launch(launch);
    let first_input = (target - gap).mul_div_ceil(10_000, 9_900);
    let (meme, refund) = self.buy(&mut launch, first_input, 1);

    assert!(meme.value() > 0);
    assert_eq!(refund.value(), 0);
    let (_, real_quote, _, _) = launch.balances_for_testing();
    assert_eq!(real_quote, target - gap);
    assert!(launch.is_live_for_testing());
    destroy(meme);
    destroy(refund);
    launch.put_back();
}

fun assert_terminal_dust_buy(target: u64, gross_meme: u64) {
    let mut fixture = start();
    fixture.prepare_terminal_gap(target, 1);

    fixture.next_tx!(ALICE, |f| {
        let mut launch = f.take_launch();
        let (meme_before, quote_before, burn_before, allocation_before) = launch.balances_for_testing();
        let (
            protocol_meme_before, creator_meme_before, protocol_quote_before, creator_quote_before,
        ) = launch.fee_totals_for_testing();
        let (meme, refund) = f.buy(&mut launch, 100, 0);
        let (meme_after, quote_after, burn_after, allocation_after) = launch.balances_for_testing();
        let (
            protocol_meme_after, creator_meme_after, protocol_quote_after, creator_quote_after,
        ) = launch.fee_totals_for_testing();

        assert_eq!(meme.value(), 0);
        assert_eq!(refund.value(), 98);
        assert_eq!(quote_after, target);
        assert_eq!(100, quote_after - quote_before + 1 + refund.value());
        assert_eq!(meme_before, meme_after + gross_meme);
        assert_eq!(burn_after, burn_before);
        assert_eq!(allocation_after, allocation_before);
        assert_eq!(protocol_meme_after, protocol_meme_before);
        assert_eq!(creator_meme_after, creator_meme_before + gross_meme);
        assert_eq!(protocol_quote_after, protocol_quote_before);
        assert_eq!(creator_quote_after, creator_quote_before + 1);
        launch.assert_lifecycle(false, true, false);
        assert_eq!(
            bcs::to_bytes(&collect_one<Bought<LAUNCH_TESTS, TEST_QUOTE>>()),
            u64_payload(
                object::id(&launch),
                vector[2, gross_meme, 0, 98, 0, gross_meme, 0, 1, meme_after, target],
            ),
        );
        f.migrate(&mut launch);
        assert!(launch.is_migrated_for_testing());
        destroy(meme);
        destroy(refund);
        destroy(launch);
    });

    fixture.end();
}

fun launch_buy(
    self: &mut LaunchFixture,
    launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>,
    amount: u64,
    min_meme_out: u64,
): (Coin<LAUNCH_TESTS>, Coin<TEST_QUOTE>) {
    let quote = coin::mint_for_testing<TEST_QUOTE>(amount, self.ctx!());
    launch.buy(
        &self.package_version,
        &self.runtime_config,
        quote,
        min_meme_out,
        self.ctx!(),
    )
}

/// Buys past the default target; the excess is refunded.
fun launch_graduate(self: &mut LaunchFixture, launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>) {
    let (meme, refund) = self.buy(launch, 30_000_000, 1);
    destroy(meme);
    destroy(refund);
}

/// Buys, sells everything back to accrue a sell burn, then graduates. Returns the Meme that
/// migration will dispose of: the curve's unsold reserve plus the pending burn.
fun reach_migration_after_sell(
    self: &mut LaunchFixture,
    launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>,
): u64 {
    let (meme, refund) = self.buy(launch, 10_000_000, 1);
    let quote = launch.sell(
        &self.package_version,
        &self.runtime_config,
        meme,
        1,
        self.ctx!(),
    );
    let (_, _, pending_burn_after_sell, _) = launch.balances_for_testing();
    destroy(refund);
    destroy(quote);
    self.graduate(launch);
    let (meme_reserve, _, pending_burn, _) = launch.balances_for_testing();

    assert!(pending_burn_after_sell > 0);
    assert_eq!(pending_burn, pending_burn_after_sell);
    assert!(meme_reserve > 0);
    assert!(launch.is_migration_ready_for_testing());

    meme_reserve + pending_burn
}

fun launch_claim(
    self: &mut LaunchFixture,
    launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>,
): (CurveFeeCap<LAUNCH_TESTS>, CreatorMetadataCap<LAUNCH_TESTS>) {
    launch.claim_creator_caps(
        &self.package_version,
        &self.runtime_config,
        option::none(),
        &self.clock,
        self.ctx!(),
    )
}

// --- Migration ---

/// Migrates, redeems the hand-off as the stored venue, discards the pool's share, and returns the
/// vault's terms.
fun migrate(self: &mut LaunchFixture, launch: &mut Launch<LAUNCH_TESTS, TEST_QUOTE>): VaultTerms {
    let mut currency = self.take_currency();
    let (meme, quote, terms) = launch
        .migrate(&self.package_version, &self.config, &mut currency, &self.clock, self.ctx!())
        .redeem(TestVenue());
    destroy(meme);
    destroy(quote);
    destroy(currency);

    terms
}

// --- Storage ---

/// The one-time-witness path delivers the currency to the Coin Registry address.
fun launch_return_currency(_: &LaunchFixture, currency: Currency<LAUNCH_TESTS>) {
    test_scenario::return_to_address(COIN_REGISTRY, currency);
}

fun launch_take_creator_metadata_cap(
    self: &LaunchFixture
): CreatorMetadataCap<LAUNCH_TESTS> {
    self.scenario.take_from_sender()
}

fun launch_take_currency(self: &LaunchFixture): Currency<LAUNCH_TESTS> {
    self.scenario.take_from_address(COIN_REGISTRY)
}

fun launch_take_coin<T>(self: &LaunchFixture, owner: address): Coin<T> {
    self.scenario.take_from_address(owner)
}

fun launch_has_vesting<T>(_: &LaunchFixture): bool {
    test_scenario::has_most_recent_shared<Vesting<T>>()
}

/// The ID of the most recently shared `Vesting<T>`, or none.
fun launch_vesting_id<T>(_: &LaunchFixture): Option<ID> {
    test_scenario::most_recent_id_shared<Vesting<T>>()
}

fun launch_has_coin<T>(_: &LaunchFixture, owner: address): bool {
    test_scenario::has_most_recent_for_address<Coin<T>>(owner)
}

/// Points the core treasury at `destination` through its delayed change, as a treasury
/// administrator would, advancing the fixture clock past its delay.
fun launch_rotate_treasury(self: &mut LaunchFixture, destination: address) {
    let now_ms = self.clock.timestamp_ms();
    self
        .treasury
        .schedule_destination(&treasury_admin(), destination, TREASURY_DELAY_MS, &self.clock);
    self.clock.set_for_testing(now_ms + TREASURY_DELAY_MS);
    self.treasury.apply_destination(&self.clock);
}

/// Takes and burns what earlier transactions paid `owner`: exactly one coin of each positive
/// amount, holding that amount, and no coin of an asset paid zero.
fun launch_burn_paid(self: &LaunchFixture, owner: address, meme: u64, quote: u64, sui: u64) {
    self.burn_paid_coin<LAUNCH_TESTS>(owner, meme);
    self.burn_paid_coin<TEST_QUOTE>(owner, quote);
    self.burn_paid_coin<SUI>(owner, sui);
}

fun launch_burn_paid_coin<T>(self: &LaunchFixture, owner: address, paid: u64) {
    if (paid > 0) assert_eq!(self.take_coin<T>(owner).burn_for_testing(), paid);

    assert!(!self.has_coin<T>(owner));
}

fun launch_take_shared(self: &LaunchFixture): Launch<LAUNCH_TESTS, TEST_QUOTE> {
    self.scenario.take_shared<Launch<LAUNCH_TESTS, TEST_QUOTE>>()
}

fun launch_take_curve_fee_cap(self: &LaunchFixture): CurveFeeCap<LAUNCH_TESTS> {
    self.scenario.take_from_sender<CurveFeeCap<LAUNCH_TESTS>>()
}

fun launch_has_curve_fee_cap(self: &LaunchFixture): bool {
    self.scenario.has_most_recent_for_sender<CurveFeeCap<LAUNCH_TESTS>>()
}

/// Returns a taken launch to shared storage for a later transaction.
fun launch_put_back(launch: Launch<LAUNCH_TESTS, TEST_QUOTE>) {
    test_scenario::return_shared(launch);
}

// --- Assertions ---

fun assert_launch_snapshot(launch: &Launch<LAUNCH_TESTS, TEST_QUOTE>) {
    let (curve_meme, real_quote, pending_burn, allocated_meme) = launch.balances_for_testing();
    let (quote_fee_bps, meme_fee_bps) = launch.policy_for_testing();

    assert_eq!(curve_meme, EXPECTED_CURVE_MEME);
    assert_eq!(real_quote, 0);
    assert_eq!(pending_burn, 0);
    assert_eq!(allocated_meme, EXPECTED_PROTOCOL_MEME + EXPECTED_POOL_MEME);
    assert_eq!(launch.virtual_quote_for_testing(), VIRTUAL_QUOTE);
    assert_eq!(launch.graduation_target_for_testing(), MIGRATION_QUOTE_TARGET);
    assert_eq!(quote_fee_bps, QUOTE_FEE_BPS);
    assert_eq!(meme_fee_bps, MEME_FEE_BPS);
    assert_eq!(*launch.allocation_plan_for_testing(), default_plan_with_blast());
    assert_eq!(launch.venue_for_testing(), type_name::with_original_ids<TestVenue>());
}

fun assert_launch_lifecycle(
    launch: &Launch<LAUNCH_TESTS, TEST_QUOTE>,
    live: bool,
    migration_ready: bool,
    migrated: bool,
) {
    assert_eq!(launch.is_live_for_testing(), live);
    assert_eq!(launch.is_migration_ready_for_testing(), migration_ready);
    assert_eq!(launch.is_migrated_for_testing(), migrated);
}

// --- Events ---

/// Every `T` payload emitted in this transaction, unwrapped from the package event envelope.
/// The latest creator-cap proposal for the operation keyed by `K`.
fun last_cap_proposal<K: copy + drop + store>(): CapProposal {
    let mut scheduled = event::events_by_type<ActionScheduled<K, address>>();
    let (owner, _, change, delay_ms, ready_at_ms) = scheduled.pop_back().action_scheduled_fields();

    CapProposal { owner, recipient: change.action(), delay_ms, ready_at_ms }
}

/// The recipients of the cancelled creator-cap proposals keyed by `K`, in order.
fun cancelled_cap_recipients<K: copy + drop + store>(): vector<Option<address>> {
    event::events_by_type<ActionCancelled<K, address>>().map!(|cancelled| {
        let (_, _, change, _, _) = cancelled.action_cancelled_fields();
        change.action()
    })
}

/// The recipients of the applied creator-cap proposals keyed by `K`, in order.
fun applied_cap_recipients<K: copy + drop + store>(): vector<Option<address>> {
    event::events_by_type<ActionApplied<K, address>>().map!(|applied| {
        let (_, _, change, _) = applied.action_applied_fields();
        change.action()
    })
}

fun collect<T: copy + drop>(): vector<T> {
    event::events_by_type<T>()
}

fun collect_one<T: copy + drop>(): T {
    let mut payloads = collect<T>();
    assert_eq!(payloads.length(), 1);
    payloads.pop_back()
}

/// Expected bytes of a payload whose fields after the launch ID are all `u64`: `Bought`, `Sold`,
/// `LaunchShared`, `CreatorFeesClaimed`, and `ProtocolFeesAccrued`.
fun u64_payload(launch_id: ID, fields: vector<u64>): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    fields.do!(|field| expected.append(bcs::to_bytes(&field)));
    expected
}

/// Expected `ProtocolFeesClaimed` bytes: the treasury paid, then Blast's three amounts and the
/// partner's three.
/// Expected `ProtocolFeesPaid` bytes: the treasury's Meme, Quote, and SUI, then the partner's.
fun protocol_fees_paid_bytes(
    launch_id: ID,
    treasury: address,
    partner_id: Option<ID>,
    amounts: vector<u64>,
): vector<u8> {
    let mut expected = bcs::to_bytes(&type_name::with_original_ids<PackageWitness>());
    expected.append(bcs::to_bytes(&launch_id));
    expected.append(bcs::to_bytes(&treasury));
    3u64.do!(|i| expected.append(bcs::to_bytes(&amounts[i])));
    expected.append(bcs::to_bytes(&partner_id));
    3u64.do!(|i| expected.append(bcs::to_bytes(&amounts[i + 3])));
    expected
}

/// Expected `LaunchTicketCreated` bytes for a fixture ticket designating `CREATOR` by address.
fun ticket_created_bytes(ticket_id: ID, metadata_cap_id: ID, burnable: bool): vector<u8> {
    let decimals = MEME_DECIMALS;
    let mut expected = bcs::to_bytes(&ticket_id);
    expected.append(bcs::to_bytes(&decimals));
    expected.append(bcs::to_bytes(&metadata_cap_id));
    expected.append(bcs::to_bytes(&creator_authority::new_address(CREATOR)));
    expected.append(bcs::to_bytes(&burnable));
    expected.append(u64_bytes(SELL_BURN_BPS));
    expected
}

/// Expected `LaunchCreated` bytes for the fixture's cold policy, without an opening round, with Blast
/// first, a free creation, and no partner.
fun launch_created_bytes(launch_id: ID, ticket_id: ID): vector<u8> {
    launch_created_bytes_with(launch_id, ticket_id, 0, option::none())
}

/// `launch_created_bytes` with this creation fee and partner.
fun launch_created_bytes_with(
    launch_id: ID,
    ticket_id: ID,
    creation_fee: u64,
    partner_id: Option<ID>,
): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&ticket_id));
    expected.append(bcs::to_bytes(&type_name::with_original_ids<TestVenue>()));
    expected.append(bcs::to_bytes(&default_fee_split()));
    expected.append(u64_bytes(VIRTUAL_QUOTE));
    expected.append(u64_bytes(MIGRATION_QUOTE_TARGET));
    expected.append(u64_bytes(QUOTE_FEE_BPS));
    expected.append(u64_bytes(MEME_FEE_BPS));
    expected.append(bcs::to_bytes(&default_plan_with_blast()));
    expected.append(u64_bytes(0));
    expected.append(u64_bytes(creation_fee));
    expected.append(bcs::to_bytes(&partner_id));
    expected
}

fun allocation_paid_bytes(
    launch_id: ID,
    destination: address,
    meme: u64,
    quote: u64,
    meme_vesting_id: Option<ID>,
    quote_vesting_id: Option<ID>,
): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&destination));
    expected.append(u64_bytes(meme));
    expected.append(u64_bytes(quote));
    expected.append(bcs::to_bytes(&meme_vesting_id));
    expected.append(bcs::to_bytes(&quote_vesting_id));
    expected
}

/// Expected bytes shared by `CurveFeeCapReassigned` and `CreatorMetadataCapReassigned`.
fun cap_reassigned_bytes(launch_id: ID, cap_id: ID, recipient: address): vector<u8> {
    let mut expected = bcs::to_bytes(&launch_id);
    expected.append(bcs::to_bytes(&cap_id));
    expected.append(bcs::to_bytes(&recipient));
    expected
}

/// Expected `Migrated` bytes.
fun migrated_bytes(
    launch_id: ID,
    meme: u64,
    quote: u64,
    disposed_meme: u64,
    total_supply_after: u64,
): vector<u8> {
    u64_payload(launch_id, vector[meme, quote, disposed_meme, total_supply_after])
}

/// Serializes one constant by value, so no test borrows a constant in place.
fun u64_bytes(value: u64): vector<u8> {
    bcs::to_bytes(&value)
}

/// Sets `bits` through the generic administration, as a pause administrator would.
fun pause_bits(self: &mut LaunchFixture, bits: u8) {
    blast_admin::package_admin::pause(
        &mut self.package_version,
        &blast_acl::witness_for_testing<PauseAdmin<BLAST_FUN>>(),
        bits,
    );
}

/// Clears `bits` through the generic administration without the release delay checks.
fun clear_bits(self: &mut LaunchFixture, bits: u8) {
    let ctx = self.scenario.ctx();
    blast_fun::blast_fun::clear_pause_bits_for_testing(&mut self.package_version, bits, ctx);
}

// === Imports ===

use blast_admin::{
    blast_acl::{Self, AdminWitness},
    delayed_action::{ActionApplied, ActionCancelled, ActionScheduled},
    package_admin::PauseAdmin,
    package_version::PackageVersion
};

use blast_core::{
    blast_core_events::ProtocolFeesPaid,
    blast_domain::{VenueAdmin, CancelAdmin, CreatorAdmin, FeeAdmin, ListingAdmin, TreasuryAdmin},
    blast_treasury::{Self, Treasury},
    bps,
    fee_split::{Self, FeeSplit},
    migration::{Self, VaultTerms}
};

use blast_fun::{
    allocation::{Self, AllocationPlan},
    creator_authority::{Self, CreatorMetadataCap, CurveFeeCap},
    curve,
    constants,
    events::{
        Bought,
        CreatorCapsClaimed,
        CreatorFeesClaimed,
        CurveFeeCapReassigned,
        LaunchCreated,
        LaunchShared,
        LaunchTicketCreated,
        MemeMetadataUpdated,
        CreatorMetadataCapReassigned,
        Migrated,
        MigrationAllocationPaid,
        ProtocolFeesAccrued,
        Sold,
    },
    launch::{
        Self,
        CurveFeeCapReassignment,
        Launch,
        LaunchInitializer,
        LaunchRegistry,
        CreatorMetadataCapReassignment
    },
    launch_config::{Self, LaunchConfig},
    launch_ticket::{Self, LaunchTicket},
    blast_fun::{Self as package_version, BLAST_FUN, PackageWitness},
    runtime_config::{Self, RuntimeConfig},
};

use blast_fun_vesting::blast_fun_linear_vesting::Vesting;

use blast_partners::blast_partners::{Self as partners, Partner, PartnerPaid};

use std::{bcs, type_name, unit_test::{assert_eq, destroy}};

use sui::{
    balance::{Self, Balance},
    clock::{Self, Clock},
    coin::{Self, Coin, TreasuryCap},
    coin_registry::Currency,
    derived_object,
    event,
    sui::SUI,
    test_scenario::{Self, Scenario},
    test_utils,
};

use fun pause_bits as LaunchFixture.pause;

use fun clear_bits as LaunchFixture.clear_pause_bits;

use fun launch_ctx as LaunchFixture.ctx;

use fun launch_end as LaunchFixture.end;

use fun launch_with_fresh_registry as LaunchFixture.with_fresh_registry;

use fun launch_next_tx as LaunchFixture.next_tx;

use fun launch_new_ticket as LaunchFixture.new_ticket;

use fun launch_new_ticket_with_mode as LaunchFixture.new_ticket_with_mode;

use fun launch_new_ticket_with_decimals as LaunchFixture.new_ticket_with_decimals;

use fun launch_new_ticket_with as LaunchFixture.new_ticket_with;

use fun launch_intake as LaunchFixture.intake;

use fun launch_new_launch_with as LaunchFixture.new_launch_with;

use fun launch_start as LaunchFixture.start_launch;

use fun launch_finalize as LaunchFixture.finalize_launch;

use fun launch_configured_initializer as LaunchFixture.configured_initializer;

use fun launch_intake_with_partner as LaunchFixture.intake_with_partner;

use fun launch_accepted_partner as LaunchFixture.accepted_partner;

use fun launch_set_creation_fee as LaunchFixture.set_creation_fee_for_testing;

use fun launch_set_protocol_lp_fees as LaunchFixture.set_protocol_lp_fees;

use fun launch_mint_extra_supply_and_finalize as LaunchFixture.mint_extra_supply_and_finalize;

use fun launch_buy as LaunchFixture.buy;

use fun launch_graduate as LaunchFixture.graduate;

use fun launch_claim as LaunchFixture.claim;

use fun launch_take_currency as LaunchFixture.take_currency;

use fun launch_take_coin as LaunchFixture.take_coin;

use fun launch_has_coin as LaunchFixture.has_coin;

use fun launch_has_vesting as LaunchFixture.has_vesting;
use fun launch_vesting_id as LaunchFixture.vesting_id;

use fun launch_burn_paid as LaunchFixture.burn_paid;

use fun launch_rotate_treasury as LaunchFixture.rotate_treasury;

use fun launch_burn_paid_coin as LaunchFixture.burn_paid_coin;

use fun launch_take_shared as LaunchFixture.take_launch;

use fun launch_take_curve_fee_cap as LaunchFixture.take_curve_fee_cap;

use fun launch_has_curve_fee_cap as LaunchFixture.has_curve_fee_cap;

use fun assert_launch_snapshot as Launch.assert_snapshot;

use fun assert_launch_lifecycle as Launch.assert_lifecycle;

use fun launch_put_back as Launch.put_back;

use fun launch_return_currency as LaunchFixture.return_currency;
use fun launch_take_creator_metadata_cap as LaunchFixture.take_creator_metadata_cap;
