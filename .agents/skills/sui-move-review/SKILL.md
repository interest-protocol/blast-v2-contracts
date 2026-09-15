---
name: sui-move-review
description: Audit Sui Move pull requests, branches, packages, deployments, upgrades, or releases across architecture, source, security, and testing. Use for a comprehensive review; use a focused skill for a narrow domain review. Requires the complete suite installation.
---

# Sui Move Review

Perform one evidence-based review across the complete standard.

## Require the complete suite

Treat this review orchestrator as suite-only, not standalone. Before reviewing,
verify that every sibling standard listed below is installed. If any is missing,
stop and tell the user to install the complete suite; do not reconstruct or skip
the missing standard.

## Load the standards

Read these sibling skills completely before reviewing. Read each standard once
per task; do not reload one that is already present, complete, and unchanged:

1. [sui-move-architecture](../sui-move-architecture/SKILL.md)
2. [sui-move-source-style](../sui-move-source-style/SKILL.md)
3. [sui-move-security](../sui-move-security/SKILL.md)
4. [sui-move-testing](../sui-move-testing/SKILL.md)

Read [Package upgrade posture](references/package-upgrade-posture.md)
completely when the target is unpublished or the review concerns publication,
deployment, upgrades, immutability claims, package-capability custody, or
operational versioning. Also read it when the evidence does not establish one
of the three postures. Otherwise apply the classification in review step 1
without loading the reference.

Read the target repository instructions, package manifest, relevant design
records, implementation, tests, and structural gates. Evidence gathering is
complete when every changed file and transitive caller that can affect an
invariant has been inspected or named as inaccessible. Treat reference
repositories as evidence, not authority over the target's accepted protocol
decisions.

## Review in this order

1. Establish intended behavior, assets and invariants, threat assumptions,
   required liveness and exits, publication status, and compatibility boundary.
   Classify package upgrade posture before deciding which upgrade machinery is
   required. This baseline is complete when every changed behavior has an
   accepted contract or a named evidence gap.
2. Apply architecture to on-chain scope, invariant ownership, state and
   authority boundaries, dependency direction, public seams, storage, and
   redundancy. This pass is complete when each affected fact has a named
   authority and consumer.
3. Search callers and apply security to every changed or transitively affected
   transition and reachable composition. Trace guards, dependency reads,
   proposed values, postconditions, effects, asset movement, emission, and
   returns in execution order. This pass is complete when every reachable path
   preserves its invariants and every applicable economic identity reconciles.
4. Apply source style to the affected production and test code. Preserve
   observable ordering and published compatibility while simplifying. This pass
   is complete when every changed declaration and function has been checked.
5. Apply architecture's event guidance and source style's error guidance to
   emitted facts, replay, payload necessity, abort ownership, diagnostic
   identity, precedence, and compatibility. This pass is complete when every
   changed event and abort path has an authoritative meaning and test oracle.
6. Apply testing to every risk identified by the other standards. Require
   evidence for relevant positive, negative, boundary, stateful, adversarial,
   replay, integration, upgrade, and dependency behavior. This pass is complete
   when each identified risk maps to passing evidence or a reported gap.
7. Run the repository's pinned build, lint, test, source-boundary, ABI,
   dependency, coverage, and diff gates when available. Validation is complete
   when every available gate passes and every unavailable gate is reported.

## Report findings

Lead with actionable findings ordered by severity. For each finding, include:

- exact file and tight line range;
- violated invariant or published contract;
- concrete failure or exploit path;
- smallest correct remediation;
- missing regression test when applicable.

Do not report personal style preferences as defects. Do not recommend a new abstraction without a concrete requirement. Distinguish confirmed defects from questions and evidence gaps.

After findings, list residual validation gaps or state that none remain. If there are no actionable findings, say so directly and summarize which gates and risk surfaces were checked.
