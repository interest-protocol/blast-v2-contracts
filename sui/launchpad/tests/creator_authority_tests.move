#[test_only]
module blast_fun::creator_authority_tests;

use blast_fun::{
    acl,
    constants,
    creator_authority,
    events,
    package_version::{Self, PackageVersion},
    runtime_config,
};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, event, test_scenario::{Self, Scenario}};

use fun acl_cancel_super_admin_transfer as AclFixture.cancel_super_admin_transfer;
use fun acl_ctx as AclFixture.ctx;
use fun acl_end as AclFixture.end;
use fun acl_grant_admin as AclFixture.grant_admin;
use fun acl_next_tx as AclFixture.next_tx;
use fun claim_end as ClaimFixture.end;
use fun claim_next_tx as ClaimFixture.next_tx;
use fun claim_next_tx_expecting_events as ClaimFixture.next_tx_expecting_events;
use fun event_ctx as EventFixture.ctx;
use fun event_end as EventFixture.end;
use fun event_next_tx as EventFixture.next_tx;
use fun event_take_package_version as EventFixture.take_package_version;
use fun init_end as InitFixture.end;
use fun signer_claim_end as SignerClaimFixture.end;
use fun signer_claim_next_tx as SignerClaimFixture.next_tx;
use fun signer_claim_sign_in as SignerClaimFixture.sign_in;
use fun signer_end as SignerFixture.end;
use fun signer_next_tx as SignerFixture.next_tx;
use fun signer_sign_in as SignerFixture.sign_in;
use fun transfer_cancel_super_admin_transfer as TransferFixture.cancel_super_admin_transfer;
use fun transfer_end as TransferFixture.end;
use fun transfer_grant_admin as TransferFixture.grant_admin;
use fun transfer_next_tx as TransferFixture.next_tx;

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

/// Bare transaction runner for singleton-creation event assertions.
public struct EventFixture {
    scenario: Scenario,
}

/// Observed facts from one production ACL package initialization.
public struct InitFixture {
    scenario: Scenario,
    user_event_count: u64,
    super_admin_cap_delivered: bool,
    admin_cap_delivered: bool,
}

/// Creator-claim seam only: a runtime configuration and clock, no ACL state.
public struct ClaimFixture {
    scenario: Scenario,
    config: runtime_config::RuntimeConfig,
    clock: Clock,
}

/// ACL registry and membership only; needs no runtime config or clock.
public struct AclFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    super_admin_cap: Option<acl::SuperAdminCap>,
    authority: acl::ProtocolAuthority,
    admin_cap: Option<acl::AdminCap>,
}

/// Delayed root-transfer choreography: ACL rotation state plus the clock.
public struct TransferFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    super_admin_cap: Option<acl::SuperAdminCap>,
    authority: acl::ProtocolAuthority,
    clock: Clock,
}

/// Live signer/config administration through the ACL sign-in seam.
public struct SignerFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    super_admin_cap: acl::SuperAdminCap,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
    config: runtime_config::RuntimeConfig,
}

/// Signer administration plus the clock inputs an attested claim needs.
public struct SignerClaimFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    authority: acl::ProtocolAuthority,
    admin_cap: acl::AdminCap,
    config: runtime_config::RuntimeConfig,
    clock: Clock,
}

// === Tests ===

#[test]
fun singleton_creation_events_use_generic_wrapper() {
    let mut fixture = start_event();
    let emitted_package_version_id;

    fixture.next_tx!(LAUNCHER, |f| {
        package_version::init_for_testing(f.ctx!());
        let (package_version, super_admin_cap, authority, config) =
            new_protocol(f.ctx!());
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
        let package_version_created =
            events::collect_one<events::PackageVersionCreated>(0);
        let (package_version_id, emitted_package_version) =
            package_version_created.package_version_created_fields();
        emitted_package_version_id = package_version_id;

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
        assert_eq!(emitted_package_version, 1);
        assert!(event::events_by_type<events::ProtocolAuthorityCreated>().is_empty());
        assert!(event::events_by_type<events::RuntimeConfigCreated>().is_empty());

        destroy(super_admin_cap);
        destroy(authority);
        destroy(config);
        destroy(package_version);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let package_version = f.take_package_version();

        assert_eq!(object::id(&package_version), emitted_package_version_id);

        destroy(package_version);
    });

    fixture.end();
}

#[test]
fun super_admin_grants_global_admin_that_configures_x_signer() {
    let mut fixture = start_signer(PROTOCOL_ADMIN);

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let admin_witness = f.sign_in();

        f.config.set_x_claim_signer(
            &f.package_version,
            &admin_witness,
            x_signer_public_key(),
        );
    });

    fixture.end();
}

#[test]
fun super_admin_grant_is_replay_complete_and_delivers_the_cap() {
    let mut fixture = start_acl();
    let granted_admin_cap_id;

    fixture.next_tx!(LAUNCHER, |f| {
        f.grant_admin(SECOND_ADMIN);

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
    let mut fixture = start_acl();

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_cap_id = f.admin_cap_id();

        f.revoke_admin(admin_cap_id);

        let revoked = events::collect_one<events::AdminRevoked>(0);
        assert_eq!(revoked.admin_revoked_fields(), admin_cap_id);
    });

    fixture.end();
}

#[test]
fun x_claim_signer_set_event_is_replay_complete() {
    let mut fixture = start_signer(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();

        f.config.set_x_claim_signer(
            &f.package_version,
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
    let mut fixture = start_signer(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();
        f.config.set_x_claim_signer(
            &f.package_version,
            &admin_witness,
            x_signer_public_key(),
        );

        f.config.revoke_x_claim_signer(&f.package_version, &admin_witness);

        let signer_revoked = events::collect_one<events::XClaimSignerRevoked>(0);
        let previous_public_key = signer_revoked.x_claim_signer_revoked_fields();
        assert_eq!(previous_public_key, x_signer_public_key());
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidXClaimPublicKey,
    location = blast_fun::runtime_config,
)]
fun x_claim_signer_rejects_invalid_public_key_length() {
    let mut fixture = start_signer(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();

        f.config.set_x_claim_signer(&f.package_version, &admin_witness, x"00");
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EXClaimSignerInactive,
    location = blast_fun::runtime_config,
)]
fun x_claim_signer_cannot_revoke_while_disabled() {
    let mut fixture = start_signer(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();

        f.config.revoke_x_claim_signer(&f.package_version, &admin_witness);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidAdminCap,
    location = blast_fun::acl,
)]
fun revoked_admin_cannot_configure_x_signer() {
    let mut fixture = start_signer(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_cap_id = f.admin_cap.admin_cap_id_for_testing();
        f.authority.revoke_admin(
            &f.package_version,
            &f.super_admin_cap,
            admin_cap_id,
        );
        let admin_witness = f.sign_in();

        f.config.set_x_claim_signer(
            &f.package_version,
            &admin_witness,
            x_signer_public_key(),
        );
    });

    fixture.end();
}

#[test]
fun active_admin_can_destroy_cap_and_renounce_membership() {
    let mut fixture = start_acl();

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_cap = f.take_admin_cap();
        let admin_cap_id = admin_cap.admin_cap_id_for_testing();

        f.authority.destroy_admin_cap(&f.package_version, admin_cap);

        let destroyed = events::collect_one<events::AdminDestroyed>(0);
        let (emitted_admin_cap_id, was_active) = destroyed.admin_destroyed_fields();
        assert_eq!(emitted_admin_cap_id, admin_cap_id);
        assert!(was_active);
    });

    fixture.end();
}

#[test]
fun revoked_admin_can_destroy_inert_cap() {
    let mut fixture = start_acl();

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_cap = f.take_admin_cap();
        let admin_cap_id = admin_cap.admin_cap_id_for_testing();

        f.revoke_admin(admin_cap_id);
        f.authority.destroy_admin_cap(&f.package_version, admin_cap);

        let destroyed = events::collect_one<events::AdminDestroyed>(0);
        let (emitted_admin_cap_id, was_active) = destroyed.admin_destroyed_fields();
        assert_eq!(emitted_admin_cap_id, admin_cap_id);
        assert!(!was_active);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidAdminCap,
    location = blast_fun::acl,
)]
fun destroyed_active_admin_is_removed_from_registry() {
    let mut fixture = start_acl();

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_cap = f.take_admin_cap();
        let admin_cap_id = admin_cap.admin_cap_id_for_testing();

        f.authority.destroy_admin_cap(&f.package_version, admin_cap);
        f.revoke_admin(admin_cap_id);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidAdminCap,
    location = blast_fun::acl,
)]
fun admin_registered_in_another_protocol_registry_is_rejected() {
    let mut fixture = start_acl();

    fixture.next_tx!(LAUNCHER, |f| {
        let (second_package_version, second_super_admin, second_authority, mut second_config) =
            new_protocol(f.ctx!());
        let admin_witness = f.sign_in_to(&second_authority);

        second_config.set_x_claim_signer(
            &second_package_version,
            &admin_witness,
            x_signer_public_key(),
        );

        destroy(second_super_admin);
        destroy(second_authority);
        destroy(second_config);
        destroy(second_package_version);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EAdminCapacityReached,
    location = blast_fun::acl,
)]
fun active_admin_registry_is_bounded() {
    let mut fixture = start_acl();

    fixture.next_tx!(LAUNCHER, |f| {
        let mut index = 1u64;
        while (index < constants::max_admins!()) {
            f.grant_admin(PROTOCOL_ADMIN);
            index = index + 1;
        };
        f.grant_admin(PROTOCOL_ADMIN);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidAdminRecipient,
    location = blast_fun::acl,
)]
fun super_admin_cannot_grant_zero_address_admin() {
    let mut fixture = start_acl();

    fixture.next_tx!(LAUNCHER, |f| {
        f.grant_admin(@0x0);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EPackageVersionMismatch,
    location = blast_fun::package_version,
)]
fun stale_package_version_rejects_acl_before_recipient_validation() {
    let mut fixture = start_acl();

    fixture.next_tx!(LAUNCHER, |f| {
        f.package_version.set_for_testing(2);
        f.grant_admin(@0x0);
    });

    fixture.end();
}

#[test]
fun super_admin_transfer_requires_delay_and_recipient_acceptance() {
    let mut fixture = start_transfer();
    let new_super_admin_cap_id;

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(NOW_MS);

        f.begin_super_admin_transfer(NEW_SUPER_ADMIN);

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
        f.accept_super_admin_transfer();

        let transferred = events::collect_one<events::SuperAdminTransferred>(0);
        let (previous_super_admin_cap_id, emitted_new_super_admin_cap_id, recipient) =
            transferred.super_admin_transferred_fields();
        assert_eq!(
            previous_super_admin_cap_id,
            f.super_admin_cap_id(),
        );
        assert_eq!(recipient, NEW_SUPER_ADMIN);
        new_super_admin_cap_id = emitted_new_super_admin_cap_id;
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        let retired_super_admin_cap = f.replace_super_admin_cap();

        assert_eq!(
            new_super_admin_cap_id,
            f.super_admin_cap_id(),
        );
        f.grant_admin(PROTOCOL_ADMIN);

        f.authority.destroy_retired_super_admin_cap(retired_super_admin_cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ESuperAdminCapStillActive,
    location = blast_fun::acl,
)]
fun active_super_admin_cap_cannot_be_destroyed() {
    let mut fixture = start_acl();

    fixture.next_tx!(LAUNCHER, |f| {
        let super_admin_cap = f.take_super_admin_cap();

        f.authority.destroy_retired_super_admin_cap(super_admin_cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ESuperAdminTransferTimeOverflow,
    location = blast_fun::acl,
)]
fun super_admin_transfer_rejects_timestamp_overflow() {
    let mut fixture = start_transfer();

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(std::u64::max_value!());

        f.begin_super_admin_transfer(NEW_SUPER_ADMIN);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ESuperAdminTransferUnchanged,
    location = blast_fun::acl,
)]
fun super_admin_transfer_rejects_unchanged_pending_recipient_before_timestamp_work() {
    let mut fixture = start_transfer();

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(NOW_MS);
        f.begin_super_admin_transfer(NEW_SUPER_ADMIN);

        f.clock.set_for_testing(std::u64::max_value!());
        f.begin_super_admin_transfer(NEW_SUPER_ADMIN);
    });

    fixture.end();
}

#[test]
fun super_admin_transfer_replaces_different_pending_recipient() {
    let mut fixture = start_transfer();

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(NOW_MS);
        f.begin_super_admin_transfer(NEW_SUPER_ADMIN);
        f.clock.set_for_testing(NOW_MS + 1);
        f.begin_super_admin_transfer(PROTOCOL_ADMIN);

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
        f.accept_super_admin_transfer();
    });

    fixture.next_tx!(PROTOCOL_ADMIN, |f| {
        let retired_super_admin_cap = f.replace_super_admin_cap();

        f.authority.destroy_retired_super_admin_cap(retired_super_admin_cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidSuperAdminCap,
    location = blast_fun::acl,
)]
fun accepted_super_admin_transfer_invalidates_previous_root_cap() {
    let mut fixture = start_transfer();

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(NOW_MS);
        f.begin_super_admin_transfer(NEW_SUPER_ADMIN);
        f.clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        f.accept_super_admin_transfer();

        f.grant_admin(PROTOCOL_ADMIN);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidSuperAdminRecipient,
    location = blast_fun::acl,
)]
fun super_admin_transfer_rejects_zero_recipient() {
    let mut fixture = start_transfer();

    fixture.next_tx!(LAUNCHER, |f| {
        f.begin_super_admin_transfer(@0x0);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ESuperAdminTransferNotReady,
    location = blast_fun::acl,
)]
fun super_admin_transfer_rejects_early_acceptance() {
    let mut fixture = start_transfer();

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(NOW_MS);
        f.begin_super_admin_transfer(NEW_SUPER_ADMIN);
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        f.accept_super_admin_transfer();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ENotPendingSuperAdminRecipient,
    location = blast_fun::acl,
)]
fun super_admin_transfer_rejects_wrong_recipient() {
    let mut fixture = start_transfer();

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(NOW_MS);
        f.begin_super_admin_transfer(NEW_SUPER_ADMIN);
        f.clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    });

    fixture.next_tx!(@0xBAD, |f| {
        f.accept_super_admin_transfer();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ENoPendingSuperAdminTransfer,
    location = blast_fun::acl,
)]
fun cancelled_super_admin_transfer_cannot_be_accepted() {
    let mut fixture = start_transfer();

    fixture.next_tx!(LAUNCHER, |f| {
        f.clock.set_for_testing(NOW_MS);
        f.begin_super_admin_transfer(NEW_SUPER_ADMIN);
        f.cancel_super_admin_transfer();
        f.clock.set_for_testing(NOW_MS + constants::super_admin_transfer_delay_ms!());
    });

    fixture.next_tx!(NEW_SUPER_ADMIN, |f| {
        f.accept_super_admin_transfer();
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ENoPendingSuperAdminTransfer,
    location = blast_fun::acl,
)]
fun super_admin_cannot_cancel_without_pending_transfer() {
    let mut fixture = start_acl();

    fixture.next_tx!(LAUNCHER, |f| {
        f.cancel_super_admin_transfer();
    });

    fixture.end();
}

#[test]
fun package_init_delivers_only_root() {
    let fixture = start_package_init();

    assert_eq!(fixture.user_event_count, 1);
    assert!(fixture.super_admin_cap_delivered);
    assert!(!fixture.admin_cap_delivered);

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EXClaimSignerInactive,
    location = blast_fun::runtime_config,
)]
fun package_init_starts_x_signer_disabled() {
    let mut fixture = start_runtime_init();

    fixture.next_tx!(X_CLAIMANT, |f| {
        f.clock.set_for_testing(NOW_MS);

        let cap = f.claim(new_x_authority(), option::some(x_claim_attestation()));

        destroy(cap);
    });

    fixture.end();
}

#[test]
fun address_creator_claim_returns_composable_cap_without_attestation() {
    let mut fixture = start_claim();

    fixture.next_tx!(CREATOR, |f| {
        let creator_state = creator_authority::new_address(CREATOR)
            .into_authority<TEST_MEME>();
        let cap = f.claim(creator_state, option::none());
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
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidCreator,
    location = blast_fun::creator_authority,
)]
fun address_identity_rejects_zero_creator_address() {
    let creator_identity = creator_authority::new_address(@0x0);
    destroy(creator_identity);
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::ECreatorNotSender,
    location = blast_fun::creator_authority,
)]
fun address_creator_claim_rejects_different_sender() {
    let mut fixture = start_claim();

    fixture.next_tx!(@0xBAD, |f| {
        let creator_state = creator_authority::new_address(CREATOR)
            .into_authority<TEST_MEME>();

        let cap = f.claim(creator_state, option::none());

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EUnexpectedXClaimAttestation,
    location = blast_fun::creator_authority,
)]
fun address_creator_claim_rejects_x_attestation() {
    let mut fixture = start_claim();

    fixture.next_tx!(CREATOR, |f| {
        let creator_state = creator_authority::new_address(CREATOR)
            .into_authority<TEST_MEME>();

        let cap = f.claim(creator_state, option::some(x_claim_attestation()));

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidXIdentityHash,
    location = blast_fun::creator_authority,
)]
fun x_identity_rejects_non_32_byte_identity_commitment() {
    let creator_identity = creator_authority::new_x(x"1122");
    destroy(creator_identity);
}

#[test]
fun valid_x_attestation_consumes_authority_and_returns_creator_cap() {
    let mut fixture = start_x_claim();

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

        let cap = f.claim(new_x_authority(), option::some(x_claim_attestation()));

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidXClaimSignature,
    location = blast_fun::runtime_config,
)]
fun x_claim_rejects_signature_bound_to_another_sender() {
    let mut fixture = start_x_claim();

    fixture.next_tx!(@0xBAD, |f| {
        f.clock.set_for_testing(NOW_MS);

        let cap = f.claim(new_x_authority(), option::some(x_claim_attestation()));

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EMissingXClaimAttestation,
    location = blast_fun::creator_authority,
)]
fun x_creator_claim_requires_attestation() {
    let mut fixture = start_x_claim();

    fixture.next_tx!(X_CLAIMANT, |f| {
        let cap = f.claim(new_x_authority(), option::none());

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidXClaimAttestation,
    location = blast_fun::creator_authority,
)]
fun x_creator_claim_rejects_malformed_attestation() {
    let mut fixture = start_x_claim();

    fixture.next_tx!(X_CLAIMANT, |f| {
        let cap = f.claim(new_x_authority(), option::some(x"00"));

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EXClaimSignerInactive,
    location = blast_fun::runtime_config,
)]
fun disabled_x_signer_rejects_before_attestation_parsing() {
    let mut fixture = start_claim();

    fixture.next_tx!(X_CLAIMANT, |f| {
        let cap = f.claim(new_x_authority(), option::some(x"00"));

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EXClaimExpired,
    location = blast_fun::creator_authority,
)]
fun x_claim_rejects_expired_attestation() {
    let mut fixture = start_x_claim();

    fixture.next_tx!(X_CLAIMANT, |f| {
        f.clock.set_for_testing(EXPIRY_MS + 1);

        let cap = f.claim(new_x_authority(), option::some(x_claim_attestation()));

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidXClaimSignature,
    location = blast_fun::runtime_config,
)]
fun x_claim_rejects_signature_for_another_meme_type() {
    let mut fixture = start_x_claim();

    fixture.next_tx!(X_CLAIMANT, |f| {
        f.clock.set_for_testing(NOW_MS);
        let creator_state = creator_authority::new_x(x_identity_hash())
            .into_authority<OTHER_MEME>();

        let cap = f.claim(creator_state, option::some(x_claim_attestation()));

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidXClaimSignature,
    location = blast_fun::runtime_config,
)]
fun x_claim_rejects_signature_for_another_x_identity() {
    let mut fixture = start_x_claim();

    fixture.next_tx!(X_CLAIMANT, |f| {
        f.clock.set_for_testing(NOW_MS);
        let creator_state = creator_authority::new_x(
            x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        ).into_authority<TEST_MEME>();

        let cap = f.claim(creator_state, option::some(x_claim_attestation()));

        destroy(cap);
    });

    fixture.end();
}

#[test]
#[expected_failure(
    abort_code = blast_fun::errors::EInvalidXClaimSignature,
    location = blast_fun::runtime_config,
)]
fun x_claim_rejects_attestation_from_rotated_signer_key() {
    let mut fixture = start_signer_claim();

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();
        f.config.set_x_claim_signer(
            &f.package_version,
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
#[expected_failure(
    abort_code = blast_fun::errors::EXClaimSignerInactive,
    location = blast_fun::runtime_config,
)]
fun x_claim_rejects_attestation_after_signer_revocation() {
    let mut fixture = start_signer_claim();

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();
        f.config.set_x_claim_signer(
            &f.package_version,
            &admin_witness,
            x_signer_public_key(),
        );
        f.config.revoke_x_claim_signer(&f.package_version, &admin_witness);
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
    let mut fixture = start_signer_claim();

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();
        f.config.set_x_claim_signer(
            &f.package_version,
            &admin_witness,
            x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        );
        f.config.revoke_x_claim_signer(&f.package_version, &admin_witness);
        f.config.set_x_claim_signer(
            &f.package_version,
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
#[expected_failure(
    abort_code = blast_fun::errors::EXClaimSignerUnchanged,
    location = blast_fun::runtime_config,
)]
fun signer_rotation_rejects_current_public_key() {
    let mut fixture = start_signer(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_witness = f.sign_in();

        f.config.set_x_claim_signer(
            &f.package_version,
            &admin_witness,
            x_signer_public_key(),
        );
        f.config.set_x_claim_signer(
            &f.package_version,
            &admin_witness,
            x_signer_public_key(),
        );
    });

    fixture.end();
}

// === Private Test Helpers ===

macro fun event_next_tx(
    $fixture: &mut EventFixture,
    $sender: address,
    $fn: |&mut EventFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun claim_next_tx(
    $fixture: &mut ClaimFixture,
    $sender: address,
    $fn: |&mut ClaimFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun claim_next_tx_expecting_events(
    $fixture: &mut ClaimFixture,
    $sender: address,
    $count: u64,
    $fn: |&mut ClaimFixture|,
) {
    let fixture = $fixture;

    assert_eq!(fixture.scenario.next_tx($sender).num_user_events(), $count);
    $fn(fixture);
}

macro fun acl_next_tx(
    $fixture: &mut AclFixture,
    $sender: address,
    $fn: |&mut AclFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun transfer_next_tx(
    $fixture: &mut TransferFixture,
    $sender: address,
    $fn: |&mut TransferFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun signer_next_tx(
    $fixture: &mut SignerFixture,
    $sender: address,
    $fn: |&mut SignerFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun signer_claim_next_tx(
    $fixture: &mut SignerClaimFixture,
    $sender: address,
    $fn: |&mut SignerClaimFixture|,
) {
    let fixture = $fixture;

    fixture.scenario.next_tx($sender);
    $fn(fixture);
}

macro fun event_ctx($fixture: &mut EventFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

macro fun acl_ctx($fixture: &mut AclFixture): &mut TxContext {
    let fixture = $fixture;

    fixture.scenario.ctx()
}

fun start_event(): EventFixture {
    EventFixture { scenario: test_scenario::begin(LAUNCHER) }
}

/// Runs production package initialization and records only the delivery facts
/// the initialization test asserts; the delivered root capability and shared
/// registry stay in scenario custody until fixture teardown.
fun start_package_init(): InitFixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    acl::init_for_testing(scenario.ctx());

    let effects = scenario.next_tx(LAUNCHER);
    let user_event_count = effects.num_user_events();
    let super_admin_cap_delivered =
        scenario.has_most_recent_for_sender<acl::SuperAdminCap>();
    let admin_cap_delivered = scenario.has_most_recent_for_sender<acl::AdminCap>();

    InitFixture {
        scenario,
        user_event_count,
        super_admin_cap_delivered,
        admin_cap_delivered,
    }
}

/// A disabled-signer runtime configuration for address-claim behavior.
fun start_claim(): ClaimFixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = runtime_config::new_disabled_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    ClaimFixture { scenario, config, clock }
}

/// A runtime configuration whose X signer is live for attested-claim behavior.
fun start_x_claim(): ClaimFixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let config = runtime_config::new_for_testing(
        x_signer_public_key(),
        scenario.ctx(),
    );
    let clock = clock::create_for_testing(scenario.ctx());

    ClaimFixture { scenario, config, clock }
}

/// The real shared runtime configuration exactly as package initialization left it.
fun start_runtime_init(): ClaimFixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    runtime_config::init_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(LAUNCHER);
    let config = scenario.take_shared<runtime_config::RuntimeConfig>();

    ClaimFixture { scenario, config, clock }
}

fun start_acl(): AclFixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, mut authority) =
        acl::new_protocol_for_testing(LAUNCHER, scenario.ctx());
    authority.grant_admin(
        &package_version,
        &super_admin_cap,
        LAUNCHER,
        scenario.ctx(),
    );

    scenario.next_tx(LAUNCHER);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();

    AclFixture {
        scenario,
        package_version,
        super_admin_cap: option::some(super_admin_cap),
        authority,
        admin_cap: option::some(admin_cap),
    }
}

fun start_transfer(): TransferFixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let package_version = package_version::new_for_testing(scenario.ctx());
    let (super_admin_cap, authority) =
        acl::new_protocol_for_testing(LAUNCHER, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    TransferFixture {
        scenario,
        package_version,
        super_admin_cap: option::some(super_admin_cap),
        authority,
        clock,
    }
}

fun start_signer(admin: address): SignerFixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (package_version, super_admin_cap, mut authority, config) =
        new_protocol(scenario.ctx());
    authority.grant_admin(
        &package_version,
        &super_admin_cap,
        admin,
        scenario.ctx(),
    );

    scenario.next_tx(admin);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();

    SignerFixture {
        scenario,
        package_version,
        super_admin_cap,
        authority,
        admin_cap,
        config,
    }
}

fun start_signer_claim(): SignerClaimFixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (package_version, super_admin_cap, mut authority, config) =
        new_protocol(scenario.ctx());
    authority.grant_admin(
        &package_version,
        &super_admin_cap,
        LAUNCHER,
        scenario.ctx(),
    );
    destroy(super_admin_cap);
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(LAUNCHER);
    let admin_cap = scenario.take_from_sender<acl::AdminCap>();

    SignerClaimFixture {
        scenario,
        package_version,
        authority,
        admin_cap,
        config,
        clock,
    }
}

fun acl_grant_admin(self: &mut AclFixture, recipient: address) {
    self.authority.grant_admin(
        &self.package_version,
        self.super_admin_cap.borrow(),
        recipient,
        self.scenario.ctx(),
    );
}

fun revoke_admin(self: &mut AclFixture, admin_cap_id: ID) {
    self.authority.revoke_admin(
        &self.package_version,
        self.super_admin_cap.borrow(),
        admin_cap_id,
    );
}

fun acl_cancel_super_admin_transfer(self: &mut AclFixture) {
    self.authority.cancel_super_admin_transfer(
        &self.package_version,
        self.super_admin_cap.borrow(),
    );
}

fun admin_cap_id(self: &AclFixture): ID {
    self.admin_cap.borrow().admin_cap_id_for_testing()
}

fun sign_in_to(
    self: &AclFixture,
    authority: &acl::ProtocolAuthority,
): acl::AdminWitness {
    authority.sign_in(&self.package_version, self.admin_cap.borrow())
}

fun take_admin_cap(self: &mut AclFixture): acl::AdminCap {
    self.admin_cap.extract()
}

fun take_super_admin_cap(self: &mut AclFixture): acl::SuperAdminCap {
    self.super_admin_cap.extract()
}

fun take_delivered_admin_cap(self: &AclFixture): acl::AdminCap {
    self.scenario.take_from_sender()
}

fun transfer_grant_admin(self: &mut TransferFixture, recipient: address) {
    self.authority.grant_admin(
        &self.package_version,
        self.super_admin_cap.borrow(),
        recipient,
        self.scenario.ctx(),
    );
}

fun begin_super_admin_transfer(self: &mut TransferFixture, recipient: address) {
    self.authority.begin_super_admin_transfer(
        &self.package_version,
        self.super_admin_cap.borrow(),
        recipient,
        &self.clock,
        self.scenario.ctx(),
    );
}

fun accept_super_admin_transfer(self: &mut TransferFixture) {
    self.authority.accept_super_admin_transfer(
        &self.package_version,
        &self.clock,
        self.scenario.ctx(),
    );
}

fun transfer_cancel_super_admin_transfer(self: &mut TransferFixture) {
    self.authority.cancel_super_admin_transfer(
        &self.package_version,
        self.super_admin_cap.borrow(),
    );
}

fun super_admin_cap_id(self: &TransferFixture): ID {
    object::id(self.super_admin_cap.borrow())
}

fun replace_super_admin_cap(self: &mut TransferFixture): acl::SuperAdminCap {
    let new_super_admin_cap = self.scenario.take_from_sender<acl::SuperAdminCap>();
    self.super_admin_cap.swap(new_super_admin_cap)
}

fun signer_sign_in(self: &SignerFixture): acl::AdminWitness {
    self.authority.sign_in(&self.package_version, &self.admin_cap)
}

fun signer_claim_sign_in(self: &SignerClaimFixture): acl::AdminWitness {
    self.authority.sign_in(&self.package_version, &self.admin_cap)
}

fun claim_x(
    self: &mut SignerClaimFixture,
    creator_state: creator_authority::CreatorAuthority<TEST_MEME>,
): creator_authority::CreatorCap<TEST_MEME> {
    creator_state.claim_creator_cap(
        &self.config,
        option::some(x_claim_attestation()),
        &self.clock,
        self.scenario.ctx(),
    )
}

fun claim<Meme>(
    self: &mut ClaimFixture,
    creator_state: creator_authority::CreatorAuthority<Meme>,
    x_claim_attestation: Option<vector<u8>>,
): creator_authority::CreatorCap<Meme> {
    creator_state.claim_creator_cap(
        &self.config,
        x_claim_attestation,
        &self.clock,
        self.scenario.ctx(),
    )
}

fun take_delivered_creator_cap(
    self: &ClaimFixture,
): creator_authority::CreatorCap<TEST_MEME> {
    self.scenario.take_from_sender()
}

fun creator_cap_delivered<Meme>(self: &ClaimFixture): bool {
    self.scenario.has_most_recent_for_sender<creator_authority::CreatorCap<Meme>>()
}

fun event_end(self: EventFixture) {
    destroy(self);
}

fun event_take_package_version(self: &EventFixture): PackageVersion {
    self.scenario.take_shared<PackageVersion>()
}

fun init_end(self: InitFixture) {
    destroy(self);
}

fun claim_end(self: ClaimFixture) {
    destroy(self);
}

fun acl_end(self: AclFixture) {
    destroy(self);
}

fun transfer_end(self: TransferFixture) {
    destroy(self);
}

fun signer_end(self: SignerFixture) {
    destroy(self);
}

fun signer_claim_end(self: SignerClaimFixture) {
    destroy(self);
}

fun new_protocol(
    ctx: &mut TxContext,
): (
    PackageVersion,
    acl::SuperAdminCap,
    acl::ProtocolAuthority,
    runtime_config::RuntimeConfig,
) {
    let package_version = package_version::new_for_testing(ctx);
    let (super_admin_cap, authority) =
        acl::new_protocol_for_testing(LAUNCHER, ctx);
    let config = runtime_config::new_disabled_for_testing(ctx);
    (package_version, super_admin_cap, authority, config)
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
