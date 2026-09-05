/// One operational cutover and emergency pause for all holder rewards.
module blast_fun_distributor::package_version;

use blast_fun::acl::AdminWitness;
use sui::event;

// === Constants ===

const PACKAGE_VERSION: u64 = 1;

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Rewards package generation must match the active version.";
#[error(code = 1)]
const EPaused: vector<u8> = b"Holder rewards are paused.";
#[error(code = 2)]
const EUnchangedPause: vector<u8> = b"Pause status must change.";
#[error(code = 3)]
const EVersionOverflow: vector<u8> = b"Rewards package generation cannot overflow.";

// === Public Types ===

/// Created only at publication; callers cannot substitute an older control object.
public struct PackageVersion has key {
    id: UID,
    version: u64,
    paused: bool,
}

/// Records the active generation; activation does not unpause rewards.
public struct VersionActivated has copy, drop {
    previous_version: u64,
    version: u64,
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

/// Launchpad admins can stop or resume enrollment, collection, publication and claims.
public fun set_paused(self: &mut PackageVersion, _: &AdminWitness, paused: bool) {
    self.assert_current();
    assert!(self.paused != paused, EUnchangedPause);

    self.paused = paused;

    event::emit(PauseChanged { paused });
}

/// After a compatible upgrade, activates exactly the next compiled generation.
/// This remains callable while paused; neither callers nor old code choose a version.
public fun activate(self: &mut PackageVersion, _: &AdminWitness) {
    let previous_version = self.version;
    let version = previous_version.checked_add(1).destroy_or!(abort EVersionOverflow);
    assert!(version == PACKAGE_VERSION, EWrongVersion);

    self.version = version;

    event::emit(VersionActivated { previous_version, version });
}

// === Package Functions ===

/// Checked at each economic transition, including claims against older rounds.
public(package) fun assert_enabled(self: &PackageVersion) {
    self.assert_current();
    assert!(!self.paused, EPaused);
}

// === Private Functions ===

fun assert_current(self: &PackageVersion) {
    assert!(self.version == PACKAGE_VERSION, EWrongVersion);
}

fun new(ctx: &mut TxContext): PackageVersion {
    PackageVersion { id: object::new(ctx), version: PACKAGE_VERSION, paused: false }
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): PackageVersion { new(ctx) }

#[test_only]
public fun set_version_for_testing(self: &mut PackageVersion, version: u64) {
    self.version = version;
}

#[test_only]
public fun paused_for_testing(self: &PackageVersion): bool { self.paused }
