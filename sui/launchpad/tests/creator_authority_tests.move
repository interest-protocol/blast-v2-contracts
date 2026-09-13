#[test_only]
module blast_fun::creator_authority_tests;

use blast_admin::acl::{Authority, SuperAdminCap, AdminCap, AdminWitness};
use blast_fun::{
    creator_authority,
    domain_fixture,
    events,
    launch_config::{Self, LaunchConfig},
    launchpad_domain::{Self, LAUNCHPAD_DOMAIN},
    package_version::{Self, PackageVersion},
    runtime_config,
};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, event, test_scenario::{Self, Scenario}};

use fun acl_ctx as AclFixture.ctx;
use fun acl_end as AclFixture.end;
use fun acl_next_tx as AclFixture.next_tx;
use fun claim_end as ClaimFixture.end;
use fun claim_next_tx as ClaimFixture.next_tx;
use fun claim_next_tx_expecting_events as ClaimFixture.next_tx_expecting_events;
use fun event_ctx as EventFixture.ctx;
use fun event_end as EventFixture.end;
use fun event_next_tx as EventFixture.next_tx;
use fun event_take_authority as EventFixture.take_authority;
use fun event_take_launch_config as EventFixture.take_launch_config;
use fun event_take_package_version as EventFixture.take_package_version;
use fun event_take_runtime_config as EventFixture.take_runtime_config;
use fun signer_claim_end as SignerClaimFixture.end;
use fun signer_claim_next_tx as SignerClaimFixture.next_tx;
use fun signer_claim_sign_in as SignerClaimFixture.sign_in;
use fun signer_end as SignerFixture.end;
use fun signer_next_tx as SignerFixture.next_tx;
use fun signer_sign_in as SignerFixture.sign_in;

// === Constants ===

const LAUNCHER: address = @0xA11CE;
const CREATOR: address = @0xC0FFEE;
const PROTOCOL_ADMIN: address = @0xAD;
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

/// Creator-claim seam only: a runtime configuration and clock, no ACL state.
public struct ClaimFixture {
    scenario: Scenario,
    config: runtime_config::RuntimeConfig,
    clock: Clock,
}

/// Launchpad-domain membership only; needs no runtime config or clock.
public struct AclFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    super_admin_cap: Option<SuperAdminCap<LAUNCHPAD_DOMAIN>>,
    authority: Authority<LAUNCHPAD_DOMAIN>,
    admin_cap: Option<AdminCap<LAUNCHPAD_DOMAIN>>,
}

/// Live signer/config administration through the shared sign-in seam.
public struct SignerFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    super_admin_cap: SuperAdminCap<LAUNCHPAD_DOMAIN>,
    authority: Authority<LAUNCHPAD_DOMAIN>,
    admin_cap: AdminCap<LAUNCHPAD_DOMAIN>,
    config: runtime_config::RuntimeConfig,
}

/// Signer administration plus the clock inputs an attested claim needs.
public struct SignerClaimFixture {
    scenario: Scenario,
    package_version: PackageVersion,
    authority: Authority<LAUNCHPAD_DOMAIN>,
    admin_cap: AdminCap<LAUNCHPAD_DOMAIN>,
    config: runtime_config::RuntimeConfig,
    clock: Clock,
}

// === Tests ===

#[test]
/// Initialization emits only the shared authority-creation fact; every Launchpad
/// product singleton is still created silently.
fun package_initialization_shares_singletons_with_only_the_authority_fact() {
    let mut fixture = start_event();

    fixture.next_tx!(LAUNCHER, |f| {
        launchpad_domain::init_for_testing(f.ctx!());
        let created = blast_admin::events::collect_one<
            blast_admin::events::AuthorityCreated<LAUNCHPAD_DOMAIN>,
        >(0);
        let (_, _, recipient, max_admins, root_transfer_delay_ms) =
            created.authority_created_fields();
        assert_eq!(recipient, LAUNCHER);
        assert_eq!(max_admins, 16);
        assert_eq!(root_transfer_delay_ms, 7 * 24 * 60 * 60 * 1_000);

        package_version::init_for_testing(f.ctx!());
        runtime_config::init_for_testing(f.ctx!());
        launch_config::init_for_testing(f.ctx!());

        // Only the shared authority-creation fact; no product singleton emits.
        assert_eq!(event::num_events(), 1);
    });

    fixture.next_tx!(LAUNCHER, |f| {
        let package_version = f.take_package_version();
        let authority = f.take_authority();
        let config = f.take_runtime_config();
        let launch_config = f.take_launch_config();

        destroy(package_version);
        destroy(authority);
        destroy(config);
        destroy(launch_config);
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
    abort_code = blast_admin::errors::EInvalidAdminCap,
    location = blast_admin::acl,
)]
fun revoked_admin_cannot_configure_x_signer() {
    let mut fixture = start_signer(LAUNCHER);

    fixture.next_tx!(LAUNCHER, |f| {
        let admin_cap_id = f.admin_cap.admin_cap_id_for_testing();
        f.authority.revoke_admin(&f.super_admin_cap, admin_cap_id);
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
#[expected_failure(
    abort_code = blast_admin::errors::EInvalidAdminCap,
    location = blast_admin::acl,
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
        let (meme, x_identity_hash, x_claim_expiry_ms) =
            claimed.creator_cap_claimed_fields();
        assert_eq!(
            meme,
            std::type_name::with_original_ids<TEST_MEME>(),
        );
        assert!(x_identity_hash.is_none());
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
    let (super_admin_cap, mut authority) = new_authority(scenario.ctx());
    authority.grant_admin(&super_admin_cap, 0, LAUNCHER, scenario.ctx());

    scenario.next_tx(LAUNCHER);
    let admin_cap = scenario.take_from_sender<AdminCap<LAUNCHPAD_DOMAIN>>();

    AclFixture {
        scenario,
        package_version,
        super_admin_cap: option::some(super_admin_cap),
        authority,
        admin_cap: option::some(admin_cap),
    }
}

fun start_signer(admin: address): SignerFixture {
    let mut scenario = test_scenario::begin(LAUNCHER);
    let (package_version, super_admin_cap, mut authority, config) =
        new_protocol(scenario.ctx());
    authority.grant_admin(&super_admin_cap, 0, admin, scenario.ctx());

    scenario.next_tx(admin);
    let admin_cap = scenario.take_from_sender<AdminCap<LAUNCHPAD_DOMAIN>>();

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
    authority.grant_admin(&super_admin_cap, 0, LAUNCHER, scenario.ctx());
    destroy(super_admin_cap);
    let clock = clock::create_for_testing(scenario.ctx());

    scenario.next_tx(LAUNCHER);
    let admin_cap = scenario.take_from_sender<AdminCap<LAUNCHPAD_DOMAIN>>();

    SignerClaimFixture {
        scenario,
        package_version,
        authority,
        admin_cap,
        config,
        clock,
    }
}

fun sign_in_to(
    self: &AclFixture,
    authority: &Authority<LAUNCHPAD_DOMAIN>,
): AdminWitness<LAUNCHPAD_DOMAIN> {
    authority.sign_in(self.admin_cap.borrow())
}

fun signer_sign_in(self: &SignerFixture): AdminWitness<LAUNCHPAD_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
}

fun signer_claim_sign_in(self: &SignerClaimFixture): AdminWitness<LAUNCHPAD_DOMAIN> {
    self.authority.sign_in(&self.admin_cap)
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

fun event_take_authority(self: &EventFixture): Authority<LAUNCHPAD_DOMAIN> {
    self.scenario.take_shared<Authority<LAUNCHPAD_DOMAIN>>()
}

fun event_take_runtime_config(self: &EventFixture): runtime_config::RuntimeConfig {
    self.scenario.take_shared<runtime_config::RuntimeConfig>()
}

fun event_take_launch_config(self: &EventFixture): LaunchConfig {
    self.scenario.take_shared<LaunchConfig>()
}


fun claim_end(self: ClaimFixture) {
    destroy(self);
}

fun acl_end(self: AclFixture) {
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
    SuperAdminCap<LAUNCHPAD_DOMAIN>,
    Authority<LAUNCHPAD_DOMAIN>,
    runtime_config::RuntimeConfig,
) {
    let package_version = package_version::new_for_testing(ctx);
    let (super_admin_cap, authority) = new_authority(ctx);
    let config = runtime_config::new_disabled_for_testing(ctx);
    (package_version, super_admin_cap, authority, config)
}

/// Unshared Launchpad-domain authority state with this package's real constants.
fun new_authority(
    ctx: &mut TxContext,
): (SuperAdminCap<LAUNCHPAD_DOMAIN>, Authority<LAUNCHPAD_DOMAIN>) {
    domain_fixture::new_authority(ctx)
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
