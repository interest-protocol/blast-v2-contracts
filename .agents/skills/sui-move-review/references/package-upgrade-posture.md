# Package Upgrade Posture

Classify the package before reporting missing `Publisher` custody,
`UpgradeCap` custody, or operational versioning. Base the classification on
old-bytecode risk and accepted lifecycle, not code size. Apply the canonical
upgrade mechanics loaded by the security standard after choosing the posture.

## Gather evidence

- Determine whether the package is unpublished, published but never upgraded,
  or already upgraded.
- Locate the `UpgradeCap`; identify its owner or custodian, current package and
  policy, and every callable release, mutable-borrow, or ticket-authorizing path.
  Collect evidence for any immutability promise.
- Determine whether an initializer claimed a `Publisher`, which module's OTW it
  used, and which accepted feature needs provenance.
- Inventory shared mutable state, asset custody, authorities, configuration,
  and dependents that old and new bytecode can reach.
- Read deployment transactions, scripts, manifests, records, and tests. Source
  alone does not prove publish-time capability custody.

Treat `Publisher` and `UpgradeCap` as independent framework capabilities. A
`Publisher` proves package or module provenance; it does not authorize
upgrades. Publication creates an `UpgradeCap`; silence in Move source does not
make the package immutable.

## Choose one posture

### Intentionally immutable

Use this posture only when the accepted design requires exactly one generation
and no dependency upgrade or rescue code.

- Require release and dependent-route evidence before the cap becomes
  permanently unusable.
- For a wrapped cap, prove no current public or entry path can release or
  mutably borrow it, issue a ticket, or reach a helper that can.
- Do not require an operational version object when no later generation can be
  published.
- Retain a `Publisher` only for a concrete provenance-gated feature.
- Reject immutability claims while the cap remains address-owned or usable by a
  current callable path.

### Simple upgradeable

Use this posture when upgrades remain possible but concurrent generations
cannot violate shared-state, custody, authority, replay, exit, event, or
dependency invariants.

- Review cap custody and policy in proportion to compromise scope and required
  recovery.
- Do not require shared package administration, an operational version
  singleton, or a `Publisher` merely because an `UpgradeCap` exists.
- Reclassify when an upgrade can change behavior reached by shared state or a
  dependent protocol.

### Evolving shared-state upgradeable

Use this posture when old and current bytecode can mutate shared state, custody
assets, exercise authority, change configuration, or break replay after a
security cutover.

- Before publication, require explicit capability custody and an operational
  cutover design when old entry points could bypass a future fix.
- Apply the security standard's complete upgrade mechanics and tests.
- Adapt authority and policy choices to accepted protocol design; do not copy
  product-specific types or constants.

## Report proportionately

Report a finding only when the chosen posture contradicts accepted intent or
creates a concrete safety, custody, liveness, compatibility, or public-claim
failure. Otherwise report a missing roadmap, custody record, `Publisher` use,
or immutability proof as a question or validation gap. Do not equate
architectural completeness with maximum machinery.

Classification is complete only when exactly one posture fits the accepted
lifecycle and old-bytecode risk, with capability custody and operational claims
supported by deployment evidence or reported as gaps.
