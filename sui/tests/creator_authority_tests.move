#[test_only]
module blast_fun::creator_authority_tests;

use blast_fun::{acl, constants, creator_authority, events, x_claim_config};
use sui::{clock, coin_registry, event, test_scenario::{Self, Scenario}};

// === Constants ===

const LAUNCHER: address = @0xA11CE;
const CREATOR: address = @0xC0FFEE;
const PROTOCOL_ADMIN: address = @0xAD;
const NEW_SUPER_ADMIN: address = @0xB0B;
const X_CLAIMANT: address = @0xC0FFEE;
const NOW_MS: u64 = 1_000_000;
const EXPIRY_MS: u64 = 2_000_000;

// === Test-Only Types ===

public struct TEST_MEME has key { id: UID }
public struct OTHER_MEME has key { id: UID }

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
    let config_created = events::collect_one<events::XClaimConfigCreated>(0);

    std::unit_test::assert_eq!(emitted_authority_id, authority_id);
    std::unit_test::assert_eq!(emitted_super_admin_cap_id, super_admin_cap_id);
    std::unit_test::assert_eq!(emitted_recipient, LAUNCHER);
    std::unit_test::assert_eq!(emitted_max_admins, constants::max_admins!());
    std::unit_test::assert_eq!(
        emitted_delay_ms,
        constants::super_admin_transfer_delay_ms!(),
    );
    std::unit_test::assert_eq!(
        config_created.x_claim_config_created_fields(),
        config_id,
    );
    assert!(event::events_by_type<events::ProtocolAuthorityCreated>().is_empty());
    assert!(event::events_by_type<events::XClaimConfigCreated>().is_empty());

    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
fun super_admin_adds_global_admin_that_configures_x_signer() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, mut config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());

    authority.add_admin(
        &super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );

    scenario.next_tx(PROTOCOL_ADMIN);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    let admin_witness = authority.sign_in(&admin_cap);
    config.set_signer(
        &admin_witness,
        x_signer_public_key(),
    );

    destroy_protocol_state(super_admin_cap, admin_cap, authority, config, scenario);
}

#[test]
fun x_claim_signer_set_event_is_replay_complete() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, authority, admin_cap, mut config) =
        new_protocol_with_admin(&mut scenario);
    let config_id = object::id(&config);
    let admin_witness = authority.sign_in(&admin_cap);

    config.set_signer(
        &admin_witness,
        x_signer_public_key(),
    );

    let signer_set = events::collect_one<events::XClaimSignerSet>(0);
    let (emitted_config_id, previous_public_key, signer_public_key) =
        signer_set.x_claim_signer_set_fields();
    std::unit_test::assert_eq!(emitted_config_id, config_id);
    assert!(previous_public_key.is_empty());
    std::unit_test::assert_eq!(signer_public_key, x_signer_public_key());

    destroy_protocol_state(super_admin_cap, admin_cap, authority, config, scenario);
}

#[test]
fun x_claim_signer_revoked_event_is_replay_complete() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, authority, admin_cap, mut config) =
        new_protocol_with_admin(&mut scenario);
    let config_id = object::id(&config);
    let admin_witness = authority.sign_in(&admin_cap);
    config.set_signer(
        &admin_witness,
        x_signer_public_key(),
    );

    config.revoke_signer(&admin_witness);

    let signer_revoked = events::collect_one<events::XClaimSignerRevoked>(0);
    let (emitted_config_id, previous_public_key) =
        signer_revoked.x_claim_signer_revoked_fields();
    std::unit_test::assert_eq!(emitted_config_id, config_id);
    std::unit_test::assert_eq!(previous_public_key, x_signer_public_key());

    destroy_protocol_state(super_admin_cap, admin_cap, authority, config, scenario);
}

#[test]
#[expected_failure(abort_code = 2)]
fun x_claim_signer_rejects_invalid_public_key_length() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, authority, admin_cap, mut config) =
        new_protocol_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.set_signer(&admin_witness, x"00");

    destroy_protocol_state(super_admin_cap, admin_cap, authority, config, scenario);
}

#[test]
#[expected_failure(abort_code = 3)]
fun x_claim_signer_cannot_revoke_while_disabled() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, authority, admin_cap, mut config) =
        new_protocol_with_admin(&mut scenario);
    let admin_witness = authority.sign_in(&admin_cap);

    config.revoke_signer(&admin_witness);

    destroy_protocol_state(super_admin_cap, admin_cap, authority, config, scenario);
}

#[test]
#[expected_failure(abort_code = 0)]
fun revoked_admin_cannot_configure_x_signer() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, admin_cap, mut config) =
        new_protocol_with_admin(&mut scenario);
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();
    authority.revoke_admin(&super_admin_cap, admin_cap_id);
    let admin_witness = authority.sign_in(&admin_cap);

    config.set_signer(
        &admin_witness,
        x_signer_public_key(),
    );

    destroy_protocol_state(super_admin_cap, admin_cap, authority, config, scenario);
}

#[test]
fun active_admin_can_destroy_cap_and_renounce_membership() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, admin_cap, config) =
        new_protocol_with_admin(&mut scenario);
    let authority_id = object::id(&authority);
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();

    authority.destroy_admin_cap(admin_cap);

    let destroyed = events::collect_one<events::AdminDestroyed>(0);
    let (emitted_authority_id, emitted_admin_cap_id, was_active) =
        destroyed.admin_destroyed_fields();
    std::unit_test::assert_eq!(emitted_authority_id, authority_id);
    std::unit_test::assert_eq!(emitted_admin_cap_id, admin_cap_id);
    assert!(was_active);

    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
fun revoked_admin_can_destroy_inert_cap() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, admin_cap, config) =
        new_protocol_with_admin(&mut scenario);
    let authority_id = object::id(&authority);
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();

    authority.revoke_admin(&super_admin_cap, admin_cap_id);
    authority.destroy_admin_cap(admin_cap);

    let destroyed = events::collect_one<events::AdminDestroyed>(0);
    let (emitted_authority_id, emitted_admin_cap_id, was_active) =
        destroyed.admin_destroyed_fields();
    std::unit_test::assert_eq!(emitted_authority_id, authority_id);
    std::unit_test::assert_eq!(emitted_admin_cap_id, admin_cap_id);
    assert!(!was_active);

    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 0)]
fun destroyed_active_admin_is_removed_from_registry() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, admin_cap, config) =
        new_protocol_with_admin(&mut scenario);
    let admin_cap_id = admin_cap.admin_cap_id_for_testing();

    authority.destroy_admin_cap(admin_cap);
    authority.revoke_admin(&super_admin_cap, admin_cap_id);

    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 0)]
fun admin_registered_in_another_protocol_registry_is_rejected() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (first_super_admin, first_authority, first_admin, first_config) =
        new_protocol_with_admin(&mut scenario);
    let (second_super_admin, second_authority, second_config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let mut second_config = second_config;
    let admin_witness = second_authority.sign_in(&first_admin);

    second_config.set_signer(
        &admin_witness,
        x_signer_public_key(),
    );

    destroy_protocol_state(
        first_super_admin,
        first_admin,
        first_authority,
        first_config,
        scenario,
    );
    second_authority.destroy_super_admin_cap_for_testing(second_super_admin);
    second_authority.destroy_protocol_authority_for_testing();
    second_config.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = 17)]
fun active_admin_registry_is_bounded() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let mut index = 0u64;
    while (index < constants::max_admins!()) {
        authority.add_admin(&super_admin_cap, PROTOCOL_ADMIN, scenario.ctx());
        index = index + 1;
    };
    authority.add_admin(&super_admin_cap, PROTOCOL_ADMIN, scenario.ctx());

    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 16)]
fun super_admin_cannot_add_zero_address_admin() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());

    authority.add_admin(
        &super_admin_cap,
        @0x0,
        scenario.ctx(),
    );

    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
fun super_admin_transfer_requires_delay_and_recipient_acceptance() {
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

    scenario.next_tx(NEW_SUPER_ADMIN);
    let new_super_admin_cap = scenario.take_from_sender<acl::SuperAdminCap>();
    authority.add_admin(
        &new_super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );

    authority.destroy_retired_super_admin_cap(old_super_admin_cap);
    authority.destroy_super_admin_cap_for_testing(new_super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    test_clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 23)]
fun active_super_admin_cap_cannot_be_destroyed() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());

    authority.destroy_retired_super_admin_cap(super_admin_cap);

    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
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

    test_clock.destroy_for_testing();
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
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

    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    test_clock.destroy_for_testing();
    scenario.end();
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

    test_clock.set_for_testing(
        NOW_MS + 1 + constants::super_admin_transfer_delay_ms!(),
    );
    scenario.next_tx(PROTOCOL_ADMIN);
    authority.accept_super_admin_transfer(&test_clock, scenario.ctx());

    scenario.next_tx(PROTOCOL_ADMIN);
    let new_super_admin_cap = scenario.take_from_sender<acl::SuperAdminCap>();
    authority.destroy_retired_super_admin_cap(old_super_admin_cap);
    authority.destroy_super_admin_cap_for_testing(new_super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    test_clock.destroy_for_testing();
    scenario.end();
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

    authority.add_admin(
        &old_super_admin_cap,
        PROTOCOL_ADMIN,
        scenario.ctx(),
    );

    authority.destroy_super_admin_cap_for_testing(old_super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    test_clock.destroy_for_testing();
    scenario.end();
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

    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    test_clock.destroy_for_testing();
    scenario.end();
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

    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    test_clock.destroy_for_testing();
    scenario.end();
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

    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    test_clock.destroy_for_testing();
    scenario.end();
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

    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    test_clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 19)]
fun super_admin_cannot_cancel_without_pending_transfer() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());

    authority.cancel_super_admin_transfer(&super_admin_cap);

    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
fun package_init_delivers_only_root() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    acl::init_for_testing(scenario.ctx());

    let effects = scenario.next_tx(LAUNCHER);
    std::unit_test::assert_eq!(effects.num_user_events(), 1);
    assert!(scenario.has_most_recent_for_sender<acl::SuperAdminCap>());
    assert!(!scenario.has_most_recent_for_sender<acl::AdminCap>());
    let super_admin_cap = scenario.take_from_sender<acl::SuperAdminCap>();
    let authority = scenario.take_shared<acl::ProtocolAuthority>();

    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 3)]
fun package_init_starts_x_signer_disabled() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    x_claim_config::init_for_testing(scenario.ctx());

    scenario.next_tx(LAUNCHER);
    let config = scenario.take_shared<x_claim_config::XClaimConfig>();
    let creator_state = new_x_authority();
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    scenario.next_tx(X_CLAIMANT);
    let (cap, metadata_cap) = claim_x(creator_state, &config, &test_clock, &mut scenario);
    destroy_claim_result(cap, metadata_cap);
    destroy_x_test_state(config, test_clock, scenario);
}

#[test]
fun address_creator_claim_returns_two_independently_composable_caps() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, protocol_authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let creator_state = creator_authority::new_address<TEST_MEME>(CREATOR);
    let test_clock = clock::create_for_testing(scenario.ctx());
    let metadata_cap = new_test_meme_metadata_cap();
    let metadata_cap_id = object::id(&metadata_cap);

    scenario.next_tx(CREATOR);
    let (cap, metadata_cap) = creator_state.claim_creator_cap<TEST_MEME>(
        metadata_cap,
        &config,
        option::none(),
        &test_clock,
        scenario.ctx(),
    );
    transfer::public_transfer(cap, PROTOCOL_ADMIN);
    transfer::public_transfer(metadata_cap, CREATOR);

    let claimed = events::collect_one<events::CreatorCapClaimed>(0);
    let (meme, x_identity_hash, creator, x_claim_expiry_ms) =
        claimed.creator_cap_claimed_fields();
    std::unit_test::assert_eq!(
        meme,
        std::type_name::with_original_ids<TEST_MEME>(),
    );
    assert!(x_identity_hash.is_none());
    std::unit_test::assert_eq!(creator, CREATOR);
    assert!(x_claim_expiry_ms.is_none());

    let effects = scenario.next_tx(PROTOCOL_ADMIN);
    std::unit_test::assert_eq!(effects.num_user_events(), 1);
    assert!(scenario.has_most_recent_for_sender<creator_authority::CreatorCap<TEST_MEME>>());
    assert!(!scenario.has_most_recent_for_sender<creator_authority::CreatorCap<OTHER_MEME>>());
    let cap = scenario.take_from_sender<creator_authority::CreatorCap<TEST_MEME>>();
    cap.destroy_cap_for_testing();

    scenario.next_tx(CREATOR);
    let metadata_cap = scenario.take_from_sender<coin_registry::MetadataCap<TEST_MEME>>();
    std::unit_test::assert_eq!(object::id(&metadata_cap), metadata_cap_id);
    transfer::public_freeze_object(metadata_cap);
    test_clock.destroy_for_testing();
    protocol_authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    protocol_authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

#[test]
fun burnable_coin_claim_returns_metadata_cap_separately() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_x_claim_config(scenario.ctx());
    let creator_state = creator_authority::new_address<TEST_MEME>(CREATOR);
    let test_clock = clock::create_for_testing(scenario.ctx());
    let metadata_cap = new_test_meme_metadata_cap_with_supply(true);
    let metadata_cap_id = object::id(&metadata_cap);

    scenario.next_tx(CREATOR);
    let (cap, metadata_cap) = creator_state.claim_creator_cap(
        metadata_cap,
        &config,
        option::none(),
        &test_clock,
        scenario.ctx(),
    );

    std::unit_test::assert_eq!(object::id(&metadata_cap), metadata_cap_id);

    destroy_claim_result(cap, metadata_cap);
    destroy_x_test_state(config, test_clock, scenario);
}

#[test]
#[expected_failure(abort_code = 9)]
fun address_identity_rejects_zero_creator_address() {
    let creator_state = creator_authority::new_address<TEST_MEME>(@0x0);
    creator_state.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = 26)]
fun address_creator_claim_rejects_different_sender() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_x_claim_config(scenario.ctx());
    let creator_state = creator_authority::new_address<TEST_MEME>(CREATOR);
    let test_clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(@0xBAD);
    let (cap, metadata_cap) = creator_state.claim_creator_cap<TEST_MEME>(
        new_test_meme_metadata_cap(),
        &config,
        option::none(),
        &test_clock,
        scenario.ctx(),
    );
    destroy_claim_result(cap, metadata_cap);
    destroy_x_test_state(config, test_clock, scenario);
}

#[test]
#[expected_failure(abort_code = 11)]
fun address_creator_claim_rejects_x_attestation() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_x_claim_config(scenario.ctx());
    let creator_state = creator_authority::new_address<TEST_MEME>(CREATOR);
    let test_clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(CREATOR);
    let (cap, metadata_cap) = creator_state.claim_creator_cap<TEST_MEME>(
        new_test_meme_metadata_cap(),
        &config,
        option::some(x_claim_attestation()),
        &test_clock,
        scenario.ctx(),
    );
    destroy_claim_result(cap, metadata_cap);
    destroy_x_test_state(config, test_clock, scenario);
}

#[test]
#[expected_failure(abort_code = 10)]
fun x_identity_rejects_non_32_byte_identity_commitment() {
    let creator_state = creator_authority::new_x<TEST_MEME>(x"1122");
    creator_state.destroy_for_testing();
}

#[test]
fun valid_x_attestation_consumes_authority_and_returns_two_caps() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_x_claim_config(scenario.ctx());
    let creator_state = new_x_authority();
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    let message = creator_authority::x_claim_attestation_bytes_for_testing<TEST_MEME>(
        x_identity_hash(),
        X_CLAIMANT,
        EXPIRY_MS,
    );
    std::unit_test::assert_eq!(
        message,
        x"64303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303a3a63726561746f725f617574686f726974795f74657374733a3a544553545f4d454d452011223344556677889900aabbccddeeffffeeddccbbaa009988776655443322110000000000000000000000000000000000000000000000000000000000c0ffee80841e0000000000",
    );

    let metadata_cap = new_test_meme_metadata_cap();
    scenario.next_tx(X_CLAIMANT);
    let (cap, metadata_cap) = creator_state.claim_creator_cap<TEST_MEME>(
        metadata_cap,
        &config,
        option::some(x_claim_attestation()),
        &test_clock,
        scenario.ctx(),
    );

    destroy_claim_result(cap, metadata_cap);
    destroy_x_test_state(config, test_clock, scenario);
}

#[test]
#[expected_failure(abort_code = 6)]
fun x_claim_rejects_signature_bound_to_another_sender() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_x_claim_config(scenario.ctx());
    let creator_state = new_x_authority();
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    scenario.next_tx(@0xBAD);
    let (cap, metadata_cap) = claim_x(creator_state, &config, &test_clock, &mut scenario);
    destroy_claim_result(cap, metadata_cap);
    destroy_x_test_state(config, test_clock, scenario);
}

#[test]
#[expected_failure(abort_code = 25)]
fun x_creator_claim_requires_attestation() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_x_claim_config(scenario.ctx());
    let creator_state = new_x_authority();
    let test_clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(X_CLAIMANT);
    let (cap, metadata_cap) = creator_state.claim_creator_cap<TEST_MEME>(
        new_test_meme_metadata_cap(),
        &config,
        option::none(),
        &test_clock,
        scenario.ctx(),
    );
    destroy_claim_result(cap, metadata_cap);
    destroy_x_test_state(config, test_clock, scenario);
}

#[test]
#[expected_failure(abort_code = 27)]
fun x_creator_claim_rejects_malformed_attestation() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_x_claim_config(scenario.ctx());
    let creator_state = new_x_authority();
    let test_clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(X_CLAIMANT);
    let (cap, metadata_cap) = creator_state.claim_creator_cap<TEST_MEME>(
        new_test_meme_metadata_cap(),
        &config,
        option::some(x"00"),
        &test_clock,
        scenario.ctx(),
    );
    destroy_claim_result(cap, metadata_cap);
    destroy_x_test_state(config, test_clock, scenario);
}

#[test]
#[expected_failure(abort_code = 3)]
fun disabled_x_signer_rejects_before_attestation_parsing() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = x_claim_config::new_disabled_for_testing(scenario.ctx());
    let creator_state = new_x_authority();
    let test_clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(X_CLAIMANT);
    let (cap, metadata_cap) = creator_state.claim_creator_cap<TEST_MEME>(
        new_test_meme_metadata_cap(),
        &config,
        option::some(x"00"),
        &test_clock,
        scenario.ctx(),
    );
    destroy_claim_result(cap, metadata_cap);
    destroy_x_test_state(config, test_clock, scenario);
}

#[test]
#[expected_failure(abort_code = 14)]
fun x_claim_rejects_expired_attestation() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_x_claim_config(scenario.ctx());
    let creator_state = new_x_authority();
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(EXPIRY_MS + 1);

    scenario.next_tx(X_CLAIMANT);
    let (cap, metadata_cap) = claim_x(creator_state, &config, &test_clock, &mut scenario);
    destroy_claim_result(cap, metadata_cap);
    destroy_x_test_state(config, test_clock, scenario);
}

#[test]
#[expected_failure(abort_code = 6)]
fun x_claim_rejects_signature_for_another_meme_type() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_x_claim_config(scenario.ctx());
    let creator_state = creator_authority::new_x<OTHER_MEME>(x_identity_hash());
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    scenario.next_tx(X_CLAIMANT);
    let (cap, metadata_cap) = creator_state.claim_creator_cap<OTHER_MEME>(
        new_other_meme_metadata_cap(),
        &config,
        option::some(x_claim_attestation()),
        &test_clock,
        scenario.ctx(),
    );
    destroy_claim_result(cap, metadata_cap);
    config.destroy_for_testing();
    test_clock.destroy_for_testing();
    scenario.end();
}

#[test]
#[expected_failure(abort_code = 6)]
fun x_claim_rejects_signature_for_another_x_identity() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = new_x_claim_config(scenario.ctx());
    let creator_state = creator_authority::new_x<TEST_MEME>(
        x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    );
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    scenario.next_tx(X_CLAIMANT);
    let (cap, metadata_cap) = claim_x(creator_state, &config, &test_clock, &mut scenario);
    destroy_claim_result(cap, metadata_cap);
    destroy_x_test_state(config, test_clock, scenario);
}

#[test]
#[expected_failure(abort_code = 6)]
fun x_claim_rejects_attestation_from_rotated_signer_key() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, protocol_authority, admin_cap, mut config) =
        new_protocol_with_admin(&mut scenario);
    let admin_witness = protocol_authority.sign_in(&admin_cap);
    config.set_signer(
        &admin_witness,
        x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    );
    let creator_state = new_x_authority();
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    scenario.next_tx(X_CLAIMANT);
    let (cap, metadata_cap) = claim_x(creator_state, &config, &test_clock, &mut scenario);
    destroy_claim_result(cap, metadata_cap);
    test_clock.destroy_for_testing();
    destroy_protocol_state(
        super_admin_cap,
        admin_cap,
        protocol_authority,
        config,
        scenario,
    );
}

#[test]
#[expected_failure(abort_code = 3)]
fun x_claim_rejects_attestation_after_signer_revocation() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, protocol_authority, admin_cap, mut config) =
        new_protocol_with_admin(&mut scenario);
    let admin_witness = protocol_authority.sign_in(&admin_cap);
    config.set_signer(
        &admin_witness,
        x_signer_public_key(),
    );
    config.revoke_signer(&admin_witness);
    let creator_state = new_x_authority();
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);

    scenario.next_tx(X_CLAIMANT);
    let (cap, metadata_cap) = claim_x(creator_state, &config, &test_clock, &mut scenario);
    destroy_claim_result(cap, metadata_cap);
    test_clock.destroy_for_testing();
    destroy_protocol_state(
        super_admin_cap,
        admin_cap,
        protocol_authority,
        config,
        scenario,
    );
}

#[test]
fun signer_rotation_reenables_x_claims_after_revocation() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, protocol_authority, admin_cap, mut config) =
        new_protocol_with_admin(&mut scenario);
    let admin_witness = protocol_authority.sign_in(&admin_cap);
    config.set_signer(
        &admin_witness,
        x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    );
    config.revoke_signer(&admin_witness);
    config.set_signer(
        &admin_witness,
        x_signer_public_key(),
    );

    let creator_state = new_x_authority();
    let mut test_clock = clock::create_for_testing(scenario.ctx());
    test_clock.set_for_testing(NOW_MS);
    let metadata_cap = new_test_meme_metadata_cap();

    scenario.next_tx(X_CLAIMANT);
    let (cap, metadata_cap) = creator_state.claim_creator_cap(
        metadata_cap,
        &config,
        option::some(x_claim_attestation()),
        &test_clock,
        scenario.ctx(),
    );
    destroy_claim_result(cap, metadata_cap);
    test_clock.destroy_for_testing();

    destroy_protocol_state(
        super_admin_cap,
        admin_cap,
        protocol_authority,
        config,
        scenario,
    );
}

#[test]
#[expected_failure(abort_code = 24)]
fun signer_rotation_rejects_current_public_key() {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, protocol_authority, admin_cap, mut config) =
        new_protocol_with_admin(&mut scenario);
    let admin_witness = protocol_authority.sign_in(&admin_cap);
    config.set_signer(
        &admin_witness,
        x_signer_public_key(),
    );
    config.set_signer(
        &admin_witness,
        x_signer_public_key(),
    );

    destroy_protocol_state(
        super_admin_cap,
        admin_cap,
        protocol_authority,
        config,
        scenario,
    );
}

// === Private Test Helpers ===

fun claim_x(
    creator_state: creator_authority::CreatorAuthority<TEST_MEME>,
    config: &x_claim_config::XClaimConfig,
    test_clock: &clock::Clock,
    scenario: &mut Scenario,
): (
    creator_authority::CreatorCap<TEST_MEME>,
    coin_registry::MetadataCap<TEST_MEME>,
) {
    creator_state.claim_creator_cap(
        new_test_meme_metadata_cap(),
        config,
        option::some(x_claim_attestation()),
        test_clock,
        scenario.ctx(),
    )
}

fun destroy_claim_result<Meme>(
    cap: creator_authority::CreatorCap<Meme>,
    metadata_cap: coin_registry::MetadataCap<Meme>,
) {
    cap.destroy_cap_for_testing();
    transfer::public_freeze_object(metadata_cap);
}

fun new_test_meme_metadata_cap(): coin_registry::MetadataCap<TEST_MEME> {
    new_test_meme_metadata_cap_with_supply(false)
}

fun new_test_meme_metadata_cap_with_supply(
    burnable: bool,
): coin_registry::MetadataCap<TEST_MEME> {
    let mut ctx = tx_context::dummy();
    let mut registry = coin_registry::create_coin_data_registry_for_testing(&mut ctx);
    let (mut initializer, mut treasury_cap) = coin_registry::new_currency(
        &mut registry,
        9,
        b"TEST".to_string(),
        b"Test Meme".to_string(),
        b"Creator authority test currency".to_string(),
        b"".to_string(),
        &mut ctx,
    );
    let coin = treasury_cap.mint(1, &mut ctx);

    if (burnable) initializer.make_supply_burn_only(treasury_cap)
    else initializer.make_supply_fixed(treasury_cap);
    let metadata_cap = initializer.finalize(&mut ctx);

    coin_registry::share_for_testing(registry);
    coin.into_balance().destroy_for_testing();

    metadata_cap
}

fun new_other_meme_metadata_cap(): coin_registry::MetadataCap<OTHER_MEME> {
    let mut ctx = tx_context::dummy();
    let mut registry = coin_registry::create_coin_data_registry_for_testing(&mut ctx);
    let (mut initializer, mut treasury_cap) = coin_registry::new_currency(
        &mut registry,
        9,
        b"OTHER".to_string(),
        b"Other Meme".to_string(),
        b"Creator authority alternate test currency".to_string(),
        b"".to_string(),
        &mut ctx,
    );
    let coin = treasury_cap.mint(1, &mut ctx);

    initializer.make_supply_fixed(treasury_cap);
    let metadata_cap = initializer.finalize(&mut ctx);

    coin_registry::share_for_testing(registry);
    coin.into_balance().destroy_for_testing();

    metadata_cap
}

fun x_claim_attestation(): vector<u8> {
    creator_authority::new_x_claim_attestation_for_testing(EXPIRY_MS, valid_x_signature())
}

fun new_protocol_for_testing(
    super_admin_recipient: address,
    ctx: &mut TxContext,
): (acl::SuperAdminCap, acl::ProtocolAuthority, x_claim_config::XClaimConfig) {
    let (super_admin_cap, authority) =
        acl::new_protocol_for_testing(super_admin_recipient, ctx);
    let config = x_claim_config::new_disabled_for_testing(ctx);
    (super_admin_cap, authority, config)
}

fun new_protocol_with_admin(
    scenario: &mut Scenario,
): (acl::SuperAdminCap, acl::ProtocolAuthority, acl::AdminCap, x_claim_config::XClaimConfig) {
    let (super_admin_cap, mut authority, config) =
        new_protocol_for_testing(LAUNCHER, scenario.ctx());
    authority.add_admin(
        &super_admin_cap,
        LAUNCHER,
        scenario.ctx(),
    );
    scenario.next_tx(LAUNCHER);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();
    (super_admin_cap, authority, admin_cap, config)
}

fun destroy_protocol_state(
    super_admin_cap: acl::SuperAdminCap,
    admin_cap: acl::AdminCap,
    mut authority: acl::ProtocolAuthority,
    config: x_claim_config::XClaimConfig,
    scenario: Scenario,
) {
    authority.destroy_admin_cap(admin_cap);
    authority.destroy_super_admin_cap_for_testing(super_admin_cap);
    authority.destroy_protocol_authority_for_testing();
    config.destroy_for_testing();
    scenario.end();
}

fun destroy_x_test_state(
    config: x_claim_config::XClaimConfig,
    test_clock: clock::Clock,
    scenario: Scenario,
) {
    config.destroy_for_testing();
    test_clock.destroy_for_testing();
    scenario.end();
}

fun new_x_claim_config(ctx: &mut TxContext): x_claim_config::XClaimConfig {
    x_claim_config::new_for_testing(x_signer_public_key(), ctx)
}

fun new_x_authority(): creator_authority::CreatorAuthority<TEST_MEME> {
    creator_authority::new_x<TEST_MEME>(x_identity_hash())
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
