---
name: sui-move-review
description: Audit Sui Move source or deployed bytecode against the complete engineering standard. Use for pull-request, branch, diff, package, module, deployed-package, security, architecture, event, error, test, or release-readiness reviews that need all suite conventions applied together.
---

# Sui Move Review

Perform one evidence-based review across the complete standard.

## Load the standards

Read these sibling skills completely before reviewing:

1. [sui-move-architecture](../sui-move-architecture/SKILL.md)
2. [sui-move-source-style](../sui-move-source-style/SKILL.md)
3. [sui-move-security](../sui-move-security/SKILL.md)
4. [sui-move-events-errors](../sui-move-events-errors/SKILL.md)
5. [sui-move-testing](../sui-move-testing/SKILL.md)

Read the target repository instructions, package manifest, relevant design records, implementation, tests, and structural gates. Treat reference repositories and bundled CLI guidance as evidence, not authority over the target's accepted protocol decisions. For a deployed package, record the network, package ID, original lineage, and Sui CLI version; inspect fetched bytecode and its package summary or disassembly as execution authority.

## Review in this order

1. Establish intended behavior, assets and invariants, threat assumptions, required liveness and exits, and the published compatibility boundary.
2. For an upgrade, compare against the published package and active `UpgradeCap` policy: existing public function signatures must remain unchanged except for permitted relaxation of generic ability constraints; struct and enum layouts and abilities must remain unchanged; module initializers must not be relied on; old package versions must remain safe or be operationally gated; and state-shape changes must use a new type and an authorized migration or a dynamic-extension seam designed before publication.
3. Map package and module responsibilities, object ownership and sequencing mode, state ownership, dependency direction, and every authority issuance and custody-changing path.
4. Run a redundancy pass over stored fields, event types and fields, public seams, parameters, helpers, and locals. Name each fact's authority and consumer; preserve type/ability boundaries and replay-critical redundancy.
5. Search callers and trace every changed or transitively affected production transition through canonical object and generic type binding, target-valid `TxContext` signatures, fail-fast guards, read-only dependency data, proposed values, postconditions, effectful handoffs, mutation, asset movement, emission, and returns.
6. Reconcile arithmetic, rounding, balances, fees, burns, refunds, and residuals.
7. Check event replay, native positions and watermarks, gap-free live/backfill handoff, archival retention, payload necessity, error ownership, abort location, and guard precedence.
8. Check naming, sections, imports, visibility, abilities, signatures, `self` receiver naming, receiver syntax, direct UID access, pinned framework reuse, macro choices, local usage, and test-only seams. For bytecode, verify the actual public and entry surface, abilities, layouts, dependencies, initializers, and absence of leaked test helpers.
9. Check test evidence across positive, negative, boundary, stateful invariant, ownership-mode, receive and derived-object lifecycle, adversarial composition, signatures, time, oracle, randomness, hostile-asset, replay, emergency, upgrade, and dependency risks.
10. Run the relevant pinned build, lint, test, source-boundary, ABI, dependency, coverage, source-verification, and diff checks when available. Treat `verify-source` as deployed root bytecode and linkage evidence, not a correctness audit or recursive dependency verification.

## Report findings

Lead with actionable findings ordered by severity. For each finding, include:

- exact file and tight line range;
- violated invariant or published contract;
- concrete failure or exploit path;
- smallest correct remediation;
- missing regression test when applicable.

Do not report personal style preferences as defects. Do not recommend a new abstraction without a concrete requirement. Distinguish confirmed defects from questions and evidence gaps.

After findings, list residual validation gaps or state that none remain. If there are no actionable findings, say so directly and summarize which gates and risk surfaces were checked.
