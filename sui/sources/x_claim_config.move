// `blast_fun::errors` intentionally centralizes package-wide abort codes through zero-cost
// macros. W04005 sees the expanded literal; this narrow suppression preserves caller-local abort
// locations and the stable code map documented in `docs/error-codes.md`.
#[allow(lint(abort_without_constant))]
module blast_fun::x_claim_config;

use blast_fun::{acl::AdminWitness, constants, events};

// === Public Structs ===

/// Shared singleton verification state for backend-attested X creator claims.
public struct XClaimConfig has key {
    id: UID,
    signer_public_key: vector<u8>,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    let config = new(ctx);
    let config_id = config.id.to_inner();

    transfer::share_object(config);

    events::x_claim_config_created(config_id);
}

// === Public Functions ===

/// Sets the current X claim signer, replacing any previously configured key.
public fun set_signer(
    config: &mut XClaimConfig,
    _: &AdminWitness,
    signer_public_key: vector<u8>,
) {
    validate_public_key(&signer_public_key);
    assert!(
        config.signer_public_key != signer_public_key,
        blast_fun::errors::x_claim_signer_unchanged!(),
    );

    let previous_public_key = config.signer_public_key;
    config.signer_public_key = signer_public_key;

    events::x_claim_signer_set(
        config.id.to_inner(),
        previous_public_key,
        config.signer_public_key,
    );
}

/// Revokes the X claim signer immediately by clearing the only active key.
public fun revoke_signer(
    config: &mut XClaimConfig,
    _: &AdminWitness,
) {
    config.assert_active();

    let previous_public_key = config.signer_public_key;
    config.signer_public_key = vector[];

    events::x_claim_signer_revoked(config.id.to_inner(), previous_public_key);
}

// === Package Functions ===

/// Rejects use of the X claim path while no backend signer is authorized.
public(package) fun assert_active(config: &XClaimConfig) {
    assert!(
        !config.signer_public_key.is_empty(),
        blast_fun::errors::x_claim_signer_inactive!(),
    );
}

/// Verifies that `signature` came from the one currently authorized Blast backend key.
public(package) fun verify_signature(
    config: &XClaimConfig,
    message: &vector<u8>,
    signature: &vector<u8>,
) {
    config.assert_active();

    assert!(
        sui::ed25519::ed25519_verify(signature, &config.signer_public_key, message),
        blast_fun::errors::invalid_x_claim_signature!(),
    );
}

// === Private Functions ===

fun new(ctx: &mut TxContext): XClaimConfig {
    XClaimConfig { id: object::new(ctx), signer_public_key: vector[] }
}

fun validate_public_key(signer_public_key: &vector<u8>) {
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
/// Creates disabled unshared X verification state and emits its creation fact.
public fun new_disabled_for_testing(ctx: &mut TxContext): XClaimConfig {
    let config = new(ctx);

    events::x_claim_config_created(config.id.to_inner());

    config
}

#[test_only]
/// Creates active unshared X verification state for focused signature tests.
public fun new_for_testing(
    signer_public_key: vector<u8>,
    ctx: &mut TxContext,
): XClaimConfig {
    validate_public_key(&signer_public_key);

    XClaimConfig { id: object::new(ctx), signer_public_key }
}

#[test_only]
/// Deletes X claim verification state after a test.
public fun destroy_for_testing(config: XClaimConfig) {
    let XClaimConfig { id, signer_public_key: _ } = config;
    id.delete();
}
