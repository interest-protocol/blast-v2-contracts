#[test_only]
module blast_fun::creator_authority_tests;

use blast_fun::{acl, constants, creator_authority, events, runtime_config};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, event, test_scenario::{Self, Scenario}};

// === Constants ===

const LAUNCHER: address = @0xA11CE;
const CREATOR: address = @0xC0FFEE;
const PROTOCOL_ADMIN: address = @0xAD;
const SECOND_ADMIN: address = @0xDAD;
const NEW_SUPER_ADMIN: address = @0xB0B;
const X_CLAIMANT: address = @0xC0FFEE;
const NOW_MS: u64 = 1_000_000;
const EXPIRY_MS: u64 = 2_000_000;

// === Test-Only Types ===

public struct TEST_MEME() has drop;
public struct OTHER_MEME() has drop;

public struct Fixture {
    scenario: Scenario,
    super_admin_cap: Option<acl::SuperAdminCap>,
    authority: acl::ProtocolAuthority,
    admin_cap: Option<acl::AdminCap>,
    config: runtime_config::RuntimeConfig,
    clock: Clock,
}

// === Tests ===

#[test]
fun singleton_creation_events_use_generic_wrapper() {
    let mut fixture = start(PROTOCOL_ADMIN);

    fixture.next_tx!(LAUNCHER, |f| {
        let (super_admin_cap, authority, config) = new_protocol(f.scenario.ctx());
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
        let runtime_config_created =
            events::collect_one<events::RuntimeConfigCreated>(0);
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
    });

    fixture.end();
}

#[test]
fun super_admin_grants_global_admin_that_configures_x_signer() {
    let mut fixture = start(PROTOCOL_ADMIN);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_x_claim_signer(
            &admin_witness,
            x_signer_public_key(),
        );
    });

    fixture.end();
}

#[test]
fun super_admin_grant_is_replay_complete_and_delivers_the_cap() {
    let mut fixture = start(LAUNCHER);
    let granted_admin_cap_id;

    fixture.next_tx!(LAUNCHER, |f| {
        f.authority.grant_admin(
            f.super_admin_cap.borrow(),
            SECOND_ADMIN,
            f.scenario.ctx(),
        );

        let granted = events::collect_one<events::AdminGranted>(0);
        let (emitted_admin_cap_id, recipient) = granted.admin_granted_fields();
        assert_eq!(recipient, SECOND_ADMIN);
        granted_admin_cap_id = emitted_admin_cap_id;
    });

    fixture.next_tx!(SECOND_ADMIN, |f| {
        let delivered_admin_cap = f.take_delivered_admin_cap();

        assert_eq!(
            granted_admin_cap_id,
            delivered_admin_cap.admin_cap_id_for_testing(),
        );

        destroy(delivered_admin_cap);
    });

    fixture.end();
}

#[test]
fun super_admin_revocation_identifies_only_the_removed_admin() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_cap_id = f.admin_cap.borrow().admin_cap_id_for_testing();

        f.authority.revoke_admin(f.super_admin_cap.borrow(), admin_cap_id);

        let revoked = events::collect_one<events::AdminRevoked>(0);
        assert_eq!(revoked.admin_revoked_fields(), admin_cap_id);
    });

    fixture.end();
}

#[test]
fun x_claim_signer_set_event_is_replay_complete() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();

        f.config.set_x_claim_signer(
            &admin_witness,
            x_signer_public_key(),
        );

        let signer_set = events::collect_one<events::XClaimSignerSet>(0);
        let (previous_public_key, signer_public_key) =
            signer_set.x_claim_signer_set_fields();
        assert!(previous_public_key.is_empty());
        assert_eq!(signer_public_key, x_signer_public_key());
    });

    fixture.end();
}

#[test]
fun x_claim_signer_revoked_event_is_replay_complete() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();
        f.config.set_x_claim_signer(
            &admin_witness,
            x_signer_public_key(),
        );

        f.config.revoke_x_claim_signer(&admin_witness);

        let signer_revoked = events::collect_one<events::XClaimSignerRevoked>(0);
        let previous_public_key = signer_revoked.x_claim_signer_revoked_fields();
        assert_eq!(previous_public_key, x_signer_public_key());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 2, location = blast_fun::runtime_config)]
fun x_claim_signer_rejects_invalid_public_key_length() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();

        f.config.set_x_claim_signer(&admin_witness, x"00");
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 3, location = blast_fun::runtime_config)]
fun x_claim_signer_cannot_revoke_while_disabled() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();

        f.config.revoke_x_claim_signer(&admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 0, location = blast_fun::acl)]
fun revoked_admin_cannot_configure_x_signer() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_cap_id = f.admin_cap.borrow().admin_cap_id_for_testing();
        f.authority.revoke_admin(f.super_admin_cap.borrow(), admin_cap_id);
        let admin_witness = f.sign_in();

        f.config.set_x_claim_signer(
            &admin_witness,
            x_signer_public_key(),
        );
    });

    fixture.end();
}

#[test]
fun active_admin_can_destroy_cap_and_renounce_membership() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_cap = f.take_admin_cap();
        let admin_cap_id = admin_cap.admin_cap_id_for_testing();

        f.authority.destroy_admin_cap(admin_cap);

        let destroyed = events::collect_one<events::AdminDestroyed>(0);
        let (emitted_admin_cap_id, was_active) = destroyed.admin_destroyed_fields();
        assert_eq!(emitted_admin_cap_id, admin_cap_id);
        assert!(was_active);
    });

    fixture.end();
}

#[test]
fun revoked_admin_can_destroy_inert_cap() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_cap = f.take_admin_cap();
        let admin_cap_id = admin_cap.admin_cap_id_for_testing();

        f.authority.revoke_admin(f.super_admin_cap.borrow(), admin_cap_id);
        f.authority.destroy_admin_cap(admin_cap);

        let destroyed = events::collect_one<events::AdminDestroyed>(0);
        let (emitted_admin_cap_id, was_active) = destroyed.admin_destroyed_fields();
        assert_eq!(emitted_admin_cap_id, admin_cap_id);
        assert!(!was_active);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 0, location = blast_fun::acl)]
fun destroyed_active_admin_is_removed_from_registry() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_cap = f.take_admin_cap();
        let admin_cap_id = admin_cap.admin_cap_id_for_testing();

        f.authority.destroy_admin_cap(admin_cap);
        f.authority.revoke_admin(f.super_admin_cap.borrow(), admin_cap_id);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 0, location = blast_fun::acl)]
fun admin_registered_in_another_protocol_registry_is_rejected() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let (second_super_admin, second_authority, mut second_config) =
            new_protocol(f.scenario.ctx());
        let admin_witness = second_authority.sign_in(f.admin_cap.borrow());

        second_config.set_x_claim_signer(
            &admin_witness,
            x_signer_public_key(),
        );

        destroy(second_super_admin);
        destroy(second_authority);
        destroy(second_config);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 17, location = blast_fun::acl)]
fun active_admin_registry_is_bounded() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let mut index = 1u64;
        while (index < constants::max_admins!()) {
            f.authority.grant_admin(
                f.super_admin_cap.borrow(),
                PROTOCOL_ADMIN,
                f.scenario.ctx(),
            );
            index = index + 1;
        };
        f.authority.grant_admin(
            f.super_admin_cap.borrow(),
            PROTOCOL_ADMIN,
            f.scenario.ctx(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 16, location = blast_fun::acl)]
fun super_admin_cannot_grant_zero_address_admin() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        f.authority.grant_admin(
            f.super_admin_cap.borrow(),
            @0x0,
            f.scenario.ctx(),
        );
    });

    fixture.end();
}

#[test]
fun super_admin_transfer_requires_delay_and_recipient_acceptance() {
    let mut fixture = start(LAUNCHER);
    let new_super_admin_cap_id;

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(NOW_MS);

        f.authority.begin_super_admin_transfer(
            f.super_admin_cap.borrow(),
            NEW_SUPER_ADMIN,
            &f.clock,
            f.scenario.ctx(),
        );

        let started = events::collect_one<events::SuperAdminTransferStarted>(0);
        let (started_recipient, execute_after_ms) =
            started.super_admin_transfer_started_fields();
        assert_eq!(started_recipient, NEW_SUPER_ADMIN);
        assert_eq!(
            execute_after_ms,
            NOW_MS + constants::super_admin_transfer_delay_ms!(),
        );

        f.clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        f.authority.accept_super_admin_transfer(&f.clock, f.scenario.ctx());

        let transferred = events::collect_one<events::SuperAdminTransferred>(0);
        let (previous_super_admin_cap_id, emitted_new_super_admin_cap_id, recipient) =
            transferred.super_admin_transferred_fields();
        assert_eq!(
            previous_super_admin_cap_id,
            object::id(f.super_admin_cap.borrow()),
        );
        assert_eq!(recipient, NEW_SUPER_ADMIN);
        new_super_admin_cap_id = emitted_new_super_admin_cap_id;
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        let retired_super_admin_cap = f.replace_super_admin_cap();

        assert_eq!(
            new_super_admin_cap_id,
            object::id(f.super_admin_cap.borrow()),
        );
        f.authority.grant_admin(
            f.super_admin_cap.borrow(),
            PROTOCOL_ADMIN,
            f.scenario.ctx(),
        );

        f.authority.destroy_retired_super_admin_cap(retired_super_admin_cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 23, location = blast_fun::acl)]
fun active_super_admin_cap_cannot_be_destroyed() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let super_admin_cap = f.take_super_admin_cap();

        f.authority.destroy_retired_super_admin_cap(super_admin_cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 22, location = blast_fun::acl)]
fun super_admin_transfer_rejects_timestamp_overflow() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(std::u64::max_value!());

        f.authority.begin_super_admin_transfer(
            f.super_admin_cap.borrow(),
            NEW_SUPER_ADMIN,
            &f.clock,
            f.scenario.ctx(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 28, location = blast_fun::acl)]
fun super_admin_transfer_rejects_unchanged_pending_recipient_before_timestamp_work() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(NOW_MS);
        f.authority.begin_super_admin_transfer(
            f.super_admin_cap.borrow(),
            NEW_SUPER_ADMIN,
            &f.clock,
            f.scenario.ctx(),
        );

        f.clock.set_for_testing(std::u64::max_value!());
        f.authority.begin_super_admin_transfer(
            f.super_admin_cap.borrow(),
            NEW_SUPER_ADMIN,
            &f.clock,
            f.scenario.ctx(),
        );
    });

    fixture.end();
}

#[test]
fun super_admin_transfer_replaces_different_pending_recipient() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(NOW_MS);
        f.authority.begin_super_admin_transfer(
            f.super_admin_cap.borrow(),
            NEW_SUPER_ADMIN,
            &f.clock,
            f.scenario.ctx(),
        );
        f.clock.set_for_testing(NOW_MS + 1);
        f.authority.begin_super_admin_transfer(
            f.super_admin_cap.borrow(),
            PROTOCOL_ADMIN,
            &f.clock,
            f.scenario.ctx(),
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

        f.clock.set_for_testing(
            NOW_MS + 1 + constants::super_admin_transfer_delay_ms!(),
        );
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        f.authority.accept_super_admin_transfer(&f.clock, f.scenario.ctx());
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let retired_super_admin_cap = f.replace_super_admin_cap();

        f.authority.destroy_retired_super_admin_cap(retired_super_admin_cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 15, location = blast_fun::acl)]
fun accepted_super_admin_transfer_invalidates_previous_root_cap() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(NOW_MS);
        f.authority.begin_super_admin_transfer(
            f.super_admin_cap.borrow(),
            NEW_SUPER_ADMIN,
            &f.clock,
            f.scenario.ctx(),
        );
        f.clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        f.authority.accept_super_admin_transfer(&f.clock, f.scenario.ctx());

        f.authority.grant_admin(
            f.super_admin_cap.borrow(),
            PROTOCOL_ADMIN,
            f.scenario.ctx(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 18, location = blast_fun::acl)]
fun super_admin_transfer_rejects_zero_recipient() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        f.authority.begin_super_admin_transfer(
            f.super_admin_cap.borrow(),
            @0x0,
            &f.clock,
            f.scenario.ctx(),
        );
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 21, location = blast_fun::acl)]
fun super_admin_transfer_rejects_early_acceptance() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(NOW_MS);
        f.authority.begin_super_admin_transfer(
            f.super_admin_cap.borrow(),
            NEW_SUPER_ADMIN,
            &f.clock,
            f.scenario.ctx(),
        );
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        f.authority.accept_super_admin_transfer(&f.clock, f.scenario.ctx());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 20, location = blast_fun::acl)]
fun super_admin_transfer_rejects_wrong_recipient() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(NOW_MS);
        f.authority.begin_super_admin_transfer(
            f.super_admin_cap.borrow(),
            NEW_SUPER_ADMIN,
            &f.clock,
            f.scenario.ctx(),
        );
        f.clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    });

    fixture.next_tx!(@0xBAD, |f| {
        f.authority.accept_super_admin_transfer(&f.clock, f.scenario.ctx());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 19, location = blast_fun::acl)]
fun cancelled_super_admin_transfer_cannot_be_accepted() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(NOW_MS);
        f.authority.begin_super_admin_transfer(
            f.super_admin_cap.borrow(),
            NEW_SUPER_ADMIN,
            &f.clock,
            f.scenario.ctx(),
        );
        f.authority.cancel_super_admin_transfer(f.super_admin_cap.borrow());
        f.clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        f.authority.accept_super_admin_transfer(&f.clock, f.scenario.ctx());
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 19, location = blast_fun::acl)]
fun super_admin_cannot_cancel_without_pending_transfer() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        f.authority.cancel_super_admin_transfer(f.super_admin_cap.borrow());
    });

    fixture.end();
}

#[test]
fun package_init_delivers_only_root() {
    start_package_init().end();
}

#[test]
#[expected_failure(abort_code = 3, location = blast_fun::runtime_config)]
fun package_init_starts_x_signer_disabled() {
    let mut fixture = start_runtime_init();

    fixture.next_tx!(X_CLAIMANT, |f| {
        f.clock.set_for_testing(NOW_MS);

        let cap = f.claim_x(new_x_authority());

        destroy(cap);
    });

    fixture.end();
}

#[test]
fun address_creator_claim_returns_composable_cap_without_attestation() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(CREATOR, |f| {
        let creator_state = creator_authority::new_address(CREATOR)
            .into_authority<TEST_MEME>();
        let cap = creator_state.claim_creator_cap<TEST_MEME>(
            &f.config,
            option::none(),
            &f.clock,
            f.scenario.ctx(),
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
    });

    fixture.next_tx_expecting_events!(PROTOCOL_ADMIN, 1, |f| {
        assert!(f.creator_cap_delivered<TEST_MEME>());
        assert!(!f.creator_cap_delivered<OTHER_MEME>());

        let cap = f.take_delivered_creator_cap();

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 9, location = blast_fun::creator_authority)]
fun address_identity_rejects_zero_creator_address() {
    let creator_identity = creator_authority::new_address(@0x0);
    destroy(creator_identity);
}

#[test]
#[expected_failure(abort_code = 26, location = blast_fun::creator_authority)]
fun address_creator_claim_rejects_different_sender() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(@0xBAD, |f| {
        let creator_state = creator_authority::new_address(CREATOR)
            .into_authority<TEST_MEME>();

        let cap = creator_state.claim_creator_cap<TEST_MEME>(
            &f.config,
            option::none(),
            &f.clock,
            f.scenario.ctx(),
        );

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 11, location = blast_fun::creator_authority)]
fun address_creator_claim_rejects_x_attestation() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(CREATOR, |f| {
        let creator_state = creator_authority::new_address(CREATOR)
            .into_authority<TEST_MEME>();

        let cap = creator_state.claim_creator_cap<TEST_MEME>(
            &f.config,
            option::some(x_claim_attestation()),
            &f.clock,
            f.scenario.ctx(),
        );

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 10, location = blast_fun::creator_authority)]
fun x_identity_rejects_non_32_byte_identity_commitment() {
    let creator_identity = creator_authority::new_x(x"1122");
    destroy(creator_identity);
}

#[test]
fun valid_x_attestation_consumes_authority_and_returns_creator_cap() {
    let mut fixture = start_with_x_signer();

    fixture.next_tx!(X_CLAIMANT, |f| {
        let message =
            creator_authority::x_claim_attestation_bytes_for_testing<TEST_MEME>(
                x_identity_hash(),
                X_CLAIMANT,
                EXPIRY_MS,
            );
        assert_eq!(
            message,
            x"64303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303a3a63726561746f725f617574686f726974795f74657374733a3a544553545f4d454d452011223344556677889900aabbccddeeffffeeddccbbaa009988776655443322110000000000000000000000000000000000000000000000000000000000c0ffee80841e0000000000",
        );

        f.clock.set_for_testing(NOW_MS);

        let cap = f.claim_x(new_x_authority());

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 6, location = blast_fun::runtime_config)]
fun x_claim_rejects_signature_bound_to_another_sender() {
    let mut fixture = start_with_x_signer();

    fixture.next_tx!(@0xBAD, |f| {
        f.clock.set_for_testing(NOW_MS);

        let cap = f.claim_x(new_x_authority());

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 25, location = blast_fun::creator_authority)]
fun x_creator_claim_requires_attestation() {
    let mut fixture = start_with_x_signer();

    fixture.next_tx!(X_CLAIMANT, |f| {
        let cap = new_x_authority().claim_creator_cap<TEST_MEME>(
            &f.config,
            option::none(),
            &f.clock,
            f.scenario.ctx(),
        );

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 27, location = blast_fun::creator_authority)]
fun x_creator_claim_rejects_malformed_attestation() {
    let mut fixture = start_with_x_signer();

    fixture.next_tx!(X_CLAIMANT, |f| {
        let cap = new_x_authority().claim_creator_cap<TEST_MEME>(
            &f.config,
            option::some(x"00"),
            &f.clock,
            f.scenario.ctx(),
        );

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 3, location = blast_fun::runtime_config)]
fun disabled_x_signer_rejects_before_attestation_parsing() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(X_CLAIMANT, |f| {
        let cap = new_x_authority().claim_creator_cap<TEST_MEME>(
            &f.config,
            option::some(x"00"),
            &f.clock,
            f.scenario.ctx(),
        );

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 14, location = blast_fun::creator_authority)]
fun x_claim_rejects_expired_attestation() {
    let mut fixture = start_with_x_signer();

    fixture.next_tx!(X_CLAIMANT, |f| {
        f.clock.set_for_testing(EXPIRY_MS + 1);

        let cap = f.claim_x(new_x_authority());

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 6, location = blast_fun::runtime_config)]
fun x_claim_rejects_signature_for_another_meme_type() {
    let mut fixture = start_with_x_signer();

    fixture.next_tx!(X_CLAIMANT, |f| {
        f.clock.set_for_testing(NOW_MS);
        let creator_state = creator_authority::new_x(x_identity_hash())
            .into_authority<OTHER_MEME>();

        let cap = creator_state.claim_creator_cap<OTHER_MEME>(
            &f.config,
            option::some(x_claim_attestation()),
            &f.clock,
            f.scenario.ctx(),
        );

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 6, location = blast_fun::runtime_config)]
fun x_claim_rejects_signature_for_another_x_identity() {
    let mut fixture = start_with_x_signer();

    fixture.next_tx!(X_CLAIMANT, |f| {
        f.clock.set_for_testing(NOW_MS);
        let creator_state = creator_authority::new_x(
            x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        ).into_authority<TEST_MEME>();

        let cap = f.claim_x(creator_state);

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 6, location = blast_fun::runtime_config)]
fun x_claim_rejects_attestation_from_rotated_signer_key() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();
        f.config.set_x_claim_signer(
            &admin_witness,
            x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        );
    });

    fixture.next_tx!(X_CLAIMANT, |f| {
        f.clock.set_for_testing(NOW_MS);

        let cap = f.claim_x(new_x_authority());

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 3, location = blast_fun::runtime_config)]
fun x_claim_rejects_attestation_after_signer_revocation() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();
        f.config.set_x_claim_signer(
            &admin_witness,
            x_signer_public_key(),
        );
        f.config.revoke_x_claim_signer(&admin_witness);
    });

    fixture.next_tx!(X_CLAIMANT, |f| {
        f.clock.set_for_testing(NOW_MS);

        let cap = f.claim_x(new_x_authority());

        destroy(cap);
    });

    fixture.end();
}

#[test]
fun signer_rotation_reenables_x_claims_after_revocation() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();
        f.config.set_x_claim_signer(
            &admin_witness,
            x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        );
        f.config.revoke_x_claim_signer(&admin_witness);
        f.config.set_x_claim_signer(
            &admin_witness,
            x_signer_public_key(),
        );
    });

    fixture.next_tx!(X_CLAIMANT, |f| {
        f.clock.set_for_testing(NOW_MS);

        let cap = f.claim_x(new_x_authority());

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(abort_code = 24, location = blast_fun::runtime_config)]
fun signer_rotation_rejects_current_public_key() {
    let mut fixture = start(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();

        f.config.set_x_claim_signer(
            &admin_witness,
            x_signer_public_key(),
        );
        f.config.set_x_claim_signer(
            &admin_witness,
            x_signer_public_key(),
        );
    });

    fixture.end();
}

// === Private Test Helpers ===

macro fun next_tx($fixture: &mut Fixture, $sender: address, $fn: |&mut Fixture|) {
    let fixture = $fixture;

    fixture.advance($sender);
    $fn(fixture);
}

macro fun next_tx_expecting_events(
    $fixture: &mut Fixture,
    $sender: address,
    $count: u64,
    $fn: |&mut Fixture|,
) {
    let fixture = $fixture;

    assert_eq!(fixture.advance($sender), $count);
    $fn(fixture);
}

fun start(admin: address): Fixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority, config) = new_protocol(scenario.ctx());
    authority.grant_admin(&super_admin_cap, admin, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(admin);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();

    Fixture {
        scenario,
        super_admin_cap: option::some(super_admin_cap),
        authority,
        admin_cap: option::some(admin_cap),
        config,
        clock,
    }
}

/// The launcher environment plus a runtime configuration whose X signer is live.
fun start_with_x_signer(): Fixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(LAUNCHER, scenario.ctx());
    authority.grant_admin(&super_admin_cap, LAUNCHER, scenario.ctx());
    let config = runtime_config::new_for_testing(
        x_signer_public_key(),
        scenario.ctx(),
    );
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(LAUNCHER);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();

    Fixture {
        scenario,
        super_admin_cap: option::some(super_admin_cap),
        authority,
        admin_cap: option::some(admin_cap),
        config,
        clock,
    }
}

/// Runs production package initialization and verifies only the root capability
/// and shared authority are delivered before custodying them.
fun start_package_init(): Fixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    acl::init_for_testing(scenario.ctx());

    let effects = scenario.next_tx(LAUNCHER);
    assert_eq!(effects.num_user_events(), 1);
    assert!(scenario.has_most_recent_for_sender<acl::SuperAdminCap>());
    assert!(!scenario.has_most_recent_for_sender<acl::AdminCap>());
    let super_admin_cap = scenario.take_from_sender<acl::SuperAdminCap>();
    let authority = scenario.take_shared<acl::ProtocolAuthority>();
    let config = runtime_config::new_disabled_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    Fixture {
        scenario,
        super_admin_cap: option::some(super_admin_cap),
        authority,
        admin_cap: option::none(),
        config,
        clock,
    }
}

/// The launcher environment around the real shared runtime configuration.
fun start_runtime_init(): Fixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (super_admin_cap, authority) =
        acl::new_protocol_for_testing(LAUNCHER, scenario.ctx());
    runtime_config::init_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(LAUNCHER);
    let config = scenario.take_shared<runtime_config::RuntimeConfig>();

    Fixture {
        scenario,
        super_admin_cap: option::some(super_admin_cap),
        authority,
        admin_cap: option::none(),
        config,
        clock,
    }
}

fun advance(self: &mut Fixture, sender: address): u64 {
    self.scenario.next_tx(sender).num_user_events()
}

fun sign_in(self: &Fixture): acl::AdminWitness {
    self.authority.sign_in(self.admin_cap.borrow())
}

fun claim_x(
    self: &mut Fixture,
    creator_state: creator_authority::CreatorAuthority<TEST_MEME>,
): creator_authority::CreatorCap<TEST_MEME> {
    creator_state.claim_creator_cap(
        &self.config,
        option::some(x_claim_attestation()),
        &self.clock,
        self.scenario.ctx(),
    )
}

fun take_admin_cap(self: &mut Fixture): acl::AdminCap {
    self.admin_cap.extract()
}

fun take_super_admin_cap(self: &mut Fixture): acl::SuperAdminCap {
    self.super_admin_cap.extract()
}

fun replace_super_admin_cap(self: &mut Fixture): acl::SuperAdminCap {
    let new_super_admin_cap = self.scenario.take_from_sender<acl::SuperAdminCap>();
    self.super_admin_cap.swap(new_super_admin_cap)
}

fun take_delivered_admin_cap(self: &Fixture): acl::AdminCap {
    self.scenario.take_from_sender()
}

fun take_delivered_creator_cap(
    self: &Fixture,
): creator_authority::CreatorCap<TEST_MEME> {
    self.scenario.take_from_sender()
}

fun creator_cap_delivered<Meme>(self: &Fixture): bool {
    self.scenario.has_most_recent_for_sender<creator_authority::CreatorCap<Meme>>()
}

fun end(self: Fixture) {
    destroy(self);
}

fun new_protocol(
    ctx: &mut TxContext,
): (acl::SuperAdminCap, acl::ProtocolAuthority, runtime_config::RuntimeConfig) {
    let (super_admin_cap, authority) =
        acl::new_protocol_for_testing(LAUNCHER, ctx);
    let config = runtime_config::new_disabled_for_testing(ctx);
    (super_admin_cap, authority, config)
}

fun new_x_authority(): creator_authority::CreatorAuthority<TEST_MEME> {
    creator_authority::new_x(x_identity_hash()).into_authority<TEST_MEME>()
}

fun x_claim_attestation(): vector<u8> {
    creator_authority::new_x_claim_attestation_for_testing(EXPIRY_MS, valid_x_signature())
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
