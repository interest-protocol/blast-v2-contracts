# Sui package upgrade security

Apply these rules when publication, upgrades, package-capability custody,
operational versioning, shared-state migration, or dependency relinking is in
scope. Also apply them when old and new package versions can both reach shared
protocol state changed by the task.

## Treat package versions as concurrent APIs

- Model an upgrade as publication of a new immutable package version, not
  in-place mutation. Old package versions remain callable, and module
  initializers do not rerun.
- Preserve every existing public function signature except for permitted
  relaxation of generic ability constraints. Preserve every existing struct
  and enum layout and ability set.
- Treat old and new versions as simultaneously callable adversarial APIs over
  every shared object and original type both can reach. Updating an SDK,
  frontend, dependency, or current package ID does not retire old bytecode.
- For every changed public or entry function body that reads or mutates shared
  protocol state, model old-to-new, new-to-old, and repeated alternating calls.
  Decide whether the operational package version must advance.
  Prove that alternation cannot:
  - bypass a new guard;
  - double-accrue or double-claim rewards or fees;
  - reuse a stale witness or snapshot;
  - restore retired state;
  - create state that either version misinterprets.
- Do not require an operational cutover for a pure, read-only, or caller-owned
  inert path unless a concrete invariant crosses versions.
- If an old mutator lacks a version check, a check added only to new bytecode
  cannot disable it. Advance a pre-existing state seam observed by every old
  mutator, or migrate to a new gated state type or package lineage and retire
  the old mutation surface. Otherwise report the risk as unresolved.

## Preserve state and cut over deliberately

- When stored shape must change, introduce a new type and an authorized
  migration, or use a dynamic-extension seam designed before publication.
  Never assume upgraded code can add a field to an existing object.
- For an upgradeable package with operational activation, gate every mutation
  of shared protocol state at its own use site with an explicit package version
  before other guards. A witness minted before cutover must not unlock an old
  mutator.
- Keep native upgrade commit separate from operational activation. Activate
  only the expected next compiled generation so a wrong build leaves the
  previous generation able to authorize repair.
- Do not version-gate a self-custodial exit or deletion of a caller-owned inert
  object when it mutates no shared state.
- Do not add speculative governance cutovers, disable paths, or
  replacement-authority hooks.

## Secure package capabilities

- Validate that `Publisher` and `UpgradeCap` belong to the original package
  before custody.
- Validate exact upgrade digests and matching framework receipts.
- Check the proposed diff against the active `UpgradeCap` policy:
  - `compatible` may change implementations and non-public signatures, relax
    generic ability constraints, add declarations, and change dependencies
    while preserving link and layout compatibility;
  - `additive` may only add declarations and change dependencies;
  - `dep_only` may only change dependencies.
- Permit policy changes only toward more restrictive settings. The framework
  exposes no loosening operation, so stop at the strictest policy that
  preserves any required rescue path.
- For a wrapped cap, expose ticket authorization only through the package's
  accepted upgrade authority, such as live revocable administration, a
  multisig, a timelocked controller, onchain governance, or another explicit
  policy.
- Validate that authority at the function that mutably borrows the cap. Never
  expose the cap, a generic mutable borrow or release, or an ungated
  ticket-authorization seam.
- Keep controlled cap custody and shared-state version gates; neither replaces
  the other. Treat a cap irreversibly wrapped behind no reachable release,
  mutable-borrow, or ticket-authorization path as unusable upgrade authority
  and analyze the package under the intentionally immutable posture instead.

## Preserve dependency liveness

- A dependent package stays linked to the dependency generation it was
  published or upgraded against.
- Before activation or destroying a dependent package's `UpgradeCap`, prove
  every dependent route survives or schedule an explicit dependency relink.
  Never make a dependent immutable while it calls a seam the cutover closes.
