# 0050: Module-local package-version constant

- Status: accepted
- Date: 2026-08-29
- Amended in place: 2026-10-02 (ADR 0097) — the constant now lives in the marker
  module beside the version container it validates
- Amends: [0049](0049-audit-hardened-package-version-and-launch-intake.md)

## Context

The compiled operational generation was exposed from the package-wide constants
registry even though only `package_version.move` consumed it. An upgrade
operator therefore had to coordinate the cutover module with a separate source
file for a value that has no cross-module caller.

The generation remains package-wide protocol policy, but its only code-level
responsibility is to initialize and validate the one `PackageVersion` singleton.

## Decision

Declare private `const PACKAGE_VERSION: u64` beside the version container. Use it
for singleton initialization, the current-generation guard, and consecutive
activation. Remove the package-visible accessor from `constants.move`.
Since 2026-10-02 the container and the constant live in the package's marker
module (`blast_fun.move`, `blast_fun_migrators.move`, `blast_sui_package.move`,
`blast_boosts_aftermath.move`), because only that module's initializer holds the
one-time witness the shared generation constructor requires.

This is the sole exception to the shared constants-registry rule. It does not
change the onchain `PackageVersion` layout, activation sequence, error behavior,
or requirement that every mutable shared-object operation check the live
singleton at its own use site.

## Alternatives considered

**Keep the package-visible accessor.** Rejected because it separates the value
from all of its consumers and advertises an unused cross-module interface.

**Duplicate the value in release tooling.** Rejected because the Move module
must remain the execution authority; tooling may verify but must not define the
generation.

## Consequences

- An upgrade changes the compiled generation beside every place that enforces it.
- The constants registry contains only values with cross-module consumers.
- The version gate and upgrade safety model remain unchanged.

## Verification

- Source checks require the private constant in `package_version.move` and
  reject another package-version constant in `constants.move`.
- Initialization, current-version rejection, consecutive activation, overflow,
  build, lint, tests, and coverage continue to pass.
