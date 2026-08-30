// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// Shared cutover that prevents stale package generations from mutating protocol state.
module blast_sui::package_version;

use blast_sui::events;

// === Constants ===

const PACKAGE_VERSION: u64 = 1;

// === Public Structs ===

/// Singleton operational package generation.
public struct PackageVersion has key {
    id: UID,
    version: u64,
}

// === Private Initialization ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(new(ctx));
}

// === Package Functions ===

/// Rejects bytecode whose generation does not match shared state.
public(package) fun assert_current(self: &PackageVersion) {
    assert!(
        self.version == PACKAGE_VERSION,
        blast_sui::errors::package_version_mismatch!(),
    );
}

/// Activates bytecode exactly one generation after shared state.
public(package) fun activate(self: &mut PackageVersion): (u64, u64) {
    let previous_version = self.version;
    let new_version = previous_version
        .checked_add(1)
        .destroy_or!(abort blast_sui::errors::package_version_overflow!());

    assert!(
        new_version == PACKAGE_VERSION,
        blast_sui::errors::package_version_mismatch!(),
    );

    self.version = new_version;

    events::package_version_advanced(previous_version, new_version);
    (previous_version, new_version)
}

// === Private Functions ===

fun new(ctx: &mut TxContext): PackageVersion {
    PackageVersion { id: object::new(ctx), version: PACKAGE_VERSION }
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): PackageVersion {
    new(ctx)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun set_for_testing(self: &mut PackageVersion, version: u64) {
    self.version = version;
}

#[test_only]
public fun value_for_testing(self: &PackageVersion): u64 {
    self.version
}

