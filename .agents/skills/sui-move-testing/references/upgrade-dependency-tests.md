# Upgrade and Dependency Tests

Apply these rules when publication, package upgrades, state migration,
operational activation, dependency relinking, external ABI validation, or
adapter fingerprinting is in scope.

- Test correct and incorrect `Publisher`, `UpgradeCap`, package, digest,
  receipt, and policy transitions.
- Prove module initializers do not rerun on upgrade. When operational activation
  exists, test old-version rejection and explicit migration or activation
  authority.
- Run compatibility checks that reject incompatible changes to existing public
  function signatures, struct or enum layouts, or abilities while accepting
  permitted generic-constraint relaxation.
- Test the active `UpgradeCap` policy and an authorized new-type migration when
  stored shape must change.
- For every version-gated cross-package seam, test that a dependent linked to
  the previous generation is rejected after activation and that the accepted
  relink or retirement path remains live.
- Verify an adapter against deployed external ABI, not only local link stubs.
- Fail closed on missing, null, duplicate, unknown, or added ABI fields that
  change consumed semantics. Review harmless additive fields before updating a
  fingerprint.
- Detect mutable dependency selectors, wrong repositories, wrong
  subdirectories, edge rebinding, and lockfile drift.
- Review a new external revision before updating a committed fingerprint.

Coverage is complete only when compatible and incompatible upgrades, old and
new callable generations, capability and policy transitions, migrations,
dependency relinking, and deployed ABI drift each have passing evidence or a
reported environment gap.
