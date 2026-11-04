// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Jose Manuel Vasconcelos Cerqueira

// `blast_sui::errors` centralizes package abort codes through zero-cost macros. This narrow
// suppression preserves caller-local abort locations and stable package error codes.
#[allow(lint(abort_without_constant))]
/// Canonical publication custody, deposit pause flags and the shared cutover that prevents
/// stale package generations from mutating protocol state.
///
/// The generation value, its checked arithmetic, and its replay event belong to
/// `blast_admin::operational_version`. The one-time witness seeds the generation and claims
/// the Publisher; both stay in an owned `Publication` until `package_admin::wrap` seals the
/// native capabilities and shares the usable `PackageVersion`, so no vault can exist before
/// custody is sealed. Pause flags stop deposits only: redemptions, receipt cancellation,
/// donations and sync never read them.
module blast_sui::blast_sui_package;

// === Constants ===

/// Current package generation accepted by every protected mutation.
const PACKAGE_VERSION: u64 = 1;

/// The generation this bytecode hands over to in a governed upgrade, always the next one.
const NEXT_PACKAGE_VERSION: u64 = PACKAGE_VERSION + 1;

// === Public Types ===

/// One-time witness: it seeds the package generation and claims this package's Publisher.
public struct BLAST_SUI_PACKAGE() has drop;

/// Publication-only custody; it cannot supply the PackageVersion every vault operation needs.
public struct Publication has key {
    id: UID,
    publisher: Publisher,
    generation: OperationalVersion<BLAST_SUI_PACKAGE>,
}

/// Singleton operational package generation and deposit pause flags.
public struct PackageVersion has key {
    id: UID,
    paused: u8,
    generation: OperationalVersion<BLAST_SUI_PACKAGE>,
}

// === Private Initialization ===

fun init(otw: BLAST_SUI_PACKAGE, ctx: &mut TxContext) {
    let generation = operational_version::new(&otw);
    let publisher = sui::package::claim(otw, ctx);

    transfer::transfer(Publication { id: object::new(ctx), publisher, generation }, ctx.sender());
}

// === Public Functions ===

/// Stops the selected deposit paths immediately; does not authorize unpausing.
public fun pause(self: &mut PackageVersion, _: &AdminWitness<PauseAdmin>, bits: u8) {
    self.assert_current();

    assert!(
        bits != 0 && (bits & constants::valid_pause_bits!()) == bits,
        blast_sui::errors::invalid_pause_bits!(),
    );
    assert!((self.paused | bits) != self.paused, blast_sui::errors::pause_unchanged!());
    self.paused = self.paused | bits;

    events::paused(bits, self.paused);
}

// === Package Functions ===

/// Clears only the requested bits once `package_admin::unpause` has checked every notice.
public(package) fun clear_pause_bits(self: &mut PackageVersion, bits: u8) {
    assert!(
        bits != 0 && (bits & constants::valid_pause_bits!()) == bits,
        blast_sui::errors::invalid_pause_bits!(),
    );
    assert!((self.paused & bits) != 0, blast_sui::errors::pause_unchanged!());
    self.paused = self.paused ^ (self.paused & bits);

    events::unpaused(bits, self.paused);
}

/// Rejects a paused deposit path before its economic checks.
public(package) fun assert_not_paused(self: &PackageVersion, bit: u8) {
    assert!((self.paused & bit) == 0, blast_sui::errors::paused!());
}

/// Consumes the unique publication for package-admin custody intake.
public(package) fun destroy(
    self: Publication,
): (Publisher, OperationalVersion<BLAST_SUI_PACKAGE>) {
    let Publication { id, publisher, generation } = self;
    id.delete();

    (publisher, generation)
}

/// Shares the usable generation, every deposit paused, in the transaction that seals custody.
public(package) fun share_version(
    generation: OperationalVersion<BLAST_SUI_PACKAGE>,
    ctx: &mut TxContext,
) {
    transfer::share_object(PackageVersion {
        id: object::new(ctx),
        paused: constants::valid_pause_bits!(),
        generation,
    });
}

/// Rejects callable bytecode from every package generation except the active one.
public(package) fun assert_current(self: &PackageVersion) {
    self.generation.assert_current(PACKAGE_VERSION);
}

/// Proves the cutover target is exactly next before any upgrade finalizer effect.
public(package) fun assert_next(self: &PackageVersion) {
    self.generation.assert_next(NEXT_PACKAGE_VERSION);
}

/// Advances the shared generation to the exact bytecode this upgrade installs.
public(package) fun advance(self: &mut PackageVersion) {
    self.generation.advance(&self.id, NEXT_PACKAGE_VERSION);
}

// === Test-Only Functions ===

#[test_only]
/// Runs package initialization with a genuine test one-time witness.
public fun init_for_testing(ctx: &mut TxContext) {
    init(sui::test_utils::create_one_time_witness<BLAST_SUI_PACKAGE>(), ctx);
}

#[test_only]
/// Creates unshared, unpaused current package-version state for focused tests.
public fun new_for_testing(ctx: &mut TxContext): PackageVersion {
    let otw = BLAST_SUI_PACKAGE();

    PackageVersion { id: object::new(ctx), paused: 0, generation: operational_version::new(&otw) }
}

#[test_only]
/// Creates an owned publication proof without running package initialization.
public fun publication_for_testing(ctx: &mut TxContext): Publication {
    let otw = BLAST_SUI_PACKAGE();
    let generation = operational_version::new(&otw);

    Publication { id: object::new(ctx), publisher: sui::package::test_claim(otw, ctx), generation }
}

#[test_only]
/// Inspects the canonical Publisher retained by initialization without releasing it.
public fun publisher_for_publication_testing(self: &Publication): &Publisher {
    &self.publisher
}

#[test_only]
/// Forces a package generation for guard and cutover tests.
public fun set_for_testing(self: &mut PackageVersion, version: u64) {
    self.generation.set_generation_for_testing(version);
}

#[test_only]
/// Returns the stored package generation for transition assertions.
public fun version_for_testing(self: &PackageVersion): u64 {
    self.generation.generation_for_testing()
}

#[test_only]
/// Returns the stored pause flags.
public fun paused_for_testing(self: &PackageVersion): u8 {
    self.paused
}

#[test_only]
/// Exercises the compiled cutover target without a native upgrade fixture.
public fun advance_for_testing(self: &mut PackageVersion) {
    self.advance();
}

#[test_only]
/// Exercises the finalizer's pre-commit proof without a native upgrade fixture.
public fun assert_next_for_testing(self: &PackageVersion) {
    self.assert_next();
}

#[test_only]
/// Claims an additional canonical-module Publisher for package-administration fixtures.
public fun publisher_for_testing(ctx: &mut TxContext): Publisher {
    sui::package::test_claim(BLAST_SUI_PACKAGE(), ctx)
}

// === Imports ===

use blast_admin::{blast_acl::AdminWitness, operational_version::{Self, OperationalVersion}};

use blast_sui::{blast_sui_domain::PauseAdmin, constants, events};

use sui::package::Publisher;
