/// One operational cutover and emergency pause for all holder rewards.
///
/// The generation value and its arithmetic belong to `blast_admin`; this module
/// owns the container, the two compiled constants, and the pause policy that
/// sits beside them. Every economic transition checks the generation first and
/// the pause second, so stale code never reports a pause error.
module blast_fun_distributor::package_version;

use blast_admin::{acl::AdminWitness, operational_version::{Self, OperationalVersion}};
use blast_fun::launchpad_domain::LAUNCHPAD_DOMAIN;
use blast_fun_distributor::package_marker::PACKAGE_MARKER;
use sui::event;

// === Constants ===

const PACKAGE_VERSION: u64 = 1;
const NEXT_PACKAGE_VERSION: u64 = 2;

// === Errors ===

#[error(code = 1)]
const EPaused: vector<u8> = b"Holder rewards are paused.";
#[error(code = 2)]
const EUnchangedPause: vector<u8> = b"Pause status must change.";

// Code 0 retired: generation comparison moved to blast_admin::operational_version.
// Code 3 retired: generation arithmetic moved to blast_admin::operational_version.

// === Public Types ===

/// Created only at publication; callers cannot substitute an older control object.
public struct PackageVersion has key {
    id: UID,
    generation: OperationalVersion<PACKAGE_MARKER>,
    paused: bool,
}

/// Records an administrator's emergency stop or resumption.
public struct PauseChanged has copy, drop {
    paused: bool,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Public Functions ===

/// Launchpad-domain admins can stop or resume enrollment, collection,
/// publication and claims. Generic membership is enough; no role is required.
public fun set_paused(
    self: &mut PackageVersion,
    _: &AdminWitness<LAUNCHPAD_DOMAIN>,
    paused: bool,
) {
    self.assert_current();
    assert!(self.paused != paused, EUnchangedPause);

    self.paused = paused;

    event::emit(PauseChanged { paused });
}

// === Package Functions ===

/// Checked at each economic transition, including claims against older rounds.
public(package) fun assert_enabled(self: &PackageVersion) {
    self.assert_current();
    assert!(!self.paused, EPaused);
}

/// Package custody checks the generation without consulting the pause: an
/// upgrade must remain possible precisely while rewards are stopped.
public(package) fun assert_current_for_upgrade(self: &PackageVersion) {
    self.assert_current();
}

/// Proves the cutover target is exactly next before any upgrade finalizer effect.
public(package) fun assert_next(self: &PackageVersion) {
    self.generation.assert_next(NEXT_PACKAGE_VERSION);
}

/// Advances the generation while leaving the pause value untouched.
public(package) fun advance(self: &mut PackageVersion) {
    let container_id = self.id.to_inner();

    self.generation.advance(container_id, NEXT_PACKAGE_VERSION);
}

// === Private Functions ===

fun assert_current(self: &PackageVersion) {
    self.generation.assert_current(PACKAGE_VERSION);
}

fun new(ctx: &mut TxContext): PackageVersion {
    PackageVersion {
        id: object::new(ctx),
        generation: operational_version::new(),
        paused: false,
    }
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): PackageVersion { new(ctx) }

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }

#[test_only]
public fun set_version_for_testing(self: &mut PackageVersion, version: u64) {
    self.generation.set_generation_for_testing(version);
}

#[test_only]
public fun version_for_testing(self: &PackageVersion): u64 {
    self.generation.generation_for_testing()
}

#[test_only]
public fun paused_for_testing(self: &PackageVersion): bool { self.paused }

#[test_only]
/// Exercises the compiled cutover target without a native upgrade fixture.
public fun advance_for_testing(self: &mut PackageVersion) { self.advance(); }
