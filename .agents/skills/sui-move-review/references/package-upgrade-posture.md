# Package Upgrade Posture

Classify the package before reporting missing `Publisher` custody, `UpgradeCap` custody, or operational versioning. Base the classification on old-bytecode risk and accepted lifecycle, not code size alone.

## Gather evidence

- Determine whether the package is unpublished, published but never upgraded, or already upgraded.
- Locate the `UpgradeCap` whether raw or wrapped; identify its owner or custodian, current package and policy, and every callable path that can release it, mutably borrow it, or authorize an upgrade. Collect any promised immutability evidence.
- Determine whether an initializer claimed a `Publisher`, which module's one-time witness it used, and which accepted feature needs package provenance.
- Inventory shared mutable protocol state, asset custody, authorities, configuration, and cross-package dependents that old and new bytecode can reach.
- Read deployment transactions, scripts, manifests, records, and tests. Source code alone does not prove where publish-time capabilities went.

Treat `Publisher` and `UpgradeCap` as independent framework capabilities. A `Publisher` proves package/module provenance; it does not authorize upgrades. Publishing creates an `UpgradeCap`; failing to mention it in Move source does not make the package immutable.

## Choose one posture

### Intentionally immutable

Use this posture only when the accepted design requires exactly one package generation and no dependency upgrade or rescue code.

- Require release gates and dependent-route verification before making the `UpgradeCap` permanently unusable. Accept either framework destruction or irreversible wrapping only after recording durable evidence of the terminal custody state.
- For a wrapped cap, trace the complete current callable surface and prove that no public or entry path can release or mutably borrow the cap, issue an `UpgradeTicket`, or reach an internal helper that can do so. The package cannot upgrade itself to add such a path without first issuing a ticket from the already inaccessible cap.
- Do not require an operational package-version object or old-bytecode gate when no later package generation can be published in the lineage.
- Claim or retain a `Publisher` only for a concrete provenance-gated feature. Do not add a marker module, custody object, or version field only for uniformity.
- Reject claims such as permanently locked, immutable, or unchangeable while the cap remains address-owned or any current callable authorization, release, or mutable-borrow path can use it. In that case a compatible upgrade may add extraction logic; a provably inaccessible wrapped cap is different because it cannot authorize that upgrade.

### Simple upgradeable

Use this posture when upgrades remain possible but concurrent old and new generations cannot violate shared-state, custody, authority, replay, or exit invariants. Typical evidence includes pure libraries, stateless adapters, or caller-owned inert objects whose safe self-custodial exits do not mutate shared protocol state.

- Review raw-cap custody and policy in proportion to its compromise scope, public reliance, and required rescue path.
- Do not require a shared `PackageAdmin`, operational version singleton, or version parameter merely because an `UpgradeCap` exists.
- Do not require a `Publisher` without an accepted provenance-gated use. Record the irreversible loss of future Publisher-only features as a question or design consequence, not a security defect by itself.
- Reclassify the package when an upgrade can change behavior reached by shared state or a dependent protocol. Small source size does not make that risk simple.

### Evolving shared-state upgradeable

Use this posture when old and current bytecode can mutate shared protocol state, custody assets, exercise authority, change configuration, or break an event/replay promise after a security cutover.

- Before publication, require an explicit capability-custody and operational-cutover design. Treat a missing seam as a finding when old entry points could bypass a future fix.
- Apply the self-contained method below when its threat assumptions match the target. Adapt authority and policy choices to the accepted protocol design rather than copying product-specific types or constants.

## Stateful upgrade method

### 1. Decide package provenance at publication

- Define one canonical package-marker module with an OTW and private initializer only when an accepted feature needs `Publisher` provenance or preserving that one-time option is an explicit requirement.
- Consume the OTW with the framework Publisher-claim operation during initial publication. Keep unrelated initializers context-only.
- Omit the marker and Publisher claim when no concrete provenance requirement exists. A `Publisher` does not authorize upgrades.

### 2. Take validated capability custody

- Define one package-administration object with `key` only, private fields, and no generic release or transfer path. Store the `UpgradeCap`; when a retained `Publisher` has no narrower concern owner, store it beside the cap.
- In the publication PTB, call a public intake function with the raw `UpgradeCap` and, when claimed, the `Publisher`; an initializer cannot receive the cap produced by publication.
- Before custody, require a supplied Publisher to originate from the canonical claiming module and require the cap's package to equal the original package ID of a canonical package type. Perform this intake before any raw-cap upgrade changes the cap's current package ID.
- Share the administration object and record its ID, capability IDs, package ID, cap version, policy, and final custodian in normalized deployment evidence.

### 3. Bind native upgrade authorization

- Expose ticket authorization only through the target's accepted upgrade authority, such as live revocable administration, a multisig, a timelocked controller, onchain governance, or another explicitly approved policy. Validate that authority in the function that mutably borrows the wrapped cap and issues the ticket.
- Never expose the `UpgradeCap`, a generic mutable borrow or release, or an ungated ticket-authorization seam. Accept the exact compiled package digest, validate its shape, and pass the wrapped cap's current policy rather than a caller-selected policy.
- Let the native upgrade command consume the resulting `UpgradeTicket` and return an `UpgradeReceipt` in the same PTB.
- Commit only that receipt into the same wrapped cap. Do not require redundant authorization at commit when the non-droppable receipt already binds the cap and authorized upgrade.
- Expose only named irreversible policy-narrowing transitions. Stop at the strictest policy that preserves any required rescue and dependency-relink path.

### 4. Separate native commit from operational activation

- Define one shared `PackageVersion { id, version }` and one private compiled generation constant when one cutover governs the protocol.
- Before publication, make every shared-state mutator borrow the version object and compare stored and compiled generations before any other guard. Check at the mutation use site; an authorization witness minted earlier in the PTB must not bypass the cutover.
- Commit the native receipt without changing operational version state. In a separate live-authorized activation, compute `stored + 1`, reject overflow, require equality with the new compiled generation, then update the singleton.
- Leave the previous generation active when activation sees a wrong compiled generation so it can authorize a repair. Skip operational activation for additive or dependency-only upgrades that do not replace existing guarded bodies.
- Treat the native `UpgradeCap` version and operational package version as independent facts.

### 5. Preserve exits and dependency liveness

- Leave caller-owned inert deletion and self-custodial exits ungated when they mutate no shared state.
- Before activation, prove every dependent route survives the cutover or schedule its explicit package relink. Do not destroy the final upgrade authority while a required dependent still needs relinking or rescue.

### 6. Verify the complete flow

- Test wrong Publisher/module and UpgradeCap/package intake, capability non-release, digest and receipt binding, accepted-authority success and rejection, revocation, quorum or delay behavior when applicable, policy narrowing, and framework version advancement.
- Test bad compiled generations, overflow, native commit without activation, additive and dependency-only behavior, and old-version rejection at every shared-state mutator.
- Test dependent relinking plus every required exit, settlement, cleanup, retry, cancellation, rotation, and recovery path across the cutover.

## Handle already-published gaps

- Do not suggest rerunning `init`. A missing `Publisher` claim cannot be added later in the same package lineage because module initializers do not rerun on upgrade.
- Do not claim that adding a version check only to new bytecode disables old bytecode. Use a pre-existing shared-state seam that every old mutator already checks, or migrate into new state or a new package lineage and retire the old mutation surface.
- Permit later `UpgradeCap` custody only when the cap is still available and the intake can prove the current cap belongs to the intended lineage. Do not reuse an original-package equality check after a raw upgrade has changed the cap's current package ID.
- Report an unrepairable old-version path explicitly as residual risk. Do not present the pre-publication method as a retroactive fix.

## Report proportionately

Report a confirmed finding only when the chosen posture contradicts accepted intent or creates a concrete safety, custody, liveness, compatibility, or public-claim failure. Otherwise report the missing roadmap, cap-custody record, Publisher use, or immutability evidence as a question or validation gap. Do not equate architectural completeness with maximum machinery.
