# 0034: Remove the premature governance cutover

- Status: accepted
- Date: 2026-08-25
- Amends: [0032](0032-admin-authorized-upgrade-cap-custody.md)

## Sources

This record cites no new external ABI facts. The framework upgrade semantics it
relies on — old bytecode remains callable, an upgrade adds modules to the same
package, and shared-object version gates are the release mechanism for retiring
old entrypoints — were established with citations in
[0007](0007-acl-pause-and-versioning.md) and
[0032](0032-admin-authorized-upgrade-cap-custody.md).

## Context

ADR 0032 shipped `PackageAdmin` with a durable `admin_authorization_enabled`
flag, a guard on the three admin-authorized functions, a package-only
`disable_admin_authorization` cutover, the `PackageAdminAuthorizationDisabled`
event, and error codes 55 and 58. The cutover existed only for a governance
module that does not exist: Blast has no accepted committee, DAO, delay, or
recovery design, and ADR 0032 itself deferred governance to its own future ADR.

That makes the cutover a speculative affordance with no production caller. It
violates two standing rules:

- a function is promoted to `public(package)` only for a concrete production
  caller in another module — the only callers of `disable_admin_authorization`
  were its own tests; and
- the smallest public ABI and fewest privileged operations that meet the
  approved product scope — the flag added storage, three guards, one event
  type, and two error codes to defend a transition nobody can perform.

The flag is also redundant as a mechanism. ADR 0007 already requires every
mutable shared protocol object, `PackageAdmin` included, to carry a
version/package gate before public release, and ADR 0032 records that wrapped
capability custody never replaces those gates. A future governance upgrade that
installs replacement authority retires the original routine-admin entrypoints
by advancing the shared object's version gate; old bytecode then aborts through
the gate, exactly as it must for every other privileged path. A second,
concern-specific kill flag duplicates that mechanism with a different error
code and its own replay surface.

## Decision

Remove the governance cutover from `package_admin` before any deployment
exists:

- `PackageAdmin` stores only `id`, the validated `Publisher`, and the wrapped
  `UpgradeCap`.
- `authorize_upgrade`, `restrict_to_additive`, and
  `restrict_to_dependency_only` keep their `AdminWitness`, digest, and
  policy-narrowing guards but drop the enabled-flag check. `commit_upgrade` is
  unchanged.
- `disable_admin_authorization`, the `PackageAdminAuthorizationDisabled`
  event, and the `admin_authorization_enabled` field of `PackageAdminCreated`
  are deleted. The module exposes no `public(package)` function.
- Error codes 55 and 58 are retired in the append-only registry and must not
  be reused.

An active routine admin therefore remains full code authority under the
wrapped cap's current policy until an approved governance ADR lands. That ADR
must design its own replacement authorization path and retire the routine-admin
entrypoints through the mandatory shared-object version gate, not through a
pre-planted flag. Nothing removed here is storage-compatible debt: no network
has a deployed `PackageAdmin`, so the struct, event schema, and error map
change before they become release commitments.

## Alternatives considered

**Keep the flag and cutover as shipped.** Rejected: it is unreachable
production code guarding a transition that has no design, and it grants the
false comfort that governance work is already partially done. The rules gate
merging functions whose only path is a test.

**Keep the flag but delete only the cutover function.** Rejected: a flag that
can never become `false` turns the three guards into dead branches and the
event field into a constant, which is worse than either shipped or removed.

**Reserve the storage now because upgrades cannot add struct fields later.**
Rejected: the future governance module does not need this field. It gates the
shared object by version (already mandatory pre-release) or attaches its own
state; a `bool` planted years early is not a usable governance design.

## Consequences

- `package_admin` shrinks to validated intake, admin-authorized exact-digest
  upgrades, irreversible policy narrowing, and receipt commit — every function
  has a production caller or is the public deployment entrypoint.
- The routine-admin path has no self-retirement affordance. Retirement arrives
  with the governance ADR that can actually replace it, via version gates.
- Error codes 55 and 58 join the retired list; the next new code is still 61.
- Indexers replay one fewer event type, and `PackageAdminCreated` loses a
  field that could never change after creation.

## Verification

- Structural checks require the two-capability `PackageAdmin` layout, forbid
  any `public(package)` function in the module, and reject reintroduction of
  `admin_authorization` state or the disabled event.
- The error-registry tests pin codes 53, 54, 56, and 57 and no longer
  reference 55 or 58.
- Positive and negative package-administration tests (provenance, digest
  length, revoked admin, policy narrowing order, foreign receipt) pass
  unchanged without the cutover suite.
- Build, warnings-as-errors lint, and the full Move suite pass against the
  pinned toolchain.
