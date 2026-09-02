---
name: sui-move-guide
description: Route Sui Move engineering tasks to the smallest applicable skill sequence. Use when a developer asks which Sui Move standard applies, wants help routing a Move task, needs object-model or deployed-bytecode guidance, or wants the complete Sui Move development flow.
---

# Sui Move Guide

Route the task to the smallest set of Sui Move skills that covers the risk. This skill is an explicit catalog, not a coding standard by itself.

## Establish the evidence base

1. Read repository instructions, accepted design records, manifests, lockfiles, and published compatibility commitments.
2. Record `sui --version` and resolve the exact compiler, edition, framework source, environment, and dependency mapping used by the target package.
3. When the installed CLI exposes `sui prompt`, use its bundled skills as version-matched first-party discovery. Verify each adopted claim against the pinned source, target network support, and `ProtocolConfig`; bundled or online guidance does not override the package pin.
4. Use current official docs and immutable upstream source when pinned evidence is unavailable. Treat examples for a newer revision as discovery only.

## Skills

- `$sui-move-architecture`: package boundaries, module responsibilities, minimal state, ownership modes, canonical authority, dependency direction, on-chain scope, abilities, capabilities, object storage, transfer and receive paths, and cross-package seams.
- `$sui-move-source-style`: module and function names, file sections, imports, visibility, `self` receiver naming, receiver syntax, direct UID access, pinned framework functions and macros, parameter and local discipline, API vocabulary, docs, and test-only seams.
- `$sui-move-security`: fail-fast ordering, authorization, canonical object and type binding, signed actions, replay, bounded work, arithmetic, custody, external seams, time, oracles, randomness, pause, versioning, and upgrades.
- `$sui-move-events-errors`: completed-fact events, minimal payloads, native metadata, replay schemas, identity, ordering, wrapper/emitter architecture, stable error registries, abort ownership, and compatibility.
- `$sui-move-testing`: risk-based tests, exact failures, guard precedence, stateful hot-potato fixtures, property tests, event replay, published-bytecode and dependency verification, and release gates.
- `$sui-move-review`: one full source or deployed-package audit across all five standards.

## Common routes

### Design a new package or major feature

1. Run `$sui-move-architecture` before defining public ABI or storage.
2. Run `$sui-move-security` before settling authority, lifecycle, or economic transitions.
3. Apply `$sui-move-source-style` while writing modules.
4. Apply `$sui-move-events-errors` when defining transition diagnostics and indexing ABI.
5. Apply `$sui-move-testing` before implementation is complete.
6. Finish with `$sui-move-review`.

### Change an existing state transition

Apply `$sui-move-security`, `$sui-move-source-style`, and `$sui-move-testing`. Add `$sui-move-events-errors` when event, error, guard precedence, or replay behavior can change. Add `$sui-move-architecture` when state ownership, authority, abilities, visibility, or package boundaries can change.

### Add or change a module, type, or public API

Apply `$sui-move-architecture` and `$sui-move-source-style`. Add `$sui-move-security` for any authority, asset, lifecycle, or shared-state type. Treat existing public function signatures as fixed except for permitted relaxation of generic ability constraints, and treat published struct and enum layouts, including abilities, as fixed; use a new type and explicit migration when stored shape must change.

### Choose object ownership, child storage, or transfer-to-object

Apply `$sui-move-architecture` to select address-owned, party, shared, immutable, wrapped, dynamic-field, object-owned, or derived-object state. Add `$sui-move-security` for caller-selected keys, `Receiving<T>`, shared writes, custody, or authority. Add `$sui-move-testing` before committing a lifecycle or cleanup path.

### Upgrade a package or migrate state

Apply `$sui-move-architecture`, `$sui-move-security`, `$sui-move-source-style`, and `$sui-move-testing`; add `$sui-move-events-errors` when indexed behavior can change. Model the upgrade as a new immutable package version: old versions remain callable, module initializers do not rerun, existing public function signatures stay fixed except for permitted generic-constraint relaxation, struct and enum layouts and abilities stay fixed, dependencies require explicit relinking, and state-shape changes require a new type or a dynamic-extension seam designed before publication. Check the proposed diff against the active `UpgradeCap` policy.

### Add events or errors

Apply `$sui-move-events-errors`, then `$sui-move-testing`. Add `$sui-move-security` when the diagnostic change exposes a new guard, authorization check, or economic transition.

### Audit redundancy or simplify Move code

Apply `$sui-move-architecture` to storage and public seams, `$sui-move-events-errors` to whole events and payload fields, and `$sui-move-source-style` to parameters, helpers, and locals. Apply `$sui-move-testing` before removing a fact or seam. Add `$sui-move-security` when simplification can change guards, authority, assets, or evaluation order.

### Build or repair tests

Apply `$sui-move-testing`. Also apply the skill that owns the behavior under test; tests must prove the rule, not invent it.

### Review a branch or pull request

Use `$sui-move-review`. It loads all five standards and reports findings by severity.

### Audit a deployed package

Use `$sui-move-review` and `$sui-move-testing`. Record the network, package ID, and Sui CLI version; inspect package summaries and disassembled bytecode; run `sui client verify-source` when publication metadata and source are available; then compare the executed ABI, abilities, dependencies, and reachable transitions with the claimed source and release commitments.

## Routing rule

When uncertain, include security and testing. Do not load every skill for a narrow naming question, and do not treat source style as a substitute for architecture or security.
