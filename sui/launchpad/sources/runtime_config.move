// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations while retaining one append-only registry in `blast_fun::errors`.
#[allow(lint(abort_without_constant))]
/// Small live protocol settings read by trades, migrators, and X creator claims.
module blast_fun::runtime_config;

use blast_admin::acl::AdminWitness;
use blast_fun::{
    bps::{Self, Bps},
    constants,
    events,
    launchpad_domain::LAUNCHPAD_DOMAIN,
    package_version::PackageVersion,
};

// === Public Structs ===

/// Shared singleton for immediately effective protocol-wide runtime settings.
public struct RuntimeConfig has key {
    id: UID,
    x_claim_signer_public_key: vector<u8>,
    protocol_fee_share_bps: Bps,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Sets the current X claim signer, replacing any previously configured key.
public fun set_x_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<LAUNCHPAD_DOMAIN>,
    signer_public_key: vector<u8>,
) {
    package_version.assert_current();
    validate_x_claim_public_key(&signer_public_key);
    assert!(
        self.x_claim_signer_public_key != signer_public_key,
        blast_fun::errors::x_claim_signer_unchanged!(),
    );

    let previous_public_key = self.x_claim_signer_public_key;
    self.x_claim_signer_public_key = signer_public_key;

    events::x_claim_signer_set(
        previous_public_key,
        self.x_claim_signer_public_key,
    );
}

/// Revokes the X claim signer immediately by clearing the only active key.
public fun revoke_x_claim_signer(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<LAUNCHPAD_DOMAIN>,
) {
    package_version.assert_current();
    self.assert_x_claim_active();

    let previous_public_key = self.x_claim_signer_public_key;
    self.x_claim_signer_public_key = vector[];

    events::x_claim_signer_revoked(previous_public_key);
}

/// Updates the live protocol share used by every subsequent trade-fee accrual.
public fun set_protocol_fee_share(
    self: &mut RuntimeConfig,
    package_version: &PackageVersion,
    _: &AdminWitness<LAUNCHPAD_DOMAIN>,
    protocol_fee_share_bps: u64,
) {
    package_version.assert_current();
    assert!(
        protocol_fee_share_bps != self.protocol_fee_share_bps.value(),
        blast_fun::errors::protocol_fee_share_unchanged!(),
    );

    let old_protocol_fee_share_bps = self.protocol_fee_share_bps.value();

    self.protocol_fee_share_bps = bps::new(protocol_fee_share_bps);

    events::protocol_fee_share_changed(
        old_protocol_fee_share_bps,
        protocol_fee_share_bps,
    );
}

/// Returns the raw live protocol share used by subsequent fee accruals.
public fun protocol_fee_share_bps(self: &RuntimeConfig): u64 {
    self.protocol_fee_share_bps.value()
}

// === Package Functions ===

/// Rejects use of the X claim path while no backend signer is authorized.
public(package) fun assert_x_claim_active(self: &RuntimeConfig) {
    assert!(
        !self.x_claim_signer_public_key.is_empty(),
        blast_fun::errors::x_claim_signer_inactive!(),
    );
}

/// Verifies that `signature` came from the one currently authorized Blast backend key.
public(package) fun verify_x_claim_signature(
    self: &RuntimeConfig,
    message: &vector<u8>,
    signature: &vector<u8>,
) {
    self.assert_x_claim_active();

    assert!(
        sui::ed25519::ed25519_verify(
            signature,
            &self.x_claim_signer_public_key,
            message,
        ),
        blast_fun::errors::invalid_x_claim_signature!(),
    );
}

/// Returns the validated live protocol share for package-owned fee arithmetic.
public(package) fun protocol_fee_share(self: &RuntimeConfig): Bps {
    self.protocol_fee_share_bps
}

// === Private Functions ===

/// Starts with no X signer and zero protocol fee share.
fun new(ctx: &mut TxContext): RuntimeConfig {
    RuntimeConfig {
        id: object::new(ctx),
        x_claim_signer_public_key: vector[],
        protocol_fee_share_bps: bps::new(0),
    }
}

fun validate_x_claim_public_key(signer_public_key: &vector<u8>) {
    assert!(
        signer_public_key.length() == constants::ed25519_public_key_length!(),
        blast_fun::errors::invalid_x_claim_public_key!(),
    );
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Creates disabled unshared runtime state for focused tests.
public fun new_disabled_for_testing(ctx: &mut TxContext): RuntimeConfig {
    new(ctx)
}

#[test_only]
/// Creates active unshared runtime state for focused signature tests.
public fun new_for_testing(
    signer_public_key: vector<u8>,
    ctx: &mut TxContext,
): RuntimeConfig {
    validate_x_claim_public_key(&signer_public_key);

    RuntimeConfig {
        id: object::new(ctx),
        x_claim_signer_public_key: signer_public_key,
        protocol_fee_share_bps: bps::new(0),
    }
}
