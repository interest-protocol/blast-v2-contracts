# Sui Package Upgrade Security

Apply these rules when publication, upgrades, package-capability custody,
operational versioning, shared-state migration, or dependency relinking is in
scope. Also apply them when old and new package versions can both reach shared
protocol state changed by the task.

## Choose only required machinery

- Treat a package as intentionally immutable only when the accepted design
  requires one generation and the `UpgradeCap` is provably unusable.
- Treat a package as simple upgradeable when upgrades cannot violate shared
  state, custody, authority, replay, exit, or dependency invariants. Do not add
  shared package administration or an operational version merely because a cap
  exists.
- Use the complete custody and operational-cutover method for evolving shared
  state whose old and new bytecode can affect the same invariant.
- Claim or retain a `Publisher` only for a concrete provenance-gated feature.
  A `Publisher` proves package identity; it does not authorize upgrades.
- Do not add speculative governance, cutover, rescue, or replacement seams.

## Treat package versions as concurrent APIs

- Model an upgrade as publication of a new immutable package version, not
  in-place mutation. Old versions remain callable and initializers do not rerun.
- Preserve every existing public function signature except permitted generic
  ability-constraint relaxation. Preserve every existing struct and enum layout
  and ability set.
- Treat old and new versions as adversarially concurrent over every shared
  object and original type both can reach. Updating an SDK, frontend,
  dependency, or current package ID does not retire old bytecode.
- For every changed public or entry body that reaches shared protocol state,
  model old-to-new, new-to-old, and repeated alternating calls. Prove they
  cannot bypass guards, double-accrue or claim, reuse stale proofs, restore
  retired state, or create state either version misinterprets.
- Do not require an operational cutover for a pure, read-only, or caller-owned
  inert path unless a concrete invariant crosses versions.
- If an old mutator lacks a usable gate, a check added only to new bytecode
  cannot disable it. Use a pre-existing seam observed by every old mutator, or
  migrate to new gated state or package lineage and retire the old surface.

## Decide provenance at publication

- Define one canonical package-marker module with an OTW and private initializer
  only when an accepted feature needs `Publisher` provenance or preserving the
  one-time option is an explicit requirement.
- Consume the OTW with the framework Publisher-claim operation during initial
  publication. Keep unrelated initializers context-only.
- Omit the marker and Publisher claim when no concrete provenance requirement
  exists.

## Take validated capability custody

- For evolving shared-state packages, define one package-administration object
  with `key` only, private fields, and no generic release or transfer path.
  Store the `UpgradeCap`; store a retained `Publisher` beside it only when no
  narrower concern owns that capability.
- In the publication PTB, call a public intake function with the raw cap and,
  when claimed, the `Publisher`; an initializer cannot receive the cap created
  by publication.
- Require a supplied `Publisher` to originate from the canonical claiming
  module and require the cap to belong to the original package ID of a canonical
  package type. Perform initial intake before a raw-cap upgrade changes the
  cap's current package ID.
- Record administration object and capability IDs, package ID, cap version,
  policy, and final custodian in normalized deployment evidence.
- Treat a cap irreversibly wrapped behind no reachable release, mutable borrow,
  or ticket-authorization path as unusable upgrade authority.

## Bind native upgrade authorization

- Expose ticket authorization only through the accepted live authority, such as
  revocable administration, a multisig, timelock, or on-chain governance.
- Validate authority in the function that mutably borrows the wrapped cap.
  Never expose the cap, a generic mutable borrow or release, or an ungated
  ticket seam.
- Accept the exact compiled digest, validate its shape, and pass the wrapped
  cap's current policy rather than a caller-selected policy.
- Let the native upgrade command consume the `UpgradeTicket` and return an
  `UpgradeReceipt` in the same PTB. Commit only that receipt into the same cap;
  do not add redundant authorization when the receipt already binds both.
- Check the proposed diff against the active policy: compatible preserves link
  and layout compatibility, additive only adds declarations or changes
  dependencies, and dependency-only only changes dependencies.
- Expose only named irreversible policy-narrowing transitions. Stop at the
  strictest policy that preserves required rescue and dependency-relink paths.

## Preserve state and cut over deliberately

- When stored shape changes, introduce a new type and authorized migration or
  use a dynamic-extension seam designed before publication.
- When one operational cutover governs evolving shared state, define one shared
  `PackageVersion { id, version }` and one private compiled generation constant.
- Before publication, make every shared-state mutator compare stored and
  compiled generations at its own use site before any other guard. A witness
  minted before cutover must not bypass this check.
- Keep native upgrade commit separate from operational activation. Activate
  only the expected next compiled generation so a wrong build leaves the prior
  generation able to authorize repair.
- In activation, compute `stored + 1`, reject overflow, require equality with
  the compiled generation, then update the singleton.
- Skip operational activation for additive or dependency-only upgrades that do
  not replace guarded bodies.
- Keep native cap version and operational package version as separate facts.

## Preserve exits and dependency liveness

- Do not version-gate caller-owned inert deletion or self-custodial exits that
  mutate no shared state.
- A dependent stays linked to the dependency generation against which it was
  published or upgraded.
- Before activation or destruction of a dependent's final `UpgradeCap`, prove
  every dependent route survives or schedule an explicit relink. Never make a
  dependent immutable while it calls a seam the cutover closes.
- Test every required exit, settlement, cleanup, retry, cancellation, rotation,
  and recovery path across the cutover.

## Handle already-published gaps

- Do not suggest rerunning `init`; a missing `Publisher` claim cannot be added
  later in the same lineage.
- Do not claim a new-bytecode version check disables an ungated old mutator.
- Permit later cap custody only when the cap remains available and intake can
  prove its current lineage. Do not reuse an original-package equality check
  after a raw upgrade changes the cap's current package ID.
- Report an unrepairable old-version path as residual risk. Do not present the
  pre-publication method as a retroactive fix.

## Completion gate

Upgrade security is complete only when every callable generation and shared
invariant is accounted for, capability custody is proven, compatibility and
cutover behavior are tested, and each unrepairable old-version path is reported.
