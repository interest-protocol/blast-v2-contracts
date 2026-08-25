#[test_only]
module blast_fun::creator_authority_tests;

use blast_fun::{acl, constants, creator_authority, events, runtime_config};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, event, test_scenario::{Self, Scenario}};

// === Constants ===

const LAUNCHER: address = @0xA11CE;
const CREATOR: address = @0xC0FFEE;
const PROTOCOL_ADMIN: address = @0xAD;
const NEW_SUPER_ADMIN: address = @0xB0B;
const X_CLAIMANT: address = @0xC0FFEE;
const NOW_MS: u64 = 1_000_000;
const EXPIRY_MS: u64 = 2_000_000;

// === Test-Only Types ===

public struct TEST_MEME() has drop;
public struct OTHER_MEME() has drop;

public struct AdminFixture {
    scenario: Scenario,
    super_admin_cap: acl::SuperAdminCap,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
    config: runtime_config::RuntimeConfig,
}

// === Tests ===

#[test]
fun singleton_creation_events_use_generic_wrapper() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let authority_id = object::id(&authority);
    let super_admin_cap_id = object::id(&super_admin_cap);
    let config_id = object::id(&config);

    let created = events::collect_one<events::ProtocolAuthorityCreated>(0);
    let (
        emitted_authority_id,
        emitted_super_admin_cap_id,
        emitted_recipient,
        emitted_max_admins,
        emitted_delay_ms,
    ) = created.protocol_authority_created_fields();
    let runtime_config_created = events::collect_one<events::RuntimeConfigCreated>(0);
    let (emitted_runtime_config_id, protocol_fee_share_bps) =
        runtime_config_created.runtime_config_created_fields();

    assert_eq!(emitted_authority_id, authority_id);
    assert_eq!(emitted_super_admin_cap_id, super_admin_cap_id);
    assert_eq!(emitted_recipient, LAUNCHER);
    assert_eq!(emitted_max_admins, constants::max_admins!());
    assert_eq!(
        emitted_delay_ms,
        constants::super_admin_transfer_delay_ms!(),
    );
    assert_eq!(emitted_runtime_config_id, config_id);
    assert_eq!(protocol_fee_share_bps, 0);
    assert!(event::events_by_type<events::ProtocolAuthorityCreated>().is_empty());
    assert!(event::events_by_type<events::RuntimeConfigCreated>().is_empty());

    destroy(super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(scenario);
}

#[test]
fun super_admin_grants_global_admin_that_configures_x_signer() {
    let mut fixture = start_admin(PROTOCOL_ADMIN);
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    fixture.config.set_x_claim_signer(
        &admin_witness,
        x_signer_public_key(),
    );

    fixture.end();
}

#[test]
fun super_admin_grant_is_replay_complete_and_delivers_the_cap() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());

    authority.grant_admin(
        &super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );

    let granted = events::collect_one<events::AdminGranted>(0);
    let (emitted_admin_cap_id, recipient) = granted.admin_granted_fields();
    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();

    assert_eq!(emitted_admin_cap_id, admin_cap.admin_cap_id_for_testing());
    assert_eq!(recipient, PROTOCOL_ADMIN);

    destroy(super_admin_cap);
    destroy(authority);
    destroy(admin_cap);
    destroy(config);
    destroy(scenario);
}

#[test]
fun super_admin_revocation_identifies_only_the_removed_admin() {
    let AdminFixture {
        scenario,
        super_admin_cap,
        mut authority,
        admin_cap,
        config,
    } = start_admin(LAUNCHER);
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();

    authority.revoke_admin(&super_admin_cap, admin_cap_id);

    let revoked = events::collect_one<events::AdminRevoked>(0);
    assert_eq!(revoked.admin_revoked_fields(), admin_cap_id);

    destroy(super_admin_cap);
    destroy(authority);
    destroy(admin_cap);
    destroy(config);
    destroy(scenario);
}

#[test]
fun x_claim_signer_set_event_is_replay_complete() {
    let mut fixture = start_admin(LAUNCHER);
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.set_x_claim_signer(
        &admin_witness,
        x_signer_public_key(),
    );

    let signer_set = events::collect_one<events::XClaimSignerSet>(0);
    let (previous_public_key, signer_public_key) =
        signer_set.x_claim_signer_set_fields();
    assert!(previous_public_key.is_empty());
    assert_eq!(signer_public_key, x_signer_public_key());

    fixture.end();
}

#[test]
fun x_claim_signer_revoked_event_is_replay_complete() {
    let mut fixture = start_admin(LAUNCHER);
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    fixture.config.set_x_claim_signer(
        &admin_witness,
        x_signer_public_key(),
    );

    fixture.config.revoke_x_claim_signer(&admin_witness);

    let signer_revoked = events::collect_one<events::XClaimSignerRevoked>(0);
    let previous_public_key = signer_revoked.x_claim_signer_revoked_fields();
    assert_eq!(previous_public_key, x_signer_public_key());

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 2)]
fun x_claim_signer_rejects_invalid_public_key_length() {
    let mut fixture = start_admin(LAUNCHER);
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.set_x_claim_signer(&admin_witness, x"00");

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 3)]
fun x_claim_signer_cannot_revoke_while_disabled() {
    let mut fixture = start_admin(LAUNCHER);
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);

    fixture.config.revoke_x_claim_signer(&admin_witness);

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 0)]
fun revoked_admin_cannot_configure_x_signer() {
    let AdminFixture {
        scenario,
        super_admin_cap,
        mut authority,
        admin_cap,
        mut config,
    } = start_admin(LAUNCHER);
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();
    authority.revoke_admin(&super_admin_cap, admin_cap_id);
    let admin_witness = authority.sign_in(&admin_cap);

    config.set_x_claim_signer(
        &admin_witness,
        x_signer_public_key(),
    );

    AdminFixture {
        scenario,
        super_admin_cap,
        authority,
        admin_cap,
        config,
    }.end();
}

#[test]
fun active_admin_can_destroy_cap_and_renounce_membership() {
    let AdminFixture {
        scenario,
        super_admin_cap,
        mut authority,
        admin_cap,
        config,
    } = start_admin(LAUNCHER);
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();

    authority.destroy_admin_cap(admin_cap);

    let destroyed = events::collect_one<events::AdminDestroyed>(0);
    let (emitted_admin_cap_id, was_active) = destroyed.admin_destroyed_fields();
    assert_eq!(emitted_admin_cap_id, admin_cap_id);
    assert!(was_active);

    destroy(super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(scenario);
}

#[test]
fun revoked_admin_can_destroy_inert_cap() {
    let AdminFixture {
        scenario,
        super_admin_cap,
        mut authority,
        admin_cap,
        config,
    } = start_admin(LAUNCHER);
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();

    authority.revoke_admin(&super_admin_cap, admin_cap_id);
    authority.destroy_admin_cap(admin_cap);

    let destroyed = events::collect_one<events::AdminDestroyed>(0);
    let (emitted_admin_cap_id, was_active) = destroyed.admin_destroyed_fields();
    assert_eq!(emitted_admin_cap_id, admin_cap_id);
    assert!(!was_active);

    destroy(super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 0)]
fun destroyed_active_admin_is_removed_from_registry() {
    let AdminFixture {
        scenario,
        super_admin_cap,
        mut authority,
        admin_cap,
        config,
    } = start_admin(LAUNCHER);
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();

    authority.destroy_admin_cap(admin_cap);
    authority.revoke_admin(&super_admin_cap, admin_cap_id);

    destroy(super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 0)]
fun admin_registered_in_another_protocol_registry_is_rejected() {
    let AdminFixture {
        mut scenario,
        super_admin_cap: first_super_admin,
        authority: first_authority,
        admin_cap: first_admin,
        config: first_config,
    } = start_admin(LAUNCHER);
    let (second_super_admin, second_authority, second_config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let mut second_config = second_config;
    let admin_witness = second_authority.sign_in(&first_admin);

    second_config.set_x_claim_signer(
        &admin_witness,
        x_signer_public_key(),
    );

    destroy(first_super_admin);
    destroy(first_admin);
    destroy(first_authority);
    destroy(first_config);
    destroy(scenario);
    destroy(second_super_admin);
    destroy(second_authority);
    destroy(second_config);
}

#[test]
#[expected_failure(abort_code = 17)]
fun active_admin_registry_is_bounded() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let mut index = 0u64;
    while (index < constants::max_admins!()) {
        authority.grant_admin(&super_admin_cap, PROTOCOL_ADMIN, scenario.ctx());
        index = index + 1;
    };
    authority.grant_admin(&super_admin_cap, PROTOCOL_ADMIN, scenario.ctx());

    destroy(super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 16)]
fun super_admin_cannot_grant_zero_address_admin() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());

    authority.grant_admin(
        &super_admin_cap,
        @0x0,
        scenario.ctx(),
    );

    destroy(super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(scenario);
}

#[test]
fun super_admin_transfer_requires_delay_and_recipient_acceptance() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (old_super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let old_super_admin_cap_id = object::id(&old_super_admin_cap);
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    authority.begin_super_admin_transfer(
        &old_super_admin_cap,
        NEW_SUPER_ADMIN,
        &test_clock,
        scenario.ctx(),
    );

    let started = events::collect_one<events::SuperAdminTransferStarted>(0);
    let (started_recipient, execute_after_ms) =
        started.super_admin_transfer_started_fields();
    assert_eq!(started_recipient, NEW_SUPER_ADMIN);
    assert_eq!(
        execute_after_ms,
        NOW_MS + constants::super_admin_transfer_delay_ms!(),
    );

    test_clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    scenario.next_tx(NEW_SUPER_ADMIN);
    authority.accept_super_admin_transfer(&test_clock, scenario.ctx());

    let transferred = events::collect_one<events::SuperAdminTransferred>(0);
    let (previous_super_admin_cap_id, new_super_admin_cap_id, recipient) =
        transferred.super_admin_transferred_fields();
    assert_eq!(previous_super_admin_cap_id, old_super_admin_cap_id);
    assert_eq!(recipient, NEW_SUPER_ADMIN);

    scenario.next_tx(NEW_SUPER_ADMIN);
    let new_super_admin_cap = scenario.take_from_sender<acl::SuperAdminCap>();
    assert_eq!(new_super_admin_cap_id, object::id(&new_super_admin_cap));
    authority.grant_admin(
        &new_super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );

    authority.destroy_retired_super_admin_cap(old_super_admin_cap);
    destroy(new_super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 23)]
fun active_super_admin_cap_cannot_be_destroyed() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());

    authority.destroy_retired_super_admin_cap(super_admin_cap);

    destroy(authority);
    destroy(config);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 22)]
fun super_admin_transfer_rejects_timestamp_overflow() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(std::u64::max_value!());

    authority.begin_super_admin_transfer(
        &super_admin_cap,
        NEW_SUPER_ADMIN,
        &test_clock,
        scenario.ctx(),
    );

    destroy(test_clock);
    destroy(super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 28)]
fun super_admin_transfer_rejects_unchanged_pending_recipient_before_timestamp_work() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    authority.begin_super_admin_transfer(
        &super_admin_cap,
        NEW_SUPER_ADMIN,
        &test_clock,
        scenario.ctx(),
    );
    test_clock.set_for_testing(std::u64::max_value!());
    authority.begin_super_admin_transfer(
        &super_admin_cap,
        NEW_SUPER_ADMIN,
        &test_clock,
        scenario.ctx(),
    );

    destroy(super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
fun super_admin_transfer_replaces_different_pending_recipient() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (old_super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    authority.begin_super_admin_transfer(
        &old_super_admin_cap,
        NEW_SUPER_ADMIN,
        &test_clock,
        scenario.ctx(),
    );
    test_clock.set_for_testing(NOW_MS + 1);
    authority.begin_super_admin_transfer(
        &old_super_admin_cap,
        PROTOCOL_ADMIN,
        &test_clock,
        scenario.ctx(),
    );

    let cancelled = events::collect_one<events::SuperAdminTransferCancelled>(0);
    assert_eq!(
        cancelled.super_admin_transfer_cancelled_fields(),
        NEW_SUPER_ADMIN,
    );
    let mut started = events::collect<events::SuperAdminTransferStarted>();
    assert_eq!(started.length(), 2);
    let second_started = started.pop_back();
    let first_started = started.pop_back();
    let (first_recipient, first_execute_after_ms) =
        first_started.super_admin_transfer_started_fields();
    let (second_recipient, second_execute_after_ms) =
        second_started.super_admin_transfer_started_fields();
    assert_eq!(first_recipient, NEW_SUPER_ADMIN);
    assert_eq!(
        first_execute_after_ms,
        NOW_MS + constants::super_admin_transfer_delay_ms!(),
    );
    assert_eq!(second_recipient, PROTOCOL_ADMIN);
    assert_eq!(
        second_execute_after_ms,
        NOW_MS + 1 + constants::super_admin_transfer_delay_ms!(),
    );

    test_clock.set_for_testing(
        NOW_MS + 1 + constants::super_admin_transfer_delay_ms!(),
    );
    scenario.next_tx(PROTOCOL_ADMIN);
    authority.accept_super_admin_transfer(&test_clock, scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let new_super_admin_cap = scenario.take_from_sender<acl::SuperAdminCap>();
    authority.destroy_retired_super_admin_cap(old_super_admin_cap);
    destroy(new_super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 15)]
fun accepted_super_admin_transfer_invalidates_previous_root_cap() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (old_super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);
    authority.begin_super_admin_transfer(
        &old_super_admin_cap,
        NEW_SUPER_ADMIN,
        &test_clock,
        scenario.ctx(),
    );
    test_clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    scenario.next_tx(NEW_SUPER_ADMIN);
    authority.accept_super_admin_transfer(&test_clock, scenario.ctx());

    authority.grant_admin(
        &old_super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );

    destroy(old_super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 18)]
fun super_admin_transfer_rejects_zero_recipient() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let test_clock = clock::create_for_testing(scenario.ctx());

    authority.begin_super_admin_transfer(
        &super_admin_cap,
        @0x0,
        &test_clock,
        scenario.ctx(),
    );

    destroy(super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 21)]
fun super_admin_transfer_rejects_early_acceptance() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);
    authority.begin_super_admin_transfer(
        &super_admin_cap,
        NEW_SUPER_ADMIN,
        &test_clock,
        scenario.ctx(),
    );

    scenario.next_tx(NEW_SUPER_ADMIN);
    authority.accept_super_admin_transfer(&test_clock, scenario.ctx());

    destroy(super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 20)]
fun super_admin_transfer_rejects_wrong_recipient() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);
    authority.begin_super_admin_transfer(
        &super_admin_cap,
        NEW_SUPER_ADMIN,
        &test_clock,
        scenario.ctx(),
    );
    test_clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());

    scenario.next_tx(@0xBAD);
    authority.accept_super_admin_transfer(&test_clock, scenario.ctx());

    destroy(super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 19)]
fun cancelled_super_admin_transfer_cannot_be_accepted() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);
    authority.begin_super_admin_transfer(
        &super_admin_cap,
        NEW_SUPER_ADMIN,
        &test_clock,
        scenario.ctx(),
    );
    authority.cancel_super_admin_transfer(&super_admin_cap);
    test_clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    scenario.next_tx(NEW_SUPER_ADMIN);
    authority.accept_super_admin_transfer(&test_clock, scenario.ctx());

    destroy(super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 19)]
fun super_admin_cannot_cancel_without_pending_transfer() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());

    authority.cancel_super_admin_transfer(&super_admin_cap);

    destroy(super_admin_cap);
    destroy(authority);
    destroy(config);
    destroy(scenario);
}

#[test]
fun package_init_delivers_only_root() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    acl::init_for_testing(scenario.ctx());

    let effects = scenario.next_tx(LAUNCHER);
    assert_eq!(effects.num_user_events(), 1);
    assert!(scenario.has_most_recent_for_sender<acl::SuperAdminCap>());
    assert!(!scenario.has_most_recent_for_sender<acl::AdminCap>());
    let super_admin_cap = scenario.take_from_sender<acl::SuperAdminCap>();
    let authority = scenario.take_shared<acl::ProtocolAuthority>();

    destroy(super_admin_cap);
    destroy(authority);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 3)]
fun package_init_starts_x_signer_disabled() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    runtime_config::init_for_testing(scenario.ctx());

    scenario.next_tx(LAUNCHER);
    let config = scenario.take_shared<runtime_config::RuntimeConfig>();
    let creator_state = new_x_authority();
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    scenario.next_tx(X_CLAIMANT);
    let cap = claim_x(creator_state, &config, &test_clock, &mut scenario);
    destroy(cap);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
fun address_creator_claim_returns_composable_cap_without_attestation() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, protocol_authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let creator_state = creator_authority::new_address(CREATOR)
        .into_authority<TEST_MEME>();
    let test_clock = clock::create_for_testing(scenario.ctx());
    scenario.next_tx(CREATOR);
    let cap = creator_state.claim_creator_cap<TEST_MEME>(
        &config,
        option::none(),
        &test_clock,
        scenario.ctx(),
    );
    transfer::public_transfer(cap, PROTOCOL_ADMIN);

    let claimed = events::collect_one<events::CreatorCapClaimed>(0);
    let (meme, x_identity_hash, creator, x_claim_expiry_ms) =
        claimed.creator_cap_claimed_fields();
    assert_eq!(
        meme,
        std::type_name::with_original_ids<TEST_MEME>(),
    );
    assert!(x_identity_hash.is_none());
    assert_eq!(creator, CREATOR);
    assert!(x_claim_expiry_ms.is_none());

    let effects = scenario.next_tx(PROTOCOL_ADMIN);
    assert_eq!(effects.num_user_events(), 1);
    assert!(scenario.has_most_recent_for_sender<creator_authority::CreatorCap<TEST_MEME>>());
    assert!(!scenario.has_most_recent_for_sender<creator_authority::CreatorCap<OTHER_MEME>>());
    let cap = scenario.take_from_sender<creator_authority::CreatorCap<TEST_MEME>>();
    destroy(cap);
    destroy(test_clock);
    destroy(super_admin_cap);
    destroy(protocol_authority);
    destroy(config);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 9)]
fun address_identity_rejects_zero_creator_address() {
    let creator_identity = creator_authority::new_address(@0x0);
    destroy(creator_identity);
}

#[test]
#[expected_failure(abort_code = 26)]
fun address_creator_claim_rejects_different_sender() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_runtime_config(scenario.ctx());
    let creator_state = creator_authority::new_address(CREATOR)
        .into_authority<TEST_MEME>();
    let test_clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(@0xBAD);
    let cap = creator_state.claim_creator_cap<TEST_MEME>(
        &config,
        option::none(),
        &test_clock,
        scenario.ctx(),
    );
    destroy(cap);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 11)]
fun address_creator_claim_rejects_x_attestation() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_runtime_config(scenario.ctx());
    let creator_state = creator_authority::new_address(CREATOR)
        .into_authority<TEST_MEME>();
    let test_clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let cap = creator_state.claim_creator_cap<TEST_MEME>(
        &config,
        option::some(x_claim_attestation()),
        &test_clock,
        scenario.ctx(),
    );
    destroy(cap);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 10)]
fun x_identity_rejects_non_32_byte_identity_commitment() {
    let creator_identity = creator_authority::new_x(x"1122");
    destroy(creator_identity);
}

#[test]
fun valid_x_attestation_consumes_authority_and_returns_creator_cap() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_runtime_config(scenario.ctx());
    let creator_state = new_x_authority();
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    let message = creator_authority::x_claim_attestation_bytes_for_testing<TEST_MEME>(
        x_identity_hash(),
        X_CLAIMANT,
        EXPIRY_MS,
    );
    assert_eq!(
        message,
        x"64303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303a3a63726561746f725f617574686f726974795f74657374733a3a544553545f4d454d452011223344556677889900aabbccddeeffffeeddccbbaa009988776655443322110000000000000000000000000000000000000000000000000000000000c0ffee80841e0000000000",
    );

    scenario.next_tx(X_CLAIMANT);
    let cap = creator_state.claim_creator_cap<TEST_MEME>(
        &config,
        option::some(x_claim_attestation()),
        &test_clock,
        scenario.ctx(),
    );

    destroy(cap);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 6)]
fun x_claim_rejects_signature_bound_to_another_sender() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_runtime_config(scenario.ctx());
    let creator_state = new_x_authority();
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    scenario.next_tx(@0xBAD);
    let cap = claim_x(creator_state, &config, &test_clock, &mut scenario);
    destroy(cap);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 25)]
fun x_creator_claim_requires_attestation() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_runtime_config(scenario.ctx());
    let creator_state = new_x_authority();
    let test_clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(X_CLAIMANT);
    let cap = creator_state.claim_creator_cap<TEST_MEME>(
        &config,
        option::none(),
        &test_clock,
        scenario.ctx(),
    );
    destroy(cap);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 27)]
fun x_creator_claim_rejects_malformed_attestation() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_runtime_config(scenario.ctx());
    let creator_state = new_x_authority();
    let test_clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(X_CLAIMANT);
    let cap = creator_state.claim_creator_cap<TEST_MEME>(
        &config,
        option::some(x"00"),
        &test_clock,
        scenario.ctx(),
    );
    destroy(cap);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 3)]
fun disabled_x_signer_rejects_before_attestation_parsing() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = runtime_config::new_disabled_for_testing(scenario.ctx());
    let creator_state = new_x_authority();
    let test_clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(X_CLAIMANT);
    let cap = creator_state.claim_creator_cap<TEST_MEME>(
        &config,
        option::some(x"00"),
        &test_clock,
        scenario.ctx(),
    );
    destroy(cap);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 14)]
fun x_claim_rejects_expired_attestation() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_runtime_config(scenario.ctx());
    let creator_state = new_x_authority();
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(EXPIRY_MS + 1);

    scenario.next_tx(X_CLAIMANT);
    let cap = claim_x(creator_state, &config, &test_clock, &mut scenario);
    destroy(cap);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 6)]
fun x_claim_rejects_signature_for_another_meme_type() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_runtime_config(scenario.ctx());
    let creator_state = creator_authority::new_x(x_identity_hash())
        .into_authority<OTHER_MEME>();
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    scenario.next_tx(X_CLAIMANT);
    let cap = creator_state.claim_creator_cap<OTHER_MEME>(
        &config,
        option::some(x_claim_attestation()),
        &test_clock,
        scenario.ctx(),
    );
    destroy(cap);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 6)]
fun x_claim_rejects_signature_for_another_x_identity() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_runtime_config(scenario.ctx());
    let creator_state = creator_authority::new_x(
        x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    ).into_authority<TEST_MEME>();
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    scenario.next_tx(X_CLAIMANT);
    let cap = claim_x(creator_state, &config, &test_clock, &mut scenario);
    destroy(cap);
    destroy(config);
    destroy(test_clock);
    destroy(scenario);
}

#[test]
#[expected_failure(abort_code = 6)]
fun x_claim_rejects_attestation_from_rotated_signer_key() {
    let mut fixture = start_admin(LAUNCHER);
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    fixture.config.set_x_claim_signer(
        &admin_witness,
        x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    );
    let creator_state = new_x_authority();
    let mut test_clock = clock::create_for_testing(fixture.scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    fixture.scenario.next_tx(X_CLAIMANT);
    let cap = claim_x(
        creator_state,
        &fixture.config,
        &test_clock,
        &mut fixture.scenario,
    );
    destroy(cap);
    destroy(test_clock);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = 3)]
fun x_claim_rejects_attestation_after_signer_revocation() {
    let mut fixture = start_admin(LAUNCHER);
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    fixture.config.set_x_claim_signer(
        &admin_witness,
        x_signer_public_key(),
    );
    fixture.config.revoke_x_claim_signer(&admin_witness);
    let creator_state = new_x_authority();
    let mut test_clock = clock::create_for_testing(fixture.scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    fixture.scenario.next_tx(X_CLAIMANT);
    let cap = claim_x(
        creator_state,
        &fixture.config,
        &test_clock,
        &mut fixture.scenario,
    );
    destroy(cap);
    destroy(test_clock);
    fixture.end();
}

#[test]
fun signer_rotation_reenables_x_claims_after_revocation() {
    let mut fixture = start_admin(LAUNCHER);
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    fixture.config.set_x_claim_signer(
        &admin_witness,
        x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    );
    fixture.config.revoke_x_claim_signer(&admin_witness);
    fixture.config.set_x_claim_signer(
        &admin_witness,
        x_signer_public_key(),
    );

    let creator_state = new_x_authority();
    let mut test_clock = clock::create_for_testing(fixture.scenario.ctx());
    test_clock.set_for_testing(NOW_MS);
    fixture.scenario.next_tx(X_CLAIMANT);
    let cap = creator_state.claim_creator_cap(
        &fixture.config,
        option::some(x_claim_attestation()),
        &test_clock,
        fixture.scenario.ctx(),
    );
    destroy(cap);
    destroy(test_clock);
    fixture.end();
}

#[test]
#[expected_failure(abort_code = 24)]
fun signer_rotation_rejects_current_public_key() {
    let mut fixture = start_admin(LAUNCHER);
    let admin_witness = fixture.authority.sign_in(&fixture.admin_cap);
    fixture.config.set_x_claim_signer(
        &admin_witness,
        x_signer_public_key(),
    );
    fixture.config.set_x_claim_signer(
        &admin_witness,
        x_signer_public_key(),
    );

    fixture.end();
}

// === Private Test Helpers ===

fun claim_x(
    creator_state: creator_authority::CreatorAuthority<TEST_MEME>,
    config: &runtime_config::RuntimeConfig,
    test_clock: &clock::Clock,
    scenario: &mut Scenario,
): creator_authority::CreatorCap<TEST_MEME> {
    creator_state.claim_creator_cap(
        config,
        option::some(x_claim_attestation()),
        test_clock,
        scenario.ctx(),
    )
}

fun x_claim_attestation(): vector<u8> {
    creator_authority::new_x_claim_attestation_for_testing(EXPIRY_MS, valid_x_signature())
}

fun new_protocol_for_testing(
    super_admin_recipient: address,
    ctx: &mut TxContext,
): (acl::SuperAdminCap, acl::ProtocolAuthority, runtime_config::RuntimeConfig) {
    let (super_admin_cap, authority) =
        acl::new_protocol_for_testing(super_admin_recipient, ctx);
    let config = runtime_config::new_disabled_for_testing(ctx);
    (super_admin_cap, authority, config)
}

fun start_admin(admin: address): AdminFixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    authority.grant_admin(
        &super_admin_cap,
        admin,
        scenario.ctx(),
    );
    scenario.next_tx(admin);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    AdminFixture {
        scenario,
        super_admin_cap,
        authority,
        admin_cap,
        config,
    }
}

fun end(self: AdminFixture) {
    destroy(self);
}

fun new_runtime_config(ctx: &mut TxContext): runtime_config::RuntimeConfig {
    runtime_config::new_for_testing(x_signer_public_key(), ctx)
}

fun new_x_authority(): creator_authority::CreatorAuthority<TEST_MEME> {
    creator_authority::new_x(x_identity_hash()).into_authority<TEST_MEME>()
}

fun x_identity_hash(): vector<u8> {
    x"11223344556677889900aabbccddeeffffeeddccbbaa00998877665544332211"
}

fun x_signer_public_key(): vector<u8> {
    x"0ca5b32f943a1d9f119adc9b45615a06bbf0ab9f46ccbcc62d167d7d5e55ce47"
}

fun valid_x_signature(): vector<u8> {
    x"9ad5e8a47856b8080b3105c805c3555bcfbdf28889ffe3fc54bc54700ff308e495e6dd1b014c9e2316bc98f0ec55c08293065ccee444aa96b1f5e107004a9a02"
}
