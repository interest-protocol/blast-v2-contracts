# Define–Export–Ignore

Use this anti-pattern when core domain logic is presented as part of one module
or package even though none of that provider's production transitions use it
and another package is its only real consumer.

## Ownership problem

The provider gains an irrelevant public surface and release obligation. The
consuming transition gains a dependency on a package that does not own the
state, units, rounding policy, lifecycle, or invariant that gives the logic
meaning.

Absence of local callers is a review signal, not proof. Keep the operation with
the provider when it:

- interprets provider-owned private state or types;
- defines a canonical rule shared by several independent consumers;
- belongs to a deliberate lower-level domain library with stable dependency
  direction.

## Safe correction

1. Trace every production caller across package boundaries. Ignore tests,
   examples, and forwarding wrappers when identifying the transition that
   actually needs the result.
2. Name the state, units, rounding direction, abort behavior, and invariant the
   logic governs.
3. Put the implementation and its tests with the module that owns that concern.
   If one downstream package is the sole consumer and the provider contributes
   no private representation or canonical policy, keep the operation private or
   package-visible there.
4. If several independent packages need the same stable operation, introduce a
   lower-level domain library. Do not turn one caller's helper into a generic
   utility package.
5. Move constants, error ownership, documentation, and boundary or rounding
   tests with the logic. Leave one authoritative production implementation.

## Publication boundary

Before publication, remove the misplaced surface completely. After publication,
old callable bytecode and compatibility commitments may force the original
function to remain. Put new ownership in the correct package, migrate current
callers, and identify the old surface as legacy; source removal does not retire
the published version.

Keep dependency direction intentional. A foundational provider may expose
primitive facts, but should not absorb a downstream lifecycle policy merely to
make that policy reusable.

## Verification obligations

- Confirm every production caller and the transition that owns the invariant.
- Check the resulting package graph for cycles, upward dependencies, and a new
  generic dumping ground.
- Preserve exact arithmetic, units, rounding, aborts, and boundary behavior.
- Build and test every affected package, and confirm current callers use one
  implementation.
- For published packages, verify old-version behavior, ABI compatibility, and
  any required operational cutover.

The central principle is: place domain logic with the transition and invariant
that give it meaning; export it elsewhere only for a deliberate shared-domain
boundary.
