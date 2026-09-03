// `errors` intentionally centralizes package-wide abort codes through zero-cost macros.
// W04005 sees the expanded literal; this suppression preserves stable codes and local checks.
#[allow(lint(abort_without_constant))]
/// Owns the one shared operational cutover used by every mutable Series1 object.
module blast_leverage_series_one::package_version;

use blast_leverage_series_one::events;

// === Constants ===

/// Current Series1 package generation accepted by the shared cutover.
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

/// Rejects callable bytecode from every generation except the active one.
public(package) fun assert_current(self: &PackageVersion) {
    assert!(
        self.version == PACKAGE_VERSION,
        blast_leverage_series_one::errors::package_version_mismatch!(),
    );
}

/// Activates this bytecode only when it is exactly one generation after shared state.
public(package) fun activate(self: &mut PackageVersion) {
    let previous_version = self.version;
    let new_version = previous_version
        .checked_add(1)
        .destroy_or!(abort blast_leverage_series_one::errors::package_version_overflow!());

    assert!(
        new_version == PACKAGE_VERSION,
        blast_leverage_series_one::errors::package_version_mismatch!(),
    );

    self.version = new_version;
    events::package_version_advanced(previous_version, new_version);
}

// === Private Functions ===

fun new(ctx: &mut TxContext): PackageVersion {
    PackageVersion {
        id: object::new(ctx),
        version: PACKAGE_VERSION,
    }
}

// === Test-Only Functions ===

#[test_only]
/// Runs package-version initialization under `test_scenario`.
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
/// Creates unshared current package-version state for focused tests.
public fun new_for_testing(ctx: &mut TxContext): PackageVersion {
    new(ctx)
}

#[test_only]
/// Forces a package version for guard and activation tests.
public fun set_for_testing(self: &mut PackageVersion, version: u64) {
    self.version = version;
}

#[test_only]
/// Returns the stored package version for transition assertions.
public fun version_for_testing(self: &PackageVersion): u64 {
    self.version
}
