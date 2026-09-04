// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Aftermath adapter version state.
module blast_leverage_aftermath::protocol;

use blast_leverage_aftermath::events;
use blast_leverage_series_one::acl::{
    Self,
    AdminWitness,
};

// === Constants ===

/// Current adapter generation accepted by shared protocol state.
const PACKAGE_VERSION: u64 = 1;

// === Public Structs ===

/// Shared version state for the Aftermath adapter package.
public struct Protocol has key {
    id: UID,
    version: u64,
}

// === Public Functions ===

/// Activates this adapter bytecode after an exact next-generation upgrade.
public fun activate_package_version(
    self: &mut Protocol,
    admin_witness: &AdminWitness,
) {
    admin_witness.assert_package_admin();

    let previous_version = self.version;
    let new_version = previous_version
        .checked_add(1)
        .destroy_or!(abort blast_leverage_aftermath::errors::package_version_overflow!());

    assert!(
        new_version == PACKAGE_VERSION,
        blast_leverage_aftermath::errors::package_version_mismatch!(),
    );

    self.version = new_version;
    events::package_version_advanced(previous_version, new_version);
}

// === Package Functions ===

/// Creates unshared Aftermath adapter version state.
public(package) fun new(ctx: &mut TxContext): Protocol {
    Protocol { id: object::new(ctx), version: PACKAGE_VERSION }
}

/// Shares the adapter protocol object.
public(package) fun share(self: Protocol) {
    transfer::share_object(self);
}

/// Rejects bytecode that is not the active adapter generation.
public(package) fun assert_current(self: &Protocol) {
    assert!(
        self.version == PACKAGE_VERSION,
        blast_leverage_aftermath::errors::package_version_mismatch!(),
    );
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): Protocol {
    new(ctx)
}

#[test_only]
public fun id_for_testing(self: &Protocol): ID {
    self.id.to_inner()
}

#[test_only]
public fun version_for_testing(self: &Protocol): u64 {
    self.version
}

#[test_only]
public fun set_version_for_testing(self: &mut Protocol, version: u64) {
    self.version = version;
}
